import Foundation
import SwiftData

/// The local store's container (A3, #78): SwiftData, one store file per account, kept out of
/// backups and protected like the rest of her health record.
///
/// **The server is the copy of record.** The store is a cache — wiped on log-out and account
/// deletion — and it must never become a second, backup-restorable copy of her health data
/// (§8.2, the same rule the Keychain token follows). The file sits in Application Support
/// with `NSFileProtectionCompleteUntilFirstUserAuthentication` (background sync must be able
/// to open it after a reboot-and-unlock) and is excluded from iCloud and iTunes backup.
///
/// This type is the store's vocabulary — rows and the queue. What a *write* means (which
/// operation it queues, what an acknowledgement does to the row) is `EventSync`'s.
@MainActor
final class EvaStore {

    let container: ModelContainer
    let uid: String

    private var context: ModelContext { container.mainContext }

    /// A uid that is not a plain identifier is refused before it becomes part of a path.
    struct InvalidUID: Error {}

    init(uid: String, inMemory: Bool = false) throws {
        guard Self.isValid(uid: uid) else { throw InvalidUID() }
        self.uid = uid
        let schema = Schema([LocalEvent.self, PendingOperation.self, LocalRefdata.self])
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: Self.url(for: uid))
        if !inMemory { Self.prepareDirectory() }
        container = try ModelContainer(for: schema, configurations: [configuration])
        if !inMemory { Self.harden(Self.url(for: uid)) }
    }

    /// `[A-Za-z0-9_-]+` — what a Firebase uid is, and nothing that could walk a path.
    nonisolated static func isValid(uid: String) -> Bool {
        !uid.isEmpty && uid.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
    }

    /// `Application Support/EvaStore/` — a directory of its own, so backup exclusion is set
    /// once on the directory and covers every file SQLite creates in it later (`-wal`,
    /// `-shm`), not only the ones that existed when the store was opened.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EvaStore", isDirectory: true)
    }

    private static func prepareDirectory() {
        var directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
    }

    /// The one store file, keyed to the uid so a second account on the same device starts
    /// empty rather than reading the previous account's events.
    static func url(for uid: String) -> URL {
        directory.appendingPathComponent("eva-\(uid).store")
    }

    /// File protection and backup exclusion, applied to the store file and its supporting
    /// files. Best-effort: a failure here is a device-level fault with no screen, and the
    /// Keychain's equivalent is handled the same way.
    private static func harden(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (
            try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        ) ?? []
        for file in files where file.lastPathComponent.hasPrefix(url.lastPathComponent) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = file
            try? mutable.setResourceValues(values)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path
            )
        }
    }

    /// Empties the store — every row and the whole queue — without closing it.
    func reset() {
        try? context.delete(model: LocalEvent.self)
        try? context.delete(model: PendingOperation.self)
        try? context.delete(model: LocalRefdata.self)
        try? context.save()
    }

    /// Whether this store is the given account's (§8.5: a mismatch wipes).
    func belongsTo(_ other: String) -> Bool { uid == other }

    /// Removes every store file on the device — whatever account it belonged to — except
    /// `keeping`'s. The `EVA_UITEST_RESET` path wipes them all (§8.5: the hook's contract is
    /// "a fresh install", and a fresh install has no store); opening an account's store
    /// wipes every *other* account's, so a second account on this device starts empty and
    /// the first account's health data does not linger beside it.
    ///
    /// SQLite's `-wal` and `-shm` companions go too. Removing only `.store` would leave a
    /// write-ahead log behind for the next file at the same path to replay.
    static func wipeAll(keeping: String? = nil) {
        // The first builds of #78 wrote straight into Application Support; their files are
        // swept from there too.
        let legacy = directory.deletingLastPathComponent()
        let files = [directory, legacy].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        let kept = keeping.map { url(for: $0).lastPathComponent }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("eva-"), name.contains(".store") else { continue }
            if let kept, name.hasPrefix(kept) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Whether any store file exists for `uid` — what the reset tests read.
    static func fileExists(for uid: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: uid).path)
    }

    func save() { try? context.save() }

    // MARK: - Reads

    /// The local events in a `localDate` range, excluding soft-deleted rows — the same
    /// predicate the API's range read applies (§8.3). Returns them unsorted; the caller
    /// orders by `loggedAt`, as the server does.
    func localEvents(from: EvaDay, through to: EvaDay) -> [LocalEvent] {
        rows(from: from, through: to).filter { $0.deletedAt == nil }
    }

    /// Every row in a range, soft-deleted ones included — what a reconcile compares against.
    func rows(from: EvaDay, through to: EvaDay) -> [LocalEvent] {
        let fromISO = from.isoDate
        let toISO = to.isoDate
        let descriptor = FetchDescriptor<LocalEvent>(
            predicate: #Predicate { $0.localDate >= fromISO && $0.localDate <= toISO }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every live (not soft-deleted) row.
    func liveEvents() -> [LocalEvent] {
        let descriptor = FetchDescriptor<LocalEvent>(predicate: #Predicate { $0.deletedAt == nil })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The rows the "Couldn't sync" card is about.
    func failedEvents() -> [LocalEvent] {
        let failed = SyncState.failed.rawValue
        let descriptor = FetchDescriptor<LocalEvent>(predicate: #Predicate { $0.syncState == failed })
        return (try? context.fetch(descriptor)) ?? []
    }

    func row(clientId: String) -> LocalEvent? {
        var descriptor = FetchDescriptor<LocalEvent>(predicate: #Predicate { $0.clientId == clientId })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func rows(serverId: String) -> [LocalEvent] {
        let descriptor = FetchDescriptor<LocalEvent>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The row a screen means by an `EvaEvent.id` — a `clientId` for an entry logged here,
    /// the server's id for one that arrived from it (`LocalEvent.displayId`).
    func row(forID id: String) -> LocalEvent? {
        if let row = row(clientId: id), row.displayId == id { return row }
        let byServer = rows(serverId: id)
        return byServer.first { $0.deletedAt == nil } ?? byServer.first ?? row(clientId: id)
    }

    func insert(_ event: LocalEvent) { context.insert(event) }

    func delete(_ event: LocalEvent) { context.delete(event) }

    // MARK: - The queue

    /// Every queued operation, in FIFO order.
    func operations() -> [PendingOperation] {
        let descriptor = FetchDescriptor<PendingOperation>(sortBy: [SortDescriptor(\.sequence)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The queued operations for one entry, in FIFO order.
    func operations(for clientId: String) -> [PendingOperation] {
        let descriptor = FetchDescriptor<PendingOperation>(
            predicate: #Predicate { $0.clientId == clientId },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func remove(_ operation: PendingOperation) { context.delete(operation) }

    /// The next FIFO sequence number, drawn from the highest one already in the queue.
    func nextSequence() -> Int {
        var descriptor = FetchDescriptor<PendingOperation>(
            sortBy: [SortDescriptor(\.sequence, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let highest = (try? context.fetch(descriptor).first?.sequence) ?? 0
        return highest + 1
    }

    /// Appends one operation to the queue, then persists. The caller has already written the
    /// store row it depends on — the queue is the *second* half of "write the store first".
    func enqueue(
        _ kind: OperationKind,
        clientId: String,
        serverId: String? = nil,
        payloadData: Data? = nil,
        timeZone: String? = nil
    ) {
        let operation = PendingOperation(
            sequence: nextSequence(),
            kind: kind,
            clientId: clientId,
            serverId: serverId,
            payloadData: payloadData,
            timeZone: timeZone
        )
        context.insert(operation)
        try? context.save()
    }

    /// Inserts one event in `pendingCreate` state and queues its create — the "log an
    /// entry" path (§8.4) at its most basic. Returns the row, so the caller can read the
    /// `clientId` that is also the `idempotencyKey`.
    func upsertPendingCreate(
        clientId: String,
        localDate: String,
        loggedAt: String,
        type: String,
        payloadData: Data,
        note: String?,
        source: String
    ) -> LocalEvent {
        let event = LocalEvent(
            clientId: clientId,
            localDate: localDate,
            loggedAt: loggedAt,
            type: type,
            payloadData: payloadData,
            note: note,
            source: source,
            syncState: .pendingCreate
        )
        context.insert(event)
        try? context.save()
        enqueue(.create, clientId: clientId)
        return event
    }

    // MARK: - Reference data (§8.3)

    /// The cached `/refdata` document, if there is one.
    func refdata() -> LocalRefdata? {
        var descriptor = FetchDescriptor<LocalRefdata>()
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Replaces the cached `/refdata` document.
    func saveRefdata(version: String, data: Data) {
        if let existing = refdata() {
            existing.version = version
            existing.data = data
        } else {
            context.insert(LocalRefdata(version: version, data: data))
        }
        try? context.save()
    }
}

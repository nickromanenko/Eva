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
@MainActor
final class EvaStore {

    let container: ModelContainer
    private let uid: String

    init(uid: String, inMemory: Bool = false) throws {
        self.uid = uid
        let schema = Schema([LocalEvent.self, PendingOperation.self])
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: Self.url(for: uid))
        container = try ModelContainer(for: schema, configurations: [configuration])
        if !inMemory { Self.harden(Self.url(for: uid)) }
    }

    /// The one store file, keyed to the uid so a second account on the same device starts
    /// empty rather than reading the previous account's events.
    private static func url(for uid: String) -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return directory.appendingPathComponent("eva-\(uid).store")
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

    /// Wipes the store — the log-out, account-deletion and `EVA_UITEST_RESET` path (§8.5).
    func reset() {
        let context = container.mainContext
        try? context.delete(model: LocalEvent.self)
        try? context.delete(model: PendingOperation.self)
        try? context.save()
    }

    /// A new account on the same device starts empty: the store is keyed to the uid, so a
    /// store file for a different uid is the caller's signal to wipe before switching.
    func belongsTo(_ other: String) -> Bool { uid == other }

    /// Wipes every store file, whatever account it belonged to — the `EVA_UITEST_RESET`
    /// path (§8.5), whose contract is "a fresh install", and a fresh install has no store.
    static func wipeAll() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let files = (
            try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        ) ?? []
        for file in files where file.lastPathComponent.hasPrefix("eva-") && file.pathExtension == "store" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Reads

    /// The local events in a `localDate` range, excluding soft-deleted rows — the same
    /// predicate the API's range read applies (§8.3). Returns them unsorted; the caller
    /// orders by `loggedAt`, as the server does.
    func localEvents(from: EvaDay, through to: EvaDay) -> [LocalEvent] {
        let fromISO = from.isoDate
        let toISO = to.isoDate
        let descriptor = FetchDescriptor<LocalEvent>(
            predicate: #Predicate {
                $0.localDate >= fromISO && $0.localDate <= toISO && $0.deletedAt == nil
            }
        )
        return (try? container.mainContext.fetch(descriptor)) ?? []
    }

    // MARK: - Writes (write-through + queue)

    /// The next FIFO sequence number, drawn from the highest one already in the queue.
    func nextSequence() -> Int {
        let descriptor = FetchDescriptor<PendingOperation>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        let highest = (try? container.mainContext.fetch(descriptor).first?.sequence) ?? 0
        return highest + 1
    }

    /// Appends one operation to the queue, then persists. The caller has already written the
    /// store row it depends on — the queue is the *second* half of "write the store first".
    func enqueue(
        _ kind: OperationKind,
        clientId: String,
        serverId: String? = nil,
        payloadData: Data? = nil
    ) {
        let operation = PendingOperation(
            sequence: nextSequence(),
            kind: kind,
            clientId: clientId,
            serverId: serverId,
            payloadData: payloadData
        )
        container.mainContext.insert(operation)
        try? container.mainContext.save()
    }

    /// Inserts (or re-inserts) one event in `pendingCreate` state and queues its create — the
    /// "log an entry" path (§8.4). Returns the row, so the caller can read the `clientId` that
    /// is also the `idempotencyKey`.
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
        container.mainContext.insert(event)
        try? container.mainContext.save()
        enqueue(.create, clientId: clientId, payloadData: payloadData)
        return event
    }
}

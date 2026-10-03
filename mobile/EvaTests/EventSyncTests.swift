import Foundation
import SwiftData
import Testing

@testable import Eva

/// ARCHITECTURE §8's rules, one test (or more) each, against the store and the queue (#78).
///
/// In-memory stores around `RecordingCalendarSource`, so the claims are about what reached
/// the "server" and in what order — the same seam the calendar's own suites use. The
/// `AppSession` half (log out, a 401, account deletion, Continue offline, the refdata
/// handshake, a timed-out create) is in `OfflineSessionTests`, which needs the stubbed
/// `URLSession`.
@Suite("Issue #78 · the local store and the sync queue (ARCHITECTURE §8)")
@MainActor
struct EventSyncTests {

    static let day = EvaDay(year: 2026, month: 9, day: 1)
    static let run = EvaSportPayload(activity: "run", durationMin: 20, intensity: .medium)

    static func write(
        _ payload: EvaEventPayload = .sport(run),
        on day: EvaDay = day,
        key: String = UUID().uuidString,
        timeZone: String = TimeZone.current.identifier
    ) -> EvaEventWrite {
        EvaEventWrite(payload: payload, localDate: day, idempotencyKey: key, timeZone: timeZone)
    }

    static func serverEvent(
        _ id: String,
        on day: EvaDay = day,
        detail: EvaEventDetail = .sport(run),
        key: String? = nil,
        loggedAt: String = "2026-09-01T09:00:00"
    ) -> EvaEvent {
        EvaEvent(id: id, detail: detail, localDate: day, loggedAt: loggedAt, idempotencyKey: key)
    }

    let source = RecordingCalendarSource()
    let sync: EventSync

    init() {
        sync = EventSync.inMemory(remote: source)
    }

    private func entries(on day: EvaDay = day) -> [EvaEvent] { sync.eventsByDay()[day] ?? [] }

    // MARK: - §8.1 / §8.4 · write the store first; the screen reads the store

    @Test("§8.4 · a logged entry is in the store before anything is sent, keyed by its idempotencyKey")
    func writeLandsInTheStoreFirst() throws {
        source.writeFailure = APIError.network
        let draft = Self.write()

        let saved = try #require(sync.save(draft))

        #expect(entries().map(\.id) == [saved.id])
        let row = try #require(sync.store.row(clientId: draft.idempotencyKey))
        #expect(row.state == .pendingCreate)
        #expect(row.serverId == nil)
        #expect(sync.store.operations().map(\.kind) == ["create"])
    }

    @Test("an entry logged here keeps one id on screen before and after the server answers")
    func displayIdIsStable() async throws {
        let saved = try #require(sync.save(Self.write()))
        await sync.drain()
        #expect(entries().map(\.id) == [saved.id], "The row re-identified when the create was acknowledged")
        #expect(sync.store.row(forID: saved.id)?.serverId == source.events.first?.id)
    }

    @Test("§8.4 · an acknowledged create writes serverId and goes synced")
    func acknowledgementSyncs() async throws {
        let draft = Self.write()
        sync.save(draft)

        await sync.drain()

        let row = try #require(sync.store.row(clientId: draft.idempotencyKey))
        #expect(row.state == .synced)
        #expect(row.serverId == source.events.first?.id)
        #expect(sync.store.operations().isEmpty)
        #expect(source.writes.map(\.idempotencyKey) == [draft.idempotencyKey],
                "The create was not sent with the device's clientId as its idempotencyKey")
    }

    // MARK: - §8.4 · FIFO, never reordered

    @Test("§8.4 · create, edit and delete go out in the order they were made")
    func theQueueIsFifo() async throws {
        source.writeFailure = APIError.network
        let created = try #require(sync.save(Self.write()))
        sync.save(Self.write(.sport(EvaSportPayload(activity: "run", durationMin: 45, intensity: .hard))),
                  editing: created.id)
        sync.delete(created)
        await sync.drain()
        #expect(source.events.isEmpty)

        source.writeFailure = nil
        await sync.drain()

        // The failed attempts are the first create, retried; then the three in order.
        #expect(source.log.drop { $0 == "create" } == ["patch", "delete"])
        #expect(source.log.last(where: { $0 == "create" }) != nil)
        #expect(source.events.isEmpty, "The delete did not follow the create")
    }

    @Test("§8.4 · an edit carries type and localDate, and patches the server's id")
    func anEditCarriesTypeAndDate() async throws {
        let created = try #require(sync.save(Self.write()))
        await sync.drain()
        let serverId = try #require(source.events.first?.id)

        sync.save(Self.write(.sport(EvaSportPayload(activity: "run", durationMin: 60, intensity: .hard))),
                  editing: created.id)
        await sync.drain()

        #expect(source.patchedIds == [serverId])
        let patch = try #require(source.writes.last)
        #expect(patch.type == .sport)
        #expect(patch.localDate == Self.day)
    }

    @Test("§8.4 · body signals for a day go through the day-addressed upsert")
    func bodySignalsUpsert() async {
        sync.save(Self.write(.bodySignals(EvaBodySignalsPayload(energy: 3))))
        await sync.drain()
        #expect(source.bodySignalWrites.map(\.localDate) == [Self.day])
    }

    @Test("§8.4 · a delete takes the row off the screen now and sends DELETE later")
    func deleteIsLocalFirst() async throws {
        let created = try #require(sync.save(Self.write()))
        await sync.drain()
        let serverId = try #require(source.events.first?.id)
        source.writeFailure = APIError.network

        sync.delete(try #require(entries().first))

        #expect(entries().isEmpty)
        #expect(sync.store.row(clientId: created.idempotencyKey ?? "")?.state == .pendingDelete)
        source.writeFailure = nil
        await sync.drain()
        #expect(source.deletedIds.last == serverId)
    }

    @Test("§8.4 · Undo while the delete is still queued removes it — nothing is sent")
    func undoWithdrawsAQueuedDelete() async throws {
        sync.save(Self.write())
        await sync.drain()
        let entry = try #require(entries().first)
        source.writeFailure = APIError.network
        sync.delete(entry)

        sync.restore(entry)
        source.writeFailure = nil
        await sync.drain()

        #expect(source.deletedIds.isEmpty, "A delete withdrawn by Undo was sent anyway")
        #expect(source.restoredIds.isEmpty, "A delete that never went was 'restored'")
        #expect(entries().map(\.id) == [entry.id])
        #expect(sync.store.operations().isEmpty)
    }

    @Test("§8.4 · Undo after the delete went sends a restore")
    func undoAfterTheDeleteRestores() async throws {
        sync.save(Self.write())
        await sync.drain()
        let entry = try #require(entries().first)
        let serverId = try #require(source.events.first?.id)
        source.restorable[serverId] = source.events.first
        sync.delete(entry)
        await sync.drain()
        #expect(source.deletedIds == [serverId])
        // A range read after the delete landed must not cost Undo its row.
        sync.reconcile([], from: Self.day, through: Self.day)

        sync.restore(entry)
        await sync.drain()

        #expect(source.restoredIds == [serverId])
        #expect(entries().count == 1)
    }

    // MARK: - §8.4 · what a failure does

    @Test("§8.4 · a 4xx marks the row failed with the API's code and the queue moves on")
    func aClientErrorFailsAndMovesOn() async throws {
        source.writeFailure = APIError.server(code: "VALIDATION", message: "x", status: 400)
        let refused = Self.write()
        sync.save(refused)
        await sync.drain()

        let row = try #require(sync.store.row(clientId: refused.idempotencyKey))
        #expect(row.state == .failed)
        #expect(row.lastError == "VALIDATION")
        #expect(sync.failedCount == 1)
        #expect(sync.store.operations().isEmpty, "A refused operation stayed at the head of the queue")
    }

    @Test("§8.4 · a 5xx blocks the queue — nothing behind it is sent out of order")
    func aServerErrorBlocks() async {
        source.writeFailure = APIError.server(code: "INTERNAL", message: "x", status: 503)
        sync.save(Self.write())
        sync.save(Self.write(on: Self.day.adding(days: -1)))
        await sync.drain()

        #expect(source.writes.count == 1, "The second entry was sent while the first was failing")
        #expect(sync.store.operations().count == 2)
        #expect(sync.failedCount == 0, "A 5xx was treated as a refusal")
    }

    @Test("§8.4 · a 401 pauses the queue and discards nothing")
    func aDeadSessionPauses() async {
        source.writeFailure = APIError.sessionExpired(message: "x")
        sync.save(Self.write())
        await sync.drain()

        #expect(sync.store.operations().count == 1)
        #expect(sync.store.operations().first?.attempts == 0, "A pause was counted as a failed attempt")
        #expect(entries().count == 1)
    }

    @Test("§8.4 · the wait after a network failure is the backoff schedule's")
    func networkFailureBacksOff() async throws {
        source.writeFailure = APIError.network
        sync.save(Self.write())
        await sync.drain()
        await sync.drain()

        let head = try #require(sync.store.operations().first)
        #expect(head.attempts == 2)
        #expect(syncBackoff(attempts: 0) == 1 && syncBackoff(attempts: 1) == 2)
    }

    // MARK: - The "Couldn't sync" card's two variants (owner decision, 2026-10-03)

    @Test("the card's wording follows the failure class")
    func troubleFollowsTheFailureClass() {
        #expect(SyncTrouble(syncOutcome(for: .network)) == .temporary)
        #expect(SyncTrouble(syncOutcome(for: .server(code: "INTERNAL", message: "x", status: 503))) == .temporary)
        #expect(SyncTrouble(syncOutcome(for: .rateLimited(message: "x", retryAt: nil))) == .temporary)
        #expect(SyncTrouble(syncOutcome(for: .server(code: "VALIDATION", message: "x", status: 400))) == .rejected)
        #expect(SyncTrouble(syncOutcome(for: .sessionExpired(message: "x"))) == nil)
        #expect(SyncTrouble.temporary.message.contains("Eva will retry automatically."))
        #expect(SyncTrouble.rejected.message == "This entry couldn't be saved. Check it and try again.")
    }

    @Test("a queue backing off shows the temporary card; a refused entry shows the rejected one")
    func troubleFollowsTheQueue() async {
        #expect(sync.trouble == nil)
        source.writeFailure = APIError.network
        sync.save(Self.write())
        await sync.drain()
        #expect(sync.trouble == .temporary)

        source.writeFailure = APIError.server(code: "VALIDATION", message: "x", status: 400)
        await sync.drain()
        #expect(sync.trouble == .rejected)

        source.writeFailure = nil
        sync.retryFailed()
        await sync.drain()
        #expect(sync.trouble == nil, "The card stayed up after the entry synced")
    }

    /// #382: the live card reads `EventSync.trouble`, not `SyncTrouble.init(_:)` — which has
    /// no caller in the app. A 5xx and a 429 are each a temporary failure *there*, through
    /// the engine's backoff, and neither marks the entry refused.
    @Test("a 5xx shows the temporary card through EventSync.trouble",
          arguments: [500, 502, 503])
    func aServerErrorIsTemporaryTrouble(status: Int) async {
        source.writeFailure = APIError.server(code: "INTERNAL", message: "x", status: status)
        sync.save(Self.write())
        await sync.drain()

        #expect(sync.trouble == .temporary)
        #expect(sync.failedCount == 0, "A \(status) marked the entry refused")
        #expect(sync.trouble?.message == "It's saved on this device. Eva will retry automatically.")
    }

    @Test("a 429 shows the temporary card through EventSync.trouble")
    func aRateLimitIsTemporaryTrouble() async {
        // A minute out, so the retry the engine schedules does not fire inside the test.
        source.writeFailure = APIError.rateLimited(message: "x", retryAt: Date().addingTimeInterval(60))
        sync.save(Self.write())
        await sync.drain()

        #expect(sync.trouble == .temporary)
        #expect(sync.failedCount == 0, "A 429 marked the entry refused")
        #expect(sync.store.operations().count == 1)
    }

    // MARK: - §8.4 · Dates

    @Test("§8.4 · a queued entry is sent with the zone it was logged in")
    func aQueuedEntryKeepsItsZone() async throws {
        source.writeFailure = APIError.network
        sync.save(Self.write(timeZone: "Europe/Lisbon"))
        await sync.drain()
        source.writeFailure = nil
        await sync.drain()

        #expect(source.writes.last?.timeZone == "Europe/Lisbon")
        #expect(source.writes.last?.localDate == Self.day, "The entry's day moved on the way out")
    }

    // MARK: - §8.3 · reads and the reconcile

    @Test("§8.3 · a range read excludes soft-deleted rows")
    func rangeReadExcludesDeleted() async throws {
        sync.reconcile([Self.serverEvent("a"), Self.serverEvent("b")], from: Self.day, through: Self.day)
        sync.delete(try #require(entries().first { $0.id == "a" }))
        #expect(entries().map(\.id) == ["b"])
        #expect(sync.store.localEvents(from: Self.day, through: Self.day).count == 1)
    }

    @Test("§8.3 · a server row replaces a synced local row")
    func serverReplacesSynced() {
        sync.reconcile([Self.serverEvent("a", note: nil)], from: Self.day, through: Self.day)
        let edited = EvaEvent(
            id: "a", detail: .sport(EvaSportPayload(activity: "swim", durationMin: 30, intensity: .light)),
            localDate: Self.day, loggedAt: "2026-09-01T09:00:00", note: "elsewhere"
        )
        sync.reconcile([edited], from: Self.day, through: Self.day)
        #expect(entries().first?.note == "elsewhere")
    }

    @Test("§8.3 · a pending local row is left alone — the server's view is older")
    func pendingIsLeftAlone() async throws {
        sync.reconcile([Self.serverEvent("a")], from: Self.day, through: Self.day)
        let entry = try #require(entries().first)
        source.writeFailure = APIError.network
        sync.save(Self.write(.sport(EvaSportPayload(activity: "run", durationMin: 90, intensity: .hard))),
                  editing: entry.id)

        sync.reconcile([Self.serverEvent("a")], from: Self.day, through: Self.day)

        guard case .sport(let sport) = entries().first?.detail else {
            Issue.record("The entry is not a sport entry any more")
            return
        }
        #expect(sport.durationMin == 90, "A reconcile overwrote an edit that had not been sent")
    }

    @Test("§8.3 · server rows absent locally are inserted; synced rows the server dropped are deleted")
    func insertAndDelete() {
        sync.reconcile([Self.serverEvent("a"), Self.serverEvent("b")], from: Self.day, through: Self.day)
        #expect(Set(entries().map(\.id)) == ["a", "b"])

        // Outside the range read, a row stays whatever the response says.
        let elsewhere = Self.day.adding(days: 40)
        sync.reconcile([Self.serverEvent("c", on: elsewhere)], from: elsewhere, through: elsewhere)

        sync.reconcile([Self.serverEvent("b")], from: Self.day, through: Self.day)
        #expect(entries().map(\.id) == ["b"], "A row deleted elsewhere stayed on this device")
        #expect(entries(on: elsewhere).map(\.id) == ["c"], "A reconcile reached outside its range")
    }

    /// The case §8.3's rules would get wrong taken literally: the create landed, its answer
    /// did not, and the next range read lists it. Inserting it would draw the entry twice.
    @Test("§8.3 · a server row that answers a pending create is not drawn twice")
    func aLostAcknowledgementIsNotADuplicate() throws {
        source.writeFailure = APIError.network
        let draft = Self.write()
        sync.save(draft)

        sync.reconcile(
            [Self.serverEvent("srv", key: draft.idempotencyKey)], from: Self.day, through: Self.day
        )

        #expect(entries().count == 1)
        #expect(sync.store.row(clientId: draft.idempotencyKey)?.serverId == "srv",
                "The row did not learn the id its create already has")
    }

    @Test("§8.3 · a pending one-per-day entry is not doubled by the server's copy of the day")
    func onePerDayPendingWins() {
        source.writeFailure = APIError.network
        sync.save(Self.write(.cycle(.flow(.heavy))))
        sync.reconcile(
            [Self.serverEvent("cycle_2026-09-01", detail: .cycle(.flow(.light)))],
            from: Self.day, through: Self.day
        )
        #expect(entries().count == 1)
        guard case .cycle(let mark) = entries().first?.detail else {
            Issue.record("The day lost its cycle entry")
            return
        }
        #expect(mark == .flow(.heavy), "The server's older copy replaced her pending entry")
    }

    // MARK: - §8.2 · what is stored

    @Test("§8.2 · a row mirrors the wire event field for field")
    func rowMirrorsTheWire() throws {
        let event = EvaEvent(
            id: "srv", detail: .appointment(EvaAppointmentPayload(startAt: "2026-09-01T10:30", questions: ["q"])),
            localDate: Self.day, loggedAt: "2026-09-01T08:00:00", note: "n", source: .user, idempotencyKey: "k"
        )
        sync.reconcile([event], from: Self.day, through: Self.day)
        let row = try #require(sync.store.row(clientId: "k"))
        #expect(row.serverId == "srv")
        #expect(row.localDate == "2026-09-01")
        #expect(row.loggedAt == "2026-09-01T08:00:00")
        #expect(row.type == "appointment")
        #expect(row.note == "n")
        #expect(row.source == "user")
        #expect(row.evaEvent() == event)
    }

    // MARK: - §8.5 · wipes

    @Test("§8.5 · a wipe empties the store and the queue, and nothing queued is sent")
    func wipeDropsTheQueue() async {
        source.writeFailure = APIError.network
        sync.save(Self.write())
        await sync.drain()
        source.writeFailure = nil

        sync.wipe()
        await sync.drain()

        #expect(entries().isEmpty)
        #expect(sync.store.operations().isEmpty)
        #expect(source.events.isEmpty, "An operation queued before the wipe was sent after it")
    }

    /// #389: closing stops collection, not only sending — a sheet still holding the store
    /// when the session ends must not leave an entry behind on the device.
    @Test("a closed store accepts no write, and reopening it does")
    func aClosedStoreRefusesWrites() throws {
        source.writeFailure = APIError.network
        let kept = try #require(sync.save(Self.write()))
        sync.close()

        #expect(sync.save(Self.write(on: Self.day.adding(days: -1))) == nil)
        sync.delete(kept)
        #expect(sync.restore(kept) == nil)
        sync.retryFailed()

        #expect(sync.store.liveEvents().count == 1)
        #expect(sync.store.operations().map(\.kind) == ["create"])

        sync.reopen()
        #expect(sync.save(Self.write(on: Self.day.adding(days: -2))) != nil)
    }

    @Test("§8.5 · log out names how many entries have not synced")
    func unsyncedCountForLogOut() throws {
        source.writeFailure = APIError.network
        let first = try #require(sync.save(Self.write()))
        sync.save(Self.write(.sport(EvaSportPayload(activity: "run", durationMin: 5, intensity: .light))),
                  editing: first.id)
        sync.save(Self.write(on: Self.day.adding(days: -1)))
        #expect(sync.unsyncedCount == 2, "Two queued operations on one entry counted twice")
        #expect(ProfileView.unsyncedTitle(2) == "2 entries have not synced yet")
        #expect(ProfileView.unsyncedTitle(1) == "1 entry has not synced yet")
    }
}

private extension EventSyncTests {
    static func serverEvent(_ id: String, note: String?) -> EvaEvent {
        EvaEvent(id: id, detail: .sport(run), localDate: day, loggedAt: "2026-09-01T09:00:00", note: note)
    }
}

/// The store file itself (§8.2, §8.5): protection, backups, and the wipes that are file
/// deletions rather than row deletions. On disk, so each test uses its own uid.
@Suite("Issue #78 · the store file", .serialized)
@MainActor
struct EvaStoreFileTests {

    @Test("§8.2 · the store file is excluded from backup")
    func excludedFromBackup() throws {
        let uid = "file-\(UUID().uuidString)"
        defer { EvaStore.wipeAll(keeping: nil) }
        let store = try EvaStore(uid: uid)
        store.insert(LocalEvent(clientId: "c", localDate: "2026-09-01", loggedAt: "2026-09-01T09:00:00",
                                type: "sport", payloadData: Data("{}".utf8)))
        store.save()

        let values = try EvaStore.url(for: uid).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        // The directory carries the exclusion too, so a `-wal` SQLite creates later is
        // covered without anyone re-applying it.
        let directory = try EvaStore.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directory.isExcludedFromBackup == true)
        #expect(EvaStore.url(for: uid).deletingLastPathComponent().lastPathComponent == "EvaStore")
        // File protection is not asserted: the simulator reports no protection class at
        // all, so a check here would never run where this suite runs. The attribute is
        // set in `EvaStore.harden`/`prepareDirectory` and is a device-only property.
    }

    @Test("a uid that is not a plain identifier never becomes a file name")
    func refusesPathLikeUIDs() {
        #expect(EvaStore.isValid(uid: "AbC_12-xy"))
        for bad in ["", "../x", "a/b", "a.b", "a b", "é"] {
            #expect(!EvaStore.isValid(uid: bad), "accepted \(bad)")
            #expect(throws: EvaStore.InvalidUID.self) { try EvaStore(uid: bad, inMemory: true) }
        }
    }

    @Test("§8.5 · opening one account's store wipes every other account's, -wal and -shm included")
    func aSecondAccountStartsEmpty() throws {
        let first = "file-\(UUID().uuidString)"
        let second = "file-\(UUID().uuidString)"
        defer { EvaStore.wipeAll(keeping: nil) }
        do {
            let store = try EvaStore(uid: first)
            store.insert(LocalEvent(clientId: "c", localDate: "2026-09-01", loggedAt: "2026-09-01T09:00:00",
                                    type: "sport", payloadData: Data("{}".utf8)))
            store.save()
        }
        #expect(EvaStore.fileExists(for: first))

        EvaStore.wipeAll(keeping: second)

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: EvaStore.url(for: first).deletingLastPathComponent().path
        ).filter { $0.hasPrefix("eva-\(first)") }
        #expect(leftovers.isEmpty, "The previous account's store survived: \(leftovers)")
    }

    /// Security review follow-up 3 (#378): the first #78 builds wrote into Application
    /// Support itself. A file there is a leftover whoever it belonged to — the signed-in
    /// account's included, since its live store is the one in `EvaStore/`.
    @Test("§8.5 · a #371-era store file at the old location goes, even the kept account's")
    func theOldLocationIsSweptRegardless() throws {
        let uid = "file-\(UUID().uuidString)"
        defer { EvaStore.wipeAll(keeping: nil) }
        let legacy = EvaStore.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let names = ["eva-\(uid).store", "eva-\(uid).store-wal", "eva-\(uid).store-shm"]
        for name in names {
            try Data("x".utf8).write(to: legacy.appendingPathComponent(name))
        }
        _ = try EvaStore(uid: uid)

        EvaStore.wipeAll(keeping: uid)

        let leftovers = names.filter {
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent($0).path)
        }
        #expect(leftovers.isEmpty, "The kept account's old-location files survived: \(leftovers)")
        #expect(EvaStore.fileExists(for: uid), "The kept account's live store was swept with them")
    }

    @Test("§8.5 · EVA_UITEST_RESET's wipe removes every store file")
    func resetRemovesEverything() throws {
        let uid = "file-\(UUID().uuidString)"
        do {
            let store = try EvaStore(uid: uid)
            store.insert(LocalEvent(clientId: "c", localDate: "2026-09-01", loggedAt: "2026-09-01T09:00:00",
                                    type: "sport", payloadData: Data("{}".utf8)))
            store.save()
        }
        EvaStore.wipeAll()
        #expect(!EvaStore.fileExists(for: uid))
    }
}

@Suite("Issue #78 · reading the uid out of the session token")
struct EvaSessionTokenTests {

    @Test("the sub claim of a JWT is the uid")
    func readsSub() {
        // {"alg":"HS256","typ":"JWT"} . {"sub":"uid-123","iat":1}
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1aWQtMTIzIiwiaWF0IjoxfQ.sig"
        #expect(EvaSessionToken.subject(of: token) == "uid-123")
    }

    @Test("a sub that is not a plain identifier is refused")
    func refusesPathLikeSub() {
        // {"sub":"../x"}
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIuLi94In0.sig"
        #expect(EvaSessionToken.subject(of: token) == nil)
    }

    @Test("anything that is not a JWT has no subject")
    func refusesOtherShapes() {
        #expect(EvaSessionToken.subject(of: "a-live-looking-token") == nil)
        #expect(EvaSessionToken.subject(of: "a.b.c") == nil)
    }
}

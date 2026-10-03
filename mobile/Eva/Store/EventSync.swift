import Foundation
import SwiftData

/// The calendar's entries, on the device first (A3, #78, ARCHITECTURE §8).
///
/// **Screens read this; only this talks to the API about events.** A write lands in the
/// store and the queue in the same turn and the screen redraws from the store at once
/// (§8.4); the queue drains in the background through `remote`, FIFO, and a range read
/// refreshes the store by reconciling against `GET /me/events` (§8.3). Nothing a screen
/// does waits on the network.
///
/// `remote` is `AppSession` in the app — it owns the token and the 401 rule, so every
/// request here still goes through `authorized(_:)` — and a recording stub in the tests.
@MainActor
@Observable
final class EventSync {

    let store: EvaStore
    @ObservationIgnored private let remote: any CalendarEventSource
    @ObservationIgnored private var engine: SyncEngine!

    /// Bumped on every change to the rows a screen reads. Screens observe this rather than
    /// the store, so one write is one redraw.
    private(set) var revision = 0

    /// Called after an entry's operation is acknowledged, with its type — the calendar
    /// re-asks for its prediction overlay when a cycle entry reaches the server.
    @ObservationIgnored var onAcknowledged: (@MainActor (EvaEventType) -> Void)?
    /// Called each time the queue empties, which is when §8.3 re-reads the visible range.
    @ObservationIgnored var onDrained: (@MainActor () -> Void)?

    @ObservationIgnored private var drainTask: Task<Drain, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var drainAgain = false
    /// The operation on the wire right now, if any.
    @ObservationIgnored private var sendingSequence: Int?
    @ObservationIgnored private var isClosed = false

    init(store: EvaStore, remote: any CalendarEventSource) {
        self.store = store
        self.remote = remote
        engine = SyncEngine(
            context: store.container.mainContext,
            perform: { [unowned self] operation in try await self.send(operation) },
            failed: { [unowned self] operation, error in self.markFailed(operation, error) }
        )
    }

    /// An in-memory store around `remote` — previews, and every test that builds a
    /// `CalendarModel` without saying which store it reads.
    static func inMemory(remote: any CalendarEventSource, uid: String = "in-memory") -> EventSync {
        // An in-memory SwiftData container cannot fail to open short of the schema itself
        // being invalid, which every test would catch at once.
        // swiftlint:disable:next force_try
        EventSync(store: try! EvaStore(uid: uid, inMemory: true), remote: remote)
    }

    // MARK: - Reading

    /// Every live entry, keyed by day and ordered by `loggedAt` the way `GET /me/events`
    /// orders a day. All of them, not a range: a year of entries is a few hundred rows, and
    /// one read per revision is cheaper than one per cell.
    func eventsByDay() -> [EvaDay: [EvaEvent]] {
        var byDay: [EvaDay: [EvaEvent]] = [:]
        for row in store.liveEvents() {
            guard let event = row.evaEvent() else { continue }
            byDay[event.localDate, default: []].append(event)
        }
        for (day, events) in byDay {
            byDay[day] = events.sorted { ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id) }
        }
        return byDay
    }

    /// Whether the store holds anything at all — the empty state is the empty store (§8.3).
    var isEmpty: Bool { store.liveEvents().isEmpty }

    /// The entries whose last operation the server refused — what "Couldn't sync your last
    /// entry" is about.
    var failedCount: Int {
        _ = revision
        return store.failedEvents().count
    }

    /// How many entries have not reached the server yet. Log out says so (§8.5).
    var unsyncedCount: Int {
        _ = revision
        return Set(store.operations().map(\.clientId)).count
    }

    // MARK: - Writing (§8.4)

    /// Logs or edits one entry: into the store now, onto the queue for later. Returns the
    /// entry as the screens will read it.
    ///
    /// `editing` is the id of the entry being replaced, `nil` for a new one. A one-per-day
    /// type logged again on a day that already has one updates that row, as the server
    /// will update that document — the day never shows two.
    @discardableResult
    func save(_ write: EvaEventWrite, editing id: String? = nil) -> EvaEvent {
        let payloadData = LocalEvent.payloadData(for: write.payload)
        let row: LocalEvent
        let kind: OperationKind
        if let existing = id.flatMap(store.row(forID:)) ?? onePerDayRow(for: write) {
            existing.localDate = write.localDate.isoDate
            existing.type = write.type.rawValue
            existing.payloadData = payloadData
            existing.note = write.note
            row = existing
            // An edit is a PATCH — unless the entry never reached the server and nothing
            // queued will put it there (its create was refused), when it has to be created.
            // A one-per-day re-log is a create either way: the server writes that day's
            // document at its derived id.
            let neverCreated = existing.serverId == nil && !hasQueuedCreate(existing)
            kind = id == nil || neverCreated ? createKind(for: write.type) : .update
        } else {
            row = LocalEvent(
                clientId: unusedClientId(write.idempotencyKey),
                localDate: write.localDate.isoDate,
                loggedAt: Self.wallClock(in: TimeZone(identifier: write.timeZone) ?? .current),
                type: write.type.rawValue,
                payloadData: payloadData,
                note: write.note,
                syncState: .pendingCreate,
                isLocalOrigin: true
            )
            store.insert(row)
            kind = createKind(for: write.type)
        }
        row.lastError = nil
        store.enqueue(kind, clientId: row.clientId, timeZone: write.timeZone)
        refreshState(of: row)
        changed()
        kick()
        // The row was just written from a payload the app built, so it reads back.
        return row.evaEvent() ?? Self.placeholder(for: row, write: write)
    }

    /// Soft-deletes one entry: off the screen now, `DELETE` queued.
    func delete(_ event: EvaEvent) {
        guard let row = store.row(forID: event.id) else { return }
        row.deletedAt = Date()
        store.enqueue(.delete, clientId: row.clientId)
        refreshState(of: row)
        changed()
        kick()
    }

    /// Undo. If the delete has not gone yet it is simply withdrawn from the queue (§8.4);
    /// if it has, a restore is queued instead.
    @discardableResult
    func restore(_ event: EvaEvent) -> EvaEvent? {
        let row: LocalEvent
        if let existing = store.row(forID: event.id) {
            row = existing
            row.deletedAt = nil
            // A delete already on the wire cannot be withdrawn — it may land — so it is
            // answered with a restore like one that went earlier.
            if let queuedDelete = store.operations(for: row.clientId).last(where: {
                $0.operationKind == .delete && $0.sequence != sendingSequence
            }) {
                store.remove(queuedDelete)
            } else {
                store.enqueue(.restore, clientId: row.clientId)
            }
        } else {
            // A reconcile already dropped the row: the delete was acknowledged and the
            // server stopped listing it. The toast still holds the entry, so it comes back
            // from that, and the server is asked to restore it.
            row = LocalEvent.synced(from: event)
            store.insert(row)
            store.enqueue(.restore, clientId: row.clientId)
        }
        refreshState(of: row)
        changed()
        kick()
        return row.evaEvent()
    }

    /// "Retry now" on the "Couldn't sync" card: every refused entry is queued again.
    func retryFailed() {
        for row in store.failedEvents() {
            row.lastError = nil
            let kind: OperationKind
            if row.deletedAt != nil {
                kind = .delete
            } else if row.serverId == nil {
                kind = createKind(for: row.eventType ?? .sport)
            } else {
                kind = .update
            }
            store.enqueue(kind, clientId: row.clientId)
            row.syncState = SyncState.synced.rawValue
            refreshState(of: row)
        }
        changed()
        kick()
    }

    // MARK: - Reading the server (§8.3)

    /// Refreshes one range from `GET /me/events`. Throws what the read threw; the store is
    /// untouched by a failure, so the screen keeps showing what it had.
    ///
    /// Returns how many entries the server listed — the first load's history question.
    @discardableResult
    func refresh(from: EvaDay, through to: EvaDay) async throws -> Int {
        let events = try await remote.events(from: from, through: to)
        guard !isClosed else { return events.count }
        reconcile(events, from: from, through: to)
        return events.count
    }

    /// Reconciles the store with the server's view of a range, by `serverId` (§8.3):
    ///
    /// - a server row replaces a local row in `synced` state;
    /// - a local row in any `pending*` (or `failed`) state is left alone — its operation has
    ///   not been acknowledged, so the server's view is older than the device's;
    /// - a server row absent locally is inserted — unless it is the answer to one of this
    ///   device's own creates whose acknowledgement was lost (same `idempotencyKey`), or a
    ///   one-per-day day she has a pending entry for, either of which would draw it twice;
    /// - a local `synced` row the server no longer lists in the range is deleted, unless
    ///   she deleted it on this device (Undo still needs it).
    func reconcile(_ events: [EvaEvent], from: EvaDay, through to: EvaDay) {
        let local = store.rows(from: from, through: to)
        let listed = Set(events.map(\.id))

        for event in events {
            let matches = local.filter { $0.serverId == event.id }
            if !matches.isEmpty {
                // A pending row owns the document until its operation is acknowledged.
                if matches.contains(where: { $0.state != .synced }) { continue }
                // Listed, so live on the server: the synced row takes the server's copy —
                // including one deleted here and since restored or re-logged elsewhere.
                let kept = matches.first { $0.deletedAt == nil } ?? matches[0]
                kept.absorb(event)
                kept.deletedAt = nil
                for other in matches where other !== kept { store.delete(other) }
                continue
            }
            if let key = event.idempotencyKey, let row = store.row(clientId: key) {
                // Her own entry, created on the server by a send whose answer never came
                // back. The queued create will be answered with this same document; until
                // then the row learns its id so later edits and deletes can address it.
                row.serverId = event.id
                if row.state == .synced { row.absorb(event) }
                continue
            }
            if event.type.isOnePerDay, local.contains(where: {
                $0.deletedAt == nil && $0.type == event.type.rawValue
                    && $0.localDate == event.localDate.isoDate && $0.state != .synced
            }) {
                continue
            }
            store.insert(LocalEvent.synced(from: event))
        }

        // A synced row the server stopped listing was deleted or purged elsewhere — except a
        // row she deleted *here*, which is already off the screen and is kept so Undo can
        // still name the document it restores.
        for row in local where row.state == .synced && row.deletedAt == nil {
            guard let serverId = row.serverId, !listed.contains(serverId) else { continue }
            store.delete(row)
        }
        store.save()
        changed()
    }

    // MARK: - Draining the queue

    /// Starts a drain now, cutting short any backoff in progress — on a write, on
    /// foreground, and when a session comes back.
    func kick() {
        guard !isClosed else { return }
        retryTask?.cancel()
        retryTask = nil
        if drainTask != nil {
            drainAgain = true
            return
        }
        drainTask = Task { [weak self] in
            guard let self else { return Drain(pass: .drained, sent: false) }
            var pass: SyncEngine.Pass
            var sent = false
            repeat {
                drainAgain = false
                if !store.operations().isEmpty { sent = true }
                pass = await engine.drain()
            } while drainAgain && pass == .drained && !isClosed
            return Drain(pass: pass, sent: sent)
        }
        Task { [weak self] in
            guard let self, let task = drainTask else { return }
            let drain = await task.value
            drainTask = nil
            guard !isClosed else { return }
            switch drain.pass {
            case .drained:
                // Only a pass that had something to send ends in `onDrained`: an empty
                // queue "draining" on every foreground would re-read the range for nothing,
                // and a re-read that drains would loop.
                if drain.sent { onDrained?() }
            case .blocked where drainAgain:
                // Something asked for a drain while this pass was failing — a new entry,
                // or the app coming back to the foreground. That ask is worth one attempt
                // now rather than at the end of the backoff.
                drainAgain = false
                kick()
            case .blocked(let wait):
                scheduleRetry(after: wait)
            case .paused:
                break
            }
        }
    }

    /// How one drain ended, and whether it had anything to send.
    private struct Drain {
        let pass: SyncEngine.Pass
        let sent: Bool
    }

    /// Kicks the queue and waits for this pass to finish — what a test awaits, and what a
    /// screen never does.
    func drain() async {
        kick()
        while let task = drainTask { _ = await task.value; await Task.yield() }
    }

    private func scheduleRetry(after wait: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            kick()
        }
    }

    /// Empties the store and stops the queue — log out and account deletion (§8.5). An
    /// operation still queued is dropped, not sent.
    func wipe() {
        isClosed = true
        retryTask?.cancel()
        retryTask = nil
        drainTask?.cancel()
        store.reset()
        changed()
    }

    /// Stops the queue without discarding anything — a 401 sign-out, after which the same
    /// account signing back in picks the queue up where it stopped (§8.4).
    func close() {
        isClosed = true
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Sending

    #if DEBUG
    /// `EVA_SYNC_DROP_ACKS=1` sends every operation and then **discards the answer**, as a
    /// connection that drops after the server has written would. The operation stays queued
    /// and is sent again — the replay the `idempotencyKey` exists for, which a UI test can
    /// then prove lands as one document (#78). DEBUG only.
    static var dropsAcknowledgements: Bool {
        ProcessInfo.processInfo.environment["EVA_SYNC_DROP_ACKS"] == "1"
    }
    #endif

    /// Sends one operation and applies the server's answer. Throws to the engine, which
    /// decides what a failure means.
    private func send(_ operation: PendingOperation) async throws {
        guard let kind = operation.operationKind,
              let row = store.row(clientId: operation.clientId)
        else { return }
        sendingSequence = operation.sequence
        defer { sendingSequence = nil }
        let clientId = row.clientId
        let timeZone = operation.timeZone

        switch kind {
        case .create:
            guard let write = row.write(timeZone: timeZone) else { return }
            let event = try await remote.createEvent(write)
            try acknowledge(clientId, with: event)
        case .bodySignals:
            guard let write = row.write(timeZone: timeZone),
                  case .bodySignals(let payload) = write.payload
            else { return }
            let event = try await remote.upsertBodySignals(EvaBodySignalsWrite(
                payload: payload,
                localDate: write.localDate,
                note: write.note,
                idempotencyKey: write.idempotencyKey,
                timeZone: write.timeZone
            ))
            try acknowledge(clientId, with: event)
        case .update:
            // No id means its create never landed — refused, and already on the card.
            guard let serverId = row.serverId, let write = row.write(timeZone: timeZone)
            else { return }
            let event = try await remote.updateEvent(id: serverId, write)
            try acknowledge(clientId, with: event)
        case .delete:
            guard let serverId = row.serverId else {
                // Never reached the server, so there is nothing there to delete.
                if store.operations(for: clientId).count <= 1 { store.delete(row) }
                changed()
                return
            }
            try await remote.deleteEvent(id: serverId)
            try acknowledge(clientId, with: nil)
        case .restore:
            guard let serverId = row.serverId else { return }
            let event = try await remote.restoreEvent(id: serverId)
            try acknowledge(clientId, with: event)
        }
    }

    /// What an acknowledgement does to the row (§8.4): it learns its server id; it takes
    /// the server's copy unless a later operation for it is still queued (the server's copy
    /// would be older than what is on screen); and another row the server has just
    /// overwritten — a one-per-day entry deleted earlier on the same day — goes.
    private func acknowledge(_ clientId: String, with event: EvaEvent?) throws {
        #if DEBUG
        if Self.dropsAcknowledgements { throw APIError.network }
        #endif
        guard !isClosed, let row = store.row(clientId: clientId) else { return }
        if let event {
            let later = store.operations(for: clientId).count > 1
            if later {
                row.serverId = event.id
            } else {
                row.absorb(event)
            }
            for other in store.rows(serverId: event.id)
            where other.clientId != clientId && store.operations(for: other.clientId).isEmpty {
                store.delete(other)
            }
        }
        // The engine removes the operation after this returns; the state is read as if it
        // already had.
        row.lastError = nil
        refreshState(of: row, acknowledging: 1)
        store.save()
        changed()
        if let type = row.eventType { onAcknowledged?(type) }
    }

    /// A 4xx: the server will never take this operation. The row is marked so the card can
    /// say so, and the queue moves on.
    private func markFailed(_ operation: PendingOperation, _ error: APIError) {
        guard let row = store.row(clientId: operation.clientId) else { return }
        row.syncState = SyncState.failed.rawValue
        row.lastError = Self.code(for: error)
        store.save()
        changed()
    }

    // MARK: - Helpers

    private func changed() { revision += 1 }

    /// The row's state, from what is still queued for it. `acknowledging` discounts the
    /// operation being acknowledged, which the engine removes only after this runs.
    private func refreshState(of row: LocalEvent, acknowledging: Int = 0) {
        let kinds = store.operations(for: row.clientId).dropFirst(acknowledging)
            .compactMap(\.operationKind)
        if kinds.isEmpty {
            if row.state != .failed { row.syncState = SyncState.synced.rawValue }
        } else if kinds.contains(.delete) {
            row.syncState = SyncState.pendingDelete.rawValue
        } else if kinds.contains(.create) || (kinds.contains(.bodySignals) && row.serverId == nil) {
            row.syncState = SyncState.pendingCreate.rawValue
        } else {
            row.syncState = SyncState.pendingUpdate.rawValue
        }
        store.save()
    }

    private func hasQueuedCreate(_ row: LocalEvent) -> Bool {
        store.operations(for: row.clientId).contains {
            $0.operationKind == .create || $0.operationKind == .bodySignals
        }
    }

    /// Body signals have their own day-addressed upsert; everything else is a create.
    private func createKind(for type: EvaEventType) -> OperationKind {
        type == .bodySignals ? .bodySignals : .create
    }

    /// The day's live entry of a one-per-day type — which a second log of that type updates.
    private func onePerDayRow(for write: EvaEventWrite) -> LocalEvent? {
        guard write.type.isOnePerDay else { return nil }
        return store.localEvents(from: write.localDate, through: write.localDate)
            .first { $0.type == write.type.rawValue }
    }

    /// The draft's key, unless a row already carries it — then a fresh one, because the
    /// `clientId` is the row's identity on this device and two rows cannot share it.
    private func unusedClientId(_ key: String) -> String {
        store.row(clientId: key) == nil ? key : UUID().uuidString
    }

    /// The API error code the card names. Never the message, which is display copy.
    private static func code(for error: APIError) -> String {
        switch error {
        case .server(let code, _, _): code
        case .decoding: "DECODING"
        case .notActivated: "NOT_ACTIVATED"
        case .network, .rateLimited, .sessionExpired: "RETRY"
        }
    }

    /// The device's wall clock, as `loggedAt` is stored: `YYYY-MM-DDTHH:mm:ss`, no zone.
    static func wallClock(in timeZone: TimeZone, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Unreachable in practice — the row was built from a payload the app encoded — and
    /// here so `save` never has to return an optional to a sheet that has already closed.
    private static func placeholder(for row: LocalEvent, write: EvaEventWrite) -> EvaEvent {
        let detail: EvaEventDetail = switch write.payload {
        case .cycle(let mark): .cycle(mark)
        case .bodySignals(let payload): .bodySignals(payload)
        case .sport(let payload): .sport(payload)
        case .appointment(let payload): .appointment(payload)
        }
        return EvaEvent(
            id: row.displayId, detail: detail, localDate: write.localDate,
            loggedAt: row.loggedAt, note: write.note, idempotencyKey: row.clientId
        )
    }
}

import Foundation
import Testing
@testable import Eva

/// An in-memory `CalendarEventSource` that records what the model asked it for.
///
/// **Not a stubbed `URLSession`, deliberately.** The claims these suites make are about
/// *requests* — how many, over which ranges, in what order — and the global
/// `EvaStubURLProtocol` is shared with every other suite in this target. Swift Testing
/// parallelises across suites, so a count read through that stub would be a count of
/// everybody's traffic, and arming it from a suite that is not `.serialized` can interleave
/// with `RateLimitedResponseTests`, which is. `CalendarEventSource` exists so this can be
/// injected narrowly instead (#159's note on the protocol says the same).
///
/// Extracted from `CalendarModelTests` when #160 added the write half: two copies of a
/// stub that has to agree with the server's one-per-day rule is one copy too many.
///
/// `suspends` is C1's, and it matters as much as the recording does: without it this source
/// returns without ever suspending, so `isFetching` is never true when a second call
/// arrives and the whole queue-and-re-run branch is unreachable from a test — which is how
/// the dropped-fetch defect shipped with a green suite.
@MainActor
final class RecordingCalendarSource: CalendarEventSource {

    // MARK: What was asked

    private(set) var ranges: [ClosedRange<EvaDay>] = []
    private(set) var refDataCalls = 0
    private(set) var writes: [EvaEventWrite] = []
    private(set) var bodySignalWrites: [EvaBodySignalsWrite] = []
    private(set) var patchedIds: [String] = []
    private(set) var deletedIds: [String] = []
    private(set) var restoredIds: [String] = []

    // MARK: What it answers with

    var events: [EvaEvent] = []
    var catalogue = EvaRefData(version: "v1", catalogues: EvaRefData.Catalogues())
    /// Thrown by the next read.
    var failure: (any Error)?
    /// Thrown by the next write, delete or restore.
    var writeFailure: (any Error)?

    /// Ids handed out by `createEvent`, so a test can predict them.
    private var nextId = 1

    // MARK: - Reading

    /// While true, every `events(from:through:)` parks until `release()` lets it go.
    var suspends = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var isParked: Bool { !parked.isEmpty }

    func events(from: EvaDay, through to: EvaDay) async throws -> [EvaEvent] {
        ranges.append(from...to)
        if suspends {
            await withCheckedContinuation { parked.append($0) }
        }
        if let failure { throw failure }
        return events.filter { (from...to).contains($0.localDate) }
    }

    func refData() async throws -> EvaRefData {
        refDataCalls += 1
        if let failure { throw failure }
        return catalogue
    }

    /// Lets every held call return, then yields so they actually run.
    func release() async {
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
        for _ in 0..<8 { await Task.yield() }
    }

    /// Suspends until request number `count` has arrived **and is parked at the network**,
    /// so the test acts during a request rather than hoping to.
    ///
    /// Records an issue instead of hanging: a request that never arrives is a broken test,
    /// not a slow one.
    func waitUntilParked(
        afterRequests count: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<2_000 {
            if ranges.count >= count && isParked { return }
            await Task.yield()
        }
        Issue.record(
            "Only \(ranges.count) request(s) arrived, parked: \(isParked)",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Writing

    /// Stores the way the route does, including the part that matters most to #50: a
    /// one-per-day type **replaces** the day's entry rather than adding to it.
    func createEvent(_ write: EvaEventWrite) async throws -> EvaEvent {
        writes.append(write)
        if let writeFailure { throw writeFailure }
        let id = write.type.isOnePerDay
            ? "\(write.type.rawValue)_\(write.localDate.isoDate)"
            : "e\(nextId)"
        nextId += 1
        let event = EvaEvent(
            id: id,
            detail: Self.detail(for: write.payload),
            localDate: write.localDate,
            loggedAt: "\(write.localDate.isoDate)T09:00:00",
            note: write.note,
            idempotencyKey: write.idempotencyKey
        )
        events.removeAll {
            $0.id == id || (write.type.isOnePerDay && $0.type == write.type
                            && $0.localDate == write.localDate)
        }
        events.append(event)
        return event
    }

    func upsertBodySignals(_ write: EvaBodySignalsWrite) async throws -> EvaEvent {
        bodySignalWrites.append(write)
        return try await createEvent(EvaEventWrite(
            payload: .bodySignals(write.payload),
            localDate: write.localDate,
            note: write.note,
            idempotencyKey: write.idempotencyKey,
            timeZone: write.timeZone
        ))
    }

    func updateEvent(id: String, _ write: EvaEventWrite) async throws -> EvaEvent {
        patchedIds.append(id)
        writes.append(write)
        if let writeFailure { throw writeFailure }
        let event = EvaEvent(
            id: id,
            detail: Self.detail(for: write.payload),
            localDate: write.localDate,
            loggedAt: "\(write.localDate.isoDate)T09:00:00",
            note: write.note,
            idempotencyKey: write.idempotencyKey
        )
        events.removeAll { $0.id == id }
        events.append(event)
        return event
    }

    func deleteEvent(id: String) async throws {
        deletedIds.append(id)
        if let writeFailure { throw writeFailure }
        events.removeAll { $0.id == id }
    }

    func restoreEvent(id: String) async throws -> EvaEvent {
        restoredIds.append(id)
        if let writeFailure { throw writeFailure }
        guard let event = restorable[id] else {
            throw APIError.server(code: "NOT_FOUND", message: "No such event", status: 404)
        }
        events.append(event)
        return event
    }

    /// What a restore would bring back, keyed by id. A test that means to exercise Undo
    /// puts the deleted entry here — the real API keeps it soft-deleted for thirty days.
    var restorable: [String: EvaEvent] = [:]

    private static func detail(for payload: EvaEventPayload) -> EvaEventDetail {
        switch payload {
        case .cycle(let mark): .cycle(mark)
        case .bodySignals(let signals): .bodySignals(signals)
        case .sport(let sport): .sport(sport)
        case .appointment(let appointment): .appointment(appointment)
        }
    }
}

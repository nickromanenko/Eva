import Foundation
import Testing
@testable import Eva

/// An in-memory `TodayCardSource` that records what the Home tab asked it for.
///
/// Same reasoning as `RecordingCalendarSource`: the claims this screen makes are about
/// *requests* — how many, in which zone, and what the model does with an answer that is
/// identical to the last one — and the global `EvaStubURLProtocol` is shared with every
/// other suite in this target. Swift Testing parallelises across suites, so a count read
/// through that stub would be a count of everybody's traffic. `TodayCardSource` exists so
/// this can be injected narrowly instead.
@MainActor
final class RecordingTodayCardSource: TodayCardSource {

    // MARK: What was asked

    private(set) var reads = 0
    private(set) var zones: [String] = []

    // MARK: What it answers with

    /// The next response. Replace it to make a refresh bring something new.
    var response: EvaTodayResponse

    /// Thrown by the next read, if set.
    var failure: (any Error)?

    /// While true, every read parks until `release()` lets it go — so a second call can
    /// arrive while the first is in flight, which is the only way the single-flight guard
    /// is reachable from a test.
    var suspends = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var isParked: Bool { !parked.isEmpty }

    init(response: EvaTodayResponse) {
        self.response = response
    }

    convenience init(card: EvaTodayCard?, date: EvaDay = EvaDay(year: 2026, month: 8, day: 18)) {
        self.init(response: EvaTodayResponse(
            date: date,
            generatedAt: "2026-08-18T06:00:00.000Z",
            contentVersion: "v1",
            card: card
        ))
    }

    func todayCard(timeZone: TimeZone) async throws -> EvaTodayResponse {
        reads += 1
        zones.append(timeZone.identifier)
        if suspends {
            await withCheckedContinuation { parked.append($0) }
        }
        if let failure { throw failure }
        return response
    }

    func release() {
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}

// MARK: - Fixtures

extension EvaTodayCard {

    /// The canvas' `home_a` — the zero-data card, and the one #99 names twice: it shows no
    /// phase, and both of its actions reach a screen that exists.
    static let coldStartFixture = EvaTodayCard(
        templateId: "cold_start",
        rung: "setup",
        title: "Start with your first log",
        line2: "Log your period or today’s body signals so Eva can begin recognizing "
            + "patterns that are specific to you.",
        actions: [
            EvaTodayCardAction(label: "Log now"),
            EvaTodayCardAction(label: "Open Calendar")
        ]
    )

    /// The canvas' `home_d` — a card with a kicker, three lines and one disabled action.
    static let phaseFixture = EvaTodayCard(
        templateId: "phase_energy",
        rung: "phase",
        kicker: "Cycle day 13 · likely approaching ovulation",
        title: "Many women notice higher energy around now",
        line2: "This is a tendency across cycles, not a prediction about your day.",
        line3: "If that matches how you feel, a harder training session may be an option.",
        actions: [EvaTodayCardAction(label: "View cycle details")]
    )
}

#if DEBUG
import Foundation

/// The `EVA_CYCLE_PREDICTION` launch hook: hands the calendar one
/// `GET /me/cycle/predictions` body instead of asking the API for it.
///
/// ```sh
/// SIMCTL_CHILD_EVA_CYCLE_PREDICTION='{"from":"2026-09-01","to":"2026-09-30",
///   "predictedPeriod":["2026-09-28"],"fertileWindow":["2026-09-13","2026-09-14"],
///   "peak":[],"confidence":"wide","withheld":null}' \
///   xcrun simctl launch --terminate-running-process $UDID com.evaapp.ios
/// ```
///
/// Same family as `EVA_ONBOARDING_STEP`, `EVA_UITEST_RESET`, `EVA_SPECIMEN` and
/// `EVA_TODAY_CARD`: read once from `ProcessInfo`, DEBUG only, the whole file inside
/// `#if DEBUG` so a Release build has neither the type nor the branch in `CalendarView`
/// that reads it.
///
/// ## Why the overlay needs one
///
/// The route exists (#205) and **refuses to answer in every environment there is**: the
/// `CYCLE_*` constants are A25–A27's clinical configuration, no deployment sets them, and
/// `CycleRulesUnsetError` is a `503` until #26 signs them off with sources. So without a
/// hook there is no way to put a predicted day on a grid — not for review against the
/// canvas, and not for a test. #206 makes "a prediction drawn like a fact" the failure mode
/// of the whole feature and asks for a UI test rather than a code review; this is what that
/// test drives.
///
/// ## A response body, not a fixture table
///
/// The value is the route's own JSON, decoded by `EvaCyclePredictions` — the same decoder
/// the real path uses, so the hook exercises it rather than bypassing it. The alternative
/// was a table of named states, and each one would have had to *generate* dates relative
/// to today, which is the one thing this slice forbids the device to do: a fixture that
/// computes `today + 14` is prediction arithmetic in Swift, DEBUG or not. Handing over a
/// literal body keeps every date something the caller wrote down.
///
/// `EVA_CYCLE_PREDICTION=unavailable` is the one named value, and it is not a state — it
/// makes the read fail the way the live route does today, which is how the "no overlay, no
/// card, and the calendar still works" path gets looked at.
enum EvaCyclePredictionLaunch {

    static let environmentKey = "EVA_CYCLE_PREDICTION"

    /// The value that fails every read instead of answering one.
    static let unavailableValue = "unavailable"

    private static let requested = ProcessInfo.processInfo.environment[environmentKey]

    /// The seeded source, or `nil` when the variable is unset and the calendar should talk
    /// to the API like any other build.
    ///
    /// The **events** half is never seeded: this wraps whatever real source the screen was
    /// going to use and answers only `predictions(from:through:)` from the hook. A calendar
    /// whose entries were fake too could not show what #206 is about — a predicted cell
    /// next to a logged one.
    @MainActor
    static func source(wrapping live: any CalendarEventSource) -> (any CalendarEventSource)? {
        guard let requested, !requested.isEmpty else { return nil }
        if requested == unavailableValue {
            return SeededPredictionSource(answer: nil, wrapping: live)
        }
        guard let data = requested.data(using: .utf8),
              let answer = try? JSONDecoder().decode(EvaCyclePredictions.self, from: data)
        else {
            // A malformed body is a broken launch, not a state to draw. Failing the read is
            // what a live 503 does, and the calendar stays usable either way.
            return SeededPredictionSource(answer: nil, wrapping: live)
        }
        return SeededPredictionSource(answer: answer, wrapping: live)
    }
}

/// A `CalendarEventSource` that answers the prediction from a seeded body and forwards
/// everything else to the real one.
///
/// It answers the **identical** body for every range, which is what makes it a fixture
/// rather than a simulation: the model's own clipping and month caching are what decide
/// which of those days reach which cell.
@MainActor
final class SeededPredictionSource: CalendarEventSource {

    private let answer: EvaCyclePredictions?
    private let live: any CalendarEventSource

    init(answer: EvaCyclePredictions?, wrapping live: any CalendarEventSource) {
        self.answer = answer
        self.live = live
    }

    func predictions(from: EvaDay, through to: EvaDay) async throws -> EvaCyclePredictions {
        guard let answer else {
            // The shape the live route answers with wherever `CYCLE_*` is unset.
            throw APIError.server(
                code: "SERVICE_UNAVAILABLE",
                message: "Cycle predictions aren't available right now. Please try again later.",
                status: 503
            )
        }
        return answer
    }

    func events(from: EvaDay, through to: EvaDay) async throws -> [EvaEvent] {
        try await live.events(from: from, through: to)
    }

    func refData() async throws -> EvaRefData { try await live.refData() }

    func createEvent(_ write: EvaEventWrite) async throws -> EvaEvent {
        try await live.createEvent(write)
    }

    func upsertBodySignals(_ write: EvaBodySignalsWrite) async throws -> EvaEvent {
        try await live.upsertBodySignals(write)
    }

    func updateEvent(id: String, _ write: EvaEventWrite) async throws -> EvaEvent {
        try await live.updateEvent(id: id, write)
    }

    func deleteEvent(id: String) async throws { try await live.deleteEvent(id: id) }

    func restoreEvent(id: String) async throws -> EvaEvent { try await live.restoreEvent(id: id) }
}
#endif

import Foundation

// `GET /me/cycle/predictions` as the calendar reads it (C12b of #11, #206).
//
// **The device derives nothing here, and that is the whole design of this file.** Every
// date below was computed by `api/src/cycle.ts` from constants that are configuration with
// cited sources (A25–A27); every threshold that decided whether there is a prediction at
// all was applied there. What arrives is three lists of days, a band and a reason, and what
// this file does is turn strings into `EvaDay`s and hand them to the grid.
//
// So there is no arithmetic on this path — no `adding(days:)`, no `days(since:)`, no
// `Calendar`, no `Date`. `CalendarPredictionTests.thePredictionPathDoesNoDateArithmetic`
// asserts that by reading the source, the way `api/test/cycle.test.ts` asserts the maths
// stays pure: a helper that "just extends the period by four days" is the exact defect
// #206 forbids, and it would pass every value-level test in the repo.

/// A27's band. **The server's vocabulary, passed through** — the client picks the words it
/// says from this and never recomputes which band it is in.
///
/// Both bands hedge, for the reason `dashboard-rules.ts` states: v1 has no
/// confirmed-ovulation path, so "estimate" is the honest word at either end. What differs
/// is how far it can move, which is what `EvaCyclePredictions.confidenceSentence` says.
enum EvaPredictionConfidence: String, Decodable, Hashable, Sendable {
    case wide
    case narrow
}

/// Why there is nothing to draw.
///
/// Three reasons, three sentences. They are **not interchangeable**: "log a period" and
/// "your cycles vary too much for Eva to estimate from" are different facts about her data,
/// and collapsing them into one line would tell two thirds of the users who see it
/// something untrue about themselves (DESIGN.md §8).
enum EvaPredictionWithheld: String, Decodable, Hashable, Sendable {
    case noFlowLogged = "no-flow-logged"
    case tooFewCountedCycles = "too-few-counted-cycles"
    case irregularCycles = "irregular-cycles"

    /// The card's heading for this reason. States what is true, never what is wrong.
    var title: String {
        switch self {
        case .noFlowLogged: "No estimate yet"
        case .tooFewCountedCycles: "Not enough logged cycles yet"
        case .irregularCycles: "Your cycle lengths vary too much to estimate from"
        }
    }

    /// What would change it, and — for the third — what it does not mean.
    ///
    /// `irregularCycles` is the one that has to say the second thing. A cycle that varies
    /// beyond her FIGO band is a reason Eva stays quiet, not a finding about her health;
    /// saying so and pointing at care is what DESIGN.md §8 and GUARDRAILS 35 require of a
    /// gate that closes on a clinical threshold.
    var body: String {
        switch self {
        case .noFlowLogged:
            "Log a period and Eva can start estimating the next one."
        case .tooFewCountedCycles:
            "Eva estimates from your own logged cycles. Keep logging and an estimate "
                + "appears once there are enough of them."
        case .irregularCycles:
            "Eva doesn't estimate from cycles this varied, because the estimate would be "
                + "wrong more often than not. It isn't a finding about your health — if it "
                + "concerns you, your provider is the person to ask."
        }
    }
}

/// One `GET /me/cycle/predictions` answer.
///
/// Three lists of days rather than three spans, which is C12a's shape and the reason a
/// withheld prediction needs no special case here: it is an empty overlay by construction.
///
/// `peak` is on the wire and is deliberately **not** decoded. It is a subset of
/// `fertileWindow`, so every peak day is already drawn as a fertile day, and the canvas
/// gives peak no treatment of its own — `mkCell` in "Eva App.dc.html" branches on the
/// fertile window and the predicted period and on nothing else. Inventing a third fill is
/// a design decision, not an implementation one (#206 Out: "anything that recomputes a
/// prediction on the device"; this is its cousin — anything that draws one the canvas has
/// not drawn).
struct EvaCyclePredictions: Decodable, Hashable, Sendable {

    /// The range this answer covers, echoed by the route. Kept because it is what makes the
    /// answer cacheable: a month is only covered when a response's range contained it.
    let from: EvaDay
    let to: EvaDay

    /// The predicted next **first flow day**, when it falls inside the range.
    ///
    /// At most one day. `cycle.ts` produces a next-period start and deliberately no period
    /// length, so washing five cells would mean inventing one — this is a `Set` because the
    /// grid asks it per day, not because more than one is expected.
    let predictedPeriod: Set<EvaDay>
    let fertileWindow: Set<EvaDay>

    /// `nil` exactly when there is no prediction — the same condition `withheld` is set on,
    /// as `toPredictionsBody` builds them together.
    let confidence: EvaPredictionConfidence?

    /// Why there is nothing to draw, or `nil` when there is something.
    ///
    /// **Read from the field, never inferred from the empty lists.** `withheld == nil` with
    /// nothing in the lists means the prediction falls outside the range that was asked
    /// for; `withheld` set means a gate closed on her data. A client that guessed from
    /// emptiness would tell the first user the second one's sentence.
    let withheld: EvaPredictionWithheld?

    init(
        from: EvaDay,
        to: EvaDay,
        predictedPeriod: Set<EvaDay> = [],
        fertileWindow: Set<EvaDay> = [],
        confidence: EvaPredictionConfidence? = nil,
        withheld: EvaPredictionWithheld? = nil
    ) {
        self.from = from
        self.to = to
        self.predictedPeriod = predictedPeriod
        self.fertileWindow = fertileWindow
        self.confidence = confidence
        self.withheld = withheld
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try Self.day(container.decode(String.self, forKey: .from), .from, in: container)
        to = try Self.day(container.decode(String.self, forKey: .to), .to, in: container)
        predictedPeriod = try Self.days(container.decode([String].self, forKey: .predictedPeriod),
                                        .predictedPeriod, in: container)
        fertileWindow = try Self.days(container.decode([String].self, forKey: .fertileWindow),
                                      .fertileWindow, in: container)
        confidence = try container.decodeIfPresent(EvaPredictionConfidence.self, forKey: .confidence)
        withheld = try container.decodeIfPresent(EvaPredictionWithheld.self, forKey: .withheld)
    }

    /// Refuses a day it cannot parse rather than dropping it.
    ///
    /// Loud rather than lenient, for `InvalidCycleDateError`'s reason on the server: a date
    /// silently read as "nothing to draw" is a prediction cell that quietly disappears, and
    /// a partly-drawn fertile window is worse than none. The message names the field and
    /// never the value — a predicted date is derived from her logs (GUARDRAILS 12).
    private static func day(
        _ raw: String, _ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EvaDay {
        guard let day = EvaDay(isoDate: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "not a YYYY-MM-DD day"
            )
        }
        return day
    }

    private static func days(
        _ raw: [String], _ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Set<EvaDay> {
        Set(try raw.map { try day($0, key, in: container) })
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, predictedPeriod, fertileWindow, confidence, withheld
    }
}

// MARK: - What the screen holds

/// The overlay as the calendar keeps it: the latest answer, the days it named, and which
/// months have been asked for.
///
/// Its own type rather than four more properties on `CalendarModel`, for the reason #206
/// makes the centre of this slice — **the device derives nothing** — and that claim is only
/// worth making if something can check it. Everything that touches a predicted date lives
/// in this file, `EvaPredictionMark.swift` and `CalendarSummary.swift`, and
/// `CalendarPredictionTests.thePredictionPathDoesNoDateArithmetic` reads all three looking
/// for the calls that could fabricate one.
///
/// **Fetch by range, cache by month**, which is `CalendarModel`'s own idiom and C12a's
/// reason for answering by range. Months rather than days, so paging back over ground
/// already walked costs nothing.
struct EvaPredictionOverlay: Equatable, Sendable {

    /// The last answer. `confidence` and `withheld` are properties of the whole analysis
    /// rather than of a range, so a later response cannot disagree with an earlier one
    /// about them and the newest is simply kept.
    private(set) var answer: EvaCyclePredictions?

    private var marksByDay: [EvaDay: [EvaPredictionMark]] = [:]
    private var coveredMonths: Set<EvaMonth> = []

    /// What is predicted for a day, in the order the cell draws and announces them.
    func marks(on day: EvaDay) -> [EvaPredictionMark] { marksByDay[day] ?? [] }

    /// Every day this overlay draws anything on. What the summary card asks when it needs
    /// to name the predicted period's date.
    var days: [EvaDay: [EvaPredictionMark]] { marksByDay }

    /// The part of `from…to` that has not been asked for, or `nil` when all of it has.
    ///
    /// Only months the caller's range covers **completely** count, so the first load's
    /// 400-day window — which starts mid-month — cannot mark its first month as overlaid
    /// and leave the days before the cut permanently unpredicted.
    func missingRange(from: EvaDay, to: EvaDay) -> (from: EvaDay, to: EvaDay)? {
        var missing: [EvaMonth] = []
        var month = from.evaMonth
        while month <= to.evaMonth {
            if month.isFullyCovered(from: from, to: to), !coveredMonths.contains(month) {
                missing.append(month)
            }
            month = month.next
        }
        guard let first = missing.min(), let last = missing.max() else { return nil }
        return (first.firstDay, last.lastDay)
    }

    /// Files one response.
    ///
    /// The days are **merged**, where a range of events is replaced by its response. The
    /// difference is what the two answers mean: a range of events is the authority for its
    /// days, so anything it omits is gone — but a prediction response names only the
    /// predicted days inside its own range and says nothing about the rest, so dropping
    /// what it did not mention would un-draw the month next door. A stale overlay is
    /// prevented by `invalidate()` instead, which empties the whole thing the moment the
    /// entries underneath it move.
    mutating func absorb(_ response: EvaCyclePredictions) {
        answer = response
        var month = response.from.evaMonth
        while month <= response.to.evaMonth {
            if month.isFullyCovered(from: response.from, to: response.to) {
                coveredMonths.insert(month)
            }
            month = month.next
        }
        for day in response.fertileWindow { marksByDay[day, default: []].append(.fertileWindow) }
        for day in response.predictedPeriod { marksByDay[day, default: []].append(.period) }
        // Re-sorted into the artboard's order rather than kept in arrival order, so a day
        // that is both draws and announces the fertile window first whichever list named it
        // first — and so no day can end up holding the same mark twice.
        for (day, marks) in marksByDay {
            marksByDay[day] = EvaPredictionMark.drawingOrder.filter(Set(marks).contains)
        }
    }

    /// Throws the whole overlay away.
    ///
    /// Called when a cycle entry changes. **The prediction is derived from exactly those
    /// entries**, on read and with nothing cached (PRD §Predictions 5), so the next request
    /// answers differently — and everything goes, not only the days near the change,
    /// because a moved anchor moves the whole projection and which months it lands in is
    /// the server's answer to give.
    mutating func invalidate() {
        self = EvaPredictionOverlay()
    }
}

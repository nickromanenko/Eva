import SwiftUI

// The context summary card above the grid, and the words in it (#206).
//
// The card is the artboard's — `padding:16px 18px;border-radius:22px;
// background:rgba(255,255,255,.68)`, an overline kicker over a heading over a line of
// secondary text, in the slot the empty-state card occupies when there is no history.
//
// **The words are not, and that is a departure worth stating.** In Cycle mode the artboard
// fills the three slots with `'Cycle day 15 · follicular'`, `'Energy usually climbs this
// week'` and `'Your next period is estimated around 31 Aug, based on your last 4 logged
// cycles. Estimates shift as you log.'` Two of the three need data no route serves the
// calendar: cycle day and phase come from the Today card's own analysis (D-series), and the
// *count* of logged cycles is not on `GET /me/cycle/predictions` at all — it answers with
// three lists of days, a band and a reason. So the kicker and heading here say what this
// screen actually knows, the closing sentence is the artboard's verbatim, and the count is
// not guessed at. Recorded in DESIGN.md §9a.
//
// Nothing below restates a threshold the server owns. A27's bands are "3–5 counted cycles"
// and "6 or more", and `narrowBandMinCycles` is configuration — so the wide sentence says
// *a few* and the narrow one says *more*, and neither one names a number the app would
// then have to keep in step with `config.ts`.

/// What the summary card says.
///
/// A value rather than three `if`s inside the view, so the sentence each state produces can
/// be asserted without rendering anything — and so the three withheld reasons cannot
/// quietly collapse into one string.
struct CalendarSummary: Equatable, Sendable {

    /// The overline. One word, naming the subject rather than grading it: a card headed
    /// with a verdict is the scoring DESIGN.md §8 rules out.
    let kicker: String
    let title: String
    let body: String

    /// `nil` for the one combination the route does not produce: no prediction, no reason.
    ///
    /// `toPredictionsBody` sets `confidence` and `withheld` together — one is `null`
    /// exactly when the other is not — so this is unreachable through the API. It returns
    /// `nil` rather than inventing a third sentence, because a card with nothing true to
    /// say is better absent than filled in.
    init?(answer: EvaCyclePredictions, predictedDays: [EvaDay: [EvaPredictionMark]]) {
        kicker = "Estimate"

        if let withheld = answer.withheld {
            // Nothing is drawn, and **the reason is shown** rather than an empty grid. The
            // three reasons are three different facts about her data and keep three
            // different sentences — see `EvaPredictionWithheld`.
            title = withheld.title
            body = withheld.body
            return
        }

        guard let confidence = answer.confidence else { return nil }

        // The predicted day the server named, if the ranges fetched so far reached it.
        // `min()` because there can only be one and taking it is how a set is read, not
        // because a second is expected: `cycle.ts` produces a next-period *start* and no
        // period length, so the list is one day long or empty.
        let predictedPeriodDay = predictedDays
            .filter { $0.value.contains(.period) }
            .keys
            .min()

        if let day = predictedPeriodDay {
            let date = day.formattingDate.formatted(EvaDay.formatStyle.day().month(.abbreviated))
            title = "Your next period is estimated around \(date)"
            body = Self.confidenceSentence(confidence)
        } else {
            // **Not the same as withheld, and it must not read like it.** An empty overlay
            // with no reason means the prediction falls outside the range that was asked
            // for — Eva has an estimate and this screen has not loaded the day it lands on.
            // Guessing at the date here would be deriving one.
            title = "Eva has an estimate for your next period"
            body = "It falls outside the dates loaded here. " + Self.confidenceSentence(confidence)
        }
    }

    /// The confidence sentence, rendered wherever the prediction is (GUARDRAILS 35).
    ///
    /// **A wide band must not read as a certainty** (A27). The two sentences differ in what
    /// they promise, not only in an adjective: the wide one says the date can move by
    /// several days, and the narrow one still refuses to call itself anything but an
    /// estimate — v1 has no confirmed-ovulation path, so both bands hedge
    /// (`dashboard-rules.ts`, `PHASE_WORDING`).
    ///
    /// Both close on the artboard's own line, verbatim.
    private static func confidenceSentence(_ confidence: EvaPredictionConfidence) -> String {
        switch confidence {
        case .wide:
            "Eva has only a few logged cycles to go on, so this is a wide estimate — it can "
                + "move by several days. Estimates shift as you log."
        case .narrow:
            "More of your logged cycles are behind this one, so it is a narrower estimate — "
                + "still an estimate. Estimates shift as you log."
        }
    }
}

// MARK: - Drawing

/// The artboard's summary card, in the slot the empty-state card takes when there is no
/// history. The two are mutually exclusive on the canvas (`isEmptyCal` / `notEmpty`) and
/// are here too — see `CalendarModel.summary`.
struct CalendarSummaryCard: View {

    let summary: CalendarSummary

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text(summary.kicker)
                .evaTextStyle(.overline)
                .textCase(.uppercase)
                .foregroundStyle(Color.evaMutedText)
            Text(summary.title)
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.body)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(.card, cornerRadius: EvaRadius.card)
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
                .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.summary")
    }
}

#Preview("Summary card") {
    let range = (from: EvaDay(year: 2026, month: 8, day: 1), to: EvaDay(year: 2026, month: 8, day: 31))
    let states: [EvaCyclePredictions] = [
        EvaCyclePredictions(
            from: range.from, to: range.to,
            predictedPeriod: [EvaDay(year: 2026, month: 8, day: 31)],
            fertileWindow: [], confidence: .narrow
        ),
        EvaCyclePredictions(
            from: range.from, to: range.to,
            predictedPeriod: [EvaDay(year: 2026, month: 8, day: 31)],
            fertileWindow: [], confidence: .wide
        ),
        EvaCyclePredictions(from: range.from, to: range.to, withheld: .noFlowLogged),
        EvaCyclePredictions(from: range.from, to: range.to, withheld: .tooFewCountedCycles),
        EvaCyclePredictions(from: range.from, to: range.to, withheld: .irregularCycles)
    ]

    return ScrollView {
        VStack(spacing: EvaSpacing.md) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, answer in
                if let summary = CalendarSummary(
                    answer: answer,
                    predictedDays: Dictionary(
                        uniqueKeysWithValues: answer.predictedPeriod.map { ($0, [EvaPredictionMark.period]) }
                    )
                ) {
                    CalendarSummaryCard(summary: summary)
                }
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background { EvaScreenBackground().ignoresSafeArea() }
}

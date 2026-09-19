import SwiftUI

/// What the marks on the grid mean.
///
/// Every row names the **shape and the corner** as well as showing the colour, which is
/// the point of the legend existing at all: the grid's marks are 5–6pt and four of them
/// share one 50pt cell, so hue is the least reliable thing about them.
///
/// The artboard's legend also lists predicted period, the fertile window and the
/// positive-test mark. **All three are real now.** #206 drew the first two; #80 adds the
/// event type the third describes and its top-left outlined square, so the rule this file
/// has followed since C1 — a row and its mark ship together — is satisfied for the last of
/// them, and there is nothing left here describing something the grid cannot draw.
///
/// The positive-test row arrives through `EvaEventGlyph.allCases` with the other four event
/// marks rather than as a row of its own, which also puts it last, where the artboard's own
/// legend puts it. Its swatch is `EvaEventGlyphMark`, so it is the cell's mark at the cell's
/// size: solid-stroked, because dashed and patterned belong to the two predicted rows above
/// it and a logged test result is something she reported.
///
/// Two rows here are not on the artboard's legend. Appointment, which is the one drawn mark
/// the artboard leaves unexplained; and spotting, whose ring the artboard does not draw at
/// all (see `EvaCycleMark.spottingRing`).
///
/// ## The notice under the fertile window
///
/// PRD §Phase 1: *"The system must display, at the point of use and not only in the T&Cs,
/// that the fertile window is not a contraceptive method."* A27 puts it on the calendar
/// legend, and GUARDRAILS 35 requires it beside the window itself — so it is a line of this
/// card, directly under the row it qualifies, and not a footnote at the bottom of a screen
/// she has to scroll to reach.
struct CalendarLegend: View {

    private let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)

    /// PRD §Phase 1, at the point of use.
    ///
    /// The canvas states it as *"Eva's predictions are not a contraceptive method"* inside
    /// the cycle-history "How this is estimated" panel. Here it names the fertile window,
    /// because that is the row it sits under and the one the sentence is actually about —
    /// and it says what the window *is* rather than only what it is not, so it reads as
    /// information rather than as a disclaimer to skip (DESIGN.md §8).
    static let notContraceptive =
        "The fertile window is an estimate from your logged cycles. It is not a "
            + "contraceptive method and should not be used as one."

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            Text("Legend")
                .evaTextStyle(.overline)
                .textCase(.uppercase)
                .foregroundStyle(Color.evaMutedText)

            // **Nine fixed rows do not need deferring, and being lazy is not free here.** A
            // `LazyVGrid` never instantiates children that are off-screen, and this card is
            // the last thing in the calendar's scroll column — so until something scrolls to
            // it the rows are *absent from the accessibility hierarchy* rather than present
            // and out of reach. Measured, not guessed: no row label anywhere before a swipe,
            // all nine after one. That is #213's finding met a second time, and it is why
            // `CalendarPredictionUITests` reveals this card before reading it.
            //
            // Left lazy all the same. VoiceOver reaches these rows by scrolling, the way it
            // reaches any lazy content on any screen, so nothing a reader does is blocked by
            // it; and the two-column geometry here is the artboard's, which a hand-rolled
            // stack of `HStack`s would have to reproduce by eye. If a row ever has to be
            // readable without scrolling, that is the trade to revisit.
            LazyVGrid(columns: columns, alignment: .leading, spacing: EvaSpacing.xs) {
                row {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(EvaCycleMark.flow(.heavy).cellFill ?? .clear)
                        .frame(width: 16, height: 16)
                } label: {
                    EvaCycleMark.legendLabel
                }

                // Spotting joins the legend in C2, because C2 is what gave it a mark —
                // and a ring beside three washes is exactly the pair of rows a legend is
                // for: they are the same colour and they do not mean the same thing.
                row {
                    Circle()
                        .strokeBorder(
                            EvaCycleMark.spotting.spottingRing ?? .clear,
                            lineWidth: EvaCalendarMetrics.spottingRingWidth
                        )
                        .frame(width: 16, height: 16)
                } label: {
                    EvaCycleMark.spottingLegendLabel
                }

                // The two rows this file has been describing as undrawn since C1 (#206).
                // The swatch is the cell's own treatment at 16pt — same stripes, same
                // broken outline — because a legend whose swatch is a simplification of
                // the mark is a legend that has to be learned twice.
                ForEach(EvaPredictionMark.allCases, id: \.self) { mark in
                    row {
                        EvaPredictionSurface(mark: mark, cornerRadius: 5)
                            .frame(width: 16, height: 16)
                    } label: {
                        mark.legendLabel
                    }
                }

                ForEach(EvaEventGlyph.allCases, id: \.self) { glyph in
                    row {
                        EvaEventGlyphMark(glyph: glyph)
                            .frame(width: 16, height: 16)
                    } label: {
                        glyph.legendLabel
                    }
                }
            }

            // No identifier of its own, and not for want of trying: `accessibilityIdentifier`
            // on the card propagates to the plain `Text`s inside it and the **outer** one
            // wins, so an inner `calendar.legend.notContraceptive` never reaches the tree.
            // Read off a UI hierarchy dump, not guessed at. A combined row is the exception
            // — it is a new element and inherits nothing, which is what lets `row` carry an
            // identifier of its own; see there. `CalendarPredictionUITests` finds this line
            // by its words among the legend's elements instead, which is the stronger
            // assertion anyway: what PRD §Phase 1 requires is the sentence, at the point of
            // use, not an identifier.
            Text(Self.notContraceptive)
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaMutedText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, EvaSpacing.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(.background, cornerRadius: EvaRadius.banner)
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
        }
        .accessibilityIdentifier("calendar.legend")
    }

    /// One row: the mark, then what it means.
    ///
    /// `children: .combine` so the pair reads as a single phrase — a swatch and a sentence
    /// announced separately would leave the reader to join them up, which is the one job
    /// this card has.
    ///
    /// **The identifier is on the row, and unlike the notice's it survives.** Combining
    /// builds a *new* element, and a new element does not inherit the card's
    /// `calendar.legend` — read off a running app, where that identifier resolves to the
    /// overline, the notice and the grid, and to no row at any scroll position. So before
    /// this the rows were unaddressable from both directions at once: invisible to a query
    /// scoped to the card, and nameless outside it. That, and not anything about what
    /// VoiceOver can read, is why #80's assertion could not be written.
    private func row(
        @ViewBuilder swatch: () -> some View,
        label: () -> String
    ) -> some View {
        HStack(spacing: EvaSpacing.xs) {
            swatch()
            Text(label())
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.legend.row")
    }
}

#Preview("Legend") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        CalendarLegend().padding(EvaSpacing.lg)
    }
}

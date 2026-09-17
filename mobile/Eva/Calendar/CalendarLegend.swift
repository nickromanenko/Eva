import SwiftUI

/// What the marks on the grid mean.
///
/// Every row names the **shape and the corner** as well as showing the colour, which is
/// the point of the legend existing at all: the grid's marks are 5–6pt and four of them
/// share one 50pt cell, so hue is the least reliable thing about them.
///
/// The artboard's legend also lists predicted period, the fertile window and the
/// positive-test mark. **Two of the three arrive here with #206**, which is the slice that
/// draws them; the positive-test mark still does not, because the event type it marks does
/// not exist yet (#80) and a legend entry for something the grid never draws is a promise.
/// It is listed neither here nor in `EvaEventGlyph` for that reason — the rule this file
/// has followed since C1 is that a row and its mark ship together.
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
            // on the card propagates to every element inside it and the **outer** one wins,
            // so an inner `calendar.legend.notContraceptive` never reaches the tree. Read
            // off a UI hierarchy dump, not guessed at. `CalendarPredictionUITests` finds
            // this line by its words among the legend's elements instead, which is the
            // stronger assertion anyway: what PRD §Phase 1 requires is the sentence, at the
            // point of use, not an identifier.
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
    }
}

#Preview("Legend") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        CalendarLegend().padding(EvaSpacing.lg)
    }
}

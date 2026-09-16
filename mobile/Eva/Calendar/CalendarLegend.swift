import SwiftUI

/// What the marks on the grid mean.
///
/// Every row names the **shape and the corner** as well as showing the colour, which is
/// the point of the legend existing at all: the grid's marks are 5–6pt and four of them
/// share one 50pt cell, so hue is the least reliable thing about them.
///
/// The artboard's legend also lists predicted period, the fertile window and the
/// positive-test mark. None of the three is drawn by C1 — predictions are C3 and the test
/// mark is C2 — and a legend entry for something the grid never draws is a promise, so
/// they arrive with the marks they describe. Appointment is listed here and is *not* on
/// the artboard's legend, which looks like an omission: it is the one drawn mark the
/// artboard leaves unexplained.
struct CalendarLegend: View {

    private let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)

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

                ForEach(EvaEventGlyph.allCases, id: \.self) { glyph in
                    row {
                        EvaEventGlyphMark(glyph: glyph)
                            .frame(width: 16, height: 16)
                    } label: {
                        glyph.legendLabel
                    }
                }
            }
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

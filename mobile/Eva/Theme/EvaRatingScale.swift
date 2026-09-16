import SwiftUI

/// The DESIGN.md §6 five-point scale — five cells, each a glyph with a word, a readout
/// beside the label and an anchor at each end.
///
/// §6 has specified this as "one component — the App canvas' `scales`" since 2026-08-30
/// and nothing had built it. #160 is the first screen that needs it (energy, mood and
/// sleep on the body-signals sheet); D2's "how are you feeling" is the second, which is
/// why it sits with the tokens rather than inside the calendar.
///
/// ## Why the word, and not just the number
///
/// A number alone is a score, and §8 rules scores out. The canvas already chose vocabulary
/// that describes — Depleted · Low · Steady · Good · High — and the readout says
/// "Low · 2 of 5" so the scale reads as a position on a range the user chose, not as a mark
/// Eva awarded. The words come from the caller, because they differ per scale.
///
/// ## Nothing is preselected
///
/// `selection` is optional all the way down. "Not set" is a real state and it is not a 3:
/// the API stores an absent rating and an answered one differently, and a scale that
/// defaulted to the middle would put a number into a health record that nobody entered.
struct EvaRatingScale: View {

    /// What is being rated — "Energy". Also the first half of each cell's announcement.
    let label: String
    /// The words for 1…5. Exactly five.
    let words: [String]
    /// The glyph for each point, or `nil` for a scale drawn as graduated dots.
    var glyphs: [String]?
    /// The words under the two ends.
    let lowAnchor: String
    let highAnchor: String
    /// The scale's own ink, which the selected cell is outlined in and the readout takes.
    let ink: Color
    /// The card's tint behind the cells.
    let tint: LinearGradient
    let border: Color

    @Binding var selection: Int?

    /// `min-height:54px` on a scale with glyphs, 44 on one without — and 44 is §1's floor,
    /// so neither goes below it.
    private static var cellHeight: CGFloat { 54 }
    /// `border-radius:15px`, the same off-scale radius the day cell uses.
    private static var cellRadius: CGFloat { 15 }
    /// `border-radius:22px` on the card, which takes `EvaRadius.card` (24) — the §9a rule
    /// the calendar's surfaces already follow.
    private static var cardRadius: CGFloat { EvaRadius.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .evaTextStyle(.control)
                    .foregroundStyle(Color.evaPrimaryText)
                Spacer(minLength: EvaSpacing.xs)
                readout
            }

            HStack(spacing: EvaSpacing.xs) {
                ForEach(1...5, id: \.self) { point in
                    cell(point)
                }
            }
            .padding(.top, EvaSpacing.sm)

            HStack {
                Text(lowAnchor)
                Spacer(minLength: EvaSpacing.xs)
                Text(highAnchor)
            }
            .evaTextStyle(.label)
            .foregroundStyle(Color.evaMutedText)
            .padding(.top, EvaSpacing.xs)
        }
        .padding(EvaSpacing.md)
        .background(tint, in: .rect(cornerRadius: Self.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// "Low · 2 of 5", or "Not set". The canvas' own string.
    private var readout: some View {
        Text(selection.flatMap(word(for:)).map { "\($0) · \(selection!) of 5" } ?? "Not set")
            .evaTextStyle(.label)
            .foregroundStyle(ink)
            .padding(.horizontal, EvaSpacing.xs)
            .padding(.vertical, EvaSpacing.xxs)
            .background(
                Color.white.opacity(0.72),
                in: .rect(
                    cornerRadius: EvaRatingScaleMetrics.readoutRadius, style: .continuous
                )
            )
            .accessibilityIdentifier("scale.\(label).readout")
    }

    private func word(for point: Int) -> String? {
        guard (1...words.count).contains(point) else { return nil }
        return words[point - 1]
    }

    private func cell(_ point: Int) -> some View {
        let isSelected = selection == point
        return Button {
            // Tapping the chosen point again clears it. A scale with no way back to
            // "not answered" makes a mis-tap into a permanent entry.
            selection = isSelected ? nil : point
        } label: {
            ZStack {
                if let glyph = glyphs?[safe: point - 1] {
                    Text(glyph)
                        .font(.system(size: EvaRatingScaleMetrics.glyphSize))
                        // The unselected glyphs are greyed *and* faded, so the selected one
                        // is not distinguished by colour alone (§1).
                        .grayscale(isSelected ? 0 : EvaRatingScaleMetrics.unselectedGrayscale)
                        .opacity(isSelected ? 1 : EvaRatingScaleMetrics.unselectedOpacity)
                } else {
                    Circle()
                        .fill(isSelected ? ink : Color.evaInputTextDisabled)
                        .frame(
                            width: EvaRatingScaleMetrics.dotSize(point),
                            height: EvaRatingScaleMetrics.dotSize(point)
                        )
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.cellHeight)
            .background(
                Color.white.opacity(isSelected ? 0.97 : 0.6),
                in: .rect(cornerRadius: Self.cellRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? ink : Color.white.opacity(0.85),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(.rect(cornerRadius: Self.cellRadius, style: .continuous))
        }
        .buttonStyle(.evaUndimmed)
        // The whole cell is a dot or an emoji, so the announcement is the only thing that
        // makes the scale readable — §6 asks for "Energy, 2 of 5, Low" exactly.
        .accessibilityLabel(
            word(for: point).map { "\(label), \(point) of 5, \($0)" } ?? "\(label), \(point) of 5"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("scale.\(label).\(point)")
    }
}

/// Drawing values read off the artboard's `scales`.
///
/// Literals here for the reason `EvaCalendarMetrics` gives: a 9pt corner on a 23pt badge is
/// a composition at the canvas' own frame, not a step on the spacing or radius scale, and
/// rounding it to the nearest named radius would change the drawing rather than honour it.
enum EvaRatingScaleMetrics {
    /// `font-size:23px` on the emoji cells.
    static let glyphSize: CGFloat = 23
    /// `border-radius:9px` on the readout badge.
    static let readoutRadius: CGFloat = 9
    /// `grayscale(.55)` and `opacity(.72)` on the cells that are not chosen.
    static let unselectedGrayscale: Double = 0.55
    static let unselectedOpacity: Double = 0.72
    /// `width:(4+n*2)px` — the graduated dots on a scale drawn without glyphs.
    static func dotSize(_ point: Int) -> CGFloat { CGFloat(4 + point * 2) }

    /// `linear-gradient(150deg, …)`, the same direction the standard card takes — see
    /// `EvaCardSurfaceModifier` for where the unit points come from.
    static func tint(_ top: Color, _ bottom: Color) -> LinearGradient {
        LinearGradient(
            colors: [top, bottom],
            startPoint: UnitPoint(x: 0.159, y: -0.092),
            endPoint: UnitPoint(x: 0.841, y: 1.092)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview("Rating scale") {
    @Previewable @State var energy: Int? = 2
    @Previewable @State var sleep: Int?

    return ZStack {
        EvaScreenBackground().ignoresSafeArea()
        VStack(spacing: EvaSpacing.md) {
            EvaRatingScale(
                label: "Energy",
                words: ["Depleted", "Low", "Steady", "Good", "High"],
                glyphs: ["😴", "🥱", "😐", "🙂", "⚡"],
                lowAnchor: "Depleted",
                highAnchor: "Energized",
                ink: .evaActionPinkSolid,
                tint: EvaRatingScaleMetrics.tint(
                    .evaPrimaryPink.opacity(0.22), .evaPrimaryPink.opacity(0.08)
                ),
                border: .evaDeepPink.opacity(0.28),
                selection: $energy
            )
            EvaRatingScale(
                label: "Sleep",
                words: ["Barely slept", "Restless", "Broken", "Solid", "Deep"],
                glyphs: nil,
                lowAnchor: "Restless",
                highAnchor: "Deep",
                ink: .evaInformationInk,
                tint: EvaRatingScaleMetrics.tint(
                    .evaInformation.opacity(0.20), .evaInformation.opacity(0.06)
                ),
                border: .evaInformation.opacity(0.28),
                selection: $sleep
            )
        }
        .padding(EvaSpacing.lg)
    }
}

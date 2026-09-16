import SwiftUI

// The marks a day cell carries, read off the `cal` screen in "Eva App.dc.html".
//
// **Position and shape carry the meaning; colour only reinforces it.** That is the whole
// design of this file and it is an accessibility property, not decoration — DESIGN.md §1:
// "Never colour alone — every state carries shape, icon or text too". Four marks on a
// 50pt cell cannot be told apart by hue by a red-green colourblind user, and three of the
// four are 5–6pt across, which is below where hue is reliably perceived by anyone. So
// each type owns a corner *and* an outline: bottom-left circle, bottom-centre square,
// bottom-right diamond, top-right badge. Two marks never share a corner, which is what
// lets a cell be read at a glance and by touch exploration.
//
// A new type does not get "the same shape in a new colour". It gets a free corner, or the
// design gets revisited.

/// One of the four marks a day cell can carry.
///
/// `cycle` is absent on purpose: a period day is drawn as the cell's *fill*, not as a
/// mark, so the two never compete for the same corner. See `EvaCycleMark.cellFill`.
enum EvaEventGlyph: String, Hashable, Sendable, CaseIterable {
    case sex
    case bodySignals
    case sport
    case appointment

    /// Which corner of the cell this mark owns. No two share one.
    enum Position: Hashable, Sendable {
        case bottomLeading
        case bottomCenter
        case bottomTrailing
        case topTrailing
    }

    /// The outline that distinguishes this mark with the colour removed.
    enum Shape: Hashable, Sendable {
        case dot
        case square
        case diamond
        /// A hollow rounded square carrying a `+`.
        case badge
    }

    var position: Position {
        switch self {
        case .sex: .bottomLeading
        case .bodySignals: .bottomCenter
        case .sport: .bottomTrailing
        case .appointment: .topTrailing
        }
    }

    var shape: Shape {
        switch self {
        case .sex: .dot
        case .bodySignals: .square
        case .sport: .diamond
        case .appointment: .badge
        }
    }

    /// The artboard's colour for this mark. Reinforcement only — never the sole signal.
    ///
    /// Sex is drawn in Secondary Text rather than a hue of its own, and that is a product
    /// decision rather than a palette shortage: the canvas note on `sex` says "the
    /// calendar shows a neutral dot with no label". A sensitive event stays neutral in its
    /// indicator as well as in its language (DESIGN.md §8).
    var tint: Color {
        switch self {
        case .sex: .evaSecondaryText
        case .bodySignals: .evaDeepPink
        case .sport: .evaSuccess
        case .appointment: .evaInformationInk
        }
    }

    /// What the legend calls it — shape named in the words, so the legend works in
    /// greyscale too. The artboard's own legend strings, with Appointment added (see
    /// `CalendarLegend`).
    var legendLabel: String {
        switch self {
        case .sex: "Sex · bottom-left dot"
        case .bodySignals: "Body signals · center square"
        case .sport: "Sport · right diamond"
        case .appointment: "Appointment · top-right badge"
        }
    }

    /// What a day cell announces for this mark. The artboard's `aria-label`s.
    var accessibilityLabel: String {
        switch self {
        case .sex: "Sex logged"
        case .bodySignals: "Body signals logged"
        case .sport: "Sport logged"
        case .appointment: "Appointment"
        }
    }
}

extension EvaEventType {
    /// The mark this type draws on a day cell, or `nil` for a type drawn some other way.
    var glyph: EvaEventGlyph? {
        switch self {
        case .sex: .sex
        case .bodySignals: .bodySignals
        case .sport: .sport
        case .appointment: .appointment
        // Drawn as the cell's fill, not as a corner mark.
        case .cycle: nil
        }
    }
}

extension EvaCycleMark {

    /// The cell wash for a logged flow, or `nil` for spotting, which is not a flow.
    ///
    /// `.spotting` answers `nil` on purpose and always will: the three washes say "period
    /// day", and a spotting day does not start a period. It is drawn instead by
    /// `spottingRing` — see there for why the artboard has nothing to copy.
    var cellFill: Color? {
        switch self {
        case .spotting: nil
        // `rgba(201,95,134,.42)` / `rgba(233,130,165,.30)` / `rgba(233,130,165,.16)`.
        case .flow(.heavy): Color.evaDeepPink.opacity(0.42)
        case .flow(.medium): Color.evaPrimaryPink.opacity(0.30)
        case .flow(.light): Color.evaPrimaryPink.opacity(0.16)
        }
    }

    /// What a day cell announces for this entry — the artboard's
    /// `['Spotting','Light','Medium','Heavy'][flow] + ' flow logged'`, except that
    /// spotting is not a flow and is not called one.
    var accessibilityLabel: String {
        switch self {
        case .spotting: "Spotting logged"
        case .flow(.light): "Light flow logged"
        case .flow(.medium): "Medium flow logged"
        case .flow(.heavy): "Heavy flow logged"
        }
    }

    /// Whether this day draws the spotting ring.
    ///
    /// ## A mark the canvas has not drawn (#160)
    ///
    /// The artboard's `mkCell` branches on flow 1–3 only, so a spotting day falls through
    /// to an ordinary cell — announced, listed, and **invisible on the grid**. C1 left that
    /// alone because nothing could log a spotting day yet (#159). C2 can, so invisible is
    /// now wrong, and there is nothing on the canvas to copy.
    ///
    /// Three constraints decided the shape, and each rules something out:
    ///
    /// * **Not a wash.** A fill of any strength is the grid's word for "period day", which
    ///   is the one thing a spotting day must not say.
    /// * **Not a corner mark.** All four corners are taken — dot, square, diamond, badge —
    ///   and the top-left is already promised to the positive-test mark in DESIGN.md §7.
    /// * **Not dashed.** Dashed and patterned are reserved for *predicted* data (§7), and
    ///   a spotting entry is something the user logged.
    ///
    /// What is left is a solid ring around the day's own number: shape-distinct from every
    /// flow cell rather than a paler one of them, concentric with the today disc so a day
    /// that is both still shows both, and inside the selection outline so neither hides the
    /// other. Recorded in DESIGN.md §9a as a deviation, not as a transcription — the canvas
    /// still needs to draw this.
    var spottingRing: Color? {
        self == .spotting ? .evaDeepPink : nil
    }

    /// The legend swatch's words.
    static let legendLabel = "Logged period · flow strength"

    /// The legend's own row for the ring, naming the shape as every other row does.
    static let spottingLegendLabel = "Spotting · ring, not a period day"
}

// MARK: - Drawing

/// One mark, at its own size. Positioned by the cell, not by itself.
struct EvaEventGlyphMark: View {
    let glyph: EvaEventGlyph

    var body: some View {
        switch glyph.shape {
        case .dot:
            Circle()
                .fill(glyph.tint)
                .frame(width: EvaCalendarMetrics.dotSize, height: EvaCalendarMetrics.dotSize)
        case .square:
            RoundedRectangle(cornerRadius: EvaCalendarMetrics.squareRadius, style: .continuous)
                .fill(glyph.tint)
                .frame(width: EvaCalendarMetrics.markSize, height: EvaCalendarMetrics.markSize)
        case .diamond:
            Rectangle()
                .fill(glyph.tint)
                .frame(width: EvaCalendarMetrics.markSize, height: EvaCalendarMetrics.markSize)
                .rotationEffect(.degrees(45))
        case .badge:
            RoundedRectangle(cornerRadius: EvaCalendarMetrics.badgeRadius, style: .continuous)
                .strokeBorder(glyph.tint.opacity(0.65), lineWidth: 1)
                .frame(width: EvaCalendarMetrics.badgeSize, height: EvaCalendarMetrics.badgeSize)
                .overlay {
                    // The artboard draws a literal `+` at 9/700. `Image(systemName:)`
                    // would be a different mark at a different optical weight, and the
                    // badge is small enough that the difference shows.
                    Text(verbatim: "+")
                        .font(.custom(EvaFont.bold, size: EvaCalendarMetrics.badgeGlyphSize))
                        .foregroundStyle(glyph.tint)
                }
        }
    }
}

/// The marks layer of a day cell: every glyph in its own corner, over whatever the cell
/// drew.
///
/// Its own view rather than a private member of `CalendarDayCell` so the corner each mark
/// lands in can be asserted on the pixels. That is the property #159 calls an accessibility
/// one — two marks must never share a corner — and it lives in the composition of
/// `EvaCalendarMetrics.inset(for:)` with `alignment(for:)`, which nothing reaches from the
/// enum values alone.
struct CalendarDayMarks: View {
    let glyphs: [EvaEventGlyph]

    var body: some View {
        ZStack {
            ForEach(glyphs, id: \.self) { glyph in
                EvaEventGlyphMark(glyph: glyph)
                    .padding(EvaCalendarMetrics.inset(for: glyph))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: EvaCalendarMetrics.alignment(for: glyph)
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Event glyphs") {
    VStack(spacing: EvaSpacing.lg) {
        HStack(spacing: EvaSpacing.lg) {
            ForEach(EvaEventGlyph.allCases, id: \.self) { glyph in
                VStack(spacing: EvaSpacing.xs) {
                    EvaEventGlyphMark(glyph: glyph)
                        .frame(width: 24, height: 24)
                    Text(glyph.rawValue)
                        .font(.evaLabel)
                        .foregroundStyle(Color.evaSecondaryText)
                }
            }
        }

        HStack(spacing: EvaSpacing.xs) {
            ForEach(EvaFlowLevel.allCases, id: \.self) { level in
                RoundedRectangle(cornerRadius: EvaCalendarMetrics.cellRadius, style: .continuous)
                    .fill(EvaCycleMark.flow(level).cellFill ?? .clear)
                    .frame(width: 44, height: EvaCalendarMetrics.cellHeight)
                    .overlay {
                        Text(level.rawValue)
                            .font(.evaLabel)
                            .foregroundStyle(Color.evaPrimaryText)
                    }
            }
        }
    }
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}

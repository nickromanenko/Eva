import SwiftUI

// Layout tokens from the Claude Design canvas — DESIGN.md §1 and §4.
// Views use these rather than literal numbers, the same way they use `Color.eva…`
// rather than literal hexes.

/// The 8-pt spacing scale (DESIGN.md §4): 4, 8, 12, 16, 24, 32, 40.
///
/// The scale is deliberately short. If a layout seems to need a value that is not
/// here, it is usually the wrong step rather than a missing token — check the canvas
/// before adding one.
enum EvaSpacing {
    /// 4 — hairline gaps: icon to its label, stacked caption lines.
    static let xxs: CGFloat = 4
    /// 8 — tight gaps inside a control.
    static let xs: CGFloat = 8
    /// 12 — related elements inside a card.
    static let sm: CGFloat = 12
    /// 16 — default padding inside cards and rows.
    static let md: CGFloat = 16
    /// 24 — screen margins, gap between cards.
    static let lg: CGFloat = 24
    /// 32 — gap between sections.
    static let xl: CGFloat = 32
    /// 40 — top of screen to first content, major breaks.
    static let xxl: CGFloat = 40
}

/// Corner radii (DESIGN.md §4).
///
/// Use `.continuous` rounded rectangles throughout — the canvas corners are
/// superelliptical, not circular arcs.
enum EvaRadius {
    /// 14 — chips, and text buttons (§5).
    static let chip: CGFloat = 14
    /// 17 — controls: primary/secondary buttons, inputs, dropdowns (§5, §6).
    static let control: CGFloat = 17
    /// 24 — content cards.
    static let card: CGFloat = 24
    /// 30 — bottom sheets. **Top corners only** — pair with
    /// `UnevenRoundedRectangle(topLeadingRadius:topTrailingRadius:)`.
    static let sheet: CGFloat = 30
    /// 999 — fully rounded pill.
    static let pill: CGFloat = 999
}

/// Sizing rules that are neither spacing nor radius.
enum EvaMetrics {
    /// 44 — minimum touch target on every interactive element (DESIGN.md §1).
    /// Apply with `.frame(minWidth:minHeight:)` when the visual size is smaller;
    /// the tappable area grows, the artwork does not.
    static let minimumTouchTarget: CGFloat = 44
}

// MARK: - Preview

private struct EvaMetricSample: Identifiable {
    let name: String
    let value: CGFloat
    var id: String { name }
}

#Preview("Spacing & radii") {
    let spacing = [
        EvaMetricSample(name: "xxs", value: EvaSpacing.xxs),
        EvaMetricSample(name: "xs", value: EvaSpacing.xs),
        EvaMetricSample(name: "sm", value: EvaSpacing.sm),
        EvaMetricSample(name: "md", value: EvaSpacing.md),
        EvaMetricSample(name: "lg", value: EvaSpacing.lg),
        EvaMetricSample(name: "xl", value: EvaSpacing.xl),
        EvaMetricSample(name: "xxl", value: EvaSpacing.xxl)
    ]
    let radii = [
        EvaMetricSample(name: "chip", value: EvaRadius.chip),
        EvaMetricSample(name: "control", value: EvaRadius.control),
        EvaMetricSample(name: "card", value: EvaRadius.card),
        EvaMetricSample(name: "sheet", value: EvaRadius.sheet)
    ]

    return ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.lg) {
            Text("Spacing").font(.headline)
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                ForEach(spacing) { step in
                    HStack(spacing: EvaSpacing.sm) {
                        Text(step.name)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 34, alignment: .leading)
                        Rectangle()
                            .fill(Color.evaPrimaryPink)
                            .frame(width: step.value, height: 12)
                        Text("\(Int(step.value))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.evaMutedText)
                    }
                }
            }

            Text("Radii").font(.headline)
            HStack(spacing: EvaSpacing.sm) {
                ForEach(radii) { radius in
                    VStack(spacing: EvaSpacing.xxs) {
                        RoundedRectangle(cornerRadius: radius.value, style: .continuous)
                            .fill(Color.evaSoftBlush)
                            .frame(width: 70, height: 70)
                        Text("\(radius.name) \(Int(radius.value))")
                            .font(.system(size: 10))
                    }
                }
            }

            HStack(spacing: EvaSpacing.sm) {
                RoundedRectangle(cornerRadius: EvaRadius.pill, style: .continuous)
                    .fill(Color.evaLightPistachio)
                    .frame(width: 120, height: EvaMetrics.minimumTouchTarget)
                    .overlay {
                        Text("pill").font(.system(size: 11))
                    }
                Text("Minimum touch target \(Int(EvaMetrics.minimumTouchTarget))pt")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.evaSecondaryText)
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}

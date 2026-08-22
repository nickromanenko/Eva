#if DEBUG
import SwiftUI

/// DESIGN.md §1 and §4 — the spacing scale, the radii, and the control heights.
///
/// `EvaSpacing`, `EvaRadius` and `EvaControl` are namespaces of `static let`s rather
/// than `CaseIterable` enums, so the lists below are written out by hand. Adding a step
/// to the scale does not add it here.
struct EvaSpecimenMetricsSection: View {

    private let spacing: [Step] = [
        Step(name: "xxs", value: EvaSpacing.xxs, use: "icon to label"),
        Step(name: "xs", value: EvaSpacing.xs, use: "inside a control"),
        Step(name: "sm", value: EvaSpacing.sm, use: "inside a card"),
        Step(name: "md", value: EvaSpacing.md, use: "card and row padding"),
        Step(name: "lg", value: EvaSpacing.lg, use: "screen margin"),
        Step(name: "xl", value: EvaSpacing.xl, use: "between sections"),
        Step(name: "xxl", value: EvaSpacing.xxl, use: "major breaks")
    ]

    private let radii: [Step] = [
        Step(name: "chip", value: EvaRadius.chip, use: "chips, text buttons"),
        Step(name: "control", value: EvaRadius.control, use: "buttons, inputs"),
        Step(name: "card", value: EvaRadius.card, use: "content cards"),
        Step(name: "sheet", value: EvaRadius.sheet, use: "sheets · top only")
    ]

    private let heights: [Step] = [
        Step(name: "control", value: EvaControl.height, use: "buttons, inputs"),
        Step(name: "text button", value: EvaControl.textButtonHeight, use: "§5 text button"),
        Step(name: "touch target", value: EvaMetrics.minimumTouchTarget, use: "§1 minimum")
    ]

    var body: some View {
        EvaSpecimenSection(number: "03", title: "Spacing & radii", reference: "DESIGN.md §1, §4") {
            EvaSpecimenGroupLabel(title: "Spacing · 4, 8, 12, 16, 24, 32, 40")
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                ForEach(spacing) { step in
                    EvaSpecimenSpacingRow(step: step)
                }
            }

            EvaSpecimenGroupLabel(title: "Radii")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: EvaSpacing.sm)],
                spacing: EvaSpacing.sm
            ) {
                ForEach(radii) { radius in
                    EvaSpecimenRadiusTile(step: radius)
                }
            }

            HStack(spacing: EvaSpacing.sm) {
                RoundedRectangle(cornerRadius: EvaRadius.pill, style: .continuous)
                    .fill(Color.evaLightPistachio)
                    .overlay {
                        RoundedRectangle(cornerRadius: EvaRadius.pill, style: .continuous)
                            .strokeBorder(Color.evaControlBorder, lineWidth: 1)
                    }
                    .frame(width: 120, height: EvaMetrics.minimumTouchTarget)
                    .overlay {
                        Text("pill · 999")
                            .evaTextStyle(.label)
                            .foregroundStyle(Color.evaPrimaryText)
                    }
                Spacer(minLength: 0)
            }

            EvaSpecimenGroupLabel(title: "Control heights")
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                ForEach(heights) { height in
                    EvaSpecimenHeightRow(step: height)
                }
            }
        }
    }
}

// MARK: - Rows
//
// The bare numbers below (label gutter, tile height, swatch widths) are specimen
// chrome — the ruler, not the thing being measured. The values under test are always
// read from `EvaSpacing` / `EvaRadius` / `EvaControl`, never typed in.

/// One named metric.
private struct Step: Identifiable {
    let name: String
    let value: CGFloat
    let use: String

    var id: String { name }
}

/// A spacing step drawn at its own width.
private struct EvaSpecimenSpacingRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: EvaSpacing.sm) {
            Text(step.name)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaPrimaryText)
                .frame(width: 34, alignment: .leading)

            Rectangle()
                .fill(Color.evaPrimaryPink)
                .frame(width: step.value, height: EvaSpacing.sm)

            Text("\(Int(step.value)) · \(step.use)")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)

            Spacer(minLength: 0)
        }
    }
}

/// A radius drawn as a tile at that radius.
private struct EvaSpecimenRadiusTile: View {
    let step: Step

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            RoundedRectangle(cornerRadius: step.value, style: .continuous)
                .fill(Color.evaSoftBlush)
                .overlay {
                    RoundedRectangle(cornerRadius: step.value, style: .continuous)
                        .strokeBorder(Color.evaControlBorder, lineWidth: 1)
                }
                .frame(height: 78)

            Text("\(step.name) · \(Int(step.value))")
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaPrimaryText)

            Text(step.use)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
                // Reserved, so a wrapping caption keeps its grid row aligned.
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A control height drawn as a bar of that height.
private struct EvaSpecimenHeightRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: EvaSpacing.sm) {
            RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                .fill(Color.evaLightPistachio)
                .overlay {
                    RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                        .strokeBorder(Color.evaControlBorder, lineWidth: 1)
                }
                .frame(width: 96, height: step.value)

            Text("\(step.name) · \(Int(step.value)) · \(step.use)")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)

            Spacer(minLength: 0)
        }
    }
}

#Preview("Spacing & radii") {
    ScrollView {
        EvaSpecimenMetricsSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

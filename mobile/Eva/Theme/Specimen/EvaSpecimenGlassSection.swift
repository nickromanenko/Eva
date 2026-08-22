#if DEBUG
import SwiftUI

/// DESIGN.md §4 — the three glass levels, the standard card treatment and the sheet
/// surface, all over a blurred colour field so there is something to see through them.
///
/// Read this section against §9a before filing anything as a bug: SwiftUI has no
/// backdrop filter, so the canvas' 20/24/28 blur radii collapse onto
/// ultraThin/thin/regular materials and `saturate(1.7)` is simply absent. What is
/// checkable here is the *ordering* — L1 lets the most colour through, L3 the least —
/// and whether L2 is genuinely body-text safe.
struct EvaSpecimenGlassSection: View {

    var body: some View {
        EvaSpecimenSection(number: "04", title: "Glass & surfaces", reference: "DESIGN.md §4") {
            EvaSpecimenNote(
                text: "§9a: blur radius is not settable in SwiftUI and Material adds its own "
                    + "tint under the white fill, so every level reads more opaque than the canvas."
            )

            VStack(spacing: EvaSpacing.md) {
                EvaSpecimenGlassCard(
                    title: "L1 · Background glass",
                    detail: "40% white, blur 20 — decorative only, body text not guaranteed.",
                    level: .background
                )

                EvaSpecimenGlassCard(
                    title: "L2 · Interactive card",
                    detail: "68% white, blur 24 — body text is safe on this level.",
                    level: .card
                )

                EvaSpecimenGlassCard(
                    title: "L3 · Sheet / modal",
                    detail: "92% white, blur 28 — long-form content.",
                    level: .sheet
                )

                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text("Standard card treatment")
                        .evaTextStyle(.h3)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text("150° white gradient, hairline border, inset top/bottom lines, mauve shadow.")
                        .evaTextStyle(.body)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EvaSpacing.md)
                .evaCardSurface()

                // The grabber and the 26pt bottom inset are §7 prose with no component
                // and no token behind them — `EvaGlass.swift` gives the surface only.
                // Drawn inline here rather than inventing tokens for them; see the
                // findings in the issue.
                VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                    Capsule(style: .continuous)
                        .fill(Color.evaMutedText.opacity(0.4))
                        .frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity)

                    Text("Bottom sheet")
                        .evaTextStyle(.h3)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text("L3 glass, 30pt top corners only, grabber, 26pt safe-area bottom padding.")
                        .evaTextStyle(.body)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EvaSpacing.md)
                .padding(.bottom, 26)
                .evaSheetSurface()
            }
            .padding(EvaSpacing.md)
            .background {
                EvaSpecimenColorField()
            }
            .clipShape(RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous))
        }
    }
}

// MARK: - Card

/// One glass level over the colour field, carrying enough text to judge legibility.
private struct EvaSpecimenGlassCard: View {
    let title: String
    let detail: String
    let level: EvaGlassLevel

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text(title)
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)

            Text(detail)
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(level)
    }
}

#Preview("Glass & surfaces") {
    ScrollView {
        EvaSpecimenGlassSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

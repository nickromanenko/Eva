#if DEBUG
import SwiftUI

/// DESIGN.md §4 — the three glass levels, the standard card treatment and the sheet
/// surface, all over a blurred colour field so there is something to see through them.
///
/// Read this section against §9b before filing anything as a bug: SwiftUI has no
/// backdrop filter, so L2's and L3's canvas blur radii collapse onto `.thin` and
/// `.regular` and `saturate(1.7)` is simply absent. What is checkable here is the
/// *ordering* — L1 lets the most colour through, L3 the least — and whether L2 is
/// genuinely body-text safe.
///
/// **L1 renders no `Material` at all** (§9a, decided on #12). Each card's caption is
/// derived from its own `EvaGlassLevel`, so the fill percentage, the canvas blur radius
/// and whether a backdrop material is drawn all come from the token rather than from a
/// sentence someone typed next to it.
struct EvaSpecimenGlassSection: View {

    var body: some View {
        EvaSpecimenSection(number: "04", title: "Glass & surfaces", reference: "DESIGN.md §4, §9a") {
            EvaSpecimenNote(
                text: "§9b: blur radius is not settable in SwiftUI, so L2 and L3 read more "
                    + "opaque than the canvas — Material adds its own tint beneath the white "
                    + "fill. §9a: that is exactly why L1 drops Material and renders as a "
                    + "plain 40% fill. With it, a 40% surface read at roughly 70% and L1 "
                    + "was indistinguishable from L2."
            )

            VStack(spacing: EvaSpacing.md) {
                EvaSpecimenGlassSeparationStrip()

                EvaSpecimenGlassCard(
                    title: "L1 · Background glass",
                    use: "decorative only — body text is not guaranteed",
                    level: .background
                )

                EvaSpecimenGlassCard(
                    title: "L2 · Interactive card",
                    use: "body text is safe on this level",
                    level: .card
                )

                EvaSpecimenGlassCard(
                    title: "L3 · Sheet / modal",
                    use: "long-form content",
                    level: .sheet
                )

                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text("Standard card treatment")
                        .evaTextStyle(.h3)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text("150° white gradient 66% → 36%, hairline 72% border, inset lines "
                        + "90% top / 40% bottom, neutral shadow (#12).")
                        .evaTextStyle(.body)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EvaSpacing.md)
                .evaCardSurface()

                // The grabber and the 26pt bottom inset are §7 prose with no component
                // and no token behind them — `EvaGlass.swift` gives the surface only.
                // Drawn inline here rather than inventing tokens for them.
                VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                    Capsule(style: .continuous)
                        .fill(Color.evaMutedText.opacity(0.4))
                        .frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity)

                    Text("Bottom sheet")
                        .evaTextStyle(.h3)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text("L3 glass, \(EvaSpecimenNumber.string(EvaRadius.sheet))pt top corners "
                        + "only, grabber, 26pt safe-area bottom padding.")
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

            EvaSpecimenNote(
                text: "§7's sheet grabber and 26pt bottom inset have no token behind them; "
                    + "they are drawn inline here, so this is prose, not a component."
            )
        }
    }
}

// MARK: - Separation

/// L1 and L2 butted edge to edge over the same backdrop, with no gap between them.
///
/// The thing #12 actually complained about was that the two levels were
/// indistinguishable, and two cards a `EvaSpacing.md` apart cannot answer that: separate
/// patches of translucency over a slowly-varying wash look alike whatever their alpha.
/// Sharing an edge turns the comparison into a step change, which the eye reads
/// immediately — if this strip looks like one rectangle, L1 and L2 have collapsed again.
private struct EvaSpecimenGlassSeparationStrip: View {

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            HStack(spacing: 0) {
                EvaSpecimenGlassSeparationHalf(level: .background, title: "L1")
                EvaSpecimenGlassSeparationHalf(level: .card, title: "L2")
            }
            // Its own field rather than the section's. The section's blobs are centred on
            // a container this strip sits at the top of, so the colour behind it depends
            // on how tall everything below happens to be — and a comparison of two
            // translucencies over a nearly-white backdrop shows nothing. This one is
            // centred on the strip.
            .background { EvaSpecimenColorField() }
            .clipShape(RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous))

            Text("L1 and L2 share an edge — the step between them is the separation "
                + "#12 asked for.")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("specimen.glass.separation")
    }
}

/// One half of the edge-to-edge strip. A square-cornered glass fill, so the two halves
/// meet without a seam of backdrop showing between them.
private struct EvaSpecimenGlassSeparationHalf: View {
    let level: EvaGlassLevel
    let title: String

    @Environment(\.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .evaTextStyle(.h3)
            Text(level.evaSpecimenFillCaption(in: environment))
                .evaTextStyle(.caption)
        }
        .foregroundStyle(Color.evaPrimaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, EvaSpacing.md)
        .evaGlass(level, in: Rectangle())
    }
}

// MARK: - Card

/// One glass level over the colour field, carrying enough text to judge legibility.
///
/// The detail line is built from the level, not written beside it: the fill percentage,
/// the canvas blur radius and whether a backdrop material is drawn are all properties of
/// `EvaGlassLevel`, and L1's caption claimed "blur 20" for months after L1 stopped
/// rendering anything to blur.
private struct EvaSpecimenGlassCard: View {
    let title: String
    /// What the level is for. The only part of the caption a token cannot supply.
    let use: String
    let level: EvaGlassLevel

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text(title)
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)

            Text("\(level.evaSpecimenFillCaption(in: environment)) — \(use).")
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(level)
    }
}

// MARK: - Deriving the caption

extension EvaGlassLevel {

    /// What this level actually paints: its white fill, and either the canvas blur it
    /// approximates with a `Material` or the fact that it draws none.
    func evaSpecimenFillCaption(in environment: EnvironmentValues) -> String {
        let fill = tint.evaSpecimenReadback(in: environment)
        let backdrop = rendersBackdropMaterial
            ? "Material ≈ blur \(EvaSpecimenNumber.string(canvasBlurRadius))"
            : "no backdrop material"
        return "\(fill.alphaPercent)% \(fill.hex) · \(backdrop)"
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

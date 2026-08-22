#if DEBUG
import SwiftUI

/// DESIGN.md §2 — brand, neutrals, semantic, the gradients, and §9a's action ramp.
///
/// **The value under each swatch is read out of the token, not typed beside it.**
/// It used to be a string transcribed from DESIGN.md, which meant a token could change
/// and its caption go on advertising the old hex — the screen whose job is to say what
/// the system currently is was the one thing in the repo that could silently lie about
/// it. `EvaSpecimenColorReadback` resolves the same `Color` the swatch is filled with,
/// so the two cannot disagree. `EvaTests` still locks the numbers to the canvas; this
/// screen shows what they actually are.
///
/// What is still hand-written is prose — what a colour is *for*, and where the
/// implementation deviates. No readback produces that.
struct EvaSpecimenColorSection: View {

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: EvaSpacing.sm)]

    var body: some View {
        EvaSpecimenSection(number: "01", title: "Colour", reference: "DESIGN.md §2, §9a") {
            EvaSpecimenNote(
                text: "Every hex and percentage below is resolved from the token itself, "
                    + "so a caption cannot outlive the value it describes."
            )

            EvaSpecimenGroupLabel(title: "Brand")
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenSwatch(name: "Primary Pink", color: .evaPrimaryPink)
                EvaSpecimenSwatch(name: "Deep Pink", color: .evaDeepPink)
                EvaSpecimenSwatch(name: "Soft Blush", color: .evaSoftBlush)
                EvaSpecimenSwatch(name: "Pistachio", color: .evaPistachio)
                EvaSpecimenSwatch(name: "Deep Pistachio", color: .evaDeepPistachio)
                EvaSpecimenSwatch(name: "Light Pistachio", color: .evaLightPistachio)
                EvaSpecimenSwatch(name: "Primary Button Top", color: .evaPrimaryButtonTop)
                EvaSpecimenSwatch(name: "Gradient Pink", color: .evaGradientPink)
            }
            EvaSpecimenNote(
                text: "The last two are gradient stops, not standalone palette entries — "
                    + "§2 names them only inside the ramps they belong to."
            )

            EvaSpecimenActionRampGroup()

            EvaSpecimenGroupLabel(title: "Neutrals")
            EvaSpecimenNote(
                text: "Translucent tokens sit on the pink→pistachio wash so their alpha reads."
            )
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenSwatch(name: "Warm Background", color: .evaWarmBackground)
                EvaSpecimenSwatch(name: "Secondary Background", color: .evaSecondaryBackground)
                EvaSpecimenSwatch(
                    name: "Glass Surface",
                    color: .evaGlassSurface,
                    showsAlphaBacking: true
                )
                EvaSpecimenSwatch(
                    name: "Elevated Glass",
                    color: .evaElevatedGlass,
                    showsAlphaBacking: true
                )
                EvaSpecimenSwatch(name: "Primary Text", color: .evaPrimaryText)
                EvaSpecimenSwatch(name: "Secondary Text", color: .evaSecondaryText)
                EvaSpecimenSwatch(name: "Muted Text", color: .evaMutedText)
                EvaSpecimenSwatch(
                    name: "Text on Dark",
                    color: .evaTextOnDark,
                    showsAlphaBacking: true
                )
            }

            EvaSpecimenGroupLabel(title: "Semantic")
            EvaSpecimenNote(
                text: "§2: never colour alone. Each row carries its mark and its words as "
                    + "well. The tint, border and ink are the artboard's own values, not "
                    + "opacities of the base hue — Success's tint is pistachio, not the "
                    + "base at 12% — which is why each is printed under its row."
            )
            VStack(spacing: EvaSpacing.xs) {
                EvaSpecimenSemanticRow(
                    name: "Success",
                    base: .evaSuccess,
                    mark: "checkmark.circle.fill",
                    use: "Saved, synced, confirmed",
                    ink: .evaSuccessInk,
                    tint: .evaSuccessTint,
                    border: .evaSuccessBorder
                )
                EvaSpecimenSemanticRow(
                    name: "Warning",
                    base: .evaWarning,
                    mark: "exclamationmark.square.fill",
                    use: "Needs attention, not urgent",
                    ink: .evaWarningInk,
                    tint: .evaWarningTint,
                    border: .evaWarningBorder
                )
                EvaSpecimenSemanticRow(
                    name: "Error",
                    base: .evaError,
                    mark: "exclamationmark.circle.fill",
                    use: "Always paired with a message",
                    ink: .evaErrorInk,
                    tint: .evaErrorTint,
                    border: .evaErrorBorder
                )
                EvaSpecimenSemanticRow(
                    name: "Information",
                    base: .evaInformation,
                    mark: "info.circle.fill",
                    use: "Account linking, limits of data",
                    ink: .evaInformationInk,
                    tint: .evaInformationTint,
                    border: .evaInformationBorder
                )
            }

            EvaSpecimenGroupLabel(title: "Authentication")
            EvaSpecimenNote(
                text: "§5 names these two fills. There is no auth-button component yet — tokens only."
            )
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenSwatch(name: "Auth · Apple", color: .evaAuthApple)
                EvaSpecimenSwatch(
                    name: "Auth · Google",
                    color: .evaAuthGoogleFill,
                    showsAlphaBacking: true
                )
            }

            EvaSpecimenGroupLabel(title: "Gradients")
            EvaSpecimenNote(
                text: "The canvas' own washes. `evaActionPink` and `.evaActionPinkPressed` "
                    + "are shown in the ramp comparison above, where the label they exist "
                    + "for is on them."
            )
            VStack(spacing: EvaSpacing.sm) {
                EvaSpecimenGradientSwatch(
                    name: "Blush → cream · 135°",
                    gradient: .evaBlushCream,
                    stops: [.evaSoftBlush, .evaWarmBackground]
                )
                EvaSpecimenGradientSwatch(
                    name: "Pistachio → cream · 135°",
                    gradient: .evaPistachioCream,
                    stops: [.evaLightPistachio, .evaWarmBackground]
                )
                EvaSpecimenGradientSwatch(
                    name: "Pink → pistachio · 120°",
                    gradient: .evaPinkPistachio,
                    stops: [.evaGradientPink, .evaLightPistachio]
                )
                EvaSpecimenGradientSwatch(
                    name: "Primary button · 180°",
                    gradient: .evaPrimaryButton,
                    stops: [.evaPrimaryButtonTop, .evaDeepPink]
                )
                EvaSpecimenGradientSwatch(
                    name: "Primary button · pressed",
                    gradient: .evaPrimaryButtonPressed,
                    stops: [.evaPrimaryButtonPressedTop, .evaPrimaryButtonPressedBottom]
                )
                EvaSpecimenGradientSwatch(
                    name: "Chip · selected",
                    gradient: .evaChipSelected,
                    stops: [.evaChipSelectedTop, .evaChipSelectedBottom]
                )
                EvaSpecimenGradientSwatch(
                    name: "White highlight over pink · 135°",
                    gradient: .evaPinkHighlightBase,
                    stops: [.evaPrimaryPink, .evaDeepPink],
                    wash: .evaWhiteHighlightWash
                )
            }
            EvaSpecimenNote(
                text: "The wash is 75% white fading to nothing across the full height, over a "
                    + "135° pink base — the canvas value, not the 28%-to-55% this first "
                    + "shipped as. Nothing sits on it, so it keeps the brand pink."
            )
        }
    }
}

// MARK: - Tiles

/// One colour tile: the colour, its name, and the value read back out of it.
private struct EvaSpecimenSwatch: View {
    let name: String
    let color: Color
    /// Draws the pink→pistachio wash behind the fill so a translucent token reads as
    /// translucent instead of vanishing into the warm background.
    var showsAlphaBacking = false

    @Environment(\.self) private var environment

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            shape
                .fill(color)
                .background {
                    if showsAlphaBacking {
                        shape.fill(LinearGradient.evaPinkPistachio)
                    }
                }
                .overlay { shape.strokeBorder(Color.evaControlBorder, lineWidth: 1) }
                .frame(height: EvaMetrics.minimumTouchTarget)

            Text(name)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaPrimaryText)
                // Reserved rather than fitted, so a two-line name does not shove its
                // whole grid row down out of line with the rest.
                .lineLimit(2, reservesSpace: true)

            Text(color.evaSpecimenReadback(in: environment).caption)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One gradient strip, its stops printed underneath, optionally with a second gradient
/// washed over it.
private struct EvaSpecimenGradientSwatch: View {
    let name: String
    let gradient: LinearGradient
    /// The stops the strip is captioned from. `LinearGradient` cannot be asked what it
    /// is made of, so this is the one pairing the readback cannot verify — but both
    /// sides are token references, so no value can drift between them.
    let stops: [Color]
    var wash: LinearGradient?

    @Environment(\.self) private var environment

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    private var stopCaption: String {
        stops
            .map { $0.evaSpecimenReadback(in: environment).caption }
            .joined(separator: " → ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            shape
                .fill(gradient)
                .overlay {
                    if let wash {
                        shape.fill(wash)
                    }
                }
                .frame(height: EvaMetrics.minimumTouchTarget)
                .overlay(alignment: .leading) {
                    Text(name)
                        .evaTextStyle(.label)
                        .foregroundStyle(Color.evaPrimaryText)
                        .padding(.leading, EvaSpacing.sm)
                }

            Text(stopCaption)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
        }
    }
}

/// A semantic colour shown the way §2 says it must appear — mark, words and colour
/// together — on its own tint and border, with all four values read back underneath.
private struct EvaSpecimenSemanticRow: View {
    let name: String
    let base: Color
    let mark: String
    let use: String
    let ink: Color
    let tint: Color
    let border: Color

    @Environment(\.self) private var environment

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    /// The evidence that these are the artboard's own values rather than opacities of
    /// the base: if they were derivations, this line would read as three tints of one hex.
    private var valueCaption: String {
        let tintValue = tint.evaSpecimenReadback(in: environment).caption
        let borderValue = border.evaSpecimenReadback(in: environment).caption
        let inkValue = ink.evaSpecimenReadback(in: environment).caption
        return "tint \(tintValue) · border \(borderValue) · ink \(inkValue)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: EvaSpacing.sm) {
            Image(systemName: mark)
                .font(.evaH3)
                .foregroundStyle(ink)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(name) · \(base.evaSpecimenReadback(in: environment).caption)")
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(ink)
                Text(use)
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                Text(valueCaption)
                    .evaTextStyle(.inputHelper)
                    .foregroundStyle(Color.evaMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, EvaSpacing.md)
        .padding(.vertical, EvaSpacing.sm)
        .frame(minHeight: EvaMetrics.minimumTouchTarget)
        .background { shape.fill(tint) }
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
    }
}

#Preview("Colour") {
    ScrollView {
        EvaSpecimenColorSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

#if DEBUG
import SwiftUI

/// DESIGN.md §2 — brand, neutrals, semantic and the gradients.
///
/// The value printed under each swatch is a **string, not a readback of the token**.
/// `Color` cannot be asked what hex it was built from in any way that survives the
/// colour-space round trip, so the caption is typed out from DESIGN.md and can drift
/// from `EvaColors.swift` without anything failing. `EvaTests` is what actually locks
/// the numbers down; this screen is for looking at the colours.
struct EvaSpecimenColorSection: View {

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: EvaSpacing.sm)]

    var body: some View {
        EvaSpecimenSection(number: "01", title: "Colour", reference: "DESIGN.md §2") {
            EvaSpecimenGroupLabel(title: "Brand")
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenSwatch(name: "Primary Pink", value: "#E982A5", color: .evaPrimaryPink)
                EvaSpecimenSwatch(name: "Deep Pink", value: "#C95F86", color: .evaDeepPink)
                EvaSpecimenSwatch(name: "Soft Blush", value: "#F9DCE6", color: .evaSoftBlush)
                EvaSpecimenSwatch(name: "Pistachio", value: "#CDE79D", color: .evaPistachio)
                EvaSpecimenSwatch(name: "Deep Pistachio", value: "#8EAD56", color: .evaDeepPistachio)
                EvaSpecimenSwatch(name: "Light Pistachio", value: "#EDF6DA", color: .evaLightPistachio)
            }

            EvaSpecimenGroupLabel(title: "Neutrals")
            EvaSpecimenNote(
                text: "Translucent tokens sit on the pink→pistachio wash so their alpha reads."
            )
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenSwatch(name: "Warm Background", value: "#FFF9F6", color: .evaWarmBackground)
                EvaSpecimenSwatch(
                    name: "Secondary Background",
                    value: "#F8F3F0",
                    color: .evaSecondaryBackground
                )
                EvaSpecimenSwatch(
                    name: "Glass Surface",
                    value: "white 66%",
                    color: .evaGlassSurface,
                    showsAlphaBacking: true
                )
                EvaSpecimenSwatch(
                    name: "Elevated Glass",
                    value: "255,252,250 · 92%",
                    color: .evaElevatedGlass,
                    showsAlphaBacking: true
                )
                EvaSpecimenSwatch(name: "Primary Text", value: "#282126", color: .evaPrimaryText)
                EvaSpecimenSwatch(name: "Secondary Text", value: "#6F656B", color: .evaSecondaryText)
                EvaSpecimenSwatch(name: "Muted Text", value: "#9A9095", color: .evaMutedText)
                EvaSpecimenSwatch(
                    name: "Text on Dark",
                    value: "#FFFFFF",
                    color: .evaTextOnDark,
                    showsAlphaBacking: true
                )
            }

            EvaSpecimenGroupLabel(title: "Semantic")
            EvaSpecimenNote(
                text: "§2: never colour alone. Each row carries its mark and its words as well."
            )
            VStack(spacing: EvaSpacing.xs) {
                EvaSpecimenSemanticRow(
                    name: "Success",
                    value: "#7A9B45",
                    mark: "checkmark.circle.fill",
                    use: "Saved, synced, confirmed",
                    ink: .evaSuccessInk,
                    tint: .evaSuccessTint,
                    border: .evaSuccessBorder
                )
                EvaSpecimenSemanticRow(
                    name: "Warning",
                    value: "#C9913F",
                    mark: "exclamationmark.square.fill",
                    use: "Needs attention, not urgent",
                    ink: .evaWarningInk,
                    tint: .evaWarningTint,
                    border: .evaWarningBorder
                )
                EvaSpecimenSemanticRow(
                    name: "Error",
                    value: "#C4645A",
                    mark: "exclamationmark.circle.fill",
                    use: "Always paired with a message",
                    ink: .evaErrorInk,
                    tint: .evaErrorTint,
                    border: .evaErrorBorder
                )
                EvaSpecimenSemanticRow(
                    name: "Information",
                    value: "#5A7BA0",
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
                EvaSpecimenSwatch(name: "Auth · Apple", value: "#1C1A1B", color: .evaAuthApple)
                EvaSpecimenSwatch(
                    name: "Auth · Google",
                    value: "white 85%",
                    color: .evaAuthGoogleFill,
                    showsAlphaBacking: true
                )
            }

            EvaSpecimenGroupLabel(title: "Gradients")
            VStack(spacing: EvaSpacing.xs) {
                EvaSpecimenGradientSwatch(name: "Blush → cream", gradient: .evaBlushCream)
                EvaSpecimenGradientSwatch(name: "Pistachio → cream", gradient: .evaPistachioCream)
                EvaSpecimenGradientSwatch(name: "Pink → pistachio", gradient: .evaPinkPistachio)
                EvaSpecimenGradientSwatch(name: "Primary button", gradient: .evaPrimaryButton)
                EvaSpecimenGradientSwatch(
                    name: "Primary button · pressed",
                    gradient: .evaPrimaryButtonPressed
                )
                EvaSpecimenGradientSwatch(name: "Chip · selected", gradient: .evaChipSelected)
                EvaSpecimenGradientSwatch(
                    name: "White highlight over pink",
                    gradient: .evaPinkHighlightBase,
                    wash: .evaWhiteHighlightWash
                )
            }
            EvaSpecimenNote(
                text: "§9b: the white wash's 28% / 55% stops are a guess, not a canvas value."
            )
        }
    }
}

// MARK: - Tiles

/// One colour tile: the colour itself, its name and the canvas value it stands for.
private struct EvaSpecimenSwatch: View {
    let name: String
    let value: String
    let color: Color
    /// Draws the pink→pistachio wash behind the fill so a translucent token reads as
    /// translucent instead of vanishing into the warm background.
    var showsAlphaBacking = false

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

            Text(value)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One gradient strip, optionally with a second gradient washed over it.
private struct EvaSpecimenGradientSwatch: View {
    let name: String
    let gradient: LinearGradient
    var wash: LinearGradient?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    var body: some View {
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
    }
}

/// A semantic colour shown the way §2 says it must appear: mark, words and colour
/// together, on the derived tint and border.
private struct EvaSpecimenSemanticRow: View {
    let name: String
    let value: String
    let mark: String
    let use: String
    let ink: Color
    let tint: Color
    let border: Color

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    var body: some View {
        HStack(spacing: EvaSpacing.sm) {
            Image(systemName: mark)
                .font(.evaH3)
                .foregroundStyle(ink)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(name) · \(value)")
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(ink)
                Text(use)
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
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

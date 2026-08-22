#if DEBUG
import SwiftUI

/// DESIGN.md §9a — the action ramp, beside the brand pink it did not replace.
///
/// This is the one place in the design system where the implementation deliberately
/// disagrees with the artboard, so it is shown as a disagreement: the canvas pink on the
/// left, the ramp that replaced it on the right, the same white label on both, and the
/// measured ratio under each. The pale pinks are still correct — they simply may not
/// carry a label — and a swatch grid that listed the ramp on its own would not say that.
///
/// Every hex and every ratio below is read out of the token (`EvaSpecimenColorReadback`),
/// not typed in. The one thing pairing a gradient with the stops it is measured from
/// cannot check is that the pairing itself is right: `LinearGradient` will not name its
/// own stops, so `evaPrimaryButton` is measured from `evaPrimaryButtonTop`/`evaDeepPink`
/// on the strength of a comment in `EvaColors.swift`. Both sides are token references,
/// so no *value* can drift between them.
struct EvaSpecimenActionRampGroup: View {

    /// WCAG 2.1 SC 1.4.3 for normal text. Every Eva label is 14.5pt or smaller, so
    /// nothing here qualifies for the 3:1 large-text bar.
    static let bar: Double = 4.5

    private let surfaces: [EvaSpecimenPinkSurface] = [
        EvaSpecimenPinkSurface(
            role: "Primary button",
            canvas: .gradient(.evaPrimaryButton, stops: [.evaPrimaryButtonTop, .evaDeepPink]),
            action: .gradient(.evaActionPink, stops: [.evaActionPinkTop, .evaActionPinkBottom])
        ),
        EvaSpecimenPinkSurface(
            role: "Primary button · pressed",
            canvas: .gradient(
                .evaPrimaryButtonPressed,
                stops: [.evaPrimaryButtonPressedTop, .evaPrimaryButtonPressedBottom]
            ),
            action: .gradient(
                .evaActionPinkPressed,
                stops: [.evaActionPinkPressedTop, .evaActionPinkPressedBottom]
            )
        ),
        EvaSpecimenPinkSurface(
            role: "Selected chip",
            canvas: .gradient(.evaChipSelected, stops: [.evaChipSelectedTop, .evaChipSelectedBottom]),
            action: .gradient(.evaActionPink, stops: [.evaActionPinkTop, .evaActionPinkBottom])
        ),
        EvaSpecimenPinkSurface(
            role: "Today marker · FAB",
            canvas: .solid(.evaDeepPink),
            action: .solid(.evaActionPinkSolid)
        ),
        EvaSpecimenPinkSurface(
            role: "Severe chip",
            canvas: .solid(.evaDeepPink),
            action: .solid(.evaChipSevere, border: .evaChipSevereBorder)
        )
    ]

    var body: some View {
        EvaSpecimenGroupLabel(title: "Pink · brand and action ramp")

        EvaSpecimenNote(
            text: "§9a, an approved deviation (#12). White on the canvas pink fails AA "
                + "wherever it carries a label, so surfaces that carry one use the deepened "
                + "ramp on the right. Washes, tints and any pink with nothing on top of it "
                + "keep the artboard pink on the left — it is still the brand colour. "
                + "Ratios are white against the worst point of each ramp; the bar is "
                + "\(EvaSpecimenNumber.string(CGFloat(Self.bar))):1 for a 14.5pt label."
        )

        HStack(alignment: .bottom, spacing: EvaSpacing.sm) {
            Text("Canvas pink · washes only")
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Action ramp · labelled")
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(surfaces) { surface in
            EvaSpecimenPinkSurfaceRow(surface: surface)
        }

        EvaSpecimenNote(
            text: "Severe is not simply the ramp: at the ramp's solid #A94A6C it landed on "
                + "the selected chip's own midpoint and the two states stopped being "
                + "distinguishable. It sits ~80 channel-units deeper, and carries a border "
                + "and a bar glyph that selected does not."
        )
    }
}

// MARK: - Model

/// One surface the ramp decision applies to: what the canvas fills it with, and what
/// the implementation fills it with instead.
struct EvaSpecimenPinkSurface: Identifiable {
    let role: String
    let canvas: EvaSpecimenRamp
    let action: EvaSpecimenRamp

    var id: String { role }
}

/// A fill to render, plus the stops to measure it from.
///
/// Two fields rather than one because `LinearGradient` is opaque — it can be drawn but
/// not asked what it is made of. `solid(_:)` needs no such pairing and derives both from
/// the single colour it is given.
struct EvaSpecimenRamp {
    /// What actually gets painted. The token itself, so the tile cannot show a
    /// reconstruction of the gradient in place of the real one.
    let style: AnyShapeStyle
    /// The stops the ratio is measured along.
    let stops: [Color]
    /// The label colour that sits on this fill in the product.
    let label: Color
    /// Drawn as a hairline where the surface has one. `nil` for the rest.
    let border: Color?

    static func solid(
        _ color: Color,
        label: Color = .evaTextOnDark,
        border: Color? = nil
    ) -> Self {
        Self(style: AnyShapeStyle(color), stops: [color], label: label, border: border)
    }

    static func gradient(
        _ gradient: LinearGradient,
        stops: [Color],
        label: Color = .evaTextOnDark,
        border: Color? = nil
    ) -> Self {
        Self(style: AnyShapeStyle(gradient), stops: stops, label: label, border: border)
    }
}

// MARK: - Rows

/// One surface's canvas fill and action fill, side by side under their role.
struct EvaSpecimenPinkSurfaceRow: View {
    let surface: EvaSpecimenPinkSurface

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text(surface.role)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaPrimaryText)

            HStack(alignment: .top, spacing: EvaSpacing.sm) {
                EvaSpecimenRampTile(ramp: surface.canvas)
                EvaSpecimenRampTile(ramp: surface.action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One fill, with the label it carries drawn on it at the size the AA bar is set by,
/// and its derived hexes and measured ratio underneath.
struct EvaSpecimenRampTile: View {
    let ramp: EvaSpecimenRamp

    /// The page these tiles sit on. Only matters for a translucent fill, but it is what
    /// makes the ratio a statement about the screen rather than about the token.
    private static let ground = Color.evaWarmBackground

    @Environment(\.self) private var environment

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    private var hexes: String {
        ramp.stops
            .map { $0.evaSpecimenReadback(in: environment).hex }
            .joined(separator: " → ")
    }

    private var ratio: Double {
        EvaSpecimenColorReadback.worstRatio(
            label: ramp.label.evaSpecimenReadback(in: environment),
            alongRamp: ramp.stops.map { $0.evaSpecimenReadback(in: environment) },
            over: Self.ground.evaSpecimenReadback(in: environment)
        )
    }

    private var passes: Bool {
        ratio >= EvaSpecimenActionRampGroup.bar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            shape
                .fill(ramp.style)
                .frame(height: EvaMetrics.minimumTouchTarget)
                .overlay {
                    Text("Label")
                        .evaTextStyle(.button)
                        .foregroundStyle(ramp.label)
                }
                .overlay {
                    if let border = ramp.border {
                        shape.strokeBorder(border, lineWidth: 1)
                    }
                }

            Text(hexes)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)

            // Pass/fail is a glyph as well as a colour — DESIGN.md §1, never colour
            // alone, which is exactly the rule this whole group exists to serve.
            Label(
                "white \(EvaSpecimenNumber.ratio(ratio))",
                systemImage: passes ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .labelStyle(.titleAndIcon)
            .evaTextStyle(.caption)
            .foregroundStyle(passes ? Color.evaSuccessInk : Color.evaErrorInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Action ramp") {
    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            EvaSpecimenActionRampGroup()
        }
        .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

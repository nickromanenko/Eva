import SwiftUI

// The DESIGN.md §3 type scale — Montserrat throughout.
//
// Fonts are referenced by **PostScript name**, one file per weight, rather than by
// family name plus `.weight()`. The four bundled statics ship `name` records that
// disagree about the family ("Montserrat Medium"/"Montserrat SemiBold" in nameID 1,
// "Montserrat" in nameID 16). Measured in the app process, Core Text prefers nameID 16
// and collapses them into a single "Montserrat" family with four members, so family
// plus weight does in fact resolve — but the names are a hazard, PostScript names are
// unambiguous, and `EvaTests` asserts each row resolves to the exact face requested.
// The PostScript names below were read out of the files' `name` tables and confirmed
// against Core Text.
//
// SwiftUI's `Font` cannot carry a line height, so each row of the scale is modelled as
// an `EvaTextStyle` that keeps the canvas' size / line-height / tracking together, and
// the `Font` values callers reach for (`Font.evaH1`) are projections of those styles.
// Apply the full style — font, leading and tracking — with `.evaTextStyle(.h1)`.

/// The PostScript names of the bundled Montserrat statics.
///
/// Registered by `UIAppFonts` in `mobile/project.yml`. XcodeGen adds each TTF to the
/// target's Copy Bundle Resources phase as an individual file reference, so they land
/// flat at the bundle root and `UIAppFonts` lists bare filenames.
enum EvaFont {
    /// Montserrat weight 400.
    static let regular = "Montserrat-Regular"
    /// Montserrat weight 500.
    static let medium = "Montserrat-Medium"
    /// Montserrat weight 600.
    static let semibold = "Montserrat-SemiBold"
    /// Montserrat weight 700.
    static let bold = "Montserrat-Bold"

    /// Montserrat's natural line box as a multiple of the point size.
    ///
    /// From the shipped files: `hhea` ascender 968, descender −251, lineGap 0 over a
    /// 1000-unit em. The `OS/2` typo metrics are identical and `fsSelection` bit 7
    /// (`USE_TYPO_METRICS`) is set, so Core Text lays out to exactly this ratio.
    /// Used to turn the canvas' line heights into SwiftUI `lineSpacing`, which measures
    /// the *gap added between* line boxes rather than the line box itself.
    static let naturalLineHeightRatio: CGFloat = 1.219
}

/// One row of the DESIGN.md §3 scale: the canvas' size, weight, line height and
/// tracking held together, since `Font` alone can only carry the first two.
struct EvaTextStyle: Sendable, Hashable {
    /// PostScript name of the Montserrat cut this row uses.
    let fontName: String
    /// Point size, at the canvas' 390 × 844 base frame.
    let size: CGFloat
    /// Total line box the canvas specifies, or `nil` where it specifies none — then the
    /// font's own leading stands.
    let lineHeight: CGFloat?
    /// Letter spacing in points. The canvas quotes `em`; these are already multiplied out.
    let tracking: CGFloat
    /// Dynamic Type ramp this row scales along. `Font.custom(_:size:)` silently anchors
    /// everything to `.body`; naming the nearest style keeps the scale's proportions as
    /// text grows. The canvas designs one fixed frame and says nothing about Dynamic
    /// Type — this preserves SwiftUI's default behaviour rather than choosing new sizes.
    let textStyle: Font.TextStyle

    /// The row as a SwiftUI `Font`. Carries size and weight only — not leading or tracking.
    var font: Font {
        .custom(fontName, size: size, relativeTo: textStyle)
    }

    /// Extra space to put between lines to reach `lineHeight`.
    ///
    /// SwiftUI's `lineSpacing` is additive on top of the font's own line box, so this is
    /// the canvas line height minus Montserrat's natural one. It cannot go below zero:
    /// leading *tighter* than the natural line box (Display, 46/48 against a natural
    /// 56.1) is unreachable this way and needs a custom layout at the call site.
    /// It is also a fixed value — it does not scale with Dynamic Type the way `font` does.
    var lineSpacing: CGFloat {
        guard let lineHeight else { return 0 }
        return max(0, lineHeight - size * EvaFont.naturalLineHeightRatio)
    }
}

extension EvaTextStyle {
    /// Display — 46/48, weight 400. Marketing headlines only.
    static let display = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 46,
        lineHeight: 48,
        tracking: 0,
        textStyle: .largeTitle
    )

    /// H1 · Screen title — 28/34, weight 600.
    static let h1 = EvaTextStyle(
        fontName: EvaFont.semibold,
        size: 28,
        lineHeight: 34,
        tracking: 0,
        textStyle: .title
    )

    /// H2 · Section heading — 21/26, weight 600.
    static let h2 = EvaTextStyle(
        fontName: EvaFont.semibold,
        size: 21,
        lineHeight: 26,
        tracking: 0,
        textStyle: .title2
    )

    /// H3 · Card heading — 17/22, weight 600.
    static let h3 = EvaTextStyle(
        fontName: EvaFont.semibold,
        size: 17,
        lineHeight: 22,
        tracking: 0,
        textStyle: .headline
    )

    /// Body — 15/24, weight 400.
    static let body = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 15,
        lineHeight: 24,
        tracking: 0,
        textStyle: .body
    )

    /// Body medium — 15/24, weight 500. Values and emphasis inside rows.
    static let bodyMedium = EvaTextStyle(
        fontName: EvaFont.medium,
        size: 15,
        lineHeight: 24,
        tracking: 0,
        textStyle: .body
    )

    /// Button — 14.5, weight 600. The canvas quotes 14.5–15; buttons are single-line,
    /// so no line height.
    static let button = EvaTextStyle(
        fontName: EvaFont.semibold,
        size: 14.5,
        lineHeight: nil,
        tracking: 0,
        textStyle: .subheadline
    )

    /// Label — 12, weight 600. Secondary colour.
    static let label = EvaTextStyle(
        fontName: EvaFont.semibold,
        size: 12,
        lineHeight: nil,
        tracking: 0,
        textStyle: .caption
    )

    /// Caption — 12.5/19, weight 400. Muted colour.
    static let caption = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 12.5,
        lineHeight: 19,
        tracking: 0,
        textStyle: .caption
    )

    /// Input helper — 12/18, weight 400.
    static let inputHelper = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 12,
        lineHeight: 18,
        tracking: 0,
        textStyle: .caption
    )

    /// Error text — 12, weight 500. Always paired with an icon (DESIGN.md §7).
    static let error = EvaTextStyle(
        fontName: EvaFont.medium,
        size: 12,
        lineHeight: nil,
        tracking: 0,
        textStyle: .caption
    )

    /// Overline — 11, weight 600, letter-spacing .14em. Uppercase at the call site;
    /// casing is a string decision, not a font one.
    static let overline = EvaTextStyle(
        fontName: EvaFont.semibold,
        size: 11,
        lineHeight: nil,
        tracking: EvaTypographyTracking.overline,
        textStyle: .caption2
    )
}

/// Letter spacing from the canvas, in points.
///
/// Tracking is a `Text` modifier rather than part of a `Font`, so it is a separate
/// constant. Callers using `.evaTextStyle(_:)` get it applied for them.
enum EvaTypographyTracking {
    /// Overline: .14em at 11pt.
    static let overline: CGFloat = 11 * 0.14
}

extension Font {
    /// Display — 46/48, weight 400. Pair with `EvaTextStyle.display.lineSpacing`.
    static let evaDisplay = EvaTextStyle.display.font
    /// H1 · Screen title — 28/34, weight 600.
    static let evaH1 = EvaTextStyle.h1.font
    /// H2 · Section heading — 21/26, weight 600.
    static let evaH2 = EvaTextStyle.h2.font
    /// H3 · Card heading — 17/22, weight 600.
    static let evaH3 = EvaTextStyle.h3.font
    /// Body — 15/24, weight 400.
    static let evaBody = EvaTextStyle.body.font
    /// Body medium — 15/24, weight 500.
    static let evaBodyMedium = EvaTextStyle.bodyMedium.font
    /// Button — 14.5, weight 600.
    static let evaButton = EvaTextStyle.button.font
    /// Label — 12, weight 600.
    static let evaLabel = EvaTextStyle.label.font
    /// Caption — 12.5/19, weight 400.
    static let evaCaption = EvaTextStyle.caption.font
    /// Input helper — 12/18, weight 400.
    static let evaInputHelper = EvaTextStyle.inputHelper.font
    /// Error text — 12, weight 500.
    static let evaError = EvaTextStyle.error.font
    /// Overline — 11, weight 600. Apply `EvaTypographyTracking.overline` alongside it,
    /// or use `.evaTextStyle(.overline)`.
    static let evaOverline = EvaTextStyle.overline.font
}

extension View {
    /// Applies a whole row of the scale: font, leading and tracking together.
    func evaTextStyle(_ style: EvaTextStyle) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

#Preview {
    let specimens: [(String, EvaTextStyle)] = [
        ("Display 46/48 · 400", .display),
        ("H1 28/34 · 600", .h1),
        ("H2 21/26 · 600", .h2),
        ("H3 17/22 · 600", .h3),
        ("Body 15/24 · 400", .body),
        ("Body medium 15/24 · 500", .bodyMedium),
        ("Button 14.5 · 600", .button),
        ("Label 12 · 600", .label),
        ("Caption 12.5/19", .caption),
        ("Input helper 12/18", .inputHelper),
        ("Error 12 · 500", .error),
        ("OVERLINE 11 · 600", .overline)
    ]

    return ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(specimens, id: \.0) { name, style in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Eva notices what changes\nand points you to care")
                        .evaTextStyle(style)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

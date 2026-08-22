import SwiftUI

// The three glass levels and the standard card treatment from DESIGN.md §4.
//
// FIDELITY NOTE — read before tuning any of this against the canvas.
// The canvas specifies glass as CSS: a translucent white fill over a
// `backdrop-filter: blur(N) saturate(1.7)`. SwiftUI has no backdrop filter. The only
// way to blur what is *behind* a view is `Material`, and that differs from the CSS in
// three ways we cannot close from here:
//
//   1. Blur radius is not adjustable. `Material` picks its own; the canvas 20/24/28
//      collapse onto ultraThin/thin/regular, which preserves the ordering (L1 least
//      blurred, L3 most) but not the exact values. They are kept below as
//      `canvasBlurRadius` so a future `UIVisualEffectView` bridge has the numbers.
//   2. Material carries its own white tint, which then sits *under* the canvas white
//      fill. The result is more opaque than the CSS at the same nominal percentage —
//      most visible at L1, where 40% white over a tinted material reads milkier than
//      the canvas. Compare against the canvas on a real screen before trusting L1.
//   3. `saturate(1.7)` has no SwiftUI equivalent and is simply not applied. Material's
//      own vibrancy is the nearest thing and is not the same effect.
//
// So: the levels are correct in intent and ordering, approximate in exact rendering.

/// A glass level from DESIGN.md §4.
enum EvaGlassLevel: CaseIterable {
    /// L1 — background glass, 40% white / blur 20. **Decorative only**; body text on
    /// top of this is not guaranteed to be legible.
    case background
    /// L2 — interactive card, 68% white / blur 24. Body-text safe.
    case card
    /// L3 — sheet or modal, 92% white / blur 28. Long-form content.
    case sheet

    /// The white fill the canvas specifies over the blur.
    var tint: Color {
        switch self {
        case .background: Color.white.opacity(0.40)
        // §4 says 68% here while the §2 neutral "Glass Surface" is 66%. The §4 glass
        // table wins for the glass levels; `Color.evaGlassSurface` keeps the §2 value.
        case .card: Color.white.opacity(0.68)
        case .sheet: Color.evaElevatedGlass
        }
    }

    /// Blur radius from the canvas, in CSS pixels. Recorded for fidelity — SwiftUI
    /// materials do not let us apply it. See the fidelity note above.
    var canvasBlurRadius: CGFloat {
        switch self {
        case .background: 20
        case .card: 24
        case .sheet: 28
        }
    }

    /// The material standing in for the canvas backdrop blur.
    var material: Material {
        switch self {
        case .background: .ultraThin
        case .card: .thin
        case .sheet: .regular
        }
    }
}

/// Applies a glass level as the view's background.
struct EvaGlassModifier<S: InsettableShape>: ViewModifier {
    let level: EvaGlassLevel
    let shape: S

    func body(content: Content) -> some View {
        content.background {
            shape
                .fill(level.material)
                .overlay { shape.fill(level.tint) }
        }
    }
}

/// The standard card treatment from DESIGN.md §4: a 150° white gradient over glass,
/// a hairline white border, inset top/bottom white lines and a soft mauve shadow.
struct EvaCardSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S

    /// `linear-gradient(150deg, rgba(255,255,255,.66), rgba(255,255,255,.36))`.
    ///
    /// CSS 0° points up and angles run clockwise, so the 150° direction vector is
    /// `(sin150, -cos150)` = `(0.5, 0.866)` in screen coordinates. Extending that
    /// through the centre of a unit square (gradient line length
    /// `|sin| + |cos|` = 1.366) gives the start/end unit points below.
    private var fill: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.66), .white.opacity(0.36)],
            startPoint: UnitPoint(x: 0.159, y: -0.092),
            endPoint: UnitPoint(x: 0.841, y: 1.092)
        )
    }

    func body(content: Content) -> some View {
        content.background {
            shape
                .fill(Material.thin)
                .overlay { shape.fill(fill) }
                .overlay { insetLines }
                .overlay { shape.strokeBorder(Color.white.opacity(0.72), lineWidth: 1) }
                .shadow(
                    color: EvaCardShadow.color,
                    radius: EvaCardShadow.radius,
                    x: 0,
                    y: EvaCardShadow.offsetY
                )
        }
    }

    /// The inset top and bottom white lines. The canvas calls for them but gives no
    /// opacities; the top line reuses the border value and the bottom is a fainter
    /// echo of it. Confirm against the canvas if a card ever looks off.
    private var insetLines: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.72))
                .frame(height: 1)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.white.opacity(0.30))
                .frame(height: 1)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

}

/// Canvas card shadow: `0 16px 36px -22px rgba(150,72,100,.45)` (DESIGN.md §4).
///
/// SwiftUI's shadow has no spread, so the -22px contraction cannot be expressed and
/// the shadow renders wider and softer than the canvas. These are the direct
/// translation (CSS blur 36 → SwiftUI radius 18); if a card reads too heavy beside the
/// canvas, `radius` is the intended knob.
private enum EvaCardShadow {
    static let color = Color(hex: 0x964864).opacity(0.45)
    static let radius: CGFloat = 18
    static let offsetY: CGFloat = 16
}

extension View {

    /// Applies a DESIGN.md §4 glass level in an arbitrary shape.
    func evaGlass(_ level: EvaGlassLevel, in shape: some InsettableShape) -> some View {
        modifier(EvaGlassModifier(level: level, shape: shape))
    }

    /// Applies a DESIGN.md §4 glass level in a continuous rounded rectangle.
    func evaGlass(
        _ level: EvaGlassLevel,
        cornerRadius: CGFloat = EvaRadius.card
    ) -> some View {
        evaGlass(level, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Applies the standard card treatment from DESIGN.md §4 in an arbitrary shape.
    func evaCardSurface(in shape: some InsettableShape) -> some View {
        modifier(EvaCardSurfaceModifier(shape: shape))
    }

    /// Applies the standard card treatment from DESIGN.md §4.
    func evaCardSurface(cornerRadius: CGFloat = EvaRadius.card) -> some View {
        evaCardSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Applies L3 glass with the sheet's top-only 30pt radius (DESIGN.md §4).
    func evaSheetSurface() -> some View {
        evaGlass(
            .sheet,
            in: UnevenRoundedRectangle(
                topLeadingRadius: EvaRadius.sheet,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: EvaRadius.sheet,
                style: .continuous
            )
        )
    }
}

// MARK: - Preview

#Preview("Glass levels") {
    ZStack {
        LinearGradient.evaPinkPistachio
            .ignoresSafeArea()

        VStack(spacing: EvaSpacing.lg) {
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("L1 · background glass")
                    .font(.system(size: 15, weight: .semibold))
                Text("40% white, blur 20 — decorative only.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evaSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EvaSpacing.md)
            .evaGlass(.background)

            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("L2 · interactive card")
                    .font(.system(size: 15, weight: .semibold))
                Text("68% white, blur 24 — body text is safe on this level.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evaSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EvaSpacing.md)
            .evaGlass(.card)

            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("Standard card treatment")
                    .font(.system(size: 15, weight: .semibold))
                Text("150° white gradient, hairline border, inset lines, mauve shadow.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evaSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EvaSpacing.md)
            .evaCardSurface()

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Capsule()
                    .fill(Color.evaMutedText.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)
                Text("L3 · sheet")
                    .font(.system(size: 15, weight: .semibold))
                Text("92% white, blur 28, 30pt top corners.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evaSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EvaSpacing.md)
            .padding(.bottom, 26)
            .evaSheetSurface()
        }
        .padding(EvaSpacing.lg)
        .foregroundStyle(Color.evaPrimaryText)
    }
}

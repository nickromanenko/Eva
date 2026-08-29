import SwiftUI

// The three glass levels and the standard card treatment from DESIGN.md §4.
//
// FIDELITY NOTE — read before tuning any of this against the canvas.
// The canvas specifies glass as CSS: a translucent white fill over a
// `backdrop-filter: blur(N) saturate(1.7)`. SwiftUI has no backdrop filter. The only
// way to blur what is *behind* a view is `Material`, and that differs from the CSS in
// three ways we cannot close from here:
//
//   1. Blur radius is not adjustable. `Material` picks its own; the canvas 24/28
//      collapse onto thin/regular, which preserves the ordering (L2 less blurred than
//      L3) but not the exact values. They are kept below as `canvasBlurRadius` so a
//      future `UIVisualEffectView` bridge has the numbers.
//   2. Material carries its own white tint, which then sits *under* the canvas white
//      fill, so a level reads more opaque than the CSS at the same nominal percentage.
//   3. `saturate(1.7)` has no SwiftUI equivalent and is simply not applied. Material's
//      own vibrancy is the nearest thing and is not the same effect.
//
// **L1 no longer uses `Material` at all** (decided on #12). Point 2 was worst there: a
// 40% white fill over a tinted ultraThin material read at roughly 70%, which made L1
// and L2 indistinguishable on a real backdrop — the one thing the three levels exist to
// do. The canvas calls L1 "decorative only", so it does not need a backdrop blur to
// carry text over; rendering it as a plain 40% white fill restores genuine transparency
// and separates it cleanly from L2, at no cost. L2 and L3 keep `Material`, where body
// text and long-form content need a stable backdrop. A `UIVisualEffectView` bridge was
// considered and rejected as disproportionate; revisit only if the remaining
// approximation at L2/L3 turns out to matter.
//
// So: the levels are correct in intent and ordering, approximate in exact rendering.

/// A glass level from DESIGN.md §4.
enum EvaGlassLevel: CaseIterable {
    /// L1 — background glass, 40% white. **Decorative only**; body text on top of this
    /// is not guaranteed to be legible. Renders as a plain fill with no backdrop
    /// material — see the fidelity note above.
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
    /// materials do not let us apply it, and L1's is not applied at all. See the
    /// fidelity note above.
    var canvasBlurRadius: CGFloat {
        switch self {
        case .background: 20
        case .card: 24
        case .sheet: 28
        }
    }

    /// Whether `evaGlass(_:in:)` renders `material` behind `tint` for this level.
    ///
    /// False for L1, which is a plain 40% white fill. See the fidelity note above.
    var rendersBackdropMaterial: Bool {
        self != .background
    }

    /// The material nearest this level's canvas blur radius.
    ///
    /// Only actually rendered where `rendersBackdropMaterial` is true. It stays defined
    /// for every level because controls that need a comparable blur borrow it by name
    /// (`EvaSecondaryButtonStyle` takes `.background.material` as its stand-in for the
    /// canvas' `backdrop-filter: blur(18px)`).
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
            ZStack {
                if level.rendersBackdropMaterial {
                    shape.fill(level.material)
                }
                shape.fill(level.tint)
            }
        }
    }
}

/// The standard card treatment from DESIGN.md §4: a 150° white gradient over glass,
/// a hairline white border, inset top/bottom white lines and a soft neutral shadow.
///
/// The shadow was mauve until #12; see `EvaCardShadow` for why it is not any more.
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

    /// The inset top and bottom white lines —
    /// `inset 0 1px 0 rgba(255,255,255,.9)` and `inset 0 -1px 0 rgba(255,255,255,.4)`.
    ///
    /// 90% / 40%, from the canvas. Note the top line is *brighter* than the 72% hairline
    /// border it sits inside, which is what gives the card its lit top edge.
    private var insetLines: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.90))
                .frame(height: 1)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.white.opacity(0.40))
                .frame(height: 1)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

}

/// Card shadow: `0 12px 30px -18px rgba(40,33,38,.35)`, from the App artboard's
/// settings screen.
///
/// ## This is a deliberate deviation from the canvas (#12, DESIGN.md §9a)
///
/// The artboards draw this pink, and not marginally: `rgba(150,72,100,…)` appears 18 times
/// for cards in the Design System artboard and 16 more in the App artboard, against **two**
/// neutral instances, both on the settings screen. Pink is the design language.
///
/// We deviate because of how it composites rather than how it is drawn. Under a
/// *translucent* card, `Material` samples the shadow behind it, so a saturated shadow tints
/// the card itself as well as ringing it — measured on Profile, the pink rendered a
/// `#D5B2BA` halo against a `#FEF8F5` ground. CSS `backdrop-filter` and SwiftUI `Material`
/// do not sample the same thing, so the artboard cannot show this.
///
/// The pink value's origin supports reading it by elevation: it is the *bottom sheet's*
/// shadow (`0 -22px 50px -22px`), right under an opaque sheet and wrong under a translucent
/// card.
///
/// ## This is a close translation, not an exact one
///
/// SwiftUI's shadow has no spread, so the `-18px` contraction is dropped exactly as the
/// old `-22px` was, and the shadow renders wider and softer than the canvas. `radius` is
/// the direct halving of CSS blur (30 → 15), the same convention the previous value used.
///
/// **Do not tune `radius` to chase the grey cast — it was tried and it is the wrong
/// lever.** Measured on the Profile screen, card minus ground: pink/r18 gave
/// −15 · −17 · −14, neutral/r15 gives −23 · −18 · −17, neutral/r8 gives −24 · −19 · −18.
///
/// Read those carefully, because an earlier version of this note read them wrongly. The
/// *colour* change moved red by 8; the *radius* change moved it by 1. So the shadow is not
/// irrelevant to the cast — it is a real contributor, and this change made the cast slightly
/// worse while removing its mauve tint. What is established is narrower: **radius** does not
/// move it, so tuning that number is wasted effort. The remainder is `Material`'s own tint,
/// which is #60.
///
/// Those deltas also carry a known bias: the ground was sampled far down the screen, under a
/// different `EvaScreenBackground` glow than the card sits on, which is worth −3.6 · −1.2 ·
/// −6.4 before anything is drawn. #60 should re-baseline against ground beside the card.
private enum EvaCardShadow {
    static let color = Color.evaPrimaryText.opacity(0.35)
    static let radius: CGFloat = 15
    static let offsetY: CGFloat = 12
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
                Text("40% white, no material — decorative only.")
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
                Text("150° white gradient, hairline border, inset lines, neutral shadow.")
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

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Canvas palette (DESIGN.md §2)
//
// Transcribed from "Eva Design System.dc.html". These are the tokens new UI uses.
// The legacy set at the bottom of this file is the pre-canvas palette and is still
// live on the onboarding screens until #3 re-skins them.

extension Color {

    // MARK: Brand

    /// `#E982A5` — primary brand pink.
    static let evaPrimaryPink = Color(hex: 0xE982A5)
    /// `#C95F86` — deep pink; primary button end stop, text buttons, "today" marker.
    static let evaDeepPink = Color(hex: 0xC95F86)
    /// `#F9DCE6` — soft blush; wash backgrounds.
    static let evaSoftBlush = Color(hex: 0xF9DCE6)
    /// `#CDE79D` — pistachio, the second brand colour.
    static let evaPistachio = Color(hex: 0xCDE79D)
    /// `#8EAD56` — deep pistachio.
    static let evaDeepPistachio = Color(hex: 0x8EAD56)
    /// `#EDF6DA` — light pistachio; wash backgrounds and gradient stops.
    static let evaLightPistachio = Color(hex: 0xEDF6DA)

    /// `#EE93B1` — top stop of the primary button gradient (DESIGN.md §5). Gradient
    /// stop only; not a standalone palette entry.
    static let evaPrimaryButtonTop = Color(hex: 0xEE93B1)
    /// `#F3AEC4` — pink stop of the pink→pistachio gradient (DESIGN.md §2). Gradient
    /// stop only; not a standalone palette entry.
    static let evaGradientPink = Color(hex: 0xF3AEC4)

    // MARK: Neutrals

    /// `#FFF9F6` — warm off-white screen background.
    static let evaWarmBackground = Color(hex: 0xFFF9F6)
    /// `#F8F3F0` — secondary background.
    static let evaSecondaryBackground = Color(hex: 0xF8F3F0)
    /// `rgba(255,255,255,.66)` — the glass surface fill.
    static let evaGlassSurface = Color.white.opacity(0.66)
    /// `rgba(255,252,250,.92)` — elevated (sheet/modal) glass fill.
    static let evaElevatedGlass = Color(hex: 0xFFFCFA).opacity(0.92)
    /// `#282126` — primary text.
    static let evaPrimaryText = Color(hex: 0x282126)
    /// `#6F656B` — secondary text.
    static let evaSecondaryText = Color(hex: 0x6F656B)
    /// `#9A9095` — muted text.
    static let evaMutedText = Color(hex: 0x9A9095)
    /// `#FFFFFF` — text on dark surfaces.
    static let evaTextOnDark = Color.white

    // MARK: Semantic
    //
    // Every semantic state is icon + text as well as colour — never colour alone
    // (DESIGN.md §2). The canvas states each state's fill, border and ink separately
    // from its base hue, and they are **not** opacities of that hue — Success's tint is
    // pistachio (`#CDE79D`), not `#7A9B45`, and each ink is its own darker hex. The
    // values below are the artboard's, read from the `semantic` list in
    // "Eva Design System.dc.html".

    /// `#7A9B45` — success. Mark: ✓ in a circle.
    static let evaSuccess = Color(hex: 0x7A9B45)
    /// `rgba(205,231,157,.26)` — pistachio-based, not a tint of `evaSuccess`.
    static let evaSuccessTint = Color.evaPistachio.opacity(0.26)
    /// `rgba(142,173,86,.32)` — deep pistachio.
    static let evaSuccessBorder = Color.evaDeepPistachio.opacity(0.32)
    /// `#4F6630`.
    static let evaSuccessInk = Color(hex: 0x4F6630)

    /// `#C9913F` — warning: needs attention, not urgent. Mark: ! in a rounded square.
    static let evaWarning = Color(hex: 0xC9913F)
    /// `rgba(201,145,63,.10)`.
    static let evaWarningTint = Color.evaWarning.opacity(0.10)
    /// `rgba(201,145,63,.3)`.
    static let evaWarningBorder = Color.evaWarning.opacity(0.30)
    /// `#8A6425`.
    static let evaWarningInk = Color(hex: 0x8A6425)

    /// `#C4645A` — error. Mark: ! in a circle. Always paired with a message under
    /// the field.
    static let evaError = Color(hex: 0xC4645A)
    /// `rgba(196,100,90,.08)`.
    static let evaErrorTint = Color.evaError.opacity(0.08)
    /// `rgba(196,100,90,.26)`.
    static let evaErrorBorder = Color.evaError.opacity(0.26)
    /// `#A9524A` — the same hex as `evaDestructiveInk`.
    static let evaErrorInk = Color(hex: 0xA9524A)

    /// `#5A7BA0` — information: account linking, predictions, limits of data.
    static let evaInformation = Color(hex: 0x5A7BA0)
    /// `rgba(90,123,160,.09)`.
    static let evaInformationTint = Color.evaInformation.opacity(0.09)
    /// `rgba(90,123,160,.26)`.
    static let evaInformationBorder = Color.evaInformation.opacity(0.26)
    /// `#3F5A76`.
    static let evaInformationInk = Color(hex: 0x3F5A76)
}

// MARK: - Control states (DESIGN.md §5, §6)
//
// The canvas gives each control's states as literal CSS. These are those values, not
// derivations — where a value is an opacity of a palette colour it is written that way,
// and where the canvas gives a discrete hex it is a hex.

extension Color {

    // MARK: Primary button

    /// `#D9799C` — pressed gradient top (§5).
    static let evaPrimaryButtonPressedTop = Color(hex: 0xD9799C)
    /// `#B45276` — pressed gradient bottom (§5).
    static let evaPrimaryButtonPressedBottom = Color(hex: 0xB45276)
    /// `rgba(201,95,134,.28)` — disabled fill; label stays white (§5).
    static let evaPrimaryButtonDisabled = Color.evaDeepPink.opacity(0.28)
    /// `rgba(40,33,38,.6)` — the 3pt focus ring (§5).
    static let evaFocusRing = Color(hex: 0x282126).opacity(0.6)

    // MARK: Secondary glass button

    /// `rgba(255,255,255,.7)` (§5).
    static let evaSecondaryFill = Color.white.opacity(0.7)
    /// `rgba(248,243,240,.9)` — pressed (§5).
    static let evaSecondaryFillPressed = Color(hex: 0xF8F3F0).opacity(0.9)
    /// `rgba(255,255,255,.5)` — disabled (§5).
    static let evaSecondaryFillDisabled = Color.white.opacity(0.5)

    // MARK: Control borders and disabled ink

    /// `rgba(40,33,38,.1)` — the default hairline on controls and inputs (§5, §6).
    static let evaControlBorder = Color(hex: 0x282126).opacity(0.1)
    /// `rgba(40,33,38,.14)` — pressed (§5).
    static let evaControlBorderPressed = Color(hex: 0x282126).opacity(0.14)
    /// `rgba(40,33,38,.06)` — disabled (§5).
    static let evaControlBorderDisabled = Color(hex: 0x282126).opacity(0.06)
    /// `#C8BFC3` — label colour on a disabled control (§5).
    static let evaDisabledText = Color(hex: 0xC8BFC3)

    // MARK: Destructive

    /// `#B85248` — solid destructive, **in modals only** (§5).
    static let evaDestructive = Color(hex: 0xB85248)
    /// `#A9524A` — destructive text and outline label (§5).
    static let evaDestructiveInk = Color(hex: 0xA9524A)
    /// `rgba(184,82,72,.5)` — outlined destructive border (§5).
    static let evaDestructiveBorder = Color(hex: 0xB85248).opacity(0.5)
    /// `rgba(196,100,90,.3)` — row-level destructive border (§5).
    static let evaDestructiveRowBorder = Color.evaError.opacity(0.3)

    // MARK: Authentication buttons

    /// `#1C1A1B` — Continue with Apple (§5).
    static let evaAuthApple = Color(hex: 0x1C1A1B)
    /// `rgba(255,255,255,.85)` — Continue with Google, glass (§5).
    static let evaAuthGoogleFill = Color.white.opacity(0.85)

    // MARK: Inputs (§6)

    /// `rgba(255,255,255,.75)` — input fill.
    static let evaInputFill = Color.white.opacity(0.75)
    /// `rgba(201,95,134,.16)` — 3pt focus ring; the border itself becomes `evaDeepPink`.
    static let evaInputFocusRing = Color.evaDeepPink.opacity(0.16)
    /// `rgba(196,100,90,.14)` — 3pt error ring; the border itself becomes `evaError`.
    static let evaInputErrorRing = Color.evaError.opacity(0.14)
    /// `#fff` — focused input fill. The field goes fully opaque, so focus reads as a
    /// change in the surface and not only as a ring.
    static let evaInputFillFocused = Color.white
    /// `rgba(255,255,255,.8)` — error input fill, a half-step up from the resting 75%.
    static let evaInputFillError = Color.white.opacity(0.8)
    /// `rgba(40,33,38,.07)` — disabled input border. The artboard uses .07 here where
    /// buttons use .06; kept distinct rather than folded into `evaControlBorderDisabled`.
    static let evaInputBorderDisabled = Color(hex: 0x282126).opacity(0.07)
    /// `rgba(248,243,240,.8)` — disabled input fill.
    static let evaInputFillDisabled = Color(hex: 0xF8F3F0).opacity(0.8)
    /// `#B3A9AE` — disabled input text.
    static let evaInputTextDisabled = Color(hex: 0xB3A9AE)

    // MARK: Chips (§6)

    /// `rgba(255,255,255,.72)` — default chip fill.
    static let evaChipFill = Color.white.opacity(0.72)
    /// `#EE93B1` — selected chip gradient top.
    static let evaChipSelectedTop = Color(hex: 0xEE93B1)
    /// `#DC7C9E` — selected chip gradient bottom.
    static let evaChipSelectedBottom = Color(hex: 0xDC7C9E)
    /// `#5F2C3F` — border on the severe chip. Deepened along with the fill: the
    /// artboard's `#A94A6C` is now the *fill's* neighbourhood, so it would draw nothing.
    static let evaChipSevereBorder = Color(hex: 0x5F2C3F)
    /// `#7E3B58` — severe chip fill. White reads at 7.91:1.
    ///
    /// Not an artboard value. The artboard's severe chip is `#C95F86`, which carries
    /// white at 3.84:1, and the approved action ramp (#12) would have deepened it to
    /// `#A94A6C` — four units per channel from the selected chip's midpoint, making the
    /// two states indistinguishable. This sits 80 channel-units below selected so severe
    /// still reads as the more serious of the two, which is the state's whole job.
    static let evaChipSevere = Color(hex: 0x7E3B58)
    /// `rgba(248,243,240,.8)` — disabled chip fill; label is `evaDisabledText`.
    static let evaChipFillDisabled = Color(hex: 0xF8F3F0).opacity(0.8)
}

// MARK: - Action pink — the ramp that carries a white label
//
// DELIBERATE DEVIATION FROM THE ARTBOARD. Approved on #12; not a canvas value.
//
// White on the canvas pink fails WCAG AA everywhere it carries a label. Measured
// against `#FFFFFF`, for a 14.5pt semibold label needing 4.5:1:
//
//   | Surface                                  | White |
//   |------------------------------------------|-------|
//   | Primary button top      `#EE93B1`        |  2.22 |
//   | Primary button end      `#C95F86`        |  3.84 |
//   | Selected chip worst pt  `#EE93B1`        |  2.22 |
//   | Severe chip / today     `#C95F86`        |  3.84 |
//
// No variant of the canvas ramp keeps the pale pink, a white label and AA together —
// flipping the label to Primary Text only trades one failure for another (`#C95F86`
// against `#282126` is 4.09). The resolution is to deepen the pink **only where it
// carries a label**, and leave the brand pink alone everywhere else. So:
//
//   * Actionable surfaces — primary button, selected chip, FAB, today marker — use the
//     `evaActionPink…` ramp below, which clears AA with a white label.
//   * Washes, tints, decorative fills and any pink with nothing sitting on top of it
//     keep `evaPrimaryPink` / `evaDeepPink` and the canvas gradients. They are still
//     the brand colour and they are still correct.
//
// These are a separate family from the brand pinks on purpose. Reaching for one of
// them is a statement that a white label sits on top; if nothing does, use the brand
// pink instead.

extension Color {

    /// `#B45276` — action ramp, resting top. White label: 4.76:1.
    static let evaActionPinkTop = Color(hex: 0xB45276)
    /// `#96486A` — action ramp, resting bottom. White label: 6.12:1.
    static let evaActionPinkBottom = Color(hex: 0x96486A)

    /// `#994664` — action ramp, pressed top. White label: 6.15:1.
    static let evaActionPinkPressedTop = Color(hex: 0x994664)
    /// `#803D5A` — action ramp, pressed bottom. White label: 7.68:1.
    static let evaActionPinkPressedBottom = Color(hex: 0x803D5A)

    /// `#A94A6C` — the flat action pink, for surfaces the canvas fills solid rather
    /// than with a gradient: the severe chip, the "today" marker, the FAB.
    /// White label: 5.41:1.
    ///
    /// Used by the today marker and the FAB. **Not** the severe chip — that would land
    /// on top of the selected chip; see `evaChipSevere`.
    static let evaActionPinkSolid = Color(hex: 0xA94A6C)
}

// MARK: - Action pink gradients
//
// The `evaActionPink…` ramp in its gradient form. Same 180° top-to-bottom geometry as
// the canvas' `evaPrimaryButton` / `evaPrimaryButtonPressed`, deepened per #12.

extension LinearGradient {

    /// Action pink, resting — `#B45276` → `#96486A`. The AA-clearing stand-in for
    /// `evaPrimaryButton` wherever a white label sits on the fill.
    static let evaActionPink = LinearGradient(
        colors: [.evaActionPinkTop, .evaActionPinkBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Action pink, pressed — `#994664` → `#803D5A`. Pair with a 0.97 scale, as the
    /// canvas does for the primary button.
    static let evaActionPinkPressed = LinearGradient(
        colors: [.evaActionPinkPressedTop, .evaActionPinkPressedBottom],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Canvas gradients (DESIGN.md §2, §5)
//
// The canvas states an angle for every wash. `evaUnitPoints(cssAngle:)` converts one
// into the SwiftUI start/end pair, so the angle stays legible at each call site rather
// than arriving as a pre-computed pair of magic numbers.

/// Start and end `UnitPoint`s for a CSS `linear-gradient` angle.
///
/// CSS 0° points up and angles run clockwise, so the direction vector in screen
/// coordinates (y down) is `(sin θ, -cos θ)`. Extending that through the centre of the
/// unit square — whose gradient line length is `|sin θ| + |cos θ|` — gives the two
/// points. Note SwiftUI's `UnitPoint` space is normalised to the view's bounds, so the
/// rendered angle only equals the CSS angle when the view is square; this matches how
/// the canvas' own boxes are drawn and how `EvaCardSurfaceModifier` handles 150°.
private func evaUnitPoints(cssAngle degrees: Double) -> (start: UnitPoint, end: UnitPoint) {
    let radians = degrees * .pi / 180
    let dx = sin(radians)
    let dy = -cos(radians)
    let half = (abs(dx) + abs(dy)) / 2
    return (
        UnitPoint(x: 0.5 - dx * half, y: 0.5 - dy * half),
        UnitPoint(x: 0.5 + dx * half, y: 0.5 + dy * half)
    )
}

extension LinearGradient {

    /// Blush → cream wash — `linear-gradient(135deg, #F9DCE6, #FFF9F6)` (§2).
    /// "Cream" is Warm Background.
    static let evaBlushCream = LinearGradient(
        colors: [.evaSoftBlush, .evaWarmBackground],
        startPoint: evaUnitPoints(cssAngle: 135).start,
        endPoint: evaUnitPoints(cssAngle: 135).end
    )

    /// Pistachio → cream wash — `linear-gradient(135deg, #EDF6DA, #FFF9F6)` (§2).
    ///
    /// The canvas' pistachio stop here is **Light** Pistachio `#EDF6DA`, not Pistachio
    /// `#CDE79D`; §2's prose names the wash "pistachio → cream" without a hex, and the
    /// darker reading was an inference.
    static let evaPistachioCream = LinearGradient(
        colors: [.evaLightPistachio, .evaWarmBackground],
        startPoint: evaUnitPoints(cssAngle: 135).start,
        endPoint: evaUnitPoints(cssAngle: 135).end
    )

    /// Pink → pistachio — `linear-gradient(120deg, #F3AEC4, #EDF6DA)` (§2).
    static let evaPinkPistachio = LinearGradient(
        colors: [.evaGradientPink, .evaLightPistachio],
        startPoint: evaUnitPoints(cssAngle: 120).start,
        endPoint: evaUnitPoints(cssAngle: 120).end
    )

    /// Pink base of the "white highlight over pink" treatment —
    /// `linear-gradient(135deg, #E982A5, #C95F86)` (§2). Overlay
    /// `evaWhiteHighlightWash` on top of this to get the full treatment.
    static let evaPinkHighlightBase = LinearGradient(
        colors: [.evaPrimaryPink, .evaDeepPink],
        startPoint: evaUnitPoints(cssAngle: 135).start,
        endPoint: evaUnitPoints(cssAngle: 135).end
    )

    /// The white top wash of the "white highlight over pink" treatment —
    /// `linear-gradient(180deg, rgba(255,255,255,.75), rgba(255,255,255,0))` (§2).
    /// It runs the full height of the surface; 75% at the top, nothing at the bottom.
    static let evaWhiteHighlightWash = LinearGradient(
        colors: [.white.opacity(0.75), .white.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Primary button, pressed — `linear-gradient(180deg, #D9799C, #B45276)` (§5).
    /// Pair with a 0.97 scale.
    static let evaPrimaryButtonPressed = LinearGradient(
        colors: [.evaPrimaryButtonPressedTop, .evaPrimaryButtonPressedBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Selected chip fill — `linear-gradient(180deg, #EE93B1, #DC7C9E)` (§6).
    static let evaChipSelected = LinearGradient(
        colors: [.evaChipSelectedTop, .evaChipSelectedBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Primary button fill — `linear-gradient(180deg, #EE93B1, #C95F86)` (§5).
    static let evaPrimaryButton = LinearGradient(
        colors: [.evaPrimaryButtonTop, .evaDeepPink],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Legacy (pre-canvas — removed by #3)
//
// The plum/mauve palette the onboarding screens were built against. It does not
// match the Claude Design canvas — see DESIGN.md §9 "Drift: implemented vs designed".
// Nothing new should use these. They stay (undeprecated, so they don't spam warnings
// across every view) until #3 re-skins the screens onto the tokens above, and go away
// with it.

extension Color {
    static let evaInk = Color(hex: 0x3A2233)
    static let evaPlum = Color(hex: 0x8E2C57)
    static let evaPink = Color(hex: 0xC96A93)
    static let evaBody = Color(hex: 0x6E5E69)
    static let evaSecondary = Color(hex: 0x5A4B55)
    static let evaMuted = Color(hex: 0x98868F)
    static let evaFaint = Color(hex: 0xA695A0)
    static let evaSoftPink = Color(hex: 0xFBEDF3)
    static let evaChipBorder = Color(hex: 0xEBDDE7)
    static let evaCardBorder = Color(hex: 0xEFE1EB)
    static let evaTrack = Color(hex: 0xEADCE6)
    static let evaBackgroundTop = Color(hex: 0xFBF7FA)
    static let evaBackgroundBottom = Color(hex: 0xF7EEF4)
    static let evaWashPink = Color(hex: 0xF6DCE9)
    static let evaGreenTint = Color(hex: 0xE6F0E9)
    static let evaGreenInk = Color(hex: 0x4E7A5E)
    static let evaGreenIcon = Color(hex: 0x6E9C7E)
    static let evaBlueTint = Color(hex: 0xE7EDF5)
    static let evaBlueInk = Color(hex: 0x4E6C8E)
    static let evaBlueIcon = Color(hex: 0x6E8CB0)
    static let evaLilacTint = Color(hex: 0xEFEAF6)
}

extension LinearGradient {
    /// Legacy plum→pink gradient used for primary actions and accents. Superseded by
    /// `evaPrimaryButton`; removed by #3.
    static let evaPlumPink = LinearGradient(
        colors: [.evaPlum, .evaPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Legacy mauve screen background. Superseded by `Color.evaWarmBackground`;
    /// removed by #3.
    static let evaScreenBackground = LinearGradient(
        colors: [.evaBackgroundTop, .evaBackgroundBottom],
        startPoint: .top,
        endPoint: .bottom
    )
}


// MARK: - Preview

private struct EvaColorSwatch: View {
    let name: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
                .frame(height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08))
                }
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Color.evaSecondaryText)
                .multilineTextAlignment(.center)
        }
    }
}

private struct EvaGradientSwatch: View {
    let name: String
    let gradient: LinearGradient
    var wash: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(gradient)
            .overlay {
                if wash {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient.evaWhiteHighlightWash)
                }
            }
            .frame(height: 42)
            .overlay(alignment: .leading) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.evaPrimaryText.opacity(0.75))
                    .padding(.leading, 12)
            }
    }
}

#Preview("Canvas palette") {
    let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Brand").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                EvaColorSwatch(name: "Primary Pink", color: .evaPrimaryPink)
                EvaColorSwatch(name: "Deep Pink", color: .evaDeepPink)
                EvaColorSwatch(name: "Soft Blush", color: .evaSoftBlush)
                EvaColorSwatch(name: "Pistachio", color: .evaPistachio)
                EvaColorSwatch(name: "Deep Pistachio", color: .evaDeepPistachio)
                EvaColorSwatch(name: "Light Pistachio", color: .evaLightPistachio)
            }

            Text("Neutrals").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                EvaColorSwatch(name: "Warm BG", color: .evaWarmBackground)
                EvaColorSwatch(name: "Secondary BG", color: .evaSecondaryBackground)
                EvaColorSwatch(name: "Glass 66%", color: .evaGlassSurface)
                EvaColorSwatch(name: "Elevated 92%", color: .evaElevatedGlass)
                EvaColorSwatch(name: "Primary Text", color: .evaPrimaryText)
                EvaColorSwatch(name: "Secondary Text", color: .evaSecondaryText)
                EvaColorSwatch(name: "Muted Text", color: .evaMutedText)
            }

            Text("Semantic").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                EvaColorSwatch(name: "Success", color: .evaSuccess)
                EvaColorSwatch(name: "Success tint", color: .evaSuccessTint)
                EvaColorSwatch(name: "Warning", color: .evaWarning)
                EvaColorSwatch(name: "Warning tint", color: .evaWarningTint)
                EvaColorSwatch(name: "Error", color: .evaError)
                EvaColorSwatch(name: "Error tint", color: .evaErrorTint)
                EvaColorSwatch(name: "Information", color: .evaInformation)
                EvaColorSwatch(name: "Info tint", color: .evaInformationTint)
            }

            Text("Action pink · white-label ramp (#12, not the canvas)").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                EvaColorSwatch(name: "Action top", color: .evaActionPinkTop)
                EvaColorSwatch(name: "Action bottom", color: .evaActionPinkBottom)
                EvaColorSwatch(name: "Pressed top", color: .evaActionPinkPressedTop)
                EvaColorSwatch(name: "Pressed bottom", color: .evaActionPinkPressedBottom)
                EvaColorSwatch(name: "Action solid", color: .evaActionPinkSolid)
            }

            Text("Gradients").font(.headline)
            VStack(spacing: 10) {
                EvaGradientSwatch(name: "Blush → cream", gradient: .evaBlushCream)
                EvaGradientSwatch(name: "Pistachio → cream", gradient: .evaPistachioCream)
                EvaGradientSwatch(name: "Pink → pistachio", gradient: .evaPinkPistachio)
                EvaGradientSwatch(name: "Primary button", gradient: .evaPrimaryButton)
                EvaGradientSwatch(name: "Action pink", gradient: .evaActionPink)
                EvaGradientSwatch(name: "Action pink · pressed", gradient: .evaActionPinkPressed)
                EvaGradientSwatch(
                    name: "White highlight over pink",
                    gradient: .evaPinkHighlightBase,
                    wash: true
                )
            }
        }
        .padding(20)
    }
    .background(Color.evaWarmBackground)
}

import SwiftUI

/// The canvas' screen ground: warm off-white with three blurred colour glows and a wash
/// of the background colour laid back over them.
///
/// Read from "Eva App.dc.html", where it sits outside every screen's own markup — the
/// phone frame paints it once and every screen is drawn on top:
///
/// ```css
/// background:#FFF9F6
/// 420×420  left:-170  top:-160     radial rgba(233,130,165,.30) → 0 at 70%  blur(44px)
/// 400×400  right:-190 top:200      radial rgba(205,231,157,.34) → 0 at 70%  blur(48px)
/// 460×360  left:-90   bottom:-190  radial rgba(249,220,230,.42) → 0 at 70%  blur(50px)
/// inset:0                          rgba(255,249,246,.42)
/// ```
///
/// Three things to know before changing it:
///
/// * **The glow geometry is absolute, at the canvas' 390 × 844 base frame.** It is
///   composition, not layout — each glow is anchored to a corner and offset by the
///   artboard's own pixel values, so the picture holds its shape on a taller phone
///   instead of stretching. That is why these numbers are literals here rather than
///   `EvaSpacing` steps: they are not spacing.
/// * **CSS blur radius is twice SwiftUI's**, the same conversion the card and button
///   shadows use in `EvaGlass.swift`.
/// * **The wash goes over the glows, not under them.** It is what keeps the whole thing
///   at the low saturation the canvas draws; without it the pink corner reads as a
///   gradient feature rather than a room's worth of light.
///
/// Only the auth screens use it today. The questionnaire keeps the legacy mauve
/// background until it moves into Profile — see DESIGN.md §9.
struct EvaScreenBackground: View {

    var body: some View {
        Color.evaWarmBackground
            .overlay(alignment: .topLeading) {
                EvaScreenGlow(
                    color: .evaPrimaryPink,
                    opacity: 0.30,
                    size: CGSize(width: 420, height: 420),
                    blur: 22
                )
                .offset(x: -170, y: -160)
            }
            .overlay(alignment: .topTrailing) {
                EvaScreenGlow(
                    color: .evaPistachio,
                    opacity: 0.34,
                    size: CGSize(width: 400, height: 400),
                    blur: 24
                )
                .offset(x: 190, y: 200)
            }
            .overlay(alignment: .bottomLeading) {
                EvaScreenGlow(
                    color: .evaSoftBlush,
                    opacity: 0.42,
                    size: CGSize(width: 460, height: 360),
                    blur: 25
                )
                .offset(x: -90, y: 190)
            }
            .overlay { Color.evaWarmBackground.opacity(0.42) }
            .clipped()
            .allowsHitTesting(false)
    }
}

/// One of the three glows — a radial fade to nothing, then blurred.
///
/// The CSS stops the colour at 70% of the box; a `RadialGradient` ending at half the
/// box's shorter edge lands in the same place once the blur has softened it, and the
/// blur is what actually decides how the glow reads.
private struct EvaScreenGlow: View {
    let color: Color
    let opacity: Double
    let size: CGSize
    let blur: CGFloat

    var body: some View {
        RadialGradient(
            colors: [color.opacity(opacity), color.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: min(size.width, size.height) / 2
        )
        .frame(width: size.width, height: size.height)
        .blur(radius: blur)
    }
}

#Preview("Screen background") {
    EvaScreenBackground()
        .ignoresSafeArea()
        .overlay {
            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("Your Prime Era\nstarts here")
                    .evaTextStyle(.h1)
                    .foregroundStyle(Color.evaPrimaryText)
                Text("Pink top-left, pistachio right, blush bottom-left, all under a 42% "
                     + "wash of the background colour.")
                    .evaTextStyle(.body)
                    .foregroundStyle(Color.evaSecondaryText)
            }
            .padding(EvaSpacing.lg)
        }
}

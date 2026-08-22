import SwiftUI

/// Determinate progress bar for the onboarding flow.
///
/// **This component is extrapolated, not transcribed.** "Eva Design System.dc.html"
/// specifies no progress bar, so nothing below is a canvas measurement — it is the
/// nearest reading of the rest of the system, and should be replaced the moment the
/// canvas gains a real one.
///
/// What it borrows, and from where:
///
/// - **Fill** — `LinearGradient.evaPrimaryButton`, the primary button's
///   `linear-gradient(180deg, #EE93B1, #C95F86)` (DESIGN.md §5), unchanged in stops
///   *and* direction. Progress is the flow's primary affordance made passive, so it
///   takes the primary fill rather than a new one; keeping the 180° top-to-bottom
///   direction rather than rotating it to the bar's long axis is what makes it the
///   same gradient as the button beneath it instead of a second, similar one.
/// - **Track** — `Color.evaControlBorder`, the `rgba(40,33,38,.1)` neutral the canvas
///   uses for every control hairline (§5, §6). The palette's other neutral candidate,
///   Secondary Background `#F8F3F0`, is all but invisible against the `#FFF9F6` warm
///   screen background; ink-at-10% reads as a recessed track over the warm background
///   and over glass alike.
/// - **Shape** — `Capsule`, the pill radius from §4.
///
/// Height (7) and the 0.35s ease-out are carried over from the pre-canvas
/// implementation and are likewise unspecified.
struct EvaProgressBarStyle: ProgressViewStyle {

    /// Bar height. Not a canvas value — see the note above.
    private static let height: CGFloat = 7

    /// How long the fill takes to catch up with a step change.
    private static let animationDuration: Double = 0.35

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let fraction = configuration.fractionCompleted ?? 0
            Capsule()
                .fill(Color.evaControlBorder)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient.evaPrimaryButton)
                        // Floors at one bar-height so the fill stays a legible pill
                        // rather than a sliver at low fractions.
                        .frame(width: max(Self.height, proxy.size.width * fraction))
                }
        }
        .frame(height: Self.height)
        .animation(
            .easeOut(duration: Self.animationDuration),
            value: configuration.fractionCompleted
        )
    }
}

// MARK: - Preview

#Preview("Progress") {
    VStack(alignment: .leading, spacing: EvaSpacing.lg) {
        ForEach([0.0, 0.25, 0.43, 0.75, 1.0], id: \.self) { value in
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("\(Int(value * 100))%")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                ProgressView(value: value)
                    .progressViewStyle(EvaProgressBarStyle())
            }
        }
    }
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}

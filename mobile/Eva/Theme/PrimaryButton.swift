import SwiftUI

/// The DESIGN.md §5 primary button: 52 high, radius 17, a 180° `#EE93B1`→`#C95F86`
/// gradient with a white label and a soft pink shadow.
///
/// One per screen. The shared pieces — state resolution, heights, press feedback, focus
/// ring — live in `EvaButtons.swift` alongside the other variants.
struct EvaPrimaryButtonStyle: ButtonStyle {

    /// Keeps the enabled fill while the button is `.disabled` for loading.
    ///
    /// `PrimaryButton` disables itself while a request is in flight so it cannot be
    /// double-tapped, but a spinner on the 28% disabled fill is both wrong (nothing is
    /// disabled — something is happening) and hard to see. The canvas has no loading
    /// state, so this is a decision, not a transcription.
    var isLoading = false

    /// Forces a state a preview cannot reach by touch. Never set this in app code.
    var previewState: EvaButtonState?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let state = previewState ?? EvaButtonState.resolved(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled || isLoading,
            isFocused: isFocused
        )

        return configuration.label
            .evaTextStyle(.button)
            .foregroundStyle(Color.evaTextOnDark)
            .frame(maxWidth: .infinity, minHeight: EvaButtonHeight.standard)
            .padding(.horizontal, EvaSpacing.md)
            .background {
                RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                    .fill(Self.fill(for: state))
                    .shadow(
                        // The disabled fill is a pale 28% pink; a full-strength pink
                        // shadow under it reads as elevation the control no longer has.
                        // §5 does not say either way.
                        color: state == .disabled ? .clear : EvaPrimaryButtonShadow.color,
                        radius: EvaPrimaryButtonShadow.radius,
                        x: 0,
                        y: EvaPrimaryButtonShadow.offsetY
                    )
            }
            .evaFocusRing(state == .focused, cornerRadius: EvaRadius.control)
            .scaleEffect(state == .pressed ? EvaButtonPress.scale : 1)
            .animation(.easeOut(duration: EvaButtonPress.duration), value: state)
    }

    private static func fill(for state: EvaButtonState) -> AnyShapeStyle {
        switch state {
        case .normal, .focused: AnyShapeStyle(LinearGradient.evaPrimaryButton)
        case .pressed: AnyShapeStyle(LinearGradient.evaPrimaryButtonPressed)
        case .disabled: AnyShapeStyle(Color.evaPrimaryButtonDisabled)
        }
    }
}

/// Canvas primary-button shadow: `0 12px 26px -12px rgba(201,95,134,.8)` (DESIGN.md §5).
///
/// CSS blur 26 → SwiftUI radius 13, and the 12px offset carries over directly. The
/// −12px **spread has no SwiftUI expression**, so the shadow spreads wider and reads
/// heavier than the canvas — the same limitation the card shadow hits in
/// `EvaGlass.swift`. `radius` is the knob if it ever looks too heavy beside the canvas.
private enum EvaPrimaryButtonShadow {
    static let color = Color.evaDeepPink.opacity(0.8)
    static let radius: CGFloat = 13
    static let offsetY: CGFloat = 12
}

extension ButtonStyle where Self == EvaPrimaryButtonStyle {
    /// DESIGN.md §5 primary button. Prefer `PrimaryButton`, which also sets the
    /// `primary.<title>` identifier `EvaUITests` navigates by; reach for the style
    /// directly only when the label is more than a string.
    static var evaPrimary: Self { EvaPrimaryButtonStyle() }
}

/// Full-width gradient call-to-action — the one primary action on a screen.
struct PrimaryButton: View {
    let title: String
    var showsArrow = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: EvaSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .tint(Color.evaTextOnDark)
                } else {
                    Text(title)
                    if showsArrow {
                        Image(systemName: "arrow.right")
                    }
                }
            }
        }
        .buttonStyle(EvaPrimaryButtonStyle(isLoading: isLoading))
        .disabled(isLoading)
        // The label is a spinner while loading, so the title has to be spoken from
        // here. The identifier is separate and unchanged either way.
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("primary.\(title)")
    }
}

// MARK: - Preview

#Preview("Primary button") {
    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.lg) {
            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("As used")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                PrimaryButton(title: "Get started", showsArrow: true) {}
                PrimaryButton(title: "Create my account") {}
                PrimaryButton(title: "Continue", isLoading: true) {}
            }

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("States")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                // Forced rather than performed: a preview cannot hold a press or take
                // keyboard focus.
                Button("Normal") {}
                    .buttonStyle(EvaPrimaryButtonStyle(previewState: .normal))
                Button("Pressed") {}
                    .buttonStyle(EvaPrimaryButtonStyle(previewState: .pressed))
                Button("Focused") {}
                    .buttonStyle(EvaPrimaryButtonStyle(previewState: .focused))
                Button("Disabled") {}
                    .buttonStyle(EvaPrimaryButtonStyle(previewState: .disabled))
                    .disabled(true)
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background {
        LinearGradient.evaBlushCream.ignoresSafeArea()
    }
}

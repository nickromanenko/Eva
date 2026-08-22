import SwiftUI

/// The DESIGN.md §5 primary button: 52 high, radius 17, a 180° pink gradient with a
/// white label and a soft pink shadow.
///
/// One per screen. The shared pieces — state resolution, heights, press feedback, focus
/// ring — live in `EvaButtons.swift` alongside the other variants.
///
/// ## Two deliberate deviations from the canvas, both approved on #12
///
/// **The fill is the action ramp, not the canvas ramp.** §5 draws the resting fill as
/// `#EE93B1`→`#C95F86` and the pressed fill as `#D9799C`→`#B45276`. White on those
/// measures 2.22:1 at the top stop and 3.84:1 at the bottom, against the 4.5:1 AA needs
/// for a 14.5pt semibold label — the whole button fails, not just its lightest edge.
/// No arrangement of the canvas ramp and a white label clears AA, so this uses
/// `LinearGradient.evaActionPink` (`#B45276`→`#96486A`, 4.76:1 → 6.12:1) resting and
/// `.evaActionPinkPressed` (`#994664`→`#803D5A`, 6.15:1 → 7.68:1) pressed. See the
/// `evaActionPink…` note in `EvaColors.swift` for why the brand pink is kept everywhere
/// it does *not* carry a label.
///
/// **The disabled label is Primary Text, not white.** §5 says
/// `background:rgba(201,95,134,.28); color:#fff`, which measures **1.45:1** — the canvas
/// asking for something unreadable. The fill is kept exactly as drawn and only the label
/// changes: `#282126` on that fill measures **10.87:1**. Disabled controls are not brand
/// moments, so nothing is lost, and the first control a new user meets stops being
/// invisible. Decided on #12 (1a), applied by #17.
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
            .foregroundStyle(Self.label(for: state))
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

    /// The action ramp resting and pressed; the canvas' own 28% fill when disabled.
    ///
    /// The disabled fill stays `evaPrimaryButtonDisabled` because it is readable once
    /// the label is Primary Text — see `label(for:)` and the type comment.
    private static func fill(for state: EvaButtonState) -> AnyShapeStyle {
        switch state {
        case .normal, .focused: AnyShapeStyle(LinearGradient.evaActionPink)
        case .pressed: AnyShapeStyle(LinearGradient.evaActionPinkPressed)
        case .disabled: AnyShapeStyle(Color.evaPrimaryButtonDisabled)
        }
    }

    /// White on the action ramp; Primary Text on the pale disabled fill.
    ///
    /// The disabled row is the deviation — 10.87:1 rather than the canvas' 1.45:1. See
    /// the type comment.
    private static func label(for state: EvaButtonState) -> Color {
        switch state {
        case .normal, .focused, .pressed: .evaTextOnDark
        case .disabled: .evaPrimaryText
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

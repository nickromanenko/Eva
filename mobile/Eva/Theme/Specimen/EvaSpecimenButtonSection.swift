#if DEBUG
import SwiftUI

/// DESIGN.md §5 — every button variant in all four states, without needing a finger.
///
/// The states are **forced**, via each style's `previewState`, not performed. A press
/// cannot be held for a screenshot and `\.isFocused` is false on iPhone unless a
/// hardware keyboard or Full Keyboard Access is attached, so the only way to review
/// pressed and focused side by side is to ask the style to draw them.
///
/// Each variant's four states are stacked vertically rather than laid out across the
/// screen: these are full-width controls, and four of them across a 390pt frame would
/// be 80pt each — narrow enough that the gradient, the shadow and the label metrics
/// would all misrepresent how the real control reads.
struct EvaSpecimenButtonSection: View {

    var body: some View {
        EvaSpecimenSection(number: "05", title: "Buttons", reference: "DESIGN.md §5") {
            EvaSpecimenNote(
                text: "\(EvaSpecimenNumber.string(EvaControl.height)) high · radius "
                    + "\(EvaSpecimenNumber.string(EvaRadius.control)) · text button "
                    + "\(EvaSpecimenNumber.string(EvaControl.textButtonHeight)) high at radius "
                    + "\(EvaSpecimenNumber.string(EvaRadius.chip)) · row destructive "
                    + "\(EvaSpecimenNumber.string(EvaMetrics.minimumTouchTarget)) high at radius "
                    + "\(EvaSpecimenNumber.string(EvaRadius.destructiveRow)) · states forced, "
                    + "not pressed."
            )

            EvaSpecimenButtonStates(title: "Primary", identifier: "primary") {
                EvaPrimaryButtonStyle(previewState: $0)
            }

            EvaSpecimenDisabledLabelNote(
                surface: "Primary",
                fill: .evaPrimaryButtonDisabled,
                canvasLabel: .evaTextOnDark,
                actualLabel: .evaPrimaryText,
                reason: "the sign-up CTA sits disabled until the form validates, so this is "
                    + "the first control a new user meets"
            )

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                EvaSpecimenGroupLabel(title: "Primary · loading")
                PrimaryButton(title: "Continue", isLoading: true) {}
                EvaSpecimenNote(
                    text: "Not a canvas state. Keeps the enabled fill while disabled so the "
                        + "spinner does not read as 'nothing is happening'."
                )
            }

            EvaSpecimenButtonStates(title: "Secondary glass", identifier: "secondary") {
                EvaSecondaryButtonStyle(previewState: $0)
            }

            EvaSpecimenButtonStates(title: "Text", identifier: "text") {
                EvaTextButtonStyle(previewState: $0)
            }

            EvaSpecimenButtonStates(
                title: "Destructive · outlined",
                identifier: "destructive.outlined"
            ) {
                EvaDestructiveButtonStyle(kind: .outlined, previewState: $0)
            }

            EvaSpecimenButtonStates(
                title: "Destructive · solid (modals only)",
                identifier: "destructive.solid"
            ) {
                EvaDestructiveButtonStyle(kind: .solid, previewState: $0)
            }

            EvaSpecimenDisabledLabelNote(
                surface: "Solid destructive",
                fill: Color.evaDestructive.opacity(0.5),
                canvasLabel: .evaTextOnDark,
                actualLabel: .evaPrimaryText,
                reason: "a modal asking you to confirm a deletion is the wrong place to "
                    + "leave a label unreadable"
            )

            EvaSpecimenButtonStates(
                title: "Destructive · row (44 high)",
                identifier: "destructive.row"
            ) {
                EvaDestructiveButtonStyle(kind: .row, previewState: $0)
            }

            EvaSpecimenButtonStates(title: "Auth · Apple", identifier: "auth.apple") {
                EvaAuthButtonStyle(provider: .apple, previewState: $0)
            }

            EvaSpecimenButtonStates(title: "Auth · Google", identifier: "auth.google") {
                EvaAuthButtonStyle(provider: .google, previewState: $0)
            }

            EvaSpecimenNote(
                text: "§5 gives the auth buttons one fill each. Pressed, focused and "
                    + "disabled borrow the rule the canvas already states for the nearest "
                    + "variant it does specify — Apple darkens like the primary, Google "
                    + "takes the secondary glass' fills. The canvas' loading state "
                    + "(#3A3436, 60% white label) is not built: nothing can reach it until "
                    + "Apple and Google sign-in exist."
            )

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                EvaSpecimenGroupLabel(title: "Auth · compact")
                EvaSpecimenNote(
                    text: "The inline variant from the account-linking banner. The artboard "
                        + "draws it 38 high at radius 12; it renders at "
                        + "\(EvaSpecimenNumber.string(EvaButtonHeight.row))/"
                        + "\(EvaSpecimenNumber.string(EvaRadius.chip)), the minimum touch "
                        + "target and the radius the system's other inline controls use."
                )
                HStack {
                    EvaAuthButton(
                        provider: .apple,
                        size: .compact,
                        identifier: "specimen.auth.compact"
                    ) {}
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                EvaSpecimenGroupLabel(title: "As used")
                EvaSpecimenNote(
                    text: "The wrappers, with the identifiers UI tests navigate by."
                )
                PrimaryButton(title: "Get started", showsArrow: true) {}
                EvaAuthButton(provider: .apple) {}
                EvaAuthButton(provider: .google) {}
                SecondaryButton(title: "Not now") {}
                TextButton(title: "Skip for now") {}
                DestructiveButton(title: "Delete my account") {}
                DestructiveButton(title: "Remove entry", kind: .row) {}
            }
        }
    }
}

// MARK: - States

/// One variant's four states, each labelled with the state it is showing.
private struct EvaSpecimenButtonStates<Style: ButtonStyle>: View {

    let title: String
    /// Prefix for the buttons' accessibility identifiers, e.g. `"primary"` gives
    /// `specimen.primary.pressed`.
    let identifier: String
    /// Builds the variant's style for a given state. A closure rather than a style
    /// instance because the forced state is part of the style's own value.
    let style: (EvaButtonState) -> Style

    private static var states: [(name: String, state: EvaButtonState)] {
        [
            ("Normal", .normal),
            ("Pressed", .pressed),
            ("Focused", .focused),
            ("Disabled", .disabled)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            EvaSpecimenGroupLabel(title: title)

            ForEach(Self.states, id: \.name) { name, state in
                Button(name) {}
                    .buttonStyle(style(state))
                    // Really disabled as well as drawn disabled, so the specimen shows
                    // the same control the app would ship, not just its paint.
                    .disabled(state == .disabled)
                    .accessibilityIdentifier("specimen.\(identifier).\(name.lowercased())")
            }
        }
        // The focus ring is drawn 3pt outside the control's edge, so without this the
        // ring on the focused row overlaps its neighbours.
        .padding(.vertical, EvaControl.focusRingWidth)
    }
}

// MARK: - Disabled label

/// §9a's disabled-label deviation, with both ratios measured rather than quoted.
///
/// The artboard keeps a white label on every disabled fill. On the primary's 28% pink
/// that is 1.45:1 — the first control a new user meets, unreadable — so these two
/// surfaces take Primary Text instead. Both numbers are computed from the tokens here,
/// so if a fill moves the note moves with it.
private struct EvaSpecimenDisabledLabelNote: View {
    let surface: String
    /// The disabled fill, composited over the page it sits on.
    let fill: Color
    /// What the canvas asks the label to be.
    let canvasLabel: Color
    /// What it actually is.
    let actualLabel: Color
    /// Why this surface was worth deviating for. Disabled controls are exempt from
    /// WCAG 1.4.3, so each of these needs its own reason, not a shared one.
    let reason: String

    /// The specimen's own page colour. The button section is drawn on the warm
    /// background, so this is the ground these fills really composite over.
    private static let ground = Color.evaWarmBackground

    @Environment(\.self) private var environment

    private func ratio(_ label: Color) -> String {
        let ground = Self.ground.evaSpecimenReadback(in: environment)
        return EvaSpecimenNumber.ratio(
            EvaSpecimenColorReadback.contrastRatio(
                label.evaSpecimenReadback(in: environment).composited(over: ground),
                fill.evaSpecimenReadback(in: environment).composited(over: ground)
            )
        )
    }

    var body: some View {
        EvaSpecimenNote(
            text: "§9a: \(surface) disabled keeps the canvas fill "
                + "\(fill.evaSpecimenReadback(in: environment).caption) but takes Primary Text, "
                + "not white — \(ratio(actualLabel)) against \(ratio(canvasLabel)). "
                + "Disabled controls are exempt from WCAG 1.4.3, but \(reason)."
        )
    }
}

#Preview("Buttons") {
    ScrollView {
        EvaSpecimenButtonSection()
            .padding(EvaSpacing.lg)
    }
    .background {
        EvaSpecimenColorField().ignoresSafeArea()
    }
}
#endif

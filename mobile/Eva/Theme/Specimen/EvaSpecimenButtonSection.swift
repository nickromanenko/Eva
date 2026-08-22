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
            EvaSpecimenNote(text: "52 high · radius 17 · states forced, not pressed.")

            EvaSpecimenButtonStates(title: "Primary", identifier: "primary") {
                EvaPrimaryButtonStyle(previewState: $0)
            }

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

            EvaSpecimenButtonStates(
                title: "Destructive · row (44 high)",
                identifier: "destructive.row"
            ) {
                EvaDestructiveButtonStyle(kind: .row, previewState: $0)
            }

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                EvaSpecimenGroupLabel(title: "As used")
                EvaSpecimenNote(
                    text: "The wrappers, with the identifiers UI tests navigate by."
                )
                PrimaryButton(title: "Get started", showsArrow: true) {}
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

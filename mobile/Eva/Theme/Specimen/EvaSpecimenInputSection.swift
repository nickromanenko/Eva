#if DEBUG
import SwiftUI

/// DESIGN.md §6 — `EvaInputField` in default, focused, error and disabled.
///
/// Focus is *told*, not taken: `EvaInputField` draws its ring from an `isFocused: Bool`
/// the caller passes, so the focused row can be shown next to the others without the
/// keyboard coming up and without stealing focus from the rest of the screen.
///
/// Each row keeps its own text so the fields behave like real fields when tapped — the
/// specimen is a screen, and a text input that cannot be typed into is not the component
/// under review.
struct EvaSpecimenInputSection: View {

    @State private var empty = ""
    @State private var filled = "sam@example.com"
    @State private var invalid = "sam@example"
    @State private var locked = "sam@example.com"
    @State private var secret = ""

    var body: some View {
        EvaSpecimenSection(number: "07", title: "Input field", reference: "DESIGN.md §6") {
            EvaSpecimenNote(text: "52 high · radius 17 · 3pt ring drawn outside the border.")

            VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                EvaInputField(label: "Default", placeholder: "you@email.com") { prompt in
                    TextField("Default", text: $empty, prompt: prompt)
                        .accessibilityIdentifier("specimen.input.default")
                }

                EvaInputField(
                    label: "Focused",
                    placeholder: "you@email.com",
                    isFocused: true
                ) { prompt in
                    TextField("Focused", text: $filled, prompt: prompt)
                        .accessibilityIdentifier("specimen.input.focused")
                }

                EvaInputField(
                    label: "Error",
                    placeholder: "you@email.com",
                    errorMessage: "That address is missing a domain — check it and try again.",
                    errorIdentifier: "specimen.input.error.message"
                ) { prompt in
                    TextField("Error", text: $invalid, prompt: prompt)
                        .accessibilityIdentifier("specimen.input.error")
                }

                EvaInputField(label: "Disabled", placeholder: "you@email.com") { prompt in
                    TextField("Disabled", text: $locked, prompt: prompt)
                        .accessibilityIdentifier("specimen.input.disabled")
                }
                .disabled(true)

                EvaInputField(label: "Secure", placeholder: "At least 8 characters") { prompt in
                    SecureField("Secure", text: $secret, prompt: prompt)
                        .accessibilityIdentifier("specimen.input.secure")
                }
            }
        }
    }
}

#Preview("Input field") {
    ScrollView {
        EvaSpecimenInputSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

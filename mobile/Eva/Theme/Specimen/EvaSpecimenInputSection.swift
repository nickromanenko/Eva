#if DEBUG
import SwiftUI

/// DESIGN.md §6 — `EvaInputField` in default, focused, error and disabled, and the
/// tokens each of those states paints with.
///
/// Focus is *told*, not taken: `EvaInputField` draws its ring from an `isFocused: Bool`
/// the caller passes, so the focused row can be shown next to the others without the
/// keyboard coming up and without stealing focus from the rest of the screen.
///
/// Each row keeps its own text so the fields behave like real fields when tapped — the
/// specimen is a screen, and a text input that cannot be typed into is not the component
/// under review.
///
/// The token grid at the bottom exists because the fill moving with the state is the
/// part of §6 the DESIGN.md transcription lost: the four fills differ by as little as
/// five percentage points, and three of them (`evaInputFillFocused`,
/// `evaInputFillError`, `evaInputBorderDisabled`) arrived with #16 with nothing on this
/// screen naming them. Seeing four fields is not the same as being able to tell which
/// token each is wearing.
struct EvaSpecimenInputSection: View {

    @State private var empty = ""
    @State private var filled = "sam@example.com"
    @State private var invalid = "sam@example"
    @State private var locked = "sam@example.com"
    @State private var secret = ""

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: EvaSpacing.sm)]

    var body: some View {
        EvaSpecimenSection(number: "07", title: "Input field", reference: "DESIGN.md §6") {
            EvaSpecimenNote(
                text: "\(EvaSpecimenNumber.string(EvaControl.height)) high · radius "
                    + "\(EvaSpecimenNumber.string(EvaRadius.control)) · "
                    + "\(EvaSpecimenNumber.string(EvaControl.focusRingWidth))pt ring drawn "
                    + "outside the border · 15pt horizontal padding."
            )

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

            EvaSpecimenGroupLabel(title: "Fills")
            EvaSpecimenNote(
                text: "The fill lifts as the field gains attention — 75% at rest, 80% when "
                    + "wrong, fully opaque when focused, so focus reads as a change in the "
                    + "surface and not only as a ring. On the wash so the alpha shows."
            )
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenInputTokenTile(name: "Fill · default", color: .evaInputFill)
                EvaSpecimenInputTokenTile(name: "Fill · focused", color: .evaInputFillFocused)
                EvaSpecimenInputTokenTile(name: "Fill · error", color: .evaInputFillError)
                EvaSpecimenInputTokenTile(name: "Fill · disabled", color: .evaInputFillDisabled)
                EvaSpecimenInputTokenTile(name: "Focus ring", color: .evaInputFocusRing)
                EvaSpecimenInputTokenTile(name: "Error ring", color: .evaInputErrorRing)
                EvaSpecimenInputTokenTile(name: "Text · disabled", color: .evaInputTextDisabled)
            }

            EvaSpecimenGroupLabel(title: "Borders")
            EvaSpecimenNote(
                text: "Drawn as hairlines, not fills — at 7% and 10% a filled swatch is "
                    + "indistinguishable from the page. The disabled input's 7% is "
                    + "deliberately not the buttons' 6%; the artboard separates them."
            )
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                EvaSpecimenInputBorderTile(name: "Border · default", color: .evaControlBorder)
                EvaSpecimenInputBorderTile(name: "Border · focused", color: .evaDeepPink)
                EvaSpecimenInputBorderTile(name: "Border · error", color: .evaError)
                EvaSpecimenInputBorderTile(name: "Border · disabled", color: .evaInputBorderDisabled)
            }
        }
    }
}

// MARK: - Tiles

/// One input fill token, over the wash so its alpha reads, captioned from itself.
private struct EvaSpecimenInputTokenTile: View {
    let name: String
    let color: Color

    @Environment(\.self) private var environment

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            shape
                .fill(color)
                .background { shape.fill(LinearGradient.evaPinkPistachio) }
                .overlay { shape.strokeBorder(Color.evaControlBorder, lineWidth: 1) }
                .frame(height: EvaMetrics.minimumTouchTarget)

            Text(name)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaPrimaryText)
                .lineLimit(2, reservesSpace: true)

            Text(color.evaSpecimenReadback(in: environment).caption)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One border token, drawn as the hairline it is, on the fill it sits on.
private struct EvaSpecimenInputBorderTile: View {
    let name: String
    let color: Color

    @Environment(\.self) private var environment

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            shape
                .fill(Color.evaInputFill)
                .overlay { shape.strokeBorder(color, lineWidth: 1) }
                .frame(height: EvaMetrics.minimumTouchTarget)

            Text(name)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaPrimaryText)
                .lineLimit(2, reservesSpace: true)

            Text(color.evaSpecimenReadback(in: environment).caption)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

import SwiftUI

/// A labelled text input built to the canvas — DESIGN.md §6 "Form controls".
///
/// 52 high, radius 17, `evaInputFill` behind a 1pt `evaControlBorder`. Focus adds a
/// `evaDeepPink` border and a 3pt `evaInputFocusRing`; an error swaps both for
/// `evaError` / `evaInputErrorRing` and puts an icon-and-message *below* the field,
/// because §2 requires every semantic state to carry a mark as well as a colour — for
/// error that mark is `!` in a circle.
///
/// **The caller keeps the field.** `EvaInputField` never builds the `TextField` or
/// `SecureField` itself; it takes one from a builder and dresses it. That keeps
/// `@FocusState`, `textContentType`, `keyboardType`, `submitLabel`, `onSubmit` and —
/// critically — `accessibilityIdentifier` at the call site, on the real control.
/// `EvaUITests` looks the password up as `app.secureTextFields["signup.password"]`, so
/// the identifier has to stay on the `SecureField` and not migrate to a wrapper.
///
/// The builder is handed the placeholder already styled as a `Text`, since a
/// `TextField`'s placeholder colour can only be set through its `prompt`:
///
/// ```swift
/// EvaInputField(
///     label: "Email",
///     placeholder: "you@email.com",
///     isFocused: focusedField == .email
/// ) { prompt in
///     TextField("Email", text: $email, prompt: prompt)
///         .focused($focusedField, equals: .email)
///         .accessibilityIdentifier("signup.email")
/// }
/// ```
///
/// The field's title (`"Email"` above) is not drawn — the prompt takes its place — but
/// it is what VoiceOver reads, so give it the same words as `label`.
///
/// Disabled comes from the environment: apply `.disabled(true)` to the whole
/// `EvaInputField` and both the styling and the control follow.
struct EvaInputField<Content: View>: View {

    /// Drawn above the field, uppercased, in the §3 Label row.
    let label: String
    /// Whether the caller's `@FocusState` currently points at this field. Focus stays
    /// with the caller; the component is only told about it so it can draw the ring.
    let isFocused: Bool
    /// The error to show under the field, or `nil` for none.
    let errorMessage: String?
    /// Identifier for the error message, e.g. `"signup.error"`. It sits on the message
    /// `Text` itself, so the element stays a static text for UI tests.
    let errorIdentifier: String?
    /// The caller's field, already carrying every modifier they applied to it.
    let content: Content

    @Environment(\.isEnabled) private var isEnabled

    /// Input height from §6. A *minimum* rather than a fixed height: the canvas designs
    /// one frame at the default content size, and clamping to exactly 52 would clip the
    /// text at larger Dynamic Type sizes. It renders at 52 as designed.
    private static var height: CGFloat { EvaControl.height }
    /// The hairline border, §6.
    private static var borderWidth: CGFloat { 1 }
    /// The focus/error ring, §6. Drawn *outside* the border, like the CSS
    /// `box-shadow: 0 0 0 3px`, so gaining focus never moves the layout.
    /// Shared with the buttons — see `EvaControl.focusRingWidth`.
    private static var ringWidth: CGFloat { EvaControl.focusRingWidth }

    init(
        label: String,
        placeholder: String,
        isFocused: Bool = false,
        errorMessage: String? = nil,
        errorIdentifier: String? = nil,
        @ViewBuilder content: (Text) -> Content
    ) {
        self.label = label
        self.isFocused = isFocused
        self.errorMessage = errorMessage
        self.errorIdentifier = errorIdentifier
        self.content = content(Self.prompt(placeholder))
    }

    /// The placeholder as a `Text` carrying its own colour.
    ///
    /// `Text.foregroundStyle(_:)` bakes the colour into the text value, which is the
    /// only way to reach a field's placeholder — the view-level `foregroundStyle` on a
    /// `TextField` colours what the user types, not the prompt.
    private static func prompt(_ placeholder: String) -> Text {
        Text(placeholder).foregroundStyle(Color.evaMutedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            Text(label)
                .textCase(.uppercase)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)

            content
                .textFieldStyle(.plain)
                // Font only, no line height: the §3 Body row's 15/24 describes running
                // text, and a single-line control has nothing to lead against.
                .font(.evaBody)
                .foregroundStyle(fieldTextColor)
                .tint(Color.evaDeepPink)
                // §6 gives no inner padding for inputs; 16 is the §4 default.
                .padding(.horizontal, EvaSpacing.md)
                .padding(.vertical, EvaSpacing.sm)
                .frame(minHeight: Self.height)
                .background(fill, in: .rect(cornerRadius: EvaRadius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: Self.borderWidth)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: EvaRadius.control + Self.ringWidth,
                        style: .continuous
                    )
                    .strokeBorder(ringColor, lineWidth: Self.ringWidth)
                    .padding(-Self.ringWidth)
                }

            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
                    // The `!` circle from §2. Hidden from VoiceOver: it repeats the
                    // message beside it, which is what actually gets read.
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.evaError)
                        .accessibilityHidden(true)
                    Text(errorMessage)
                        .evaTextStyle(.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .evaAccessibilityIdentifier(errorIdentifier)
                }
                .foregroundStyle(Color.evaErrorInk)
            }
        }
    }

    private var fill: Color {
        isEnabled ? .evaInputFill : .evaInputFillDisabled
    }

    private var fieldTextColor: Color {
        isEnabled ? .evaPrimaryText : .evaInputTextDisabled
    }

    /// Error outranks focus: a focused field that is also wrong should read as wrong.
    private var borderColor: Color {
        guard isEnabled else { return .evaControlBorder }
        if errorMessage != nil { return .evaError }
        return isFocused ? .evaDeepPink : .evaControlBorder
    }

    /// `.clear` rather than an optional ring, so the states are one view that changes
    /// colour instead of two views that replace each other.
    private var ringColor: Color {
        guard isEnabled else { return .clear }
        if errorMessage != nil { return .evaInputErrorRing }
        return isFocused ? .evaInputFocusRing : .clear
    }
}

private extension View {
    /// `accessibilityIdentifier` that tolerates a missing identifier, rather than
    /// stamping an empty string onto the element.
    @ViewBuilder
    func evaAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

#Preview("Input states") {
    @Previewable @State var empty = ""
    @Previewable @State var focused = "sam@example.com"
    @Previewable @State var invalid = "sam@example"
    @Previewable @State var locked = "sam@example.com"

    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.lg) {
            EvaInputField(label: "Default", placeholder: "you@email.com") { prompt in
                TextField("Default", text: $empty, prompt: prompt)
                    .accessibilityIdentifier("preview.default")
            }

            EvaInputField(
                label: "Focused",
                placeholder: "you@email.com",
                isFocused: true
            ) { prompt in
                TextField("Focused", text: $focused, prompt: prompt)
                    .accessibilityIdentifier("preview.focused")
            }

            EvaInputField(
                label: "Error",
                placeholder: "you@email.com",
                errorMessage: "That address is missing a domain — check it and try again.",
                errorIdentifier: "preview.error"
            ) { prompt in
                TextField("Error", text: $invalid, prompt: prompt)
                    .accessibilityIdentifier("preview.invalid")
            }

            EvaInputField(label: "Disabled", placeholder: "you@email.com") { prompt in
                TextField("Disabled", text: $locked, prompt: prompt)
                    .accessibilityIdentifier("preview.disabled")
            }
            .disabled(true)

            EvaInputField(label: "Secure", placeholder: "At least 8 characters") { prompt in
                SecureField("Secure", text: $empty, prompt: prompt)
                    .accessibilityIdentifier("preview.secure")
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}

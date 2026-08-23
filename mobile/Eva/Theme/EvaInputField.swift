import SwiftUI

/// A labelled text input built to the canvas — DESIGN.md §6 "Form controls".
///
/// 52 high, radius 17, 15pt of horizontal padding, `evaInputFill` behind a 1pt
/// `evaControlBorder`. Focus adds a `evaDeepPink` border and a 3pt `evaInputFocusRing`;
/// an error swaps both for `evaError` / `evaInputErrorRing` and puts an
/// icon-and-message *below* the field, because §2 requires every semantic state to carry
/// a mark as well as a colour — for error that mark is `!` in a circle.
///
/// An unmet **helper rule** is not an error and does not get that treatment: see
/// `isHelperUnmet`.
///
/// The fill moves with the state too, which the DESIGN.md transcription lost and the
/// artboard states: 75% white at rest, 80% on error, fully opaque when focused. See
/// `fill` and `EvaInputFill`.
///
/// **The caller keeps the field.** `EvaInputField` never builds the `TextField` or
/// `SecureField` itself; it takes one from a builder and dresses it. That keeps
/// `@FocusState`, `textContentType`, `keyboardType`, `submitLabel`, `onSubmit` and —
/// critically — `accessibilityIdentifier` at the call site, on the real control.
/// `EvaUITests` looks the password up as `app.textFields["signup.password"] after tapping signup.password.reveal`, so
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
///
/// ## Helper text and the trailing accessory
///
/// Both are canvas features the component did not have until the auth screens needed
/// them. §6's password field carries a "Show" affordance *inside* the field, and §3's
/// scale has an Input helper row whose specimen string is the sign-up screen's own "At
/// least 8 characters, including one number." — so the helper line under a field and the
/// control at its trailing edge are part of the designed input, not screen furniture.
///
/// The accessory is a slot rather than a built-in reveal button, for the same reason the
/// field itself is: the state it toggles (`SecureField` or `TextField`) belongs to the
/// caller. `EvaInputRevealButton` is the canvas' Show/Hide control, ready to drop in.
struct EvaInputField<Content: View, Accessory: View>: View {

    /// Drawn above the field, sentence-cased, in the §3 Label row.
    let label: String
    /// Whether the caller's `@FocusState` currently points at this field. Focus stays
    /// with the caller; the component is only told about it so it can draw the ring.
    let isFocused: Bool
    /// The error to show under the field, or `nil` for none.
    let errorMessage: String?
    /// Identifier for the error message, e.g. `"signup.error"`. It sits on the message
    /// `Text` itself, so the element stays a static text for UI tests.
    let errorIdentifier: String?
    /// The rule the field is asking for, stated up front rather than revealed as an error
    /// after failure — §6's password helper. It stays visible in every state; whether it
    /// reads as unmet is `isHelperUnmet`, not whether the field is in error.
    let helperText: String?
    /// Whether the rule in `helperText` is currently unsatisfied.
    ///
    /// This is the artboard's `pwHelpColor` — in "Sign up · validation" the rule turns
    /// `evaErrorInk` while the password input keeps its **normal** border, because the
    /// `signup` spec note is explicit that password rules are "stated up front as helper
    /// text, not revealed as an error after failure". So an unmet rule is deliberately
    /// *not* an `errorMessage`: it recolours this line and nothing else.
    ///
    /// It also gains the `!` mark, which the artboard does not draw. §2 requires every
    /// semantic state to carry a mark as well as a colour, and the mark is the cheapest
    /// way to honour both that and the spec note.
    let isHelperUnmet: Bool
    /// Identifier for the helper `Text`, e.g. `"signup.password.rule"`. Kept distinct
    /// from `errorIdentifier` so a client-side rule and a server failure are two
    /// different elements to a UI test.
    let helperIdentifier: String?
    /// A control at the field's trailing edge, inside the border — the canvas' Show/Hide
    /// on a password field. `EmptyView` when there is none.
    let accessory: Accessory
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
    /// The artboard's `padding:0 15px`.
    ///
    /// **This is not an `EvaSpacing` step**, and it should not become one: the scale is
    /// 4 / 8 / 12 / 16 / 24 / 32 / 40 and the canvas is deliberately using an off-scale
    /// value for this one control. It first shipped as `EvaSpacing.md` (16) on the note
    /// that "§6 gives no inner padding for inputs" — the artboard does give one, and
    /// this is it. Corrected by #16.
    private static var horizontalPadding: CGFloat { 15 }

    init(
        label: String,
        placeholder: String,
        isFocused: Bool = false,
        errorMessage: String? = nil,
        errorIdentifier: String? = nil,
        helperText: String? = nil,
        isHelperUnmet: Bool = false,
        helperIdentifier: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: (Text) -> Content
    ) {
        self.label = label
        self.isFocused = isFocused
        self.errorMessage = errorMessage
        self.errorIdentifier = errorIdentifier
        self.helperText = helperText
        self.isHelperUnmet = isHelperUnmet
        self.helperIdentifier = helperIdentifier
        self.accessory = accessory()
        self.content = content(Self.prompt(placeholder))
    }

    /// The placeholder as a `Text` carrying its own colour.
    ///
    /// `Text.foregroundStyle(_:)` bakes the colour into the text value, which is the
    /// only way to reach a field's placeholder — the view-level `foregroundStyle` on a
    /// `TextField` colours what the user types, not the prompt.
    private static func prompt(_ placeholder: String) -> Text {
        Text(placeholder).foregroundStyle(Color.evaSecondaryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            // Sentence case, not uppercase: both artboards draw "Email" and "Password"
            // that way. The uppercasing came from #2 and was never a canvas value.
            Text(label)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)

            HStack(spacing: EvaSpacing.xs) {
                content
                    .textFieldStyle(.plain)
                    // Font only, no line height: the §3 Body row's 15/24 describes running
                    // text, and a single-line control has nothing to lead against.
                    .font(.evaBody)
                    .foregroundStyle(fieldTextColor)
                    .tint(Color.evaDeepPink)
                    // Vertical padding belongs to the text, not to the row: the accessory
                    // is already 44 high for its touch target, and padding it too would
                    // push the field past the 52 §6 asks for.
                    .padding(.vertical, EvaSpacing.sm)

                accessory
            }
            .padding(.horizontal, Self.horizontalPadding)
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

            if let helperText {
                HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
                    // The `!` circle is decorative — but unlike the error row, the helper's
                    // words are identical whether the rule is met or not, so hiding the mark
                    // would leave the state carried by colour alone. The accessibility label
                    // below says it instead, which is also what makes the state assertable.
                    if isHelperUnmet {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.evaError)
                            .accessibilityHidden(true)
                    }
                    Text(helperText)
                        .evaTextStyle(.inputHelper)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            isHelperUnmet ? "Not met yet: \(helperText)" : helperText
                        )
                        .evaAccessibilityIdentifier(helperIdentifier)
                }
                .foregroundStyle(isHelperUnmet ? Color.evaErrorInk : Color.evaSecondaryText)
            }
        }
    }

    /// The fill lifts as the field gains attention: 75% white at rest, 80% when wrong,
    /// fully opaque when focused. Disabled drops to the warm grey.
    ///
    /// The artboard states all four; only two of them have tokens. See
    /// `EvaInputFill` for the two that do not.
    ///
    /// Error outranks focus here for the same reason it does in `borderColor` — a
    /// focused field that is also wrong should read as wrong.
    private var fill: Color {
        guard isEnabled else { return .evaInputFillDisabled }
        if errorMessage != nil { return Color.evaInputFillError }
        return isFocused ? Color.evaInputFillFocused : .evaInputFill
    }

    private var fieldTextColor: Color {
        isEnabled ? .evaPrimaryText : .evaInputTextDisabled
    }

    /// Error outranks focus: a focused field that is also wrong should read as wrong.
    ///
    /// Disabled is `evaInputBorderDisabled` — the artboard's `rgba(40,33,38,.07)`, kept
    /// distinct from the buttons' 6%. It first shipped as `evaControlBorder` (10%), the
    /// same hairline as an enabled field, which is the part that actually read wrong.
    private var borderColor: Color {
        guard isEnabled else { return .evaInputBorderDisabled }
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

extension EvaInputField where Accessory == EmptyView {
    /// A field with nothing at its trailing edge — every input except the password.
    init(
        label: String,
        placeholder: String,
        isFocused: Bool = false,
        errorMessage: String? = nil,
        errorIdentifier: String? = nil,
        helperText: String? = nil,
        isHelperUnmet: Bool = false,
        helperIdentifier: String? = nil,
        @ViewBuilder content: (Text) -> Content
    ) {
        self.init(
            label: label,
            placeholder: placeholder,
            isFocused: isFocused,
            errorMessage: errorMessage,
            errorIdentifier: errorIdentifier,
            helperText: helperText,
            isHelperUnmet: isHelperUnmet,
            helperIdentifier: helperIdentifier,
            accessory: { EmptyView() },
            content: content
        )
    }
}

/// The canvas' Show/Hide control for a password field — §6 draws it inside the field at
/// its trailing edge, `font:600 12.5px`, in the deep pink.
///
/// Two rounded-off values. The label takes the §3 Control row (13/600) rather than an
/// off-scale 12.5, and its colour is `evaActionPinkTop` rather than the artboard's
/// `#C95F86`, which measures 3.68:1 on the input's white fill — the same §9a swap the
/// text button makes. The 44pt frame is the §1 minimum touch target; the artboard's own
/// hit area is 42.
///
/// It does not own the reveal state. The caller does, because revealing a password means
/// swapping a `SecureField` for a `TextField`, and the field belongs to the caller.
struct EvaInputRevealButton: View {

    /// Whether the password is currently visible. Drives both the label and the
    /// accessibility state.
    let isRevealed: Bool
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(isRevealed ? "Hide" : "Show", action: action)
            .buttonStyle(.plain)
            .evaTextStyle(.control)
            .foregroundStyle(Color.evaActionPinkTop)
            .frame(minWidth: EvaMetrics.minimumTouchTarget, minHeight: EvaMetrics.minimumTouchTarget)
            .contentShape(.rect)
            .accessibilityLabel(Text(isRevealed ? "Hide password" : "Show password"))
            .accessibilityIdentifier(identifier ?? "input.reveal")
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

            EvaInputField(
                label: "Secure",
                placeholder: "At least 8 characters",
                helperText: "At least 8 characters, including one number."
            ) { prompt in
                SecureField("Secure", text: $empty, prompt: prompt)
                    .accessibilityIdentifier("preview.secure")
            }

            EvaInputField(
                label: "Secure · rule unmet",
                placeholder: "At least 8 characters",
                helperText: "At least 8 characters, including one number.",
                isHelperUnmet: true,
                helperIdentifier: "preview.rule"
            ) { prompt in
                SecureField("Secure · rule unmet", text: $invalid, prompt: prompt)
                    .accessibilityIdentifier("preview.weak")
            }

            EvaInputField(
                label: "Secure · revealed",
                placeholder: "At least 8 characters",
                helperText: "At least 8 characters, including one number.",
                accessory: {
                    EvaInputRevealButton(isRevealed: true, identifier: "preview.reveal") {}
                }
            ) { prompt in
                TextField("Secure · revealed", text: $focused, prompt: prompt)
                    .accessibilityIdentifier("preview.revealed")
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}

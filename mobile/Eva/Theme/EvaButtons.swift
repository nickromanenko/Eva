import SwiftUI

// The DESIGN.md §5 button variants other than the primary, plus the pieces every Eva
// button shares — state resolution, heights, press feedback and the focus ring.
//
// The primary button keeps its own file (`PrimaryButton.swift`) because it is the one
// variant with a call site today and the one whose `primary.<title>` identifiers the UI
// tests navigate by; everything else lives here so a reader looking for "the buttons"
// finds the set in one place, the way `EvaGlass.swift` holds the whole glass system.
//
// Each variant is a `ButtonStyle` plus a thin `View` wrapper. The style owns the whole
// appearance — typography, height, fill, border, states — so a bespoke label can be
// dropped into `Button { … } label: { … }.buttonStyle(.evaSecondary)`. The wrapper
// exists to set the `accessibilityIdentifier`, which a `ButtonStyle` cannot do: the
// style decorates the label, not the button's accessibility element.

// MARK: - Shared

/// The visual state a button style renders.
///
/// Resolved from the `ButtonStyleConfiguration` and the environment. `#Preview`s pass
/// one in directly to show a state that cannot be reached by touch in a preview.
///
/// Pressed and focused are mutually exclusive here while in reality they can coincide.
/// The canvas draws them as separate rows and portrait iPhone rarely has both, so the
/// combination is not modelled.
enum EvaButtonState: Hashable {
    case normal
    case pressed
    case focused
    case disabled

    /// Disabled wins over pressed, which wins over focused.
    static func resolved(isPressed: Bool, isEnabled: Bool, isFocused: Bool) -> Self {
        if !isEnabled {
            .disabled
        } else if isPressed {
            .pressed
        } else if isFocused {
            .focused
        } else {
            .normal
        }
    }
}

/// Button heights from DESIGN.md §5.
enum EvaButtonHeight {
    /// 52 — primary, secondary glass and the full-size destructive variants.
    static let standard = EvaControl.height
    /// 48 — text button.
    static let text = EvaControl.textButtonHeight
    /// 44 — the row-level destructive variant, which is also the minimum touch target.
    static let row = EvaMetrics.minimumTouchTarget
}

/// Press feedback.
///
/// §5 specifies `scale .97` on the primary button only. It is applied to every variant
/// so a press feels the same everywhere; the canvas' *distinct pressed fills* are
/// applied only where it gives them.
enum EvaButtonPress {
    static let scale: CGFloat = 0.97
    static let duration: TimeInterval = 0.12
}

/// The 3pt focus ring from DESIGN.md §5.
enum EvaFocusRing {
    static let width = EvaControl.focusRingWidth
}

extension View {

    /// Draws the DESIGN.md §5 focus ring just outside the control's edge.
    ///
    /// §5 gives the ring for the primary button; every Eva button style applies the
    /// same one, because a focusable control that shows no focus is an accessibility
    /// defect rather than a design choice.
    ///
    /// On iPhone `\.isFocused` is false unless Full Keyboard Access or a hardware
    /// keyboard is in play, so this is normally invisible — which is why the previews
    /// force the state rather than trying to reach it.
    ///
    /// The ring sits outside the border the way a CSS ring does: the overlay shape is
    /// grown by the ring width with negative padding, and its radius grown to match so
    /// the two curves stay concentric.
    /// - Parameter color: the ring colour. Defaults to the §5 button ring; inputs pass
    ///   their own (`evaInputFocusRing` when focused, `evaInputErrorRing` when wrong),
    ///   which is why this is a parameter rather than a constant.
    func evaFocusRing(
        _ isVisible: Bool,
        cornerRadius: CGFloat,
        color: Color = .evaFocusRing
    ) -> some View {
        overlay {
            if isVisible {
                RoundedRectangle(
                    cornerRadius: cornerRadius + EvaFocusRing.width,
                    style: .continuous
                )
                .strokeBorder(color, lineWidth: EvaFocusRing.width)
                .padding(-EvaFocusRing.width)
            }
        }
    }
}

// MARK: - The style for a button that paints itself

/// A `ButtonStyle` that adds nothing at all to the label it is handed.
///
/// For the two Eva controls that draw their own appearance *inside* the button's label
/// rather than in a style — `ChipToggleButton` and `EvaInputRevealButton`. Both used
/// `.plain`, and every built-in style dims a disabled button's whole subtree on top of
/// whatever the label already drew: the chip's fill token says 80% and the chip
/// rendered at 40%, its label landing at 1.3:1 (#14). A custom style is not dimmed, so
/// what the component paints is what reaches the screen, and the disabled *appearance*
/// stops depending on which style the control happens to wear.
///
/// This changes nothing about `.disabled(_:)` itself. The control still takes no taps,
/// still reports `isEnabled == false` to everything downstream — which is how these two
/// resolve their disabled appearance — and VoiceOver still announces it as dimmed.
///
/// It draws no pressed state, which is what `.plain` gave these two as well: §6 gives
/// chips no pressed appearance, and §5's `EvaButtonPress.scale` belongs to the button
/// variants that declare one.
struct EvaUndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == EvaUndimmedButtonStyle {
    /// For a button whose label already carries the whole appearance, including the
    /// disabled one. Use instead of `.plain`, which halves it — see
    /// `EvaUndimmedButtonStyle`.
    static var evaUndimmed: Self { EvaUndimmedButtonStyle() }
}

// MARK: - Secondary glass

/// The DESIGN.md §5 secondary button: `rgba(255,255,255,.7)` over blur 18, with a 1pt
/// `rgba(40,33,38,.1)` hairline. The quiet action next to a primary.
///
/// Blur 18 is not settable — see the fidelity note at the top of `EvaGlass.swift`. It
/// falls below L1's 20, so `.ultraThin` stands in and the fill reads slightly more
/// opaque than the canvas.
///
/// §5 gives no label colour for this variant; `evaPrimaryText` is used, which is what
/// the canvas' glass surfaces carry elsewhere.
struct EvaSecondaryButtonStyle: ButtonStyle {

    /// Forces a state a preview cannot reach by touch. Never set this in app code.
    var previewState: EvaButtonState?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let state = previewState ?? EvaButtonState.resolved(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            isFocused: isFocused
        )

        return configuration.label
            .evaTextStyle(.button)
            .foregroundStyle(state == .disabled ? Color.evaDisabledText : Color.evaPrimaryText)
            .frame(maxWidth: .infinity, minHeight: EvaButtonHeight.standard)
            .padding(.horizontal, EvaSpacing.md)
            .background {
                let shape = RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                shape
                    .fill(EvaGlassLevel.background.material)
                    .overlay { shape.fill(Self.fill(for: state)) }
                    .overlay { shape.strokeBorder(Self.border(for: state), lineWidth: 1) }
            }
            .evaFocusRing(state == .focused, cornerRadius: EvaRadius.control)
            .scaleEffect(state == .pressed ? EvaButtonPress.scale : 1)
            .animation(.easeOut(duration: EvaButtonPress.duration), value: state)
    }

    private static func fill(for state: EvaButtonState) -> Color {
        switch state {
        case .normal, .focused: .evaSecondaryFill
        case .pressed: .evaSecondaryFillPressed
        case .disabled: .evaSecondaryFillDisabled
        }
    }

    private static func border(for state: EvaButtonState) -> Color {
        switch state {
        case .normal, .focused: .evaControlBorder
        case .pressed: .evaControlBorderPressed
        case .disabled: .evaControlBorderDisabled
        }
    }
}

/// The DESIGN.md §5 secondary glass button — the quiet action beside a primary.
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(EvaSecondaryButtonStyle())
            .accessibilityIdentifier("secondary.\(title)")
    }
}

// MARK: - Text

/// The DESIGN.md §5 text button: `#C95F86`, min-height 48, radius 14, no fill.
///
/// §5 gives no pressed appearance. The label fades rather than gaining a fill, since a
/// fill would make it read as a secondary button.
///
/// **Its label is 14, not the 14.5 of the full-size buttons.** The artboard draws this
/// one variant at `font:600 14px` — corrected by #16, which first shipped as the §3
/// Button row.
struct EvaTextButtonStyle: ButtonStyle {

    /// Forces a state a preview cannot reach by touch. Never set this in app code.
    var previewState: EvaButtonState?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    /// Opacity of the label while pressed. Not a canvas value — see the type comment.
    private static let pressedLabelOpacity: Double = 0.7

    /// The text button's label row — Montserrat SemiBold 14, single-line.
    ///
    /// The §3 scale has no 14 row: it steps 14.5 (Button) → 13 (Control) → 12 (Label),
    /// and 14 is used by this one variant. Rather than reach past the type system for a
    /// bare `Font.custom(_:size:)`, the row is built as an `EvaTextStyle` here, so it
    /// still resolves the PostScript name through `EvaFont` and still carries leading
    /// and tracking the way every other label in the file does — `EvaTextStyle.font` is
    /// itself the `.custom` call.
    ///
    /// If a second variant ever wants 14, this belongs in `EvaTypography.swift` as a
    /// scale row instead. Adding one is a design decision, so it is reported rather than
    /// taken here.
    func makeBody(configuration: Configuration) -> some View {
        let state = previewState ?? EvaButtonState.resolved(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            isFocused: isFocused
        )

        return configuration.label
            .evaTextStyle(EvaTextStyle.textButton)
            .foregroundStyle(Self.label(for: state))
            .frame(minHeight: EvaButtonHeight.text)
            .padding(.horizontal, EvaSpacing.sm)
            .contentShape(.rect(cornerRadius: EvaRadius.chip, style: .continuous))
            .evaFocusRing(state == .focused, cornerRadius: EvaRadius.chip)
            .scaleEffect(state == .pressed ? EvaButtonPress.scale : 1)
            .animation(.easeOut(duration: EvaButtonPress.duration), value: state)
    }

    /// The artboard's `#C95F86` measures 3.68:1 on the warm background — under AA for a
    /// 14pt semibold label. `evaActionPinkTop` is the same decision as the #12 ramp,
    /// applied to a label instead of a fill: 4.57:1, and it is already in the palette.
    private static func label(for state: EvaButtonState) -> Color {
        switch state {
        case .normal, .focused: .evaActionPinkTop
        case .pressed: Color.evaActionPinkTop.opacity(pressedLabelOpacity)
        case .disabled: .evaDisabledText
        }
    }
}

/// The DESIGN.md §5 text button — a tertiary action with no surface of its own.
struct TextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(EvaTextButtonStyle())
            .accessibilityIdentifier("text.\(title)")
    }
}

// MARK: - Destructive

/// The three destructive shapes DESIGN.md §5 calls for.
enum EvaDestructiveButtonKind: Hashable {

    /// Outlined — `rgba(184,82,72,.5)` border, `#A9524A` label, no fill. The default:
    /// use this unless the action is the confirming button of a modal.
    case outlined

    /// Solid `#B85248` with a white label. **Modals only** — §5 restricts the solid
    /// destructive to the confirming button of an alert or sheet, so it never competes
    /// with a screen's primary action. A destructive-confirmed modal also stays
    /// disabled until `DELETE` is typed (§5); that gate belongs to the modal, not here.
    case solid

    /// The row-level variant, for a destructive action sitting in a list of settings
    /// rows. §5 gives it as "44/13".
    ///
    /// Reading the artboard settled what "44/13" meant, and the answer was *both*: the
    /// button is `height:44; border-radius:13px; font:600 13px`. It first shipped as
    /// radius `EvaRadius.chip` (14) with the 14.5 Button label, on the guess that 13 was
    /// a radius alone. Corrected by #16 — the radius is 13 and the label is the §3
    /// Control row.
    case row

    var height: CGFloat {
        switch self {
        case .outlined, .solid: EvaButtonHeight.standard
        case .row: EvaButtonHeight.row
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .outlined, .solid: EvaRadius.control
        case .row: EvaRadius.destructiveRow
        }
    }

    /// The row of the §3 scale this variant's label uses.
    ///
    /// The full-size variants take the Button row (14.5/600) like every other 52-high
    /// control. The row-level variant takes Control (13/600), which is what the artboard
    /// draws it at — the same row the chips and dialog buttons use.
    var textStyle: EvaTextStyle {
        switch self {
        case .outlined, .solid: .button
        case .row: .control
        }
    }

    /// Row-level destructive actions sit inside a list and size to it; the full-size
    /// variants are full-width buttons.
    var isFullWidth: Bool {
        self != .row
    }

    func fill(for state: EvaButtonState) -> Color {
        switch self {
        case .outlined, .row:
            .clear
        case .solid:
            switch state {
            case .normal, .focused: .evaDestructive
            // STILL A GUESS. The artboard gives no pressed fill for the solid
            // destructive, so the darker of the two destructive hexes stands in rather
            // than a newly derived one. Measured, it barely works as feedback:
            // `#A9524A` against the resting `#B85248` is **1.09:1**, which is below the
            // threshold most people can see as a state change at all — the 0.97 press
            // scale is doing all the work. Logged on #12; left as-is here deliberately,
            // because replacing it means inventing a value rather than reading one.
            case .pressed: .evaDestructiveInk
            // The artboard's own disabled rule: `background:#B85248; opacity:.5`. It
            // first shipped as the primary's 28% recipe, which was borrowed, not read.
            // Corrected by #16.
            //
            // Note the artboard applies `opacity` to the whole element, which would fade
            // the white label with the fill; here it is applied to the fill only, so the
            // label keeps its own colour and `label(for:)` stays the single place a
            // label colour is decided.
            case .disabled: Color.evaDestructive.opacity(0.5)
            }
        }
    }

    func border(for state: EvaButtonState) -> Color {
        switch self {
        case .solid:
            .clear
        case .outlined:
            switch state {
            case .normal, .focused: .evaDestructiveBorder
            // Not specified; the same border at full strength.
            case .pressed: .evaDestructive
            case .disabled: .evaControlBorderDisabled
            }
        case .row:
            switch state {
            case .normal, .focused: .evaDestructiveRowBorder
            case .pressed: .evaDestructiveBorder
            case .disabled: .evaControlBorderDisabled
            }
        }
    }

    func label(for state: EvaButtonState) -> Color {
        switch self {
        // §5 keeps the label white on a filled control, disabled included — but white on
        // `#B85248` at 50% over the warm background measures 2.10:1. This is the same
        // defect #17 fixed on the primary's disabled state, so it takes the same answer:
        // Primary Text, 7.49:1. A deliberate deviation from the artboard.
        case .solid: state == .disabled ? .evaPrimaryText : .evaTextOnDark
        case .outlined, .row: state == .disabled ? .evaDisabledText : .evaDestructiveInk
        }
    }
}

/// The DESIGN.md §5 destructive button in each of its three shapes.
struct EvaDestructiveButtonStyle: ButtonStyle {
    let kind: EvaDestructiveButtonKind

    /// Keeps the enabled appearance while the button is `.disabled` for loading — the
    /// same decision `EvaPrimaryButtonStyle` documents, for the same reason.
    ///
    /// The solid variant's disabled fill is `#B85248` at 50% with a Primary Text label,
    /// which says "unavailable". A confirm button waiting on `DELETE /me` is not
    /// unavailable, it is working, and it has to be inert so it cannot be double-tapped.
    /// The canvas has no loading state for any button (DESIGN.md §9c), so this is a
    /// decision rather than a transcription.
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
            .evaTextStyle(kind.textStyle)
            .foregroundStyle(kind.label(for: state))
            .frame(maxWidth: kind.isFullWidth ? .infinity : nil, minHeight: kind.height)
            .padding(.horizontal, EvaSpacing.md)
            .background {
                let shape = RoundedRectangle(cornerRadius: kind.cornerRadius, style: .continuous)
                shape
                    .fill(kind.fill(for: state))
                    .overlay { shape.strokeBorder(kind.border(for: state), lineWidth: 1) }
            }
            .evaFocusRing(state == .focused, cornerRadius: kind.cornerRadius)
            .scaleEffect(state == .pressed ? EvaButtonPress.scale : 1)
            .animation(.easeOut(duration: EvaButtonPress.duration), value: state)
    }
}

/// The DESIGN.md §5 destructive button.
///
/// Defaults to the outlined shape. `.solid` is for the confirming button of a modal
/// only, and `.row` for a destructive action inside a list of settings rows.
struct DestructiveButton: View {
    let title: String
    var kind: EvaDestructiveButtonKind = .outlined
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(EvaDestructiveButtonStyle(kind: kind))
            .accessibilityIdentifier("destructive.\(title)")
    }
}

// MARK: - Authentication

/// The identity providers DESIGN.md §5 draws an authentication button for.
///
/// The label belongs to the provider rather than the call site: the canvas uses the same
/// "Continue with …" wording on both the sign-up and the log-in screen, so there is
/// nothing for a caller to decide.
enum EvaAuthProvider: String, CaseIterable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    /// What Firebase — and therefore `user.authProviders` — calls this provider.
    ///
    /// Deliberately NOT `rawValue`. The raw value is the word `POST /auth/idp` wants in its
    /// request body (`"apple"`), and the server stores Firebase's own id (`"apple.com"`).
    /// One property cannot be both, and when it tried, `isConnected` was false for every
    /// account: Profile never showed a connected provider, and `DELETE /me` never sent an
    /// Apple authorization code — so revocation, the whole reason `providers.ts` holds a
    /// signing key, silently never ran.
    var firebaseProviderID: String {
        switch self {
        case .apple: "apple.com"
        case .google: "google.com"
        }
    }

    var title: String {
        switch self {
        // Apple's Human Interface Guidelines allow a custom button only with one of its
        // own titles; "Continue with Apple" is one of them. Do not reword it.
        case .apple: "Continue with Apple"
        case .google: "Continue with Google"
        }
    }

    /// The provider's name on its own, for a place that names it rather than offers it —
    /// Profile's connected-accounts list (#7).
    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }
}

/// The two sizes the canvas draws an authentication button at.
enum EvaAuthButtonSize: Hashable {

    /// The full-width control from the design system's Authentication column —
    /// `min-height:52px; border-radius:17px; font:600 14.5px`. What both auth screens
    /// lead with.
    case standard

    /// The compact button inside the account-linking banner on the sign-up artboard —
    /// drawn there as `height:38px; border-radius:12px; font:600 13px`.
    ///
    /// **Raised to 44 high at the 14 chip radius.** 38 is below the 44pt minimum touch
    /// target DESIGN.md §1 requires of every interactive element, and 12 is not on the
    /// radius scale; 44/14 is the pair the system already uses for its other inline
    /// controls (chips, the row-level destructive). The label stays the artboard's
    /// Control row.
    case compact

    var height: CGFloat {
        switch self {
        case .standard: EvaButtonHeight.standard
        case .compact: EvaButtonHeight.row
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard: EvaRadius.control
        case .compact: EvaRadius.chip
        }
    }

    var textStyle: EvaTextStyle {
        switch self {
        case .standard: .button
        case .compact: .control
        }
    }

    /// Edge of the provider mark. 16 on the artboard's full-width buttons. The compact
    /// button draws no mark, so this is only read for `.standard`.
    var markSize: CGFloat {
        switch self {
        case .standard: 16
        case .compact: 14
        }
    }

    /// Full-width like a primary action, or sized to its label inside a banner.
    var isFullWidth: Bool {
        self == .standard
    }
}

/// The DESIGN.md §5 authentication button: solid `#1C1A1B` for Apple, glass
/// `rgba(255,255,255,.85)` with a hairline for Google, both 52 high at radius 17 with the
/// provider mark 8pt ahead of the label.
///
/// §5 gives no pressed, focused or disabled appearance for this variant. Rather than
/// invent three, each state borrows the rule the canvas already states for the nearest
/// variant it *does* specify: Apple darkens the way the primary does, Google takes the
/// secondary glass' pressed fill and borders, and both fade their label when disabled.
/// The 0.97 press scale and the focus ring are shared by every Eva button.
///
/// ## Loading
///
/// The canvas draws one, and only for this variant: `#3A3436` with a 60% white label. #7
/// made it reachable — a provider sign-in has a gap between the sheet closing and
/// `/auth/idp` answering, with nothing on screen to say the app is doing something.
///
/// It is applied **to Apple as drawn**. Google keeps its own resting glass and only swaps
/// its label for a spinner: `#3A3436` is a dark fill, and turning the light button dark
/// mid-tap would read as a different button rather than as the same one waiting. That
/// half is a decision, not a transcription, and it follows the rule the rest of this style
/// already uses — borrow from the nearest variant the canvas does specify, which for a
/// loading fill is `PrimaryButton`'s "keep the resting fill, replace the label".
struct EvaAuthButtonStyle: ButtonStyle {
    let provider: EvaAuthProvider
    var size: EvaAuthButtonSize = .standard

    /// Keeps the button drawn as enabled while it is `.disabled` for a request in flight,
    /// and takes the canvas' loading fill on Apple. Same contract as
    /// `EvaPrimaryButtonStyle.isLoading`: the caller disables the button so it cannot be
    /// tapped twice, and the disabled *appearance* would say "nothing is happening" when
    /// something is.
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

        return HStack(spacing: EvaSpacing.xs) {
            // The artboard's compact linking button is text-only; only the full-width
            // buttons carry a provider mark. The loading row drops the mark too — it
            // draws no gap and no glyph, just the fill.
            if size != .compact, !isLoading {
                EvaAuthProviderMark(provider: provider, size: size.markSize)
            }
            configuration.label
        }
        .evaTextStyle(size.textStyle)
        .foregroundStyle(label(for: state))
        .frame(maxWidth: size.isFullWidth ? .infinity : nil, minHeight: size.height)
        .padding(.horizontal, EvaSpacing.md)
        .background {
            let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            shape
                .fill(backdrop)
                .overlay { shape.fill(fill(for: state)) }
                .overlay { shape.strokeBorder(border(for: state), lineWidth: 1) }
                .shadow(
                    color: shadowColor(for: state),
                    radius: EvaAuthButtonShadow.radius(for: provider),
                    x: 0,
                    y: EvaAuthButtonShadow.offsetY(for: provider)
                )
        }
        .evaFocusRing(state == .focused, cornerRadius: size.cornerRadius)
        .scaleEffect(state == .pressed ? EvaButtonPress.scale : 1)
        .animation(.easeOut(duration: EvaButtonPress.duration), value: state)
    }

    /// Google's fill is translucent, so it needs something behind it — the same
    /// `backdrop-filter: blur(18px)` stand-in the secondary glass button uses. Apple's
    /// fill is opaque and needs none.
    private var backdrop: AnyShapeStyle {
        switch provider {
        case .apple: AnyShapeStyle(Color.clear)
        case .google: AnyShapeStyle(EvaGlassLevel.background.material)
        }
    }

    private func fill(for state: EvaButtonState) -> Color {
        // The canvas' loading fill, ahead of every other state: a button that is waiting
        // is not pressed, focused or disabled, whatever the environment says. Apple only —
        // Google is not drawn loading and keeps its resting glass (see the type comment).
        if isLoading, provider == .apple { return .evaAuthAppleLoading }
        return switch provider {
        case .apple:
            switch state {
            // Not a canvas value: §5 gives Apple one fill. The press darkens it the way
            // the primary's press darkens the primary, so the feedback matches the rest
            // of the system rather than relying on the scale alone.
            case .pressed: Color.evaAuthApple.opacity(0.82)
            case .disabled: Color.evaAuthApple.opacity(0.5)
            case .normal, .focused: .evaAuthApple
            }
        case .google:
            switch state {
            case .pressed: .evaSecondaryFillPressed
            case .disabled: .evaSecondaryFillDisabled
            case .normal, .focused: .evaAuthGoogleFill
            }
        }
    }

    private func border(for state: EvaButtonState) -> Color {
        switch provider {
        case .apple:
            .clear
        case .google:
            switch state {
            case .pressed: .evaControlBorderPressed
            case .disabled: .evaControlBorderDisabled
            case .normal, .focused: .evaControlBorder
            }
        }
    }

    private func label(for state: EvaButtonState) -> Color {
        guard state != .disabled else { return .evaDisabledText }
        switch provider {
        // `rgba(255,255,255,.6)` on `#3A3436` is the canvas' own loading pair. It measures
        // 5.29:1, so unlike the disabled labels §9a had to move, this one is kept as drawn.
        case .apple: return isLoading ? Color.evaTextOnDark.opacity(0.6) : .evaTextOnDark
        case .google: return .evaPrimaryText
        }
    }

    /// The sign-up artboard hangs a shadow under both full-width auth buttons —
    /// `0 10px 22px -8px rgba(28,26,27,.5)` under Apple and
    /// `0 6px 18px -10px rgba(40,33,38,.3)` under Google. The compact button in the
    /// linking banner has none, and neither does a disabled control.
    private func shadowColor(for state: EvaButtonState) -> Color {
        guard size == .standard, state != .disabled else { return .clear }
        switch provider {
        case .apple: return Color.evaAuthApple.opacity(0.5)
        case .google: return Color.evaPrimaryText.opacity(0.18)
        }
    }
}

/// The auth buttons' shadows, from the sign-up artboard:
/// `0 10px 22px -8px rgba(28,26,27,.5)` under Apple and
/// `0 6px 18px -10px rgba(40,33,38,.3)` under Google.
///
/// The negative spread has no SwiftUI expression — the same limitation the card and
/// primary-button shadows hit — and here it is doing most of the work: −8 and −10 against
/// blurs of 22 and 18 pull the shadow back almost to the button's own edge. Translating
/// the blurs directly (22 → 11, 18 → 9) put a dark halo under both buttons on the device
/// that is nowhere on the canvas, so each radius is pulled in by roughly its spread and
/// Google's opacity comes down with it. Checked side by side against
/// `docs/design/Eva App.dc.html`, rail item **Sign up**.
private enum EvaAuthButtonShadow {

    static func radius(for provider: EvaAuthProvider) -> CGFloat {
        switch provider {
        case .apple: 7
        case .google: 4
        }
    }

    static func offsetY(for provider: EvaAuthProvider) -> CGFloat {
        switch provider {
        case .apple: 8
        case .google: 4
        }
    }
}

/// The provider mark that leads an authentication button.
///
/// Apple's is `apple.logo`, the mark Apple ships in SF Symbols for exactly this button.
/// Google's is the artboard's **placeholder** disc — the design system's Authentication
/// column ends with a dashed "Official marks drop in here · brand assets supplied by the
/// vendor" slot, so the canvas is explicit that no real Google mark exists yet. It gets
/// replaced by the vendor asset when Google sign-in lands (#7).
///
/// Hidden from VoiceOver: the button's label already says which provider it is.
private struct EvaAuthProviderMark: View {
    let provider: EvaAuthProvider
    let size: CGFloat

    var body: some View {
        Group {
            switch provider {
            case .apple:
                Image(systemName: "apple.logo")
                    .font(.system(size: size))
            case .google:
                Circle()
                    .fill(
                        AngularGradient(
                            colors: Color.evaAuthGoogleMarkStops,
                            center: .center
                        )
                    )
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The DESIGN.md §5 authentication button — "Continue with Apple" / "Continue with
/// Google".
///
/// The identifier is `auth.apple` / `auth.google` rather than the wrappers' usual
/// `<variant>.<title>`: the provider is the stable thing here, the wording is not, and
/// both auth screens carry the same two buttons. `identifier` overrides it where a second
/// button for the same provider is on screen — the account-linking banner's recovery
/// action is the one case.
struct EvaAuthButton: View {
    let provider: EvaAuthProvider
    var size: EvaAuthButtonSize = .standard
    var identifier: String?
    /// Draws the canvas' loading state and makes the button inert, so a provider sheet
    /// cannot be asked for twice while the first answer is still in flight.
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    // The spinner takes the label's ink, so it reads as the same control
                    // waiting rather than as a new element: 60% white on Apple's loading
                    // fill, Primary Text on Google's glass.
                    .tint(provider == .apple ? Color.evaTextOnDark.opacity(0.6) : Color.evaPrimaryText)
            } else {
                Text(provider.title)
            }
        }
        .buttonStyle(EvaAuthButtonStyle(provider: provider, size: size, isLoading: isLoading))
        .disabled(isLoading)
        // The label is a spinner while loading, so the title has to be spoken from here —
        // the same arrangement `PrimaryButton` uses. Apple's Human Interface Guidelines
        // require the button to say "Continue with Apple", and VoiceOver is where that
        // string has to survive the spinner.
        .accessibilityLabel(Text(provider.title))
        .accessibilityIdentifier(identifier ?? "auth.\(provider.rawValue)")
    }
}

// MARK: - Style shorthands

extension ButtonStyle where Self == EvaSecondaryButtonStyle {
    /// DESIGN.md §5 secondary glass. Prefer `SecondaryButton`, which also sets the
    /// `secondary.<title>` identifier; reach for the style directly only when the label
    /// is more than a string.
    static var evaSecondary: Self { EvaSecondaryButtonStyle() }
}

extension ButtonStyle where Self == EvaTextButtonStyle {
    /// DESIGN.md §5 text button. Prefer `TextButton`, which also sets the
    /// `text.<title>` identifier.
    static var evaText: Self { EvaTextButtonStyle() }
}

extension ButtonStyle where Self == EvaAuthButtonStyle {
    /// DESIGN.md §5 authentication button. Prefer `EvaAuthButton`, which also sets the
    /// `auth.<provider>` identifier.
    static func evaAuth(
        _ provider: EvaAuthProvider,
        size: EvaAuthButtonSize = .standard
    ) -> Self {
        EvaAuthButtonStyle(provider: provider, size: size)
    }
}

extension ButtonStyle where Self == EvaDestructiveButtonStyle {
    /// DESIGN.md §5 destructive button. Prefer `DestructiveButton`, which also sets the
    /// `destructive.<title>` identifier.
    static func evaDestructive(_ kind: EvaDestructiveButtonKind = .outlined) -> Self {
        EvaDestructiveButtonStyle(kind: kind)
    }
}

// MARK: - Preview

/// One variant's four states side by side. `state` is forced rather than performed,
/// because a preview cannot hold a press or take keyboard focus.
private struct EvaButtonStateRow<Style: ButtonStyle>: View {
    let title: String
    let style: (EvaButtonState) -> Style

    private let states: [(name: String, state: EvaButtonState)] = [
        ("Normal", .normal),
        ("Pressed", .pressed),
        ("Focused", .focused),
        ("Disabled", .disabled)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text(title)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)

            ForEach(states, id: \.name) { name, state in
                Button(name) {}
                    .buttonStyle(style(state))
                    .disabled(state == .disabled)
            }
        }
    }
}

#Preview("Button variants") {
    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.xl) {
            EvaButtonStateRow(title: "Secondary glass") {
                EvaSecondaryButtonStyle(previewState: $0)
            }

            EvaButtonStateRow(title: "Text") {
                EvaTextButtonStyle(previewState: $0)
            }

            EvaButtonStateRow(title: "Destructive · outlined") {
                EvaDestructiveButtonStyle(kind: .outlined, previewState: $0)
            }

            EvaButtonStateRow(title: "Destructive · solid (modals only)") {
                EvaDestructiveButtonStyle(kind: .solid, previewState: $0)
            }

            EvaButtonStateRow(title: "Destructive · row (44 high)") {
                EvaDestructiveButtonStyle(kind: .row, previewState: $0)
            }

            EvaButtonStateRow(title: "Auth · Apple") {
                EvaAuthButtonStyle(provider: .apple, previewState: $0)
            }

            EvaButtonStateRow(title: "Auth · Google") {
                EvaAuthButtonStyle(provider: .google, previewState: $0)
            }

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("As used")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                EvaAuthButton(provider: .apple) {}
                EvaAuthButton(provider: .google) {}
                EvaAuthButton(provider: .apple, size: .compact) {}
                EvaAuthButton(provider: .apple, identifier: "preview.apple.loading", isLoading: true) {}
                EvaAuthButton(provider: .google, identifier: "preview.google.loading", isLoading: true) {}
                SecondaryButton(title: "Not now") {}
                TextButton(title: "Skip for now") {}
                DestructiveButton(title: "Delete my account") {}
                DestructiveButton(title: "Remove entry", kind: .row) {}
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background {
        LinearGradient.evaBlushCream.ignoresSafeArea()
    }
}

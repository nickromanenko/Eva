import SwiftUI

// The small pieces the canvas' auth screens share — "Eva App.dc.html", rail items
// **Sign up**, **Log in**, **Check your inbox**, **Forgot password** and **Reset link
// sent**. They are drawn identically across them, so they live here rather than being
// written several times; they are grouped in one file for the same reason
// `EvaButtons.swift` groups the button variants, and each is a handful of lines.
//
// None of them is a design-system component: they are screen furniture the auth screens
// happen to share. Anything here that a non-auth screen wants belongs in `Eva/Theme/`.

// MARK: - Type rows the §3 scale does not have
//
// The canvas draws the auth screens' brand strings at sizes the design system's type
// scale has no row for — the scale steps Display 46 → H1 28, and these sit between them.
// They are modelled as `EvaTextStyle` values rather than bare `Font.custom` calls so they
// still resolve their face through `EvaFont` and still carry tracking the way every other
// string does; this is the same accommodation `EvaTextButtonStyle` makes for its 14pt
// label.
//
// **These now serve five screens, which is past the point where the first version of this
// note said they should move into `EvaTypography.swift` as scale rows.** They have not
// moved: adding a row is a design decision, and #6 is a feature. Reported with #6.

private extension EvaTextStyle {

    /// The `eva.` lockup — `font:400 30px/1; letter-spacing:.4px` on both auth screens.
    /// (The design system's own header draws the same lockup at 44 on a desktop canvas.)
    static let authWordmark = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 30,
        lineHeight: nil,
        tracking: 0.4,
        textStyle: .title
    )

    /// The auth hero — `font:400 34px/1.12; letter-spacing:-.2px`.
    ///
    /// **No line height.** The canvas' 1.12 works out at 38.1, which is tighter than
    /// Montserrat's own 41.4pt line box at this size, and `EvaTextStyle.lineSpacing` can
    /// only add leading, never remove it. Rather than clamp silently, the row asks for
    /// the natural box — the hero is two lines, so it reads about 3pt looser than the
    /// artboard across the single break. Same reasoning as `EvaTextStyle.display`.
    static let authHero = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 34,
        lineHeight: nil,
        tracking: -0.2,
        textStyle: .largeTitle
    )

    /// The centred title of the two "check your email" screens — `font:400 30px/1.15` on
    /// both **Check your inbox** and **Reset link sent**.
    ///
    /// No line height, for the reason `authHero` gives: 1.15 works out at 34.5, under
    /// Montserrat's 36.6pt natural box at this size.
    static let authStatusTitle = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 30,
        lineHeight: nil,
        tracking: 0,
        textStyle: .largeTitle
    )
}

// MARK: - Screen scaffold

/// The frame both auth screens are drawn in: a scrolling column with the CTA cluster
/// held at the bottom.
///
/// The artboard draws these as a **non-scrolling** 390 × 844 screen — the auth container
/// is `min-height:100%; display:flex; flex-direction:column` and the cross-link carries
/// `margin-top:auto`, so the CTA, the legal note and the cross-link sit against the
/// bottom edge and everything above them flows from the top.
///
/// The naive reading — one `ScrollView` holding all of it — is what shipped first, and it
/// put the CTA **behind the keyboard** with no way to scroll it clear: the content is
/// taller than a real iPhone frame (which, unlike the artboard, spends ~93pt on safe
/// areas), so the scroll view was already at its content bottom while the keyboard still
/// covered the button. Nothing above the keyboard can fix that, because with the keyboard
/// up there is not enough room for the hero, the form *and* the CTA at once.
///
/// So `footer` lives outside the scroll view, which is the pattern
/// `OnboardingStepLayout` already uses for the questionnaire — and the reason the
/// questionnaire never had this bug. It keeps the artboard's bottom-pinned cluster,
/// keeps the CTA and the cross-link reachable with the keyboard up, and leaves the
/// scrolling to the part that can afford to scroll. `scrollBounceBehavior(.basedOnSize)`
/// makes "does not scroll" literal whenever the upper column fits.
///
/// ## Accessibility sizes fall back to one scrolling column
///
/// A pinned footer only works while the footer is small, and the sign-up legal note is
/// not: measured on an iPhone 17 Pro at `.accessibility5` it alone passes 350pt, the
/// pinned cluster took roughly 450 of the 781 available points, the form was squeezed
/// into a window too small to use and the CTA truncated its own label. The switch is
/// therefore `isAccessibilitySize` — from `.accessibility1` up. So at accessibility sizes
/// the screen becomes the single scrolling column the artboard's `min-height:100%` box
/// degrades into anyway — same order, nothing pinned, nothing unreachable. That is also
/// the honest answer for the keyboard there: at AX5 the hero, the form and the CTA cannot
/// share a frame with a keyboard under any layout, so scrolling is the only thing left.
struct AuthScreenLayout<Content: View, Footer: View>: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder let content: Content
    /// The CTA cluster. Every element in it should fill the width — it is laid out in a
    /// centred column, the way the artboard draws the legal note and the cross-link.
    @ViewBuilder let footer: Footer

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                    footerColumn
                        .padding(.top, EvaSpacing.lg)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.md)
                .padding(.bottom, EvaSpacing.lg)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, EvaSpacing.lg)
                    .padding(.top, EvaSpacing.md)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)

                footerColumn
                    .padding(.horizontal, EvaSpacing.lg)
                    // The artboard's 22pt between the form and the CTA. It belongs to the
                    // footer rather than to the scrolling column so it survives a scroll.
                    .padding(.top, EvaSpacing.lg)
                    // No bottom padding of its own. The artboard's 40pt sits above a frame
                    // edge; here the home indicator's 34pt safe area plus the text button's
                    // own 14pt of slack inside its 48pt target already puts the cross-link
                    // where the artboard puts it, and every point spent twice comes off the
                    // form above.
            }
        }
    }

    private var footerColumn: some View {
        VStack(spacing: 0) {
            footer
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Wordmark

/// The `eva.` lockup that opens both auth screens — the word in Primary Text, the full
/// stop in Deep Pistachio.
struct AuthWordmark: View {

    var body: some View {
        (
            Text("eva").foregroundStyle(Color.evaPrimaryText)
                + Text(".").foregroundStyle(Color.evaDeepPistachio)
        )
        .evaTextStyle(.authWordmark)
        .accessibilityLabel(Text("Eva"))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero

/// The headline and its one-line promise, at the top of each auth screen.
struct AuthHero: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text(title)
                .evaTextStyle(.authHero)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status hero

/// The centred opening of the two "check your email" screens: a glass tile holding an
/// envelope, the title under it, then a line of body copy — "Check your inbox" and
/// "Reset link sent" on the canvas.
///
/// The tile is `96 × 96, radius 32` on the activation screen and `88 × 88, radius 30` on
/// link sent; both are `rgba(255,255,255,.7)` over `blur(22px)` with a `.8` white hairline
/// and `0 14px 30px -14px rgba(40,33,38,.24)` under them. Neither radius is on the §4
/// scale, and both are a third of the edge — so that is the rule kept here, rather than
/// two literals. The fill and blur are L2 glass to within a percent, which is what it
/// takes. The envelope is `envelope` from SF Symbols in place of the canvas' CSS-drawn
/// one, in the ink the artboard gives it: Deep Pink after sign-up, Deep Pistachio once a
/// reset link is on its way.
///
/// The shadow's `-14px` spread has no SwiftUI expression; the radius is pulled in the way
/// `EvaAuthButtonShadow` pulls the auth buttons' in, so it does not halo.
struct AuthStatusHero: View {
    let title: String
    let subtitle: String
    let tileSize: CGFloat
    let envelopeColor: Color

    /// The artboard's envelope is 46pt across on the larger tile; the symbol is sized to
    /// match its footprint.
    private var envelopeSize: CGFloat { tileSize * 0.44 }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "envelope")
                .font(.system(size: envelopeSize, weight: .light))
                .foregroundStyle(envelopeColor)
                .frame(width: tileSize, height: tileSize)
                .evaGlass(.card, cornerRadius: tileSize / 3)
                .overlay {
                    RoundedRectangle(cornerRadius: tileSize / 3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                }
                .shadow(color: Color.evaPrimaryText.opacity(0.24), radius: 8, y: 14)
                .accessibilityHidden(true)

            Text(title)
                .evaTextStyle(.authStatusTitle)
                .foregroundStyle(Color.evaPrimaryText)
                .padding(.top, EvaSpacing.lg)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .padding(.top, EvaSpacing.sm)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Success note

/// The pistachio note under the activation hero — "The link works for 24 hours. Nothing
/// is saved to your profile until you confirm."
///
/// The artboard draws it as `padding:12px 16px; border-radius:16px;
/// background:rgba(205,231,157,.28); border:1px solid rgba(142,173,86,.3); font:500
/// 12.5px/1.5; color:#5C7434`. It takes the §2 Success tokens rather than those values —
/// the design system is the authority for a semantic tint, the same call
/// `EvaRadius.banner` makes for the information banner — and the §3 Caption row, whose
/// size and leading match. Two things are rounded: the radius to the 17 control step
/// (16 is off the scale), and the weight to Caption's 400.
///
/// It also gains the ✓ mark the artboard does not draw. §2 says every semantic state
/// carries a mark as well as a colour, and Success's is a circled tick. Hidden from
/// VoiceOver, which reads the sentence.
struct AuthSuccessNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.evaCaption)
                .accessibilityHidden(true)
            Text(message)
                .evaTextStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.evaSuccessInk)
        .padding(.vertical, EvaSpacing.sm)
        .padding(.horizontal, EvaSpacing.md)
        .background(
            Color.evaSuccessTint,
            in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                .strokeBorder(Color.evaSuccessBorder, lineWidth: 1)
        }
    }
}

// MARK: - Rate-limited banner

/// What sign up, log in and the reset screens show for a `429 RATE_LIMITED`.
///
/// The canvas change list (`rateLimited`, #38) asks for an inline banner in the
/// Information tone, not Error: nothing the user typed was wrong and the server did not
/// act on it, so the field treatment would blame the wrong thing. The copy is the change
/// list's, with the second sentence saying what a 429 means in practice — the request was
/// refused before anything happened.
struct AuthRateLimitedBanner: View {
    let identifier: String
    /// When the server said to come back (#38). `nil` keeps the original wording, which is
    /// what the screens with a cooldown of their own still pass.
    var retryAt: Date?

    init(identifier: String, retryAt: Date? = nil) {
        self.identifier = identifier
        self.retryAt = retryAt
    }

    var body: some View {
        if let retryAt {
            // Redrawn once a second so the wait counts down in place. `TimelineView` asks
            // for the wall clock each time, so a minute spent in the background is a minute
            // gone from the wait rather than a minute the countdown still owes — the trap
            // the issue names, and the reason nothing here holds a duration.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                banner(message: Self.message(retryAt: retryAt, at: context.date))
            }
        } else {
            banner(message: Self.fallbackMessage)
        }
    }

    private func banner(message: String) -> some View {
        EvaInfoBanner(title: "Too many attempts", message: message)
            .accessibilityIdentifier(identifier)
    }

    /// Said when the server gave no usable `Retry-After`.
    static let fallbackMessage = "Try again in a minute. Nothing about your account has changed."

    /// The wait, in words, plus the sentence that keeps this from reading as an accusation.
    ///
    /// §8: describe, do not blame. Someone throttled out of their own health data is told
    /// what the situation is and that nothing was lost by it — never what they did wrong,
    /// and never how many attempts they have left, which would be a number about the
    /// account rather than about the request.
    static func message(retryAt: Date, at now: Date) -> String {
        let seconds = Int(retryAt.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else {
            return "You can try again now. Nothing about your account has changed."
        }
        return "You can try again in \(spelled(seconds)). Nothing about your account has changed."
    }

    /// Seconds below a minute, whole minutes above it — rounded **up**, so the banner never
    /// invites a tap the server will still refuse.
    private static func spelled(_ seconds: Int) -> String {
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// The sign-up and log-in CTA, held until a `429`'s window has passed (#38).
///
/// The defect this removes: the screen showed "Too many attempts" and left the button
/// enabled, so the natural response to the message spent another attempt and — on the
/// per-address counter — pushed the window further out. A message that describes a state
/// while the UI still invites the action that caused it is not handling the state.
///
/// Wraps `PrimaryButton` rather than replacing it: the identifier stays `primary.<title>`,
/// which every UI test and `EvaUITestCase` already looks for, and the disabled appearance
/// is the one `EvaPrimaryButtonStyle` already draws for an invalid form.
///
/// `blockedUntil` is an instant, and the clock is read fresh each tick, so backgrounding
/// the app does not owe the user the time they spent away — and the button re-enables on
/// its own without the screen having to schedule anything.
struct AuthThrottledPrimaryButton: View {
    let title: String
    var isLoading = false
    /// The screen's own reason to allow a tap — form validity, usually.
    var isFormValid = true
    /// When the server's window ends, or `nil` when there is no window to wait out.
    var blockedUntil: Date?
    let action: () -> Void

    var body: some View {
        if let blockedUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                button(isBlocked: context.date < blockedUntil)
            }
        } else {
            button(isBlocked: false)
        }
    }

    private func button(isBlocked: Bool) -> some View {
        PrimaryButton(title: title, isLoading: isLoading, action: action)
            .disabled(isBlocked || !isFormValid)
    }
}

// MARK: - Resend with a cooldown

/// The "Resend email" / "Resend link" secondary button, which the canvas rate-limits to
/// once per 60 seconds. It counts the wait down in its own label rather than in a toast:
/// the design system draws a toast, but there is no toast component in `Eva/Theme/` yet
/// and this screen is not the place to design one — see DESIGN.md §9a. The label is
/// where the user is looking, and it says both that the button is unavailable and for how
/// long, which is what §2 asks of a state: never colour (or dimming) alone.
///
/// `cooldownEnds` is owned by the screen — it is the screen that knows an email was just
/// sent. A `TimelineView` redraws the label once a second only while a cooldown is
/// running; with none there is nothing to tick.
///
/// The identifier is fixed by the caller rather than derived from the title, because the
/// title changes every second and a UI test needs one name for the control.
struct AuthResendButton: View {
    let title: String
    let identifier: String
    let cooldownEnds: Date?
    let action: () -> Void

    var body: some View {
        if let cooldownEnds {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Self.secondsRemaining(until: cooldownEnds, at: context.date)
                button(remaining: remaining)
            }
        } else {
            button(remaining: 0)
        }
    }

    private func button(remaining: Int) -> some View {
        Button(action: action) {
            Text(remaining > 0 ? "\(title) · \(remaining)s" : title)
                .monospacedDigit()
        }
        .buttonStyle(.evaSecondary)
        .disabled(remaining > 0)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(remaining > 0 ? "Available in \(remaining) seconds" : ""))
        .accessibilityIdentifier(identifier)
    }

    /// Whole seconds left, rounded up so the label never reads "0s" while still disabled.
    static func secondsRemaining(until end: Date, at now: Date) -> Int {
        max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }
}

/// How long a resend button stays unavailable after a send. The canvas' 60 seconds, which
/// is also the server's own throttle on the resend route.
enum AuthResendCooldown {
    static let duration: TimeInterval = 60

    /// When a cooldown started now would end.
    static func endingNow() -> Date {
        Date(timeIntervalSinceNow: duration)
    }
}

// MARK: - Inline status

/// A one-line message under a status screen's content — the resend confirmation the
/// canvas shows as a toast, or a failure that has no field to hang off.
///
/// Error takes the §3 Error row with the `!` mark, the same pair `EvaInputField` draws
/// under a field; the plain kind takes Caption in the secondary ink. Either way the
/// text carries the identifier, so it stays a static text to UI tests.
struct AuthStatusLine: View {
    enum Kind {
        case plain
        case error
    }

    let message: String
    let kind: Kind
    let identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
            if kind == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.evaError)
                    .accessibilityHidden(true)
            }
            Text(message)
                .evaTextStyle(kind == .error ? .error : .caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .foregroundStyle(kind == .error ? Color.evaErrorInk : Color.evaSecondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Divider

/// The hairline-label-hairline rule that separates the provider buttons from the email
/// form — "or continue with email" on sign-up, "or use your email" on log-in.
///
/// The canvas sets the label at 12/500; it takes the §3 Label row, which is the same size
/// at 600. The rules are the `rgba(40,33,38,.10)` control hairline.
struct AuthMethodDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: EvaSpacing.sm) {
            rule
            Text(title)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)
                // Both rules are infinitely flexible, so without this the stack hands
                // them the width first and wraps a five-word label onto two lines.
                .layoutPriority(1)
            rule
        }
        // One element to VoiceOver, and one that is decoration plus a label rather than
        // three separate things to swipe past.
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.evaControlBorder)
            .frame(height: 1)
    }
}

// MARK: - Cross-link

/// The line at the foot of each auth screen that routes to the other one — "Already have
/// an account? Log in" and "New to Eva? Create an account".
struct AuthSwitchPrompt: View {
    let question: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: EvaSpacing.xxs) {
            Text(question)
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaSecondaryText)

            TextButton(title: actionTitle, action: action)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Legal note

/// The small print under the sign-up CTA.
///
/// The canvas draws "Terms" and "Privacy Policy" as links. They are **plain text** here:
/// the pages exist on the marketing site (`website/src/pages/terms.astro`,
/// `privacy.astro`) but the site has no configured public URL for the app to open, so a
/// tappable-looking word that does nothing would be worse than a sentence that does not
/// claim to be tappable. Reported with #3; give it the URLs and it becomes a link.
struct AuthLegalNote: View {

    var body: some View {
        Text("By continuing you agree to Eva's Terms and Privacy Policy. "
             + "Your health data is encrypted and never sold.")
            .evaTextStyle(.caption)
            .foregroundStyle(Color.evaSecondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

#Preview("Auth screen layout") {
    AuthScreenLayout {
        AuthWordmark()
        AuthHero(
            title: "Your Prime Era\nstarts here",
            subtitle: "Eva learns your cycle, your energy and your goals — then adapts. "
                + "No scores, no judgment."
        )
        .padding(.top, EvaSpacing.xl)
    } footer: {
        PrimaryButton(title: "Create account") {}
        AuthLegalNote()
            .padding(.top, EvaSpacing.md)
        AuthSwitchPrompt(question: "Already have an account?", actionTitle: "Log in") {}
            .padding(.top, EvaSpacing.lg)
    }
    .background {
        EvaScreenBackground().ignoresSafeArea()
    }
}

#Preview("Auth screen parts") {
    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.lg) {
            AuthWordmark()
            AuthHero(
                title: "Your Prime Era\nstarts here",
                subtitle: "Eva learns your cycle, your energy and your goals — then "
                    + "adapts. No scores, no judgment."
            )
            AuthMethodDivider(title: "or continue with email")
            AuthLegalNote()
            AuthSwitchPrompt(question: "Already have an account?", actionTitle: "Log in") {}
            AuthStatusHero(
                title: "Check your inbox",
                subtitle: "We sent an activation link to",
                tileSize: 96,
                envelopeColor: .evaDeepPink
            )
            AuthSuccessNote(
                message: "The link works for 24 hours. Nothing is saved to your profile until you confirm."
            )
            AuthRateLimitedBanner(identifier: "preview.rateLimited")
            AuthResendButton(
                title: "Resend email",
                identifier: "preview.resend",
                cooldownEnds: AuthResendCooldown.endingNow()
            ) {}
            AuthResendButton(title: "Resend email", identifier: "preview.resend.ready", cooldownEnds: nil) {}
            AuthStatusLine(
                message: "Email sent again. Check spam if it hasn't arrived.",
                kind: .plain,
                identifier: "preview.status"
            )
            AuthStatusLine(
                message: "Can't reach Eva right now. Check your connection.",
                kind: .error,
                identifier: "preview.error"
            )
        }
        .padding(EvaSpacing.lg)
    }
    .background {
        EvaScreenBackground().ignoresSafeArea()
    }
}

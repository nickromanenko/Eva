import SwiftUI

// The small pieces the canvas' two auth screens share — "Eva App.dc.html", rail items
// **Sign up** and **Log in**. They are drawn identically on both, so they live here
// rather than being written twice; they are grouped in one file for the same reason
// `EvaButtons.swift` groups the button variants, and each is a handful of lines.
//
// None of them is a design-system component: they are screen furniture the auth screens
// happen to share. Anything here that a third screen wants belongs in `Eva/Theme/`.

// MARK: - Type rows the §3 scale does not have
//
// The canvas draws the auth screens' two brand strings at sizes the design system's type
// scale has no row for — the scale steps Display 46 → H1 28, and these sit between them.
// They are modelled as `EvaTextStyle` values rather than bare `Font.custom` calls so they
// still resolve their face through `EvaFont` and still carry tracking the way every other
// string does; this is the same accommodation `EvaTextButtonStyle` makes for its 14pt
// label.
//
// **If a second screen wants either of these, they belong in `EvaTypography.swift` as
// scale rows.** Adding a row is a design decision, so it is reported rather than taken
// here.

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
        }
        .padding(EvaSpacing.lg)
    }
    .background {
        EvaScreenBackground().ignoresSafeArea()
    }
}

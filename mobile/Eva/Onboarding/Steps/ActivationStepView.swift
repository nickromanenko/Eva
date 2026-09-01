import SwiftUI

/// The activation gate — "Eva App.dc.html", rail item **Check your inbox**, and its
/// **not activated** variant from the canvas change list (#6).
///
/// Sign-up no longer returns a session: the account exists, an email is on its way, and
/// `POST /auth/signin` refuses the address until the link is opened. This screen is where
/// the user waits, and it does three things while they do.
///
/// **It retries sign-in on its own.** The link opens the website, not the app, so the
/// app never receives a token; it finds out the account is activated by trying. Every
/// return to the foreground — and every `eva://activated`, which the website tries once
/// the link has worked — makes one `signIn` with the credentials still in memory. Success
/// routes exactly as a log in would; `NOT_ACTIVATED` means "not yet" and shows nothing;
/// any other failure is swallowed too, because an automatic probe the user did not ask
/// for should not report on itself. The user can always press Resend.
///
/// **It throttles Resend to once a minute**, counting the wait down in the button's own
/// label — the canvas' 60s, which is also the server's throttle. After sign-up the count
/// starts at once, since an email has just been sent; after a refused log in it does
/// not, since nothing has.
///
/// **It keeps the address on screen and offers a way back.** "Change email" after sign-up
/// returns to the form with the address pre-filled, as the artboard's spec note asks. After
/// a refused log in the same slot reads "Back to log in": the account exists, and a
/// pre-filled sign-up would only meet `EMAIL_EXISTS`. That label is the one thing this
/// variant changes beyond its copy — the change list asks for "the same layout as
/// activation", and it is.
///
/// "Open email app" opens `message://`, and does nothing if nothing claims it. It is the
/// primary because the artboard makes it one, and because it is the action most likely to
/// end the wait.
struct ActivationStepView: View {

    let model: OnboardingModel
    /// One sign-in attempt with the credentials the model holds. The flow routes on
    /// success and throws on anything else; this screen decides what to show.
    let onRetrySignIn: () async throws -> Void
    let onResend: (_ email: String) async throws -> Void
    let onBack: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var cooldownEnds: Date?
    @State private var isResending = false
    @State private var isRetrying = false
    @State private var status: Status?

    private enum Status: Equatable {
        case sentAgain
        case rateLimited
        case failed(String)
    }

    private var isAfterSignUp: Bool { model.activationOrigin == .signUp }

    var body: some View {
        AuthScreenLayout {
            AuthStatusHero(
                title: isAfterSignUp ? "Check your inbox" : "Check your inbox first",
                subtitle: isAfterSignUp
                    ? "We sent an activation link to"
                    : "Your account isn't active yet. The activation link went to",
                tileSize: 96,
                envelopeColor: .evaDeepPink
            )
            .padding(.top, EvaSpacing.xxl)

            // The artboard's `font:600 15px`. Body medium is the scale's emphasis row for
            // a value inside body copy, one weight step lighter than drawn.
            Text(model.email)
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, EvaSpacing.xs)
                .accessibilityIdentifier("activation.email")

            // The second sentence is what the API actually does: the account is created
            // but nothing is written to a profile until the questionnaire, which the
            // gate stands in front of. Same standard as the delete copy (DESIGN.md §9a).
            AuthSuccessNote(
                message: "The link works for 24 hours. Nothing is saved to your profile until you confirm."
            )
            .padding(.top, EvaSpacing.md)
            .frame(maxWidth: .infinity)

            statusLine
                .padding(.top, EvaSpacing.md)
        } footer: {
            VStack(spacing: EvaSpacing.xs) {
                PrimaryButton(title: "Open email app", action: openMail)

                AuthResendButton(
                    title: "Resend email",
                    identifier: "activation.resend",
                    cooldownEnds: cooldownEnds,
                    action: resend
                )

                TextButton(title: isAfterSignUp ? "Change email" : "Back to log in", action: onBack)
            }
        }
        .onAppear {
            // Once: sign-up has just sent the email. Re-entering the screen does not
            // restart it — the screen is rebuilt on every step change, so this is the
            // only "once" there is.
            if isAfterSignUp, cooldownEnds == nil {
                cooldownEnds = AuthResendCooldown.endingNow()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { retrySignIn() }
        }
        .onOpenURL { url in
            if EvaDeepLink(url: url) == .activated { retrySignIn() }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .sentAgain:
            // The canvas' toast copy, drawn in place — see `AuthResendButton`.
            AuthStatusLine(
                message: "Email sent again. Check spam if it hasn't arrived.",
                kind: .plain,
                identifier: "activation.status"
            )
        case .rateLimited:
            AuthRateLimitedBanner(identifier: "activation.rateLimited")
        case .failed(let message):
            AuthStatusLine(message: message, kind: .error, identifier: "activation.error")
        case nil:
            EmptyView()
        }
    }

    // MARK: - Behaviour

    /// `message://` is what Mail claims. `openURL` reports whether anything took it and
    /// nothing is shown either way: the simulator has no Mail, and a user whose mail is a
    /// website has other ways to their inbox than this button.
    private func openMail() {
        guard let url = URL(string: "message://") else { return }
        openURL(url) { _ in }
    }

    private func resend() {
        guard !isResending else { return }
        isResending = true
        status = nil
        Task {
            do {
                try await onResend(model.email)
                status = .sentAgain
                cooldownEnds = AuthResendCooldown.endingNow()
            } catch let error as APIError where error.isRateLimited {
                // The server's throttle is the same 60s as ours; a 429 means the screen's
                // clock and the server's disagreed, so the screen restarts its own.
                status = .rateLimited
                cooldownEnds = AuthResendCooldown.endingNow()
            } catch {
                status = .failed(error.localizedDescription)
            }
            isResending = false
        }
    }

    /// One attempt, and only with something to attempt with. An empty password means
    /// this screen was reached without credentials — `EVA_ONBOARDING_STEP=7`, or a
    /// future path that clears them — and a sign-in that cannot succeed is not worth a
    /// request.
    private func retrySignIn() {
        guard !isRetrying, !model.email.isEmpty, !model.password.isEmpty else { return }
        isRetrying = true
        Task {
            // Silent on every failure by design — see the type comment.
            try? await onRetrySignIn()
            isRetrying = false
        }
    }
}

#Preview("Check your inbox") {
    let model = OnboardingModel()
    model.email = "maria.ferreira@gmail.com"
    model.showActivation(after: .signUp)
    return ZStack {
        EvaScreenBackground().ignoresSafeArea()
        ActivationStepView(model: model, onRetrySignIn: {}, onResend: { _ in }, onBack: {})
    }
}

#Preview("Not activated") {
    let model = OnboardingModel()
    model.email = "maria.ferreira@gmail.com"
    model.showActivation(after: .logIn)
    return ZStack {
        EvaScreenBackground().ignoresSafeArea()
        ActivationStepView(model: model, onRetrySignIn: {}, onResend: { _ in }, onBack: {})
    }
}

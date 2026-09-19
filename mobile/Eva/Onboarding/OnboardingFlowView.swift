import SwiftUI

/// Container for the authentication flow: one auth screen (or log in) → the activation
/// gate → password reset, then into the app.
///
/// #19 removed the questionnaire half. The canvas draws authentication as one screen and
/// puts the questionnaire fields in Profile, so once a user authenticates they land in the
/// app and personalise from Profile rather than through a post-auth wizard. What remains
/// here is the canvas-true auth screen on `EvaScreenBackground`.
struct OnboardingFlowView: View {
    @State private var model = OnboardingModel()
    let session: AppSession

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            stepContent
                .transition(stepTransition)
                .id(model.step)
        }
        .animation(.easeInOut(duration: 0.3), value: model.step)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .createAccount:
            CreateAccountStepView(
                model: model,
                onSubmit: { email in
                    // Sign-up no longer signs anyone in — and since #120 it creates no
                    // account either. An address is all it sends; the link on its way is
                    // where the account is made and the password chosen. So the next
                    // screen is the gate.
                    _ = try await session.signUp(email: email)
                    model.showActivation(after: .signUp)
                },
                onProviderCredential: signIn(with:),
                onGoToLogIn: model.chooseLogIn
            )
        case .logIn:
            LoginStepView(
                model: model,
                onSubmit: { _, _ in try await signIn() },
                onProviderCredential: signIn(with:),
                onGoToSignUp: model.chooseCreateAccount,
                onForgotPassword: model.chooseForgotPassword
            )
        case .activation:
            ActivationStepView(
                model: model,
                onRetrySignIn: signIn,
                onResend: session.resendActivation,
                onBack: model.back
            )
        case .forgot:
            ForgotPasswordStepView(
                model: model,
                onSubmit: { email in
                    try await session.requestPasswordReset(email: email)
                    model.next()
                },
                onBackToLogIn: model.back
            )
        case .forgotSent:
            LinkSentStepView(
                email: model.email,
                onResend: session.requestPasswordReset,
                onBackToLogIn: model.back
            )
        }
    }

    /// One sign-in, and the routing every caller of it shares: log in's CTA and the
    /// activation gate's silent retry are the same request with the same two outcomes.
    /// `NOT_ACTIVATED` is the one this flow answers itself, by showing the gate; the log-in
    /// screen would otherwise have to put "confirm your email" under its password field,
    /// which is not a thing the user typed wrong. Everything else is rethrown to whoever
    /// asked, which is what lets the gate stay silent about its own probe.
    private func signIn() async throws {
        do {
            try await session.signIn(email: model.email, password: model.password)
            // .ready is handled by EvaRootView switching to the dashboard.
        } catch APIError.notActivated {
            model.showActivation(after: .logIn)
        }
    }

    /// The Apple and Google half of the same routing (#7), shared by both auth screens.
    ///
    /// There is no activation branch, and that is not an omission. #6's emailed link exists
    /// to prove an address the user typed; Apple and Google have already proved theirs, so
    /// `/auth/idp` returns a session outright and `NOT_ACTIVATED` cannot come back from it.
    private func signIn(with credential: ProviderCredential) async throws {
        try await session.signInWithProvider(credential)
        // .ready is handled by EvaRootView switching to the dashboard.
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

#Preview {
    OnboardingFlowView(session: AppSession())
}

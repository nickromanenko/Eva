import SwiftUI

/// Container for the onboarding flow: one auth screen (or log in) → the activation gate
/// → 4-step questionnaire → done.
///
/// The two halves are drawn on different grounds on purpose. Authentication is built to
/// the canvas and sits on `EvaScreenBackground`; the questionnaire keeps the legacy mauve
/// gradient until it moves into Profile, which is where the canvas puts those fields.
/// DESIGN.md §9 tracks the split.
struct OnboardingFlowView: View {
    @State private var model = OnboardingModel()
    let session: AppSession

    init(session: AppSession) {
        self.session = session
        // Returning user with an unfinished questionnaire lands directly on it.
        if session.state == .needsQuestionnaire {
            _model = State(initialValue: {
                let model = OnboardingModel()
                if model.step.rawValue < OnboardingStep.aboutYou.rawValue {
                    model.step = .aboutYou
                }
                return model
            }())
        }
    }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            stepContent
                .transition(stepTransition)
                .id(model.step)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.step.questionnaireIndex != nil {
                questionnaireHeader
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.step)
    }

    /// Canvas ground for the auth screens; the legacy mauve gradient for the
    /// questionnaire, which the canvas does not draw.
    @ViewBuilder
    private var background: some View {
        if model.step.isAuthScreen {
            EvaScreenBackground()
        } else {
            LinearGradient.evaScreenBackground
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .createAccount:
            CreateAccountStepView(
                model: model,
                onSubmit: { email, password in
                    // Sign-up no longer signs anyone in (#6): the account exists and an
                    // activation link is on its way, so the next screen is the gate, not
                    // the questionnaire.
                    _ = try await session.signUp(email: email, password: password)
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
        case .aboutYou:
            AboutYouStepView(model: model, onContinue: model.next)
        case .goals:
            GoalsStepView(model: model, onContinue: model.next)
        case .health:
            HealthStepView(model: model, onContinue: model.next)
        case .lifestyle:
            LifestyleStepView(model: model) {
                try await session.submitQuestionnaire(model.profilePayload)
                model.next()
            }
        case .done:
            DoneStepView(onFinish: session.enterDashboard)
        }
    }

    /// One sign-in, and the routing every caller of it shares: log in\'s CTA and the
    /// activation gate\'s silent retry are the same request with the same three outcomes.
    /// `NOT_ACTIVATED` is the one this flow answers itself, by showing the gate; the log-in
    /// screen would otherwise have to put "confirm your email" under its password field,
    /// which is not a thing the user typed wrong. Everything else is rethrown to whoever
    /// asked, which is what lets the gate stay silent about its own probe.
    private func signIn() async throws {
        do {
            try await session.signIn(email: model.email, password: model.password)
            if session.state == .needsQuestionnaire {
                model.startQuestionnaire()
            }
            // .ready is handled by EvaApp switching to the dashboard.
        } catch APIError.notActivated {
            model.showActivation(after: .logIn)
        }
    }

    /// The Apple and Google half of the same routing (#7), shared by both auth screens.
    ///
    /// **No new `OnboardingStep`.** Provider sign-in draws no screen of its own: it starts
    /// from a button on a step that already exists, and it lands where every other
    /// authentication lands — the questionnaire, or the dashboard. The enum is a list of
    /// *screens*, and adding a case with no screen behind it would leave an unreachable
    /// raw value that `EVA_ONBOARDING_STEP` could still jump to.
    ///
    /// There is no activation branch either, and that is not an omission. #6's emailed
    /// link exists to prove an address the user typed; Apple and Google have already
    /// proved theirs, so `/auth/idp` returns a session outright and `NOT_ACTIVATED` cannot
    /// come back from it.
    private func signIn(with credential: ProviderCredential) async throws {
        try await session.signInWithProvider(credential)
        if session.state == .needsQuestionnaire {
            model.startQuestionnaire()
        }
        // .ready is handled by EvaRootView switching to the dashboard.
    }

    /// Back + progress bar + step caption — questionnaire screens.
    private var questionnaireHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                backButton
                    .opacity(model.step == .aboutYou ? 0 : 1)
                    .disabled(model.step == .aboutYou)
                ProgressView(value: model.questionnaireProgress)
                    .progressViewStyle(EvaProgressBarStyle())
            }
            if let index = model.step.questionnaireIndex {
                Text("Set up your plan · Step \(index + 1) of 4")
                    .font(.system(size: 11.5, weight: .bold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evaFaint)
                    .padding(.leading, 52)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var backButton: some View {
        Button(action: model.back) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.evaInk)
                .frame(width: 38, height: 38)
                .background(.white, in: .circle)
                .shadow(color: .evaInk.opacity(0.18), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
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

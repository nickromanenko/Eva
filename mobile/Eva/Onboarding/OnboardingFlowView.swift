import SwiftUI

/// Container for the onboarding flow: welcome → info screens → sign-up (or email
/// form) → 4-step questionnaire → done.
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
            LinearGradient.evaScreenBackground
                .ignoresSafeArea()

            stepContent
                .transition(stepTransition)
                .id(model.step)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.step.showsPublicHeader {
                publicHeader
            } else if model.step.questionnaireIndex != nil {
                questionnaireHeader
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.step)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome:
            WelcomeStepView(onGetStarted: model.getStarted, onLogIn: model.chooseLogIn)
        case .infoScience:
            InfoScienceStepView(onContinue: model.next)
        case .infoSolution:
            InfoSolutionStepView(onContinue: model.next)
        case .signUp:
            SignUpStepView(onEmailSignUp: model.chooseEmailSignUp)
        case .emailSignUp:
            EmailSignUpStepView(
                model: model,
                onSubmit: { email, password in
                    try await session.signUp(email: email, password: password)
                    model.startQuestionnaire()
                },
                onGoToLogin: model.chooseLogIn
            )
        case .logIn:
            LoginStepView { email, password in
                try await session.signIn(email: email, password: password)
                if session.state == .needsQuestionnaire {
                    model.startQuestionnaire()
                }
                // .ready is handled by EvaApp switching to the dashboard.
            }
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

    /// Floating back button only — public screens before authentication.
    private var publicHeader: some View {
        HStack {
            backButton
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
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

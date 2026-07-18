import SwiftUI

/// Container for the 8-step onboarding flow: welcome → why Eva → sign-up →
/// questionnaire (about you, goals, health, lifestyle) → done.
struct OnboardingFlowView: View {
    @State private var model = OnboardingModel()
    let onFinished: () -> Void

    var body: some View {
        ZStack {
            LinearGradient.evaScreenBackground
                .ignoresSafeArea()

            stepContent
                .transition(stepTransition)
                .id(model.step)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.step.showsHeader {
                progressHeader
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.step)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome:
            // "Log in" goes to the sign-up step for now; a real login flow comes with auth.
            WelcomeStepView(onGetStarted: model.next, onLogIn: { model.step = .signUp })
        case .whyEva:
            WhyEvaStepView(onContinue: model.next)
        case .signUp:
            SignUpStepView(onContinue: model.next)
        case .aboutYou:
            AboutYouStepView(model: model, onContinue: model.next)
        case .goals:
            GoalsStepView(model: model, onContinue: model.next)
        case .health:
            HealthStepView(model: model, onContinue: model.next)
        case .lifestyle:
            LifestyleStepView(model: model, onContinue: model.next)
        case .done:
            DoneStepView(onFinish: onFinished)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 14) {
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

            ProgressView(value: model.progress)
                .progressViewStyle(EvaProgressBarStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

#Preview {
    OnboardingFlowView(onFinished: {})
}

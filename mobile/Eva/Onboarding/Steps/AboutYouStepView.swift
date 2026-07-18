import SwiftUI

struct AboutYouStepView: View {
    @Bindable var model: OnboardingModel
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepLayout(buttonTitle: "Continue", onContinue: onContinue) {
            QuestionnaireHeading(
                title: "A little about you",
                subtitle: "This helps Eva personalise your plan."
            )

            VStack(spacing: 14) {
                StepperCard(title: "Age", value: $model.age, range: 13...99)
                StepperCard(title: "Weight · kg", value: $model.weightKg, range: 30...200)
                StepperCard(title: "Height · cm", value: $model.heightCm, range: 120...220)
            }
            .padding(.top, 22)
        }
    }
}

#Preview {
    AboutYouStepView(model: OnboardingModel(), onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

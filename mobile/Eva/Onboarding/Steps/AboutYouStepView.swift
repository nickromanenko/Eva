import SwiftUI

struct AboutYouStepView: View {
    @Bindable var model: OnboardingModel
    let onContinue: () -> Void

    var body: some View {
        // Continue is held while the date breaks the 18+ rule (A12). The API refuses the
        // same dates and is the enforcement; this keeps her from answering three more
        // screens before being told.
        OnboardingStepLayout(
            buttonTitle: "Continue",
            isEnabled: model.isOldEnough,
            onContinue: onContinue
        ) {
            QuestionnaireHeading(
                title: "A little about you",
                subtitle: "This helps Eva personalise your plan."
            )

            VStack(spacing: 14) {
                DateOfBirthCard(
                    value: $model.dateOfBirth,
                    errorMessage: model.dateOfBirthError
                )
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

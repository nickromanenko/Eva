import SwiftUI

struct AboutYouStepView: View {
    @Bindable var model: OnboardingModel
    /// Which system the two body metrics are typed in (#82). The values themselves are
    /// kilograms and centimeters whichever way this reads.
    let units: EvaUnitPreference
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
                WeightEntryCard(kilograms: $model.weightKg, system: units.system)
                HeightEntryCard(centimeters: $model.heightCm, system: units.system)
            }
            .padding(.top, 22)
        }
    }
}

#Preview {
    AboutYouStepView(model: OnboardingModel(), units: EvaUnitPreference(), onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

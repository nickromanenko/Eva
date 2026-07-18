import SwiftUI

struct GoalsStepView: View {
    @Bindable var model: OnboardingModel
    let onContinue: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]

    var body: some View {
        OnboardingStepLayout(buttonTitle: "Continue", onContinue: onContinue) {
            QuestionnaireHeading(
                kicker: "Questionnaire · 2 of 4",
                title: "What do you want to improve?",
                subtitle: "Choose all that matter to you."
            )

            LazyVGrid(columns: columns, spacing: 11) {
                ForEach(OnboardingModel.goalOptions, id: \.self) { goal in
                    ChipToggleButton(
                        label: goal,
                        isSelected: model.goals.contains(goal),
                        isCentered: true
                    ) {
                        toggle(goal)
                    }
                }
            }
            .padding(.top, 22)
        }
    }

    private func toggle(_ goal: String) {
        if model.goals.contains(goal) {
            model.goals.remove(goal)
        } else {
            model.goals.insert(goal)
        }
    }
}

#Preview {
    GoalsStepView(model: OnboardingModel(), onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

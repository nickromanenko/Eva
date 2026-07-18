import SwiftUI

struct HealthStepView: View {
    @Bindable var model: OnboardingModel
    let onContinue: () -> Void

    private let medsColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        OnboardingStepLayout(buttonTitle: "Continue", onContinue: onContinue) {
            QuestionnaireHeading(title: "Your health")

            sectionLabel("Any conditions we should know about?")
                .padding(.top, 22)
            VStack(spacing: 10) {
                ForEach(OnboardingModel.conditionOptions, id: \.self) { condition in
                    ChipToggleButton(
                        label: condition,
                        isSelected: model.conditions.contains(condition)
                    ) {
                        toggleCondition(condition)
                    }
                }
            }
            .padding(.top, 12)

            sectionLabel("Do you take medications affecting hormones?")
                .padding(.top, 24)
            LazyVGrid(columns: medsColumns, spacing: 10) {
                ForEach(OnboardingModel.medicationOptions, id: \.self) { option in
                    ChipToggleButton(
                        label: option,
                        isSelected: model.medications == option,
                        isCentered: true
                    ) {
                        model.medications = option
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.evaPlum)
    }

    private func toggleCondition(_ condition: String) {
        if model.conditions.contains(condition) {
            model.conditions.remove(condition)
        } else if condition == "None of these" {
            model.conditions = [condition]
        } else {
            model.conditions.remove("None of these")
            model.conditions.insert(condition)
        }
    }
}

#Preview {
    HealthStepView(model: OnboardingModel(), onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

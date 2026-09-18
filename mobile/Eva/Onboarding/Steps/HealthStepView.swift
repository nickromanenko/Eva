import SwiftUI

struct HealthStepView: View {
    @Bindable var model: OnboardingModel
    let onContinue: () -> Void

    // Two columns, not three. The options name a medication now rather than answering
    // yes/no (#81), and "Progestogen-only pill" does not fit a third of the width.
    private let medsColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        OnboardingStepLayout(buttonTitle: "Continue", onContinue: onContinue) {
            QuestionnaireHeading(title: "Your health")

            sectionLabel("Any conditions we should know about?")
                .padding(.top, 22)
            VStack(spacing: 10) {
                ForEach(OnboardingModel.conditionOptions) { condition in
                    ChipToggleButton(
                        label: condition.label,
                        isSelected: model.conditions.contains(condition.code)
                    ) {
                        toggleCondition(condition.code)
                    }
                }
            }
            .padding(.top, 12)

            sectionLabel("Do you take any hormonal medication?")
                .padding(.top, 24)
            LazyVGrid(columns: medsColumns, spacing: 10) {
                ForEach(OnboardingModel.medicationOptions) { option in
                    ChipToggleButton(
                        label: option.label,
                        isSelected: model.medications == option.code,
                        isCentered: true
                    ) {
                        model.medications = option.code
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

    /// "None of these" is exclusive in both directions: choosing it clears the rest, and
    /// choosing anything else clears it. It is a real answer rather than an empty list —
    /// "I have none of these" and "I did not say" are different facts, which is why the API
    /// keeps a `noneOfThese` code for it.
    private static let noConditions = "noneOfThese"

    private func toggleCondition(_ code: String) {
        if model.conditions.contains(code) {
            model.conditions.remove(code)
        } else if code == Self.noConditions {
            model.conditions = [code]
        } else {
            model.conditions.remove(Self.noConditions)
            model.conditions.insert(code)
        }
    }
}

#Preview {
    HealthStepView(model: OnboardingModel(), onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

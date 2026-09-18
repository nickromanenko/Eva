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
        // Continue is held until the medication question is answered (#215). The API has no
        // code for "unanswered" and refuses the empty string the payload would otherwise
        // send, so without this the only place she learns the question was required is a
        // failed submission three screens later, in the API's own words.
        OnboardingStepLayout(
            buttonTitle: "Continue",
            isEnabled: model.hasMedicationAnswer,
            onContinue: onContinue
        ) {
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

            medicationRule
                .padding(.top, EvaSpacing.sm)
        }
    }

    /// The rule stated up front, in the treatment `EvaInputField` gives §6's password
    /// helper — `inputHelper` text that recolours to `evaErrorInk` and gains the `!` mark
    /// while it is unmet (DESIGN.md §2: a semantic state never rides on colour alone).
    ///
    /// It is a helper and not an error, and the difference is the point: an error under an
    /// untouched question accuses her of getting something wrong when all she has done is
    /// not answered yet. The chips themselves are never recoloured for the same reason.
    private var medicationRule: some View {
        HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
            if !model.hasMedicationAnswer {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.evaError)
                    .accessibilityHidden(true)
            }
            Text(OnboardingModel.medicationRule)
                .evaTextStyle(.inputHelper)
                .fixedSize(horizontal: false, vertical: true)
                // The words do not change with the state, so VoiceOver would otherwise be
                // told nothing about it — the same reason `EvaInputField`'s helper says it.
                .accessibilityLabel(
                    model.hasMedicationAnswer
                        ? OnboardingModel.medicationRule
                        : "Not met yet: \(OnboardingModel.medicationRule)"
                )
                .accessibilityIdentifier("questionnaire.medications.rule")
        }
        .foregroundStyle(
            model.hasMedicationAnswer ? Color.evaSecondaryText : Color.evaErrorInk
        )
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

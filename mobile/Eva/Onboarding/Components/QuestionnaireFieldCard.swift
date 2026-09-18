import SwiftUI

/// The card chrome the "A little about you" step draws every field in: an uppercase title
/// over one control, on white with a hairline border.
///
/// Extracted from `StepperCard` when #81 put a second kind of field in that group — a date
/// of birth is not a number with −/+ controls, and three cards in one stack have to be one
/// card with three contents rather than two that nearly match.
///
/// **The values here are the pre-token ones**, kept exactly as `StepperCard` drew them
/// rather than restated in tokens, because moving them would redraw the step in the middle
/// of a schema change. These are the onboarding screens DESIGN.md §9 records as drifted from
/// the canvas, and #19 rebuilds this one into Profile against the canvas' own `editProfile`
/// rows. Extracting them into one place is what makes that a single edit.
struct QuestionnaireFieldCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.evaMuted)
                .textCase(.uppercase)
                .kerning(1)
            content
        }
        .padding(18)
        .background(.white, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.evaCardBorder, lineWidth: 1)
        )
    }
}

/// Date of birth, with the 18+ rule stated under the control (#81).
///
/// **The date is what Eva stores; the age is derived from it** (PRD §Sign Up, Profile
/// fields 1). A stored age is wrong within a year of being written and wrong silently.
///
/// **The floor is checked here as well as at the API** (PRD §Product frame, Age; A12). Not
/// because the client is trusted — `parseProfile` refuses the same dates, and that is the
/// enforcement — but because the canvas' rule is that a validation appears under the field
/// it belongs to rather than as a failed request after four more screens.
///
/// It stays on whatever screen captures the date even after #19 moves the rest of the
/// questionnaire into Profile: it gates the account, not the personalisation.
struct DateOfBirthCard: View {
    @Binding var value: Date
    /// The message to show under the control, or `nil` when the date is acceptable.
    let errorMessage: String?

    var body: some View {
        QuestionnaireFieldCard(title: "Date of birth") {
            DatePicker(
                "Date of birth",
                selection: $value,
                // Nothing after today is a date of birth. The floor itself is deliberately
                // *not* expressed as a range: a picker that cannot reach an under-18 date
                // silently corrects the answer instead of telling her the rule, and she is
                // then refused by the API with no idea why.
                in: ...Date.now,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Color.evaPlum)
            .accessibilityIdentifier("questionnaire.dateOfBirth")

            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
                    // Decorative: it repeats the message beside it, which is what VoiceOver
                    // reads. The same pairing `EvaInputField` draws an error with.
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.evaError)
                        .accessibilityHidden(true)
                    Text(errorMessage)
                        .evaTextStyle(.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("questionnaire.dateOfBirth.error")
                }
                .foregroundStyle(Color.evaErrorInk)
            }
        }
    }
}

#Preview("Date of birth") {
    @Previewable @State var kilograms = 64.0

    VStack(spacing: 14) {
        DateOfBirthCard(value: .constant(.now), errorMessage: OnboardingModel.minimumAgeMessage)
        WeightEntryCard(kilograms: $kilograms, system: .metric)
    }
    .padding()
    .background(LinearGradient.evaScreenBackground)
}

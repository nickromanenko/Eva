import SwiftUI

/// Card with −/+ controls for numeric questionnaire values (weight, height).
///
/// The chrome is `QuestionnaireFieldCard`, shared with `DateOfBirthCard` since #81 replaced
/// the age stepper with a date — two cards in one stack that only nearly matched would be a
/// design defect waiting to happen.
struct StepperCard: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        QuestionnaireFieldCard(title: title) {
            HStack {
                bumpButton("minus") { value = max(range.lowerBound, value - 1) }
                Spacer()
                Text("\(value)")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(Color.evaInk)
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(.snappy(duration: 0.2), value: value)
                Spacer()
                bumpButton("plus") { value = min(range.upperBound, value + 1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private func bumpButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.evaPlum)
                .frame(width: 42, height: 42)
                .background(Color.evaBackgroundTop, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.evaChipBorder, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StepperCard(title: "Weight · kg", value: .constant(64), range: 30...200)
        .padding()
}

import SwiftUI

/// Card with −/+ controls for numeric questionnaire values (age, weight, height).
struct StepperCard: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.evaMuted)
                .textCase(.uppercase)
                .kerning(1)
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
        .padding(18)
        .background(.white, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.evaCardBorder, lineWidth: 1)
        )
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
    StepperCard(title: "Age", value: .constant(28), range: 13...99)
        .padding()
}

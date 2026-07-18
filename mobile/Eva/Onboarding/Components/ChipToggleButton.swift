import SwiftUI

/// Selectable pill/card used for questionnaire options.
struct ChipToggleButton: View {
    let label: String
    let isSelected: Bool
    var isCentered = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.evaPlum : Color.evaSecondary)
                .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .background(isSelected ? Color.evaSoftPink : .white, in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isSelected ? Color.evaPlum : Color.evaChipBorder, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    VStack {
        ChipToggleButton(label: "Cycle health", isSelected: true, isCentered: true) {}
        ChipToggleButton(label: "PCOS", isSelected: false) {}
    }
    .padding()
}

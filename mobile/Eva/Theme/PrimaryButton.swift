import SwiftUI

/// Full-width gradient call-to-action button used throughout onboarding.
struct PrimaryButton: View {
    let title: String
    var showsArrow = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 16.5, weight: .bold))
                    if showsArrow {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(LinearGradient.evaPlumPink, in: .rect(cornerRadius: 16))
            .shadow(color: .evaPlum.opacity(0.45), radius: 15, y: 9)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityIdentifier("primary.\(title)")
    }
}

#Preview {
    PrimaryButton(title: "Get started", showsArrow: true) {}
        .padding()
}

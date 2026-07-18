import SwiftUI

struct SignUpStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Create your account")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.evaInk)
                    Text("Then we'll ask a few questions to personalise Eva. Your data stays private.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.evaBody)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    VStack(spacing: 12) {
                        // TODO: wire to Firebase Auth (Apple / Google / email+password) in the auth phase
                        authButton(title: "Continue with Apple", systemImage: "apple.logo", style: .filled)
                        authButton(title: "Continue with Google", systemImage: "g.circle", style: .outlined)
                        authButton(title: "Sign up with email", systemImage: "envelope", style: .outlined)
                    }
                    .padding(.top, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 58)
            }
            .scrollIndicators(.hidden)

            Text("By continuing you agree to Eva's \(Text("Terms").fontWeight(.semibold).foregroundStyle(Color.evaPlum)) & \(Text("Privacy Policy").fontWeight(.semibold).foregroundStyle(Color.evaPlum)).")
                .font(.system(size: 12))
                .foregroundStyle(Color.evaFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 16)
        }
    }

    private enum AuthButtonStyle { case filled, outlined }

    private func authButton(title: String, systemImage: String, style: AuthButtonStyle) -> some View {
        Button(action: onContinue) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
            }
            .foregroundStyle(style == .filled ? .white : Color.evaInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(style == .filled ? Color.evaInk : .white, in: .rect(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(style == .filled ? .clear : Color(hex: 0xE7D6E2), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SignUpStepView(onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

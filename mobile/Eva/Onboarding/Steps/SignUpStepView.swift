import SwiftUI

struct SignUpStepView: View {
    let onEmailSignUp: () -> Void

    @State private var showComingSoon = false

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
                        // Apple/Google arrive in a later phase; email is live.
                        authButton(title: "Continue with Apple", systemImage: "apple.logo", style: .filled) {
                            showComingSoon = true
                        }
                        authButton(title: "Continue with Google", systemImage: "g.circle", style: .outlined) {
                            showComingSoon = true
                        }
                        authButton(title: "Sign up with email", systemImage: "envelope", style: .outlined, action: onEmailSignUp)
                    }
                    .padding(.top, 24)
                    .alert("Coming soon", isPresented: $showComingSoon) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Apple and Google sign-in are on the way. For now, sign up with email.")
                    }
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

    private func authButton(title: String, systemImage: String, style: AuthButtonStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .accessibilityIdentifier("signup.method.\(title)")
    }
}

#Preview {
    SignUpStepView(onEmailSignUp: {})
        .background(LinearGradient.evaScreenBackground)
}

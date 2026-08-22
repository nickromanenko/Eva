import SwiftUI

/// Email/password sign-in for returning users, reached from "Log in" on welcome.
struct LoginStepView: View {
    let onSubmit: (_ email: String, _ password: String) async throws -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private enum Field { case email, password }
    @FocusState private var focusedField: Field?

    private var isValid: Bool {
        email.wholeMatch(of: /\S+@\S+\.\S+/) != nil && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Welcome back")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.evaInk)
                    Text("Log in to continue your Prime Era.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.evaBody)
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 16) {
                        field(label: "Email") {
                            TextField("you@email.com", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .accessibilityIdentifier("login.email")
                        }
                        field(label: "Password") {
                            SecureField("Your password", text: $password)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { submit() }
                                .accessibilityIdentifier("login.password")
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.evaPlum)
                                .accessibilityIdentifier("login.error")
                        }
                    }
                    .padding(.top, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 58)
            }
            .scrollIndicators(.hidden)

            Button(action: submit) {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Log in")
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    isValid ? AnyShapeStyle(LinearGradient.evaPlumPink) : AnyShapeStyle(Color(hex: 0xD7C3D1)),
                    in: .rect(cornerRadius: 16)
                )
                .shadow(color: isValid ? .evaPlum.opacity(0.45) : .clear, radius: 15, y: 9)
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isLoading)
            .accessibilityIdentifier("login.submit")
            .padding(.horizontal, 26)
            .padding(.bottom, 16)
        }
    }

    private func submit() {
        guard isValid, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(email, password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func field(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.evaMuted)
            content()
                .font(.system(size: 15.5))
                .foregroundStyle(Color.evaInk)
                .padding(15)
                .background(.white, in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.evaChipBorder, lineWidth: 1.5)
                )
        }
    }
}

#Preview {
    LoginStepView { _, _ in }
        .background(LinearGradient.evaScreenBackground)
}

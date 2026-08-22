import SwiftUI

struct EmailSignUpStepView: View {
    @Bindable var model: OnboardingModel
    let onSubmit: (_ email: String, _ password: String) async throws -> Void
    let onGoToLogin: () -> Void

    @State private var errorMessage: String?
    @State private var showLoginLink = false
    @State private var isLoading = false

    private enum Field { case email, password }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sign up with email")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.evaInk)
                    Text("Create your login — you can add the rest in a moment.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.evaBody)
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 16) {
                        EvaInputField(
                            label: "Email",
                            placeholder: "you@email.com",
                            isFocused: focusedField == .email
                        ) { prompt in
                            TextField("Email", text: $model.email, prompt: prompt)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .accessibilityIdentifier("signup.email")
                        }
                        // The form's errors all arrive on submit, so they hang off the
                        // last field — which keeps them exactly where they used to sit.
                        EvaInputField(
                            label: "Password",
                            placeholder: "At least 8 characters",
                            isFocused: focusedField == .password,
                            errorMessage: errorMessage,
                            errorIdentifier: "signup.error"
                        ) { prompt in
                            // .password, not .newPassword: the automatic strong-password
                            // overlay breaks both UI tests and manual typing in simulators.
                            SecureField("Password", text: $model.password, prompt: prompt)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.done)
                                .onSubmit { submit() }
                                .accessibilityIdentifier("signup.password")
                        }
                        if showLoginLink {
                            Button("Log in instead", action: onGoToLogin)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(Color.evaPlum)
                        }
                        if errorMessage == nil {
                            Text(model.isEmailFormValid
                                 ? "Looks good — you're ready to continue."
                                 : "Enter a valid email and a password of 8+ characters.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(model.isEmailFormValid ? Color.evaGreenIcon : Color.evaFaint)
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
                        Text("Create account")
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(background, in: .rect(cornerRadius: 16))
                .shadow(color: model.isEmailFormValid ? .evaPlum.opacity(0.45) : .clear, radius: 15, y: 9)
            }
            .buttonStyle(.plain)
            .disabled(!model.isEmailFormValid || isLoading)
            .accessibilityIdentifier("signup.submit")
            .padding(.horizontal, 26)
            .padding(.bottom, 16)
        }
    }

    private func submit() {
        guard model.isEmailFormValid, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        showLoginLink = false
        Task {
            do {
                try await onSubmit(model.email, model.password)
            } catch {
                errorMessage = error.localizedDescription
                showLoginLink = (error as? APIError)?.code == "EMAIL_EXISTS"
            }
            isLoading = false
        }
    }

    private var background: AnyShapeStyle {
        model.isEmailFormValid
            ? AnyShapeStyle(LinearGradient.evaPlumPink)
            : AnyShapeStyle(Color(hex: 0xD7C3D1))
    }
}

#Preview {
    EmailSignUpStepView(model: OnboardingModel(), onSubmit: { _, _ in }, onGoToLogin: {})
        .background(LinearGradient.evaScreenBackground)
}

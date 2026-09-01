import SwiftUI

/// "Reset your password" — "Eva App.dc.html", rail item **Forgot password** (#6).
///
/// One field and one action. The artboard's spec note fixes the two things that matter:
/// the response is identical whether or not the address exists, so a successful request
/// always goes on to **Link sent** and never says "no account for that address"; and
/// the copy stays short — no security lecture.
///
/// The address is the model's, shared with log in and sign up, so whatever was typed on
/// the log-in screen is already here. The canvas pre-fills it the same way.
///
/// The title takes `AuthHero` at 34 where the artboard draws this one at 32 — the same
/// left-aligned title-and-line shape as log in, two points larger, rather than a fourth
/// off-scale size for one screen.
struct ForgotPasswordStepView: View {

    @Bindable var model: OnboardingModel
    let onSubmit: (_ email: String) async throws -> Void
    let onBackToLogIn: () -> Void

    @State private var emailError: String?
    @State private var isRateLimited = false
    @State private var isLoading = false
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        AuthScreenLayout {
            AuthWordmark()

            AuthHero(
                title: "Reset your password",
                subtitle: "Enter the email you use for Eva and we'll send a reset link."
            )
            .padding(.top, EvaSpacing.xl)

            EvaInputField(
                label: "Email",
                placeholder: "you@email.com",
                isFocused: isEmailFocused,
                errorMessage: emailError,
                errorIdentifier: "forgot.email.error"
            ) { prompt in
                TextField("Email", text: $model.email, prompt: prompt)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isEmailFocused)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .accessibilityIdentifier("forgot.email")
            }
            .padding(.top, EvaSpacing.lg)

            if isRateLimited {
                AuthRateLimitedBanner(identifier: "forgot.rateLimited")
                    .padding(.top, EvaSpacing.md)
            }
        } footer: {
            PrimaryButton(title: "Send reset link", isLoading: isLoading, action: submit)
                .disabled(!model.isEmailValid)

            TextButton(title: "Back to log in", action: onBackToLogIn)
                .padding(.top, EvaSpacing.lg)
        }
        // §6: validation on blur, never while typing.
        .onChange(of: isEmailFocused) { wasFocused, _ in
            if wasFocused { validate() }
        }
    }

    private func validate() {
        emailError = model.email.isEmpty || model.isEmailValid
            ? nil
            : "That doesn't look like a valid email address."
    }

    private func submit() {
        guard model.isEmailValid, !isLoading else { return }
        isEmailFocused = false
        isLoading = true
        emailError = nil
        isRateLimited = false
        Task {
            do {
                try await onSubmit(model.email)
            } catch let error as APIError where error.isRateLimited {
                isRateLimited = true
            } catch {
                emailError = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview("Forgot password") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        ForgotPasswordStepView(model: OnboardingModel(), onSubmit: { _ in }, onBackToLogIn: {})
    }
}

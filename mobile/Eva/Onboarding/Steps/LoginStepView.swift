import SwiftUI

/// The canvas' log-in screen — "Eva App.dc.html", rail item **Log in**.
///
/// The same hierarchy as sign-up, deliberately: the artboard's spec note asks for it so
/// "the two screens feel like one system". Providers first, then an "or use your email"
/// rule, then the form.
///
/// ## Two divergences from the artboard, both explained below
///
/// **The hero is "Welcome back", not "Welcome back, Maria".** The canvas is a prototype
/// with a signed-in mock; on the real screen nobody has authenticated yet, so there is no
/// name to greet.
///
/// **The address and password live on the model, not here.** Both are shared with
/// sign-up, forgot password and the activation gate: the canvas pre-fills the address
/// across those screens, and the activation gate retries sign-in with the credentials
/// that were typed here. A screen-local `@State` could do neither.
struct LoginStepView: View {

    @Bindable var model: OnboardingModel
    let onSubmit: (_ email: String, _ password: String) async throws -> Void
    let onGoToSignUp: () -> Void
    let onForgotPassword: () -> Void

    @State private var errorMessage: String?
    @State private var isRevealingPassword = false
    @State private var isLoading = false
    @State private var comingSoonMessage = ""
    @State private var showsComingSoon = false

    private enum Field: Hashable { case email, password }
    @FocusState private var focusedField: Field?

    /// Enough to enable the CTA, and no more. The artboard's spec note is explicit that
    /// log-in shows **no error before submit** — anything stricter here would start
    /// telling a returning user their own address looks wrong.
    private var isValid: Bool {
        model.isEmailValid && !model.password.isEmpty
    }

    var body: some View {
        AuthScreenLayout {
            AuthWordmark()

            AuthHero(
                title: "Welcome back",
                subtitle: "Your cycle continued without you. Let's catch up."
            )
            .padding(.top, EvaSpacing.xl)

            providerButtons
                .padding(.top, EvaSpacing.lg)

            AuthMethodDivider(title: "or use your email")
                .padding(.vertical, EvaSpacing.lg)

            emailForm
        } footer: {
            PrimaryButton(title: "Log in", isLoading: isLoading, action: submit)
                .disabled(!isValid)

            AuthSwitchPrompt(
                question: "New to Eva?",
                actionTitle: "Create an account",
                action: onGoToSignUp
            )
            .padding(.top, EvaSpacing.lg)
        }
        .alert("Coming soon", isPresented: $showsComingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(comingSoonMessage)
        }
    }

    // MARK: - Sections

    private var providerButtons: some View {
        VStack(spacing: EvaSpacing.sm) {
            EvaAuthButton(provider: .apple) { comingSoon(.providers) }
            EvaAuthButton(provider: .google) { comingSoon(.providers) }
        }
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
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
                    .accessibilityIdentifier("login.email")
            }

            EvaInputField(
                label: "Password",
                placeholder: "Your password",
                isFocused: focusedField == .password,
                // One combined message, on the last field — the artboard asks for a
                // failure that does not say which of the two was wrong, so it cannot be
                // used to find out which addresses have accounts.
                errorMessage: errorMessage,
                errorIdentifier: "login.error",
                accessory: {
                    EvaInputRevealButton(
                        isRevealed: isRevealingPassword,
                        identifier: "login.password.reveal"
                    ) {
                        isRevealingPassword.toggle()
                    }
                }
            ) { prompt in
                passwordField(prompt: prompt)
            }

            HStack {
                Spacer(minLength: 0)
                TextButton(title: "Forgot password?", action: onForgotPassword)
            }
        }
    }

    /// `SecureField` until the reveal button is tapped, `TextField` after it. Both carry
    /// the same identifier and the same focus value, so revealing does not move focus.
    @ViewBuilder
    private func passwordField(prompt: Text) -> some View {
        if isRevealingPassword {
            TextField("Password", text: $model.password, prompt: prompt)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("login.password")
        } else {
            SecureField("Password", text: $model.password, prompt: prompt)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("login.password")
        }
    }

    // MARK: - Behaviour

    /// The one thing this screen draws but cannot do yet.
    private enum Unbuilt {
        case providers

        var message: String {
            switch self {
            case .providers:
                "Apple and Google sign-in are on the way. For now, log in with your email."
            }
        }
    }

    private func comingSoon(_ unbuilt: Unbuilt) {
        comingSoonMessage = unbuilt.message
        showsComingSoon = true
    }

    private func submit() {
        guard isValid, !isLoading else { return }
        focusedField = nil
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(model.email, model.password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview("Log in") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        LoginStepView(
            model: OnboardingModel(),
            onSubmit: { _, _ in },
            onGoToSignUp: {},
            onForgotPassword: {}
        )
    }
}

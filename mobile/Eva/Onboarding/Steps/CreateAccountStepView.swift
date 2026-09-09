import SwiftUI

/// The canvas' sign-up screen — one screen for every way into Eva.
///
/// Built from "Eva App.dc.html", rail items **Sign up** and **Sign up · validation**:
/// the `eva.` lockup, the hero, Continue with Apple, Continue with Google, an
/// "or continue with email" rule, then email and password inline, the CTA, the legal
/// note and a cross-link to log in. It replaces the five screens the app used to walk
/// through (welcome → two info screens → method picker → email form); see #3.
///
/// ## The account-linking state is still unreachable, and #7 did not change that
///
/// The canvas' "Sign up · validation" artboard shows an information banner for an address
/// that already signs in with Apple. It is built to the artboard here and nothing sets it.
///
/// #7 was expected to be what made it reachable. It is not: the API never asks "does this
/// address already use Apple?", because answering that question to an unauthenticated
/// caller tells anyone holding an address which providers back it. Firebase links matching
/// addresses on its own, silently and after the fact, and it would answer wrongly for
/// every Hide My Email relay anyway. Nothing in the `/auth/idp` contract carries that
/// signal, so there is nothing to wire the banner to.
///
/// `previewShowsAccountLinking` still renders it for review. Reaching it for real would
/// need a design answer to a different question — what to offer someone whose address is
/// taken — not a wire-up.
struct CreateAccountStepView: View {

    @Bindable var model: OnboardingModel
    let onSubmit: (_ email: String, _ password: String) async throws -> Void
    /// Signs in (or creates an account) with an Apple or Google credential (#7).
    let onProviderCredential: (ProviderCredential) async throws -> Void
    let onGoToLogIn: () -> Void

    /// Forces the canvas' account-linking state, which nothing in app code can reach —
    /// see the type comment. **Never set this outside a preview**, the same contract the
    /// button styles' `previewState` has.
    var previewShowsAccountLinking = false

    @State private var emailError: String?
    /// Whether the stated password rule is currently unsatisfied. Not an error message:
    /// the artboard recolours the helper line and leaves the input alone — see
    /// `EvaInputField.isHelperUnmet`.
    @State private var isPasswordRuleUnmet = false
    @State private var submissionError: String?
    @State private var isRevealingPassword = false
    @State private var isLoading = false

    private enum Field: Hashable { case email, password }
    @FocusState private var focusedField: Field?

    /// The rule §6 asks to be stated up front rather than revealed as a failure.
    ///
    /// It is helper text in **every** state, never an error: the `signup` artboard's spec
    /// note says password rules are "stated up front as helper text, not revealed as an
    /// error after failure", and `signupErr` keeps it as helper text with the password
    /// input on its normal border. Failing it only recolours the line and adds the `!`
    /// mark §2 requires. A *server* failure is a real error and gets the full treatment.
    private static let passwordRule = "At least 8 characters, including one number."

    var body: some View {
        AuthScreenLayout {
            AuthWordmark()

            AuthHero(
                title: "Your Prime Era\nstarts here",
                subtitle: "Eva learns your cycle, your energy and your goals — then "
                    + "adapts. No scores, no judgment."
            )
            .padding(.top, EvaSpacing.xl)

            providerButtons
                .padding(.top, EvaSpacing.lg)

            AuthMethodDivider(title: "or continue with email")
                .padding(.vertical, EvaSpacing.lg)

            if previewShowsAccountLinking {
                accountLinkingBanner
                    .padding(.bottom, EvaSpacing.md)
            }

            emailForm
        } footer: {
            PrimaryButton(title: "Create account", isLoading: isLoading, action: submit)
                .disabled(!model.isEmailFormValid)

            AuthLegalNote()
                .padding(.top, EvaSpacing.md)

            AuthSwitchPrompt(
                question: "Already have an account?",
                actionTitle: "Log in",
                action: onGoToLogIn
            )
            .padding(.top, EvaSpacing.lg)
        }
        // §6: validation runs on blur, never while typing.
        .onChange(of: focusedField) { previous, _ in
            validate(previous)
        }
    }

    // MARK: - Sections

    private var providerButtons: some View {
        ProviderSignInButtons(identifierPrefix: "auth", onCredential: onProviderCredential)
    }

    /// The canvas' "Sign up · validation" banner. Information blue, not error red — its
    /// own spec note is explicit that nothing went wrong.
    private var accountLinkingBanner: some View {
        EvaInfoBanner(
            title: "This email already uses Apple sign-in",
            message: "We won't create a second profile. Continue with Apple and "
                + "everything you've logged stays in one place."
        ) {
            // Deliberately inert. The banner it sits in is preview-only, and giving this
            // button a real Apple sign-in would make the preview start a flow — while
            // still leaving the banner itself unreachable, which is the actual gap.
            EvaAuthButton(
                provider: .apple,
                size: .compact,
                identifier: "signup.linkApple"
            ) {}
        }
        .accessibilityIdentifier("signup.linkBanner")
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            EvaInputField(
                label: "Email",
                placeholder: "you@email.com",
                isFocused: focusedField == .email,
                errorMessage: emailError,
                errorIdentifier: "signup.email.error"
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

            EvaInputField(
                label: "Password",
                placeholder: "Create a password",
                isFocused: focusedField == .password,
                // Server failures only. A failed submission names neither field, so it
                // hangs off the last one — where it has always been drawn — and it is the
                // one thing on this screen that earns the error border and ring.
                errorMessage: submissionError,
                errorIdentifier: "signup.error",
                // The rule is always the helper line; failing it recolours the line and
                // marks it, and never touches the input. Its own identifier, so a showing
                // rule and a server error are two elements rather than one.
                helperText: Self.passwordRule,
                isHelperUnmet: isPasswordRuleUnmet,
                helperIdentifier: "signup.password.rule",
                accessory: {
                    EvaInputRevealButton(
                        isRevealed: isRevealingPassword,
                        identifier: "signup.password.reveal"
                    ) {
                        isRevealingPassword.toggle()
                    }
                }
            ) { prompt in
                passwordField(prompt: prompt)
            }
        }
    }

    /// `SecureField` until the reveal button is tapped, `TextField` after it.
    ///
    /// `.password`, not `.newPassword`: the automatic strong-password overlay breaks both
    /// UI tests and manual typing in the simulator. Both branches carry the same
    /// identifier and the same focus value, so revealing does not move focus and a test
    /// finds the control either way — as a secure text field by default, a text field once
    /// revealed.
    @ViewBuilder
    private func passwordField(prompt: Text) -> some View {
        if isRevealingPassword {
            TextField("Password", text: $model.password, prompt: prompt)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .password)
                .submitLabel(.done)
                .onSubmit(submit)
                .accessibilityIdentifier("signup.password")
        } else {
            SecureField("Password", text: $model.password, prompt: prompt)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.done)
                .onSubmit(submit)
                .accessibilityIdentifier("signup.password")
        }
    }

    // MARK: - Behaviour

    /// Validates the field focus has just left. Nothing is validated while typing.
    private func validate(_ field: Field?) {
        switch field {
        case .email:
            emailError = model.email.isEmpty || model.isEmailValid
                ? nil
                : "That doesn't look like a valid email address."
        case .password:
            isPasswordRuleUnmet = !model.password.isEmpty && !model.isPasswordValid
        case nil:
            break
        }
    }

    private func submit() {
        guard model.isEmailFormValid, !isLoading else { return }
        focusedField = nil
        isLoading = true
        submissionError = nil
        Task {
            do {
                try await onSubmit(model.email, model.password)
            } catch {
                submissionError = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview("Sign up") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        CreateAccountStepView(
            model: OnboardingModel(),
            onSubmit: { _, _ in },
            onProviderCredential: { _ in },
            onGoToLogIn: {}
        )
    }
}

#Preview("Sign up · account linking") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        CreateAccountStepView(
            model: OnboardingModel(),
            onSubmit: { _, _ in },
            onProviderCredential: { _ in },
            onGoToLogIn: {},
            previewShowsAccountLinking: true
        )
    }
}

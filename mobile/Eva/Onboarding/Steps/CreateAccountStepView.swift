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
    let onSubmit: (_ email: String) async throws -> Void
    /// Signs in (or creates an account) with an Apple or Google credential (#7).
    let onProviderCredential: (ProviderCredential) async throws -> Void
    let onGoToLogIn: () -> Void

    /// Forces the canvas' account-linking state, which nothing in app code can reach —
    /// see the type comment. **Never set this outside a preview**, the same contract the
    /// button styles' `previewState` has.
    var previewShowsAccountLinking = false

    @State private var emailError: String?
    @State private var submissionError: String?
    @State private var isLoading = false

    private enum Field: Hashable { case email }
    @FocusState private var focusedField: Field?

    // The password rule that used to live here moved to the activation page with the
    // field itself (#120) — `website/src/pages/activate.astro`. `api/test/auth.test.ts`
    // reads it from there and pins the server's WEAK_PASSWORD message against it, so the
    // message still quotes text the user was actually shown.

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
            // **No password field** (#120). Sign-up sends an address and nothing else: a
            // credential set here would sit on an address nobody had proved yet, which is
            // exactly what let someone reserve a stranger's address and inherit the account
            // when they confirmed it. The password is chosen on the activation page, where
            // the link has just proved the address in the same request.
            //
            // The server error still hangs off the last field, which is now this one.
            EvaInputField(
                label: "Email",
                placeholder: "you@email.com",
                isFocused: focusedField == .email,
                errorMessage: emailError ?? submissionError,
                errorIdentifier: "signup.error"
            ) { prompt in
                TextField("Email", text: $model.email, prompt: prompt)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.go)
                    .accessibilityIdentifier("signup.email")
            }
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
                try await onSubmit(model.email)
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
            onSubmit: { _ in },
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
            onSubmit: { _ in },
            onProviderCredential: { _ in },
            onGoToLogIn: {},
            previewShowsAccountLinking: true
        )
    }
}

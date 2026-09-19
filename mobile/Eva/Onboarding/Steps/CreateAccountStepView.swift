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
/// that already has an account. It is built to the artboard here and nothing sets it.
///
/// #7 was expected to be what made it reachable. It is not: nothing in the `/auth/idp`
/// contract carries a signal to wire the banner to. The copy no longer names a provider
/// (#77) — `POST /auth/signup`'s `409 EMAIL_EXISTS` is exactly "this address already has an
/// account", so the banner *could* be wired to that response. The wiring itself is still a
/// separate decision, not this screen's.
///
/// `previewShowsAccountLinking` still renders it for review.
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
    /// A `429` the screen is sitting in (#38) — set on the throttled response, cleared on
    /// the next submit. Two pieces, because they are two facts: *that* the request was
    /// throttled shows the banner, and *when* the window ends holds the CTA. A server that
    /// sent no usable `Retry-After` gives the first without the second, and the screen then
    /// says less rather than holding the button for a guess.
    @State private var isRateLimited = false
    @State private var retryAt: Date?

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

            if isRateLimited {
                AuthRateLimitedBanner(identifier: "signup.rateLimited", retryAt: retryAt)
                    .padding(.top, EvaSpacing.md)
            }
        } footer: {
            AuthThrottledPrimaryButton(
                title: "Create account",
                isLoading: isLoading,
                isFormValid: model.isEmailFormValid,
                blockedUntil: retryAt,
                action: submit
            )

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
    ///
    /// **It never names a provider (#77).** `EMAIL_EXISTS` says an address already has an
    /// account and nothing about *which* provider, and for a Hide My Email relay there is
    /// no provider to name — so "continue with Apple" would send some people to create a
    /// second account. The action leads to log in, never to a provider button.
    private var accountLinkingBanner: some View {
        EvaInfoBanner(
            title: "This email already has an Eva account",
            message: "Log in to continue. If you use Apple, you can link it from Profile."
        ) {
            TextButton(title: "Log in", action: onGoToLogIn)
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
        isRateLimited = false
        retryAt = nil
        Task {
            do {
                try await onSubmit(model.email)
            } catch let error as APIError where error.isRateLimited {
                // Not a field error: nothing typed was wrong and the server refused before
                // it did anything, so the banner says so and the CTA waits it out.
                isRateLimited = true
                retryAt = error.retryAt
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

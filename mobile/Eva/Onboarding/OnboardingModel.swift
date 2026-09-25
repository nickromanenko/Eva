import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    // The public auth flow. The canvas draws authentication as one screen and gives each of
    // the two a cross-link to the other, so there is no public back stack and no public
    // header — #3 collapsed welcome / infoScience / infoSolution / signUp / emailSignUp
    // into `createAccount`.
    case createAccount, logIn
    // The activation gate and password reset (#6). These were appended rather than slotted
    // in next to the auth screens so their raw values would not shift again; #19 removed the
    // questionnaire steps that used to sit between, so the raw values are now contiguous.
    case activation, forgot, forgotSent
}

/// How the activation screen was reached, which decides what it says and where its
/// tertiary action goes back to (#6).
enum ActivationOrigin {
    /// Sign-up just created the account and the email is on its way. "Change email"
    /// returns to sign-up with the address pre-filled.
    case signUp
    /// Log in was refused with `NOT_ACTIVATED` — the password was right, the address is
    /// not confirmed. The account exists, so the way back is to log in, not to sign up.
    case logIn
}

@Observable
final class OnboardingModel {
    var step: OnboardingStep = .createAccount

    // Email sign-up form. `email` is also what log in, forgot password and the
    // activation screen read and write — it is the address the whole public flow is
    // about, and the canvas pre-fills it across those screens.
    var email = ""
    var password = ""

    /// Set when `showActivation(after:)` routes here. Read by `back()` and the screen.
    private(set) var activationOrigin: ActivationOrigin = .signUp

    /// `initialStep` is where the flow opens: `.createAccount` for a first launch or a log out;
    /// the root passes `.logIn` when the session ended for a reason the user has to act
    /// on by signing back in (#59) — the account exists, so sign-up is the wrong door.
    init(startingAt initialStep: OnboardingStep = .createAccount) {
        step = initialStep
        #if DEBUG
        // Lets tooling (screenshots, previews) jump straight to a step:
        // SIMCTL_CHILD_EVA_ONBOARDING_STEP=2 xcrun simctl launch <udid> com.evaapp.ios
        // (0 createAccount, 1 logIn, 2 activation, 3 forgot, 4 forgotSent.)
        if let raw = ProcessInfo.processInfo.environment["EVA_ONBOARDING_STEP"],
           let value = Int(raw),
           let debugStep = OnboardingStep(rawValue: value) {
            step = debugStep
        }
        #endif
    }

    var isEmailValid: Bool {
        email.wholeMatch(of: /\S+@\S+\.\S+/) != nil
    }

    /// The rule the sign-up screen states up front: "At least 8 characters, including one
    /// number." (canvas, §6 helper text).
    ///
    /// `POST /auth/signup` now enforces the same rule and rejects a password that fails
    /// it with `WEAK_PASSWORD` (#20), so client and server state one rule, not two. This
    /// stays as the local check: the CTA should not need a round trip to enforce a rule
    /// the screen already states.
    var isPasswordValid: Bool {
        password.count >= 8 && password.contains(where: \.isNumber)
    }

    /// What enables the sign-up CTA. **The address alone** (#120): sign-up sends nothing
    /// else, because a credential set before the address is proven is the hole that issue
    /// closes. `isPasswordValid` still guards the log-in and reset forms, where a password
    /// is actually typed.
    var isEmailFormValid: Bool {
        isEmailValid
    }

    // MARK: - Navigation

    func chooseLogIn() { step = .logIn }

    func chooseCreateAccount() { step = .createAccount }

    func chooseForgotPassword() { step = .forgot }

    /// Routes to the activation gate. `email` and `password` are left as they are: the
    /// screen retries sign-in with them when the app comes back to the foreground, so
    /// clearing either would turn the retry into a request that cannot be made.
    func showActivation(after origin: ActivationOrigin) {
        activationOrigin = origin
        step = .activation
    }

    /// The back stack, plus where each auth screen's tertiary action returns to. The two
    /// main auth screens cross-link to each other instead — the canvas draws no back control
    /// on either — but `logIn` keeps an entry here so every step in the enum has one place
    /// it goes back to.
    func back() {
        switch step {
        case .logIn: step = .createAccount
        // "Change email" after sign-up, "Back to log in" after a refused log in. The
        // address stays in `email` either way, which is the canvas' pre-fill.
        case .activation:
            switch activationOrigin {
            case .signUp: step = .createAccount
            case .logIn: step = .logIn
            }
        // Both reset screens' "Back to log in". Link sent goes to log in rather than back
        // to the form: the request has been made, and the next thing to do is log in
        // with the new password once the website has set it.
        case .forgot, .forgotSent: step = .logIn
        case .createAccount: break
        }
    }

    func next() {
        switch step {
        case .forgot: step = .forgotSent
        case .forgotSent: step = .logIn
        case .createAccount, .logIn, .activation: break
        }
    }
}

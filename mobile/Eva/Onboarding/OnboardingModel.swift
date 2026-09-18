import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    // Public flow. The canvas draws authentication as one screen and gives each of the
    // two a cross-link to the other, so there is no public back stack and no public
    // header — #3 collapsed welcome / infoScience / infoSolution / signUp / emailSignUp
    // into `createAccount`.
    case createAccount, logIn
    // Questionnaire (post-auth). Still on legacy styling: the canvas puts these fields in
    // Profile, which does not exist yet — see DESIGN.md §9.
    case aboutYou, goals, health, lifestyle, done
    // The activation gate and password reset (#6). Appended rather than slotted in next
    // to the auth screens so the raw values 0–6 above keep meaning what
    // `EVA_ONBOARDING_STEP` tooling expects: 7 activation, 8 forgot, 9 forgotSent.
    case activation, forgot, forgotSent

    /// Index within the 4-step questionnaire, when applicable.
    var questionnaireIndex: Int? {
        switch self {
        case .aboutYou: 0
        case .goals: 1
        case .health: 2
        case .lifestyle: 3
        default: nil
        }
    }

    /// Whether this step is one of the canvas' auth screens, drawn on
    /// `EvaScreenBackground` — as opposed to the questionnaire on its legacy ground.
    var isAuthScreen: Bool {
        switch self {
        case .createAccount, .logIn, .activation, .forgot, .forgotSent: true
        case .aboutYou, .goals, .health, .lifestyle, .done: false
        }
    }
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

    // Questionnaire answers (PRD: date of birth, weight/height, goals, health, lifestyle,
    // sports, meds). `conditions` and `medications` hold **codes**, not the labels drawn on
    // the chips — see `ProfileOption`.
    var dateOfBirth = OnboardingModel.defaultDateOfBirth
    // **The canonical units, whatever the device is set to show** (#82). A weight typed as
    // 150 lb is stored here as 68.04, and switching the setting changes the screen and not
    // this. `Double` rather than `Int` because a kilogram is 2.2 lb: at whole kilograms,
    // 150 lb and 151 lb are the same stored number and both come back as 150. See
    // `EvaBodyUnits`.
    var weightKg = 64.0
    var heightCm = 168.0
    var goals: Set<String> = []
    var conditions: Set<String> = []
    var medications: String?
    var lifestyle: String?
    var sports: Set<String> = []

    static let goalOptions = ["Energy", "Sleep", "Fitness", "Nutrition", "Stress & mood", "Cycle health", "Focus", "Weight"]
    /// PRD §Sign Up, Profile fields 5 (A8) — the four the app shipped with, plus Diabetes,
    /// Coeliac disease and Food allergies. Codes are `users.ts`' `CONDITION_CODES`.
    static let conditionOptions = [
        ProfileOption("pcos", "PCOS"),
        ProfileOption("endometriosis", "Endometriosis"),
        ProfileOption("thyroidCondition", "Thyroid condition"),
        ProfileOption("anaemia", "Anaemia"),
        ProfileOption("diabetes", "Diabetes"),
        ProfileOption("coeliacDisease", "Coeliac disease"),
        ProfileOption("foodAllergies", "Food allergies"),
        ProfileOption("noneOfThese", "None of these"),
    ]
    /// PRD §Sign Up, Profile fields 4 (A8). This replaced a Yes/No/Not sure answer, which
    /// recorded that something was taken without recording what — and *which* hormonal
    /// medication is the whole of what the answer is for. Codes are `MEDICATION_CODES`.
    static let medicationOptions = [
        ProfileOption("combinedPill", "Combined pill"),
        ProfileOption("progestogenOnlyPill", "Progestogen-only pill"),
        ProfileOption("hormonalIud", "Hormonal IUD"),
        ProfileOption("implant", "Implant"),
        ProfileOption("hrt", "HRT"),
        ProfileOption("none", "None"),
    ]
    static let lifestyleOptions = ["Mostly sitting", "Lightly active", "Active", "Very active"]
    static let sportOptions = ["Strength", "Running", "Yoga", "Pilates", "Cycling", "Swimming", "Dancing", "Walking"]

    // MARK: - Date of birth and the 18+ floor (#81)

    /// Eva is 18 and over (PRD §Product frame, Age; A12). The API enforces the same number
    /// in `parseProfile` and is the enforcement; this is what puts the rule under the field
    /// instead of behind a refused request four screens later.
    static let minimumAgeYears = 18

    static let minimumAgeMessage = "You must be \(minimumAgeYears) or over to use Eva."

    /// Where the picker opens. An adult date rather than today's, so the control does not
    /// start on a value its own rule rejects — and not the floor either, which would read as
    /// a suggestion that being exactly 18 is the expected answer.
    static var defaultDateOfBirth: Date {
        Calendar.current.date(byAdding: .year, value: -28, to: Date.now) ?? Date.now
    }

    /// Whole years to today, in the user's own calendar and zone — which is the same
    /// measurement the API makes, because `profilePayload` sends `timeZone` and the server
    /// resolves her day from it rather than from UTC.
    var ageYears: Int {
        Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date.now).year ?? 0
    }

    var isOldEnough: Bool { ageYears >= Self.minimumAgeYears }

    /// `nil` until she has actually chosen a date that breaks the rule. The picker opens on
    /// an adult date, so a message shown before any interaction would be accusing her of
    /// something she has not done.
    var dateOfBirthError: String? { isOldEnough ? nil : Self.minimumAgeMessage }

    init() {
        #if DEBUG
        // Lets tooling (screenshots, previews) jump straight to a step:
        // SIMCTL_CHILD_EVA_ONBOARDING_STEP=2 xcrun simctl launch <udid> com.evaapp.ios
        // (0 createAccount, 1 logIn, 2 aboutYou, 3 goals, 4 health, 5 lifestyle, 6 done,
        //  7 activation, 8 forgot, 9 forgotSent — the raw values shifted when #3
        //  collapsed the five public screens into one; #6's three are appended so they
        //  did not shift again.)
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

    /// Questionnaire answers as the API payload.
    ///
    /// `timeZone` is sent so the 18+ floor is measured against *her* day. Without it the API
    /// falls back to the earliest day it could currently be anywhere, which is the safe
    /// direction for a floor and would refuse her on her own eighteenth birthday.
    var profilePayload: ProfilePayload {
        ProfilePayload(
            dateOfBirth: Self.wireDate(dateOfBirth),
            weightKg: weightKg,
            heightCm: heightCm,
            goals: goals.sorted(),
            conditions: conditions.sorted(),
            medications: medications ?? "",
            lifestyle: lifestyle ?? "",
            sports: sports.sorted(),
            timeZone: TimeZone.current.identifier
        )
    }

    /// `YYYY-MM-DD` in the user's own zone — a calendar label, never an instant, which is
    /// what the API stores. `en_US_POSIX` because a fixed format read under an arbitrary
    /// locale is the classic way to send a Buddhist-calendar year to a server expecting a
    /// Gregorian one.
    static func wireDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Progress across the 4 questionnaire steps: 25% → 100%.
    var questionnaireProgress: Double {
        guard let index = step.questionnaireIndex else { return 1 }
        return Double(index + 1) / 4
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

    /// Called after any successful authentication with an incomplete questionnaire.
    func startQuestionnaire() { step = .aboutYou }

    /// The questionnaire's back stack, plus where each auth screen's tertiary action
    /// returns to. The two main auth screens cross-link to each other instead — the
    /// canvas draws no back control on either — but `logIn` keeps an entry here so every
    /// step in the enum has one place it goes back to.
    func back() {
        switch step {
        case .logIn: step = .createAccount
        case .goals: step = .aboutYou
        case .health: step = .goals
        case .lifestyle: step = .health
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
        case .createAccount, .aboutYou, .done: break
        }
    }

    func next() {
        switch step {
        // The activation screen's foreground retry is the third way to sign in, so it
        // lands where the other two do.
        case .createAccount, .logIn, .activation: step = .aboutYou
        case .aboutYou: step = .goals
        case .goals: step = .health
        case .health: step = .lifestyle
        case .lifestyle: step = .done
        case .forgot: step = .forgotSent
        case .forgotSent: step = .logIn
        case .done: break
        }
    }
}

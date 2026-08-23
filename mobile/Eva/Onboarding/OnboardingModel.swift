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
}

@Observable
final class OnboardingModel {
    var step: OnboardingStep = .createAccount

    // Email sign-up form
    var email = ""
    var password = ""

    // Questionnaire answers (PRD: age, weight/height, goals, health, lifestyle, sports, meds)
    var age = 28
    var weightKg = 64
    var heightCm = 168
    var goals: Set<String> = []
    var conditions: Set<String> = []
    var medications: String?
    var lifestyle: String?
    var sports: Set<String> = []

    static let goalOptions = ["Energy", "Sleep", "Fitness", "Nutrition", "Stress & mood", "Cycle health", "Focus", "Weight"]
    static let conditionOptions = ["PCOS", "Endometriosis", "Thyroid condition", "Anemia", "None of these"]
    static let medicationOptions = ["Yes", "No", "Not sure"]
    static let lifestyleOptions = ["Mostly sitting", "Lightly active", "Active", "Very active"]
    static let sportOptions = ["Strength", "Running", "Yoga", "Pilates", "Cycling", "Swimming", "Dancing", "Walking"]

    init() {
        #if DEBUG
        // Lets tooling (screenshots, previews) jump straight to a step:
        // SIMCTL_CHILD_EVA_ONBOARDING_STEP=2 xcrun simctl launch <udid> com.evaapp.ios
        // (0 createAccount, 1 logIn, 2 aboutYou, 3 goals, 4 health, 5 lifestyle, 6 done —
        //  the raw values shifted when #3 collapsed the five public screens into one.)
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
    /// The API only enforces the length — `POST /auth/signup` rejects under 8 characters
    /// and says nothing about digits. The client is the stricter of the two on purpose:
    /// the canvas states the rule to the user, and helper text that the CTA then ignores
    /// is worse than a rule the server has not caught up with. Worth an API issue.
    var isPasswordValid: Bool {
        password.count >= 8 && password.contains(where: \.isNumber)
    }

    var isEmailFormValid: Bool {
        isEmailValid && isPasswordValid
    }

    /// Questionnaire answers as the API payload.
    var profilePayload: ProfilePayload {
        ProfilePayload(
            age: age,
            weightKg: weightKg,
            heightCm: heightCm,
            goals: goals.sorted(),
            conditions: conditions.sorted(),
            medications: medications ?? "",
            lifestyle: lifestyle ?? "",
            sports: sports.sorted()
        )
    }

    /// Progress across the 4 questionnaire steps: 25% → 100%.
    var questionnaireProgress: Double {
        guard let index = step.questionnaireIndex else { return 1 }
        return Double(index + 1) / 4
    }

    // MARK: - Navigation

    func chooseLogIn() { step = .logIn }

    func chooseCreateAccount() { step = .createAccount }

    /// Called after any successful authentication with an incomplete questionnaire.
    func startQuestionnaire() { step = .aboutYou }

    /// The questionnaire's back stack. The two auth screens cross-link to each other
    /// instead — the canvas draws no back control on either — but `logIn` keeps an entry
    /// here so every step in the enum has one place it goes back to.
    func back() {
        switch step {
        case .logIn: step = .createAccount
        case .goals: step = .aboutYou
        case .health: step = .goals
        case .lifestyle: step = .health
        case .createAccount, .aboutYou, .done: break
        }
    }

    func next() {
        switch step {
        case .createAccount, .logIn: step = .aboutYou
        case .aboutYou: step = .goals
        case .goals: step = .health
        case .health: step = .lifestyle
        case .lifestyle: step = .done
        case .done: break
        }
    }
}

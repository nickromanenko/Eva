import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    // Public flow
    case welcome, infoScience, infoSolution, signUp, emailSignUp
    // Questionnaire (post-auth)
    case aboutYou, goals, health, lifestyle, done

    /// Plain floating back button, no progress (public screens).
    var showsPublicHeader: Bool {
        switch self {
        case .infoScience, .infoSolution, .signUp, .emailSignUp: true
        default: false
        }
    }

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
    var step: OnboardingStep = .welcome

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
        // xcrun simctl launch --setenv EVA_ONBOARDING_STEP=3 ...
        if let raw = ProcessInfo.processInfo.environment["EVA_ONBOARDING_STEP"],
           let value = Int(raw),
           let debugStep = OnboardingStep(rawValue: value) {
            step = debugStep
        }
        #endif
    }

    var isEmailFormValid: Bool {
        email.wholeMatch(of: /\S+@\S+\.\S+/) != nil && password.count >= 8
    }

    /// Progress across the 4 questionnaire steps: 25% → 100%.
    var questionnaireProgress: Double {
        guard let index = step.questionnaireIndex else { return 1 }
        return Double(index + 1) / 4
    }

    // MARK: - Navigation

    func getStarted() { step = .infoScience }

    /// "Log in" / Apple / Google — auth is stubbed until the Firebase Auth phase;
    /// all of them land on the questionnaire.
    func authenticate() { step = .aboutYou }

    func chooseEmailSignUp() { step = .emailSignUp }

    func submitEmailForm() {
        guard isEmailFormValid else { return }
        authenticate()
    }

    func back() {
        switch step {
        case .infoScience: step = .welcome
        case .infoSolution: step = .infoScience
        case .signUp: step = .infoSolution
        case .emailSignUp: step = .signUp
        case .goals: step = .aboutYou
        case .health: step = .goals
        case .lifestyle: step = .health
        default: break
        }
    }

    func next() {
        switch step {
        case .welcome: step = .infoScience
        case .infoScience: step = .infoSolution
        case .infoSolution: step = .signUp
        case .signUp, .emailSignUp: step = .aboutYou
        case .aboutYou: step = .goals
        case .goals: step = .health
        case .health: step = .lifestyle
        case .lifestyle: step = .done
        case .done: break
        }
    }
}

import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, whyEva, signUp, aboutYou, goals, health, lifestyle, done

    /// Steps that show the back button + progress bar header.
    var showsHeader: Bool { self != .welcome && self != .done }
}

@Observable
final class OnboardingModel {
    var step: OnboardingStep = .welcome

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

    var progress: Double {
        Double(step.rawValue) / Double(OnboardingStep.done.rawValue)
    }

    func next() {
        if let following = OnboardingStep(rawValue: step.rawValue + 1) {
            step = following
        }
    }

    func back() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
            step = previous
        }
    }
}

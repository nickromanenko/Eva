import Foundation
import SwiftUI

/// The editable profile the Profile screen's personalisation rows work on (#19).
///
/// This is the questionnaire's collection state, moved out of `OnboardingModel` when the
/// wizard was deleted. It holds the same fields the API stores in `users/{uid}.profile`
/// (`APIProfile`), initialised from the account's existing profile or from the same
/// defaults a fresh questionnaire used to, and it produces the same bulk `ProfilePayload`
/// the wizard sent. The difference is *when* it sends: every row edit re-sends the whole
/// profile rather than walking a five-step flow, because #19 kept `PUT /me/questionnaire`
/// as the bulk write and added no per-field route.
@Observable
final class ProfileEditorModel {

    var dateOfBirth: Date
    /// **The canonical units, whatever the device is set to show** (#82). A weight typed as
    /// 150 lb is stored here as 68.04, and switching the setting changes the screen and not
    /// this. `Double` rather than `Int` because a kilogram is 2.2 lb: at whole kilograms,
    /// 150 lb and 151 lb are the same stored number and both come back as 150.
    var weightKg: Double
    var heightCm: Double
    var goals: Set<String>
    /// `conditions`, `medications` and `lifestyle` hold **codes**, not the labels drawn on
    /// the chips — see `ProfileOption`.
    var conditions: Set<String>
    var medications: String?
    var lifestyle: String?
    var sports: Set<String>

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
    /// PRD §Sign Up, Profile fields 4 (A8). One value out of a closed list, because *which*
    /// hormonal medication is the whole of what the answer is for. Codes are
    /// `MEDICATION_CODES`.
    static let medicationOptions = [
        ProfileOption("combinedPill", "Combined pill"),
        ProfileOption("progestogenOnlyPill", "Progestogen-only pill"),
        ProfileOption("hormonalIud", "Hormonal IUD"),
        ProfileOption("implant", "Implant"),
        ProfileOption("hrt", "HRT"),
        ProfileOption("none", "None"),
    ]
    /// PRD §Sign Up (A8) — the activity band (#221). Codes are `nutrition.ts`'
    /// `ACTIVITY_BANDS`, which the nutrition engine keys its activity factors by; the labels
    /// are the ones the chips have always drawn.
    static let lifestyleOptions = [
        ProfileOption("mostlySitting", "Mostly sitting"),
        ProfileOption("lightlyActive", "Lightly active"),
        ProfileOption("active", "Active"),
        ProfileOption("veryActive", "Very active"),
    ]
    static let sportOptions = ["Strength", "Running", "Yoga", "Pilates", "Cycling", "Swimming", "Dancing", "Walking"]

    init(profile: APIProfile?) {
        if let profile {
            dateOfBirth = Self.date(fromWire: profile.dateOfBirth) ?? Self.defaultDateOfBirth
            weightKg = profile.weightKg
            heightCm = profile.heightCm
            goals = Set(profile.goals)
            conditions = Set(profile.conditions)
            medications = profile.medications.isEmpty ? nil : profile.medications
            lifestyle = profile.lifestyle
            sports = Set(profile.sports)
        } else {
            dateOfBirth = Self.defaultDateOfBirth
            weightKg = 64.0
            heightCm = 168.0
            goals = []
            conditions = []
            medications = nil
            lifestyle = nil
            sports = []
        }
    }

    // MARK: - Date of birth and the 18+ floor (#81)

    /// Eva is 18 and over (PRD §Product frame, Age; A12). The API enforces the same number
    /// in `parseProfile` and is the enforcement; this is what puts the rule under the field
    /// instead of behind a refused request.
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

    /// `nil` until she has actually chosen a date that breaks the rule.
    var dateOfBirthError: String? { isOldEnough ? nil : Self.minimumAgeMessage }

    // MARK: - The medication question, which has to be answered (#215)

    /// The rule the medication editor states under the chips — up front, the way §6's
    /// password helper states its rule.
    static let medicationRule = "Choose one. None is an answer."

    /// Whether the medication question has an answer. It is one value out of a closed list
    /// with **no member for "unanswered"**: `parseProfile` refuses anything that is not a
    /// `MEDICATION_CODES` entry, and `profilePayload`'s `medications ?? ""` is not one of
    /// them. `conditions` is deliberately not held the same way: an empty list is a
    /// legitimate answer there.
    var hasMedicationAnswer: Bool { medications != nil }

    // MARK: - The activity band, which has to be answered too (#221)

    /// Whether the activity question has an answer — what the **Activity editor's** Save
    /// waits for, since saving that screen without picking a band would be saving nothing.
    /// Every other editor saves regardless: an unanswered band is left out of the body,
    /// which `parseProfile` accepts as unanswered (#221).
    var hasLifestyleAnswer: Bool { lifestyle != nil }

    /// The chip label for the stored code, or `nil` while unanswered — what the Profile
    /// row shows. Never the code itself.
    var lifestyleLabel: String? {
        Self.lifestyleOptions.first { $0.code == lifestyle }?.label
    }

    // MARK: - The payload

    /// The edited profile as the API body. `timeZone` is sent so the 18+ floor is measured
    /// against *her* day.
    var profilePayload: ProfilePayload {
        ProfilePayload(
            dateOfBirth: Self.wireDate(dateOfBirth),
            weightKg: weightKg,
            heightCm: heightCm,
            goals: goals.sorted(),
            conditions: conditions.sorted(),
            medications: medications ?? "",
            lifestyle: lifestyle,
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

    /// The inverse of `wireDate`: a stored `YYYY-MM-DD` back into the `Date` the picker
    /// reads, in the user's own zone. `nil` for a label the formatter cannot parse, which
    /// the caller falls back to the default for.
    static func date(fromWire string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

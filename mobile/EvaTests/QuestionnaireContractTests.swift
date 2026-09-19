import Foundation
import Testing
@testable import Eva

/// `api/src/users.ts`, found from this file rather than from the test bundle — the API's
/// sources are not in it. Same approach `CalendarPredictionTests` uses to reach the calendar
/// sources it scans.
///
/// Reading the API's own source is the point of it. A second copy of a list or a shape, kept
/// here, is a copy that drifts — and both #215 defects are that drift: one list the app and
/// the API agreed on, and one they silently did not.
private let apiUsersSource: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // EvaTests
    .deletingLastPathComponent()      // mobile
    .deletingLastPathComponent()      // repo root
    .appendingPathComponent("api/src/users.ts")

private func apiSource() throws -> String {
    try String(contentsOf: apiUsersSource, encoding: .utf8)
}

/// What the questionnaire is allowed to put on the wire (#215).
///
/// The API is the enforcement — `parseProfile` refuses a `medications` value outside
/// `MEDICATION_CODES` — and that is exactly the problem these cases exist for. A refusal that
/// only ever happens at the server arrives after Save, in the route's own words, and
/// `MedicationsSettingsView` answers it by holding Save until the question has an answer. So
/// the rule is checked here too, and checked against the list the server actually holds.
@Suite("Issue #215 · the questionnaire cannot submit a payload the API refuses")
struct QuestionnairePayloadTests {

    // MARK: - The health step's CTA

    @Test("an unanswered medication question holds the CTA")
    func unansweredMedicationHoldsTheCTA() {
        let model = ProfileEditorModel(profile: nil)
        #expect(!model.hasMedicationAnswer)
        // What the CTA would send if it were not held. The empty string is not one of
        // `MEDICATION_CODES`, so this is the 400 the gate exists to make unreachable. The
        // assertion is on the payload rather than on the flag, so a gate that stopped
        // describing what is actually sent would fail here.
        #expect(model.profilePayload.medications == "")
    }

    @Test("answering it releases the CTA and sends the code the chip carries")
    func answeringReleasesTheCTA() {
        let model = ProfileEditorModel(profile: nil)
        model.medications = "none"
        #expect(model.hasMedicationAnswer)
        #expect(model.profilePayload.medications == "none")
    }

    @Test("every chip the step draws releases the CTA")
    func everyChipReleasesTheCTA() {
        for option in ProfileEditorModel.medicationOptions {
            let model = ProfileEditorModel(profile: nil)
            model.medications = option.code
            #expect(model.hasMedicationAnswer, "\(option.code) left the CTA held")
        }
    }

    // MARK: - The chips and the API's vocabulary

    /// `MEDICATION_CODES` as `api/src/users.ts` declares it — read, for the reason
    /// `cycle.test.ts` reads two files to pin one number.
    static func apiMedicationCodes() throws -> [String] {
        let source = try apiSource()
        guard let list = source.firstMatch(of: /MEDICATION_CODES = \[([^\]]*)\]/)?.1 else {
            return []
        }
        return list.matches(of: /'([A-Za-z0-9_]+)'/).map { String($0.1) }
    }

    @Test("the pin is reading a list, not an empty match")
    func theAPIListIsActuallyRead() throws {
        // Named, so this fails if the constant is renamed or the file moves rather than
        // passing vacuously on an empty set — the way a derived list passes when it derives
        // as nothing.
        #expect(try Self.apiMedicationCodes().contains("combinedPill"),
                "\(apiUsersSource.path) no longer yields MEDICATION_CODES")
    }

    @Test("every medication chip carries a code the API accepts")
    func everyChipIsACodeTheAPIAccepts() throws {
        let accepted = Set(try Self.apiMedicationCodes())
        for option in ProfileEditorModel.medicationOptions {
            #expect(
                accepted.contains(option.code),
                """
                The "\(option.label)" chip sends \(option.code), which parseProfile refuses. \
                Codes are permanent (users.ts); the label is the half that changes.
                """
            )
        }
    }

    @Test("and the API accepts no code the step cannot draw")
    func theStepDrawsEveryCodeTheAPIAccepts() throws {
        let drawn = Set(ProfileEditorModel.medicationOptions.map(\.code))
        for code in try Self.apiMedicationCodes() {
            #expect(
                drawn.contains(code),
                "The API accepts \(code) and no chip offers it — she cannot give that answer."
            )
        }
    }
}

/// The other half of `APIUserDecodingTests.nullProfileDecodes`, and the half that was
/// missing (#215).
///
/// `profile: null` was pinned; a profile with something *in* it never was. So when #211 added
/// `timeZone` to `ProfilePayload` — the request body, which was also the type `APIUser`
/// decoded its profile with — nothing went red until an account actually had a profile. The
/// API reads `timeZone` to resolve which day it is where she is, and deliberately never
/// stores it, so the first response that carried a profile was the first one that would not
/// decode: `PUT /me/questionnaire` threw `.decoding` and left her on the last questionnaire
/// step under "Something went wrong", and every launch after that answered `GET /me` the same
/// way, which `bootstrap()` reads as `.unreachable`.
@Suite("Issue #215 · the profile the API actually sends")
struct APIProfileDecodingTests {

    /// A real `PUT /me/questionnaire` response, captured from the API on `main`, with the id
    /// and address replaced. Verbatim rather than minimised: what this suite is for is the
    /// difference between the shape the server sends and the shape the app expected, and a
    /// trimmed body would be a second opinion about that difference.
    private static let response = """
    {"user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true,\
    "profile":{"dateOfBirth":"1998-09-25","weightKg":64,"heightCm":168,"goals":["Energy"],\
    "conditions":["noneOfThese"],"medications":"none","lifestyle":"Active","sports":["Yoga"]},\
    "authProviders":["password"],"activated":true}}
    """

    private static func servedProfile() throws -> APIProfile {
        let response = try JSONDecoder().decode(
            UserResponse.self, from: Data(Self.response.utf8)
        )
        return try #require(response.user.profile)
    }

    /// What a profile entered in pounds and feet looks like coming back. `EvaBodyUnits`
    /// converts at the edge and stores SI (#82), so 150 lb and 5'8" are `68.04` and `172.72`
    /// on the wire — a TypeScript `number` the way the metric entry above is, and the reason
    /// `APIProfile` cannot type these as `Int`. Nothing in the JSON says which of the two a
    /// user typed, and nothing should.
    private static let imperialResponse = """
    {"user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true,\
    "profile":{"dateOfBirth":"1998-09-25","weightKg":68.04,"heightCm":172.72,"goals":[],\
    "conditions":[],"medications":"none","lifestyle":"Active","sports":[]},\
    "authProviders":["password"],"activated":true}}
    """

    @Test("it decodes, with no timeZone in it")
    func theServedProfileDecodes() throws {
        let profile = try Self.servedProfile()
        #expect(profile.dateOfBirth == "1998-09-25")
        #expect(profile.weightKg == 64)
        #expect(profile.heightCm == 168)
        #expect(profile.goals == ["Energy"])
        #expect(profile.conditions == ["noneOfThese"])
        #expect(profile.medications == "none")
        #expect(profile.lifestyle == "Active")
        #expect(profile.sports == ["Yoga"])
    }

    @Test("a body she typed in pounds and feet comes back fractional, and still decodes")
    func aConvertedProfileDecodes() throws {
        let response = try JSONDecoder().decode(
            UserResponse.self, from: Data(Self.imperialResponse.utf8)
        )
        let profile = try #require(response.user.profile)
        #expect(profile.weightKg == 68.04)
        #expect(profile.heightCm == 172.72)
    }

    /// The field names `users.ts` declares on `interface Profile`. Comment lines are dropped
    /// first, so prose inside the doc comments cannot be read as a field.
    static func apiProfileFields() throws -> [String] {
        let source = try apiSource()
        guard let block = source.firstMatch(of: /export interface Profile \{([\s\S]*?)\n\}/)?.1
        else { return [] }
        return block
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("*") && !$0.hasPrefix("/") }
            .compactMap { $0.firstMatch(of: /^([A-Za-z_]\w*)\??:/)?.1 }
            .map(String.init)
    }

    @Test("the pin is reading an interface, not an empty match")
    func theAPIInterfaceIsActuallyRead() throws {
        #expect(try Self.apiProfileFields().contains("dateOfBirth"),
                "\(apiUsersSource.path) no longer yields `interface Profile`")
    }

    /// The case that would have caught #211 on the day it landed, and the reason this file
    /// reads TypeScript at all: the captured body above pins the app against a response
    /// somebody copied once, and only this pins it against the response the API will send
    /// next time.
    @Test("APIProfile carries exactly the fields users.ts declares")
    func theShapeMatchesTheAPIsInterface() throws {
        let declared = Set(try Self.apiProfileFields())
        let decoded = Set(
            Mirror(reflecting: try Self.servedProfile()).children.compactMap(\.label)
        )
        #expect(
            decoded == declared,
            """
            APIProfile and users.ts' `Profile` have drifted apart — \
            only in Swift: \(decoded.subtracting(declared).sorted()), \
            only in TypeScript: \(declared.subtracting(decoded).sorted()). \
            A field the API sends and the app does not decode is data thrown away; a field \
            the app requires and the API does not send is every response failing to decode, \
            which is #215.
            """
        )
    }
}

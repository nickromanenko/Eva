import Foundation
import Testing
@testable import Eva

/// The API's sources, reached from this file the way `QuestionnaireContractTests` reaches
/// `users.ts` — a second copy of a list kept here would be a copy that drifts.
private let apiSourceDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // EvaTests
    .deletingLastPathComponent()      // mobile
    .deletingLastPathComponent()      // repo root
    .appendingPathComponent("api/src")

private func apiSource(_ file: String) throws -> String {
    try String(contentsOf: apiSourceDirectory.appendingPathComponent(file), encoding: .utf8)
}

/// `lifestyle` is an activity-band code, not the chip's label (#221).
///
/// The band is the one profile answer the nutrition engine does arithmetic with, so a label
/// the API could not map used to become `FACTORS[lifestyle] ?? 1.2` — a plausible calorie
/// target rather than an error. The API now refuses anything but a code on write, and reads
/// an old label as a code or as absent. These cases pin the app's half: it sends the code,
/// never `""`, and it reads a code, a `null` and a legacy label without failing `GET /me`.
@Suite("Issue #221 · lifestyle is an activity-band code")
struct LifestyleCodeTests {

    // MARK: - Writing

    private static func encoded(_ model: ProfileEditorModel) throws -> [String: Any] {
        let data = try JSONEncoder().encode(model.profilePayload)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("picking a chip sends its code, not its label")
    func aChipSendsItsCode() throws {
        let model = ProfileEditorModel(profile: nil)
        #expect(!model.hasLifestyleAnswer, "the Activity editor's Save is open before a band is picked")
        model.selectLifestyle(try #require(
            ProfileEditorModel.lifestyleOptions.first { $0.label == "Lightly active" }
        ))
        #expect(model.hasLifestyleAnswer, "picking a band left the Activity editor's Save held")
        #expect(try Self.encoded(model)["lifestyle"] as? String == "lightlyActive")
    }

    @Test("every chip stores a code the API accepts, and the row shows that chip's label")
    func everyChipRoundTrips() throws {
        let accepted = Set(try Self.apiActivityBands())
        for option in ProfileEditorModel.lifestyleOptions {
            let model = ProfileEditorModel(profile: nil)
            model.selectLifestyle(option)
            let sent = try Self.encoded(model)["lifestyle"] as? String
            #expect(sent.map(accepted.contains) == true, "the \(option.label) chip sent \(String(describing: sent))")
            #expect(model.activityRowValue == option.label)
        }
    }

    @Test("the Activity row is empty while unanswered, and never shows a code")
    func theRowShowsLabels() throws {
        #expect(ProfileEditorModel(profile: nil).activityRowValue == "")
        let model = ProfileEditorModel(profile: try Self.profile(lifestyle: #""mostlySitting""#))
        #expect(model.activityRowValue == "Mostly sitting")
    }

    @Test("an unanswered band is left out of the body, never sent as an empty string")
    func unansweredIsOmitted() throws {
        let model = ProfileEditorModel(profile: nil)
        #expect(!model.hasLifestyleAnswer)
        let body = try Self.encoded(model)
        #expect(body["lifestyle"] == nil, "lifestyle was sent as \(String(describing: body["lifestyle"]))")
    }

    @Test("saving another editor with the band unset sends no lifestyle, and the rest intact",
          arguments: ["null", #""Sedentary""#])
    func anotherEditorSavesWithTheBandUnset(served: String) throws {
        // Her stored band is one the API serves as unanswered — never set, or a pre-#221
        // label it could not map — and she saves Goals. The body must be one `parseProfile`
        // accepts: `lifestyle` absent (never `""`, never a guessed band), everything else sent.
        let model = ProfileEditorModel(profile: try Self.profile(lifestyle: served))
        model.goals.insert("Sleep")
        let body = try Self.encoded(model)
        #expect(body["lifestyle"] == nil, "lifestyle was sent as \(String(describing: body["lifestyle"]))")
        #expect(body["goals"] as? [String] == ["Sleep"])
        #expect(body["medications"] as? String == "none")
        #expect(body["dateOfBirth"] as? String == "1998-09-25")
    }

    // MARK: - Reading

    private static func profile(lifestyle: String) throws -> APIProfile {
        let json = """
        {"dateOfBirth":"1998-09-25","weightKg":64,"heightCm":168,"goals":[],\
        "conditions":[],"medications":"none","lifestyle":\(lifestyle),"sports":[]}
        """
        return try JSONDecoder().decode(APIProfile.self, from: Data(json.utf8))
    }

    @Test("a served code decodes as that code, and the row shows its label")
    func aCodeDecodes() throws {
        let profile = try Self.profile(lifestyle: #""veryActive""#)
        #expect(profile.lifestyle == "veryActive")
        #expect(ProfileEditorModel(profile: profile).lifestyleLabel == "Very active")
    }

    @Test("null decodes as unanswered, and the row shows nothing")
    func nullDecodes() throws {
        let profile = try Self.profile(lifestyle: "null")
        #expect(profile.lifestyle == nil)
        let model = ProfileEditorModel(profile: profile)
        #expect(!model.hasLifestyleAnswer)
        #expect(model.lifestyleLabel == nil)
    }

    @Test("an absent key decodes as unanswered")
    func absentDecodes() throws {
        let json = """
        {"dateOfBirth":"1998-09-25","weightKg":64,"heightCm":168,"goals":[],\
        "conditions":[],"medications":"none","sports":[]}
        """
        let profile = try JSONDecoder().decode(APIProfile.self, from: Data(json.utf8))
        #expect(profile.lifestyle == nil)
    }

    @Test("a legacy label from an API before #221 maps to its code", arguments: [
        ("Mostly sitting", "mostlySitting"),
        ("Lightly active", "lightlyActive"),
        ("Active", "active"),
        ("Very active", "veryActive"),
    ])
    func aLegacyLabelMaps(label: String, code: String) throws {
        #expect(try Self.profile(lifestyle: "\"\(label)\"").lifestyle == code)
    }

    @Test("anything else is unanswered, not guessed, and the account still decodes",
          arguments: [#""""#, #""active ""#, #""Sedentary""#, #""ACTIVE""#, "3"])
    func anythingElseIsUnanswered(raw: String) throws {
        #expect(try Self.profile(lifestyle: raw).lifestyle == nil)
    }

    // MARK: - The API's vocabulary

    /// `ACTIVITY_BANDS` as `nutrition.ts` declares it — the list `parseProfile` accepts.
    static func apiActivityBands() throws -> [String] {
        let source = try apiSource("nutrition.ts")
        guard let list = source.firstMatch(of: /ACTIVITY_BANDS = \[([^\]]*)\]/)?.1 else { return [] }
        return list.matches(of: /'([A-Za-z0-9_]+)'/).map { String($0.1) }
    }

    /// `LIFESTYLE_LABELS` as `users.ts` declares it — the labels the API maps on read.
    static func apiLegacyLabels() throws -> [String: String] {
        let source = try apiSource("users.ts")
        guard let block = source.firstMatch(of: /LIFESTYLE_LABELS[^=]*= new Map\(\[([\s\S]*?)\]\)/)?.1
        else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: block.matches(of: /\['([^']+)', '([^']+)'\]/)
                .map { (String($0.1), String($0.2)) }
        )
    }

    @Test("the pins are reading lists, not empty matches")
    func theAPIListsAreActuallyRead() throws {
        #expect(try Self.apiActivityBands().contains("mostlySitting"))
        #expect(try Self.apiLegacyLabels()["Active"] == "active")
    }

    @Test("the chips offer exactly the bands the API accepts")
    func theChipsMatchTheAPI() throws {
        #expect(
            ProfileEditorModel.lifestyleOptions.map(\.code) == (try Self.apiActivityBands())
        )
    }

    @Test("the app reads legacy labels by the same table the API does")
    func theLegacyTableMatchesTheAPI() throws {
        #expect(APIProfile.legacyLifestyleLabels == (try Self.apiLegacyLabels()))
    }
}

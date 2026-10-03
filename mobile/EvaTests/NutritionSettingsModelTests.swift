import Foundation
import Testing
@testable import Eva

/// Nutrition Settings (canvas `nSet`, #223): the preference is reversed here, by her, and by
/// nothing else (#212).
@MainActor
@Suite("Nutrition settings")
struct NutritionSettingsModelTests {

    @Test("Reading the screen writes nothing and shows what the server holds")
    func readingWritesNothing() async {
        let source = RecordingNutritionSource(
            profile: .partial(goal: .lose, step: .done, targetWeightKg: 60, hideNumbers: true)
        )
        let model = NutritionSettingsModel(source: source)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.hideNumbers)
        #expect(source.patches.isEmpty)
        #expect(Set(source.calls).isSubset(of: [.profile]))
    }

    @Test("Turning it off sends hideNumbers alone — no other answer moves with it")
    func turningOffSendsOnlyThePreference() async throws {
        let source = RecordingNutritionSource(
            profile: .partial(goal: .lose, step: .done, targetWeightKg: 60, hideNumbers: true)
        )
        let model = NutritionSettingsModel(source: source)
        await model.load()
        await model.setHideNumbers(false)

        #expect(!model.hideNumbers)
        let patch = try #require(source.patches.last)
        #expect(source.patches.count == 1)
        #expect(patch.hideNumbers == false)
        #expect(patch.goal == nil && patch.step == nil && patch.targetWeightKg == nil)
        #expect(patch.focusAreas == nil && patch.mealPattern == nil)
        #expect(source.stored.complete, "reversing the preference undid the setup")
    }

    @Test("A failed save puts the switch back where the server has it")
    func failedSaveReverts() async {
        let source = RecordingNutritionSource(
            profile: .partial(goal: .lose, step: .done, targetWeightKg: 60, hideNumbers: true)
        )
        let model = NutritionSettingsModel(source: source)
        await model.load()
        source.failsSave = true
        await model.setHideNumbers(false)
        #expect(model.hideNumbers, "the screen shows numbers the account still hides")
        #expect(model.errorMessage != nil)
    }

    @Test("Before setup has started, nothing is hidden by a preference she has not given")
    func noProfileIsOff() async {
        let model = NutritionSettingsModel(source: RecordingNutritionSource())
        await model.load()
        #expect(model.phase == .ready)
        #expect(!model.hideNumbers)
    }
}

/// The Body metrics row on Nutrition Settings (owner decision on #381): no height or weight
/// while the numbers are hidden.
@MainActor
@Suite("Nutrition settings · body metrics row")
struct NutritionSettingsBodyMetricsTests {

    private let body = APIProfile.body(weightKg: 64, heightCm: 168)

    @Test("Hidden numbers: the row names Profile and carries no value")
    func hiddenShowsNoValue() async {
        let model = NutritionSettingsModel(source: RecordingNutritionSource(
            profile: .partial(goal: .maintain, step: .done, hideNumbers: true)
        ))
        await model.load()
        for system in EvaUnitSystem.allCases {
            let value = model.bodyMetricsValue(body, system: system)
            #expect(value == "Set in Profile")
            #expect(value.rangeOfCharacter(from: .decimalDigits) == nil, "a number on the row: \(value)")
        }
    }

    @Test("Turned off by her, the values come back, in her units")
    func offShowsValues() async {
        let model = NutritionSettingsModel(source: RecordingNutritionSource(
            profile: .partial(goal: .maintain, step: .done, hideNumbers: true)
        ))
        await model.load()
        await model.setHideNumbers(false)
        #expect(model.bodyMetricsValue(body, system: .metric) == "168 cm · 64 kg")
        #expect(model.bodyMetricsValue(body, system: .imperial) == "5 ft 6 in · 141 lb")
    }

    @Test("Before the preference has loaded, and when it fails to, no value is shown")
    func unknownPreferenceShowsNoValue() async {
        let source = RecordingNutritionSource(
            profile: .partial(goal: .maintain, step: .done, hideNumbers: true)
        )
        let model = NutritionSettingsModel(source: source)
        #expect(model.bodyMetricsValue(body, system: .metric) == "Set in Profile", "before load")
        source.failsProfile = true
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.bodyMetricsValue(body, system: .metric) == "Set in Profile", "after a failed load")
    }
}

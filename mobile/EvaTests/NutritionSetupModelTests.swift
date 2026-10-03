import Foundation
import Testing
@testable import Eva

/// The Nutrition coach's setup flow (S3, #223), below the screen: units through the
/// conversion boundary, the skipped Step 5, the focus-area cap, the one qualitative
/// projection both triggers reach — and A31, as a test that can fail.
@MainActor
@Suite("Nutrition setup")
struct NutritionSetupModelTests {

    // MARK: - Units (#82): Step 4 and Step 5 in her units, SI on the wire

    @Test(
        "Step 4 confirms the stored metrics in the units setting, the band by its label",
        arguments: [
            (EvaUnitSystem.metric, "168 cm", "64 kg"),
            (.imperial, "5 ft 6 in", "141 lb"),
            (.stonesAndPounds, "5 ft 6 in", "10 st 1 lb"),
        ]
    )
    func stepFourFollowsTheUnits(system: EvaUnitSystem, height: String, weight: String) {
        let model = NutritionSetupModel(
            source: RecordingNutritionSource(body: .body(weightKg: 64, heightCm: 168)),
            units: .fixed(system)
        )
        #expect(model.heightText == height)
        #expect(model.weightText == weight)
        #expect(model.bandText == "Lightly active", "the band's code reached the screen")
    }

    @Test(
        "A target typed in her units is sent in kilograms, through EvaBodyUnits",
        arguments: [
            (EvaUnitSystem.metric, ["kilograms": "62,5"], 62.5),
            (.imperial, ["pounds": "150"], EvaBodyUnits.kilograms(fromPounds: 150)),
            (.stonesAndPounds, ["stones": "10", "pounds": "10"], EvaBodyUnits.kilograms(fromPounds: 150)),
        ]
    )
    func stepFiveSendsKilograms(system: EvaUnitSystem, typed: [String: String], kilograms: Double) async {
        let source = RecordingNutritionSource(profile: .partial(goal: .lose, step: .targetWeight))
        let model = NutritionSetupModel(source: source, units: .fixed(system))
        await model.load()
        #expect(model.step == .targetWeight)
        model.targetEntry.kilogramsText = typed["kilograms"] ?? ""
        model.targetEntry.stonesText = typed["stones"] ?? ""
        model.targetEntry.poundsText = typed["pounds"] ?? ""
        #expect(model.canFinish)

        await model.finish()

        #expect(source.patches.last?.targetWeightKg == kilograms)
        #expect(source.patches.last?.step == "done")
    }

    @Test("A target the API would refuse as out of range cannot be sent")
    func outOfRangeTargetIsNotSent() {
        var entry = NutritionTargetEntry(system: .stonesAndPounds)
        entry.stonesText = "10"
        entry.poundsText = "14"
        #expect(entry.kilograms == nil, "14 pounds is a stone, not a remainder")
        entry = NutritionTargetEntry(system: .metric)
        entry.kilogramsText = "25"
        #expect(entry.kilograms == nil)
    }

    @Test(
        "A guard's offered value rounds up in every unit, so it clears the floor it offers",
        arguments: [
            (EvaUnitSystem.metric, "52.2 kg"),
            (.imperial, "116 lb"),
            (.stonesAndPounds, "8 st 4 lb"),
        ]
    )
    func offeredValueClearsTheFloor(system: EvaUnitSystem, offered: String) async {
        let floor = 52.2
        let model = NutritionSetupModel(
            source: RecordingNutritionSource(profile: .partial(goal: .lose, step: .targetWeight)),
            units: .fixed(system)
        )
        let refusal = APINutritionRefusal(reason: "below-bmi-floor", lowestSupportedWeightKg: floor)
        #expect(model.offeredText(refusal) == offered)
        model.useOffered(refusal)
        // 115 lb is 52.16 kg — under the floor, and refused again. Rounding up is the point.
        #expect((model.targetEntry.kilograms ?? 0) >= floor)
    }

    // MARK: - Step 5 is skipped for goals 4 and 5 (PRD line 745)

    @Test("Goals 4 and 5 finish at Step 4: no target-weight step, no target weight sent",
          arguments: [APINutritionGoal.maintain, .eatBetter])
    func steadyGoalsSkipStepFive(goal: APINutritionGoal) async {
        let source = RecordingNutritionSource(body: .body(weightKg: 64, heightCm: 168))
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        await model.choose(goal)
        await model.advance()
        await model.chooseMeals(3)
        #expect(model.step == .bodyMetrics)
        #expect(model.isFinalStep, "the hide-numbers question would never be asked")

        await model.advance()

        #expect(source.patches.allSatisfy { $0.step != SetupStep.targetWeight.rawValue })
        #expect(source.patches.allSatisfy { $0.targetWeightKg == nil })
        #expect(source.patches.last?.step == "done")
        #expect(source.patches.last?.hideNumbers == false, "the preference was not asked on the path")
        #expect(model.phase == .summary)
    }

    @Test("A weight-change goal goes on to Step 5")
    func weightGoalReachesStepFive() async {
        let source = RecordingNutritionSource(profile: .partial(goal: .lose, step: .bodyMetrics))
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        #expect(!model.isFinalStep)
        await model.advance()
        #expect(model.step == .targetWeight)
        #expect(model.isFinalStep)
    }

    // MARK: - Focus areas cap at three (canvas `s2`)

    @Test("A fourth focus area is refused: three stay chosen, the rest stay listed and disabled")
    func focusAreasCapAtThree() async {
        let source = RecordingNutritionSource(profile: .partial(goal: .lose, step: .focusAreas))
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        let codes = NutritionFocusArea.all.map(\.code)
        for code in codes.prefix(4) {
            model.toggleFocusArea(code)
        }
        await model.advance()

        #expect(model.selectedFocusAreas == Array(codes.prefix(3)), "the oldest was swapped out")
        #expect(source.patches.compactMap(\.focusAreas).allSatisfy { $0.count <= 3 })
        #expect(source.stored.focusAreas == Array(codes.prefix(3)))
        let disabled = codes.filter(model.isFocusAreaDisabled)
        #expect(disabled.count == codes.count - 3, "the remainder must be listed and disabled")
        #expect(!model.isFocusAreaDisabled(codes[0]), "a chosen one can still be unchosen")
    }

    // MARK: - One qualitative projection, two triggers (#212, A28)

    @Test("The preference and A28's gate reach the same qualitative projection")
    func bothTriggersReachOneProjection() {
        let plan = APINutritionPlan.targets(.sample)
        let fromPreference = NutritionSummary.project(
            plan: plan, goal: .eatBetter, hideNumbers: true, modeGate: .none
        )
        for gate in [NutritionModeGate.pregnancy, .earlyPostpartum] {
            let fromMode = NutritionSummary.project(
                plan: plan, goal: .eatBetter, hideNumbers: false, modeGate: gate
            )
            guard case .qualitative(let a) = fromPreference, case .qualitative(let b) = fromMode else {
                Issue.record("\(gate) did not reach the qualitative projection")
                continue
            }
            #expect(a.goal == b.goal)
            #expect(a.guidance == b.guidance, "two triggers, two projections")
        }
        // The control: neither trigger, numbers.
        guard case .numbers = NutritionSummary.project(
            plan: plan, goal: .eatBetter, hideNumbers: false, modeGate: .none
        ) else {
            Issue.record("with no trigger the numbers were hidden — the assertion above proves nothing")
            return
        }
    }

    @Test("The qualitative projection's type carries no numeric field at all")
    func qualitativeTypeHasNoNumbers() {
        let value = NutritionQualitative(goal: .lose, guidance: ["a sentence"])
        let numeric = Mirror(reflecting: value).children.filter { Self.isNumeric($0.value) }
        #expect(numeric.isEmpty, "a number in the type is a number a screen can render")
        // The control: the numbers arm is caught by the same check.
        let numbers = NutritionNumbers(
            calorieTargetKcal: 1800, proteinG: 90, fatG: 60, carbG: 200, fibreG: 25,
            targetWeightKg: 60, timelineWeeks: 12
        )
        #expect(Mirror(reflecting: numbers).children.contains { Self.isNumeric($0.value) })
    }

    @Test("A weight-change goal is unavailable while A28 pauses it, and nothing is sent for it")
    func pregnancyPausesWeightGoals() async {
        let source = RecordingNutritionSource()
        let model = NutritionSetupModel(source: source, units: .fixed(.metric), modeGate: .pregnancy)
        await model.load()
        for goal in APINutritionGoal.allCases {
            #expect(model.isAvailable(goal) == !goal.isWeightChange, "\(goal)")
        }
        await model.choose(.lose)
        #expect(source.patches.isEmpty)
        #expect(model.step == .goal)
    }

    // MARK: - A31: Eva never infers the preference

    /// The pattern a heuristic would fire on — a falling weight across successive reads and
    /// a plan pinned at the 1,200 kcal floor — fed to the flow over many loads, then the whole
    /// setup finished. The preference must end where she left it, and the flow must have
    /// asked its source for nothing but its own three reads.
    @Test("Logging the pattern a heuristic would fire on leaves the preference unchanged")
    func a31NothingInfersThePreference() async {
        let source = RecordingNutritionSource(body: .body(weightKg: 72, heightCm: 168))
        source.plan = .targets(.floor)
        source.stored = .partial(goal: .lose, step: .done, targetWeightKg: 60, hideNumbers: false)

        for weight in stride(from: 72.0, through: 60.0, by: -2) {
            source.body = .body(weightKg: weight, heightCm: 168)
            let model = NutritionSetupModel(source: source, units: .fixed(.metric))
            await model.load()
            #expect(model.phase == .summary)
            guard case .numbers = model.summary else {
                Issue.record("the numbers were hidden at \(weight) kg without her asking")
                continue
            }
        }
        #expect(source.patches.isEmpty, "a read wrote something")
        #expect(source.stored.hideNumbers == false)
        #expect(Set(source.calls).isSubset(of: [.profile, .plan, .body]))

        // Her own action is the one thing that changes it — the control that shows this test
        // can see a change at all.
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        source.stored = .partial(goal: .lose, step: .targetWeight)
        await model.load()
        model.targetEntry.kilogramsText = "60"
        model.hideNumbers = true
        await model.finish()
        #expect(source.patches.compactMap(\.hideNumbers) == [true])
        guard case .qualitative = model.summary else {
            Issue.record("her own choice did not hide the numbers")
            return
        }
    }

    /// The case the loop above cannot see: a **default**. A fresh load at the last step, with
    /// no preference stored yet and every signal a heuristic would key on — a low weight, a
    /// falling one, a plan at the floor — must still start the toggle off. Nothing is set by
    /// the test before the check.
    @Test(
        "A31: with no stored preference, heuristic bait does not turn the toggle on",
        arguments: [
            (APINutritionGoal.lose, SetupStep.targetWeight),
            (.maintain, .bodyMetrics),
        ]
    )
    func a31TheDefaultIsNotInferred(goal: APINutritionGoal, step: SetupStep) async {
        let source = RecordingNutritionSource(
            profile: .partial(goal: goal, step: step, hideNumbers: nil),
            body: .body(weightKg: 48, heightCm: 168)
        )
        source.plan = .targets(.floor)
        for weight in [58.0, 54.0, 50.0, 48.0] {
            source.body = .body(weightKg: weight, heightCm: 168)
            let model = NutritionSetupModel(source: source, units: .fixed(.metric))
            await model.load()
            #expect(model.isFinalStep, "the preference is not asked on this step")
            #expect(model.hideNumbers == false, "the toggle started on at \(weight) kg — inferred")
        }
        // Finished untouched, what is saved is her untouched answer: off.
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        model.targetEntry.kilogramsText = "50"
        await model.finish()
        #expect(source.patches.last?.hideNumbers == false)
    }

    // MARK: - Failures

    @Test("A failed plan read on resume shows the retry state, never an endless spinner")
    func failedPlanOnResumeShowsRetry() async {
        let source = RecordingNutritionSource(
            profile: .partial(goal: .lose, step: .done, targetWeightKg: 60, hideNumbers: false)
        )
        source.failsPlan = true
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        #expect(model.phase == .failed)

        // And the retry works once the plan does.
        source.failsPlan = false
        await model.load()
        #expect(model.phase == .summary)
    }

    @Test("A failed save does not advance the step, and says so")
    func failedSaveDoesNotAdvance() async {
        let source = RecordingNutritionSource()
        source.failsSave = true
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()

        await model.choose(.lose)
        #expect(model.step == .goal, "advanced past an answer the server does not hold")
        #expect(model.errorMessage != nil)

        source.stored = .partial(goal: .lose, step: .mealPattern)
        await model.load()
        await model.chooseMeals(3)
        #expect(model.step == .mealPattern)
    }

    @Test("Focus-area saves are chained: the second starts only after the first finishes")
    func focusSavesKeepTheirOrder() async {
        let source = RecordingNutritionSource(profile: .partial(goal: .lose, step: .focusAreas))
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        source.holdsSaves = true
        let codes = NutritionFocusArea.all.map(\.code)

        model.toggleFocusArea(codes[0])
        model.toggleFocusArea(codes[1])
        await Self.settle { source.heldSaveCount == 1 }
        // Give an unchained second save every chance to start before checking it has not.
        for _ in 0..<20 { await Task.yield() }
        #expect(source.patches.count == 1, "the second save started while the first was open")

        source.releaseSave()
        await Self.settle { source.heldSaveCount == 1 && source.patches.count == 2 }
        source.releaseSave()
        source.holdsSaves = false
        await model.advance()

        #expect(source.patches.compactMap(\.focusAreas) == [[codes[0]], [codes[0], codes[1]]])
        #expect(source.stored.focusAreas == [codes[0], codes[1]])
    }

    @Test(
        "Resume shows her stored target in her units",
        arguments: [
            (EvaUnitSystem.metric, ["kilograms": "68"]),
            (.imperial, ["pounds": "150"]),
            (.stonesAndPounds, ["stones": "10", "pounds": "10"]),
        ]
    )
    func resumeRestoresTheTarget(system: EvaUnitSystem, shown: [String: String]) async {
        let stored = EvaBodyUnits.kilograms(fromPounds: 150)  // 68.04 kg, typed as 150 lb
        let source = RecordingNutritionSource(
            profile: .partial(goal: .lose, step: .targetWeight, targetWeightKg: stored)
        )
        let model = NutritionSetupModel(source: source, units: .fixed(system))
        await model.load()
        #expect(model.targetEntry.kilogramsText == shown["kilograms"] ?? "")
        #expect(model.targetEntry.stonesText == shown["stones"] ?? "")
        #expect(model.targetEntry.poundsText == shown["pounds"] ?? "")
        // Imperial round-trips exactly; metric shows whole kilograms of the same value.
        if system != .metric {
            #expect(model.targetEntry.kilograms == stored)
        }
    }

    // MARK: - The plan route's adjustment (#224) and the summary's status row (canvas `sSum`)

    @Test("The adjustment is read beside the targets, and the adjusted number is the one shown")
    func adjustmentDecodesBesideTargets() throws {
        let body = Data("""
            {"plan":{"kind":"targets","targets":{"bmrKcal":1400,"tdeeKcal":1925,\
            "calorieTargetKcal":1636,"macros":{"proteinG":102,"fatG":55,"carbG":180,"fibreG":25},\
            "weightPlan":null},"adjustment":{"calorieTargetKcal":1718,\
            "reasonId":"luteal_adjustment","confidence":"narrow"}}}
            """.utf8)
        let plan = try JSONDecoder().decode(APINutritionPlanResponse.self, from: body).plan
        guard case .numbers(let numbers) = NutritionSummary.project(
            plan: plan, goal: .maintain, hideNumbers: false, modeGate: .none
        ) else {
            Issue.record("targets did not project to numbers")
            return
        }
        #expect(numbers.calorieTargetKcal == 1718, "the engine's number was shown, not the adjusted one")
        #expect(numbers.cycleAdjustment == .luteal(confidence: "narrow"))
    }

    @Test(
        "The status says what the route served, and no number",
        arguments: [
            (APINutritionAdjustment(calorieTargetKcal: 1718, reasonId: "luteal_adjustment", confidence: "wide"),
             NutritionCycleAdjustment.luteal(confidence: "wide")),
            (APINutritionAdjustment(calorieTargetKcal: 1636, reasonId: nil, confidence: nil),
             NutritionCycleAdjustment.none),
        ]
    )
    func adjustmentStatus(adjustment: APINutritionAdjustment, expected: NutritionCycleAdjustment) {
        let status = NutritionCycleAdjustment(adjustment)
        #expect(status == expected)
        #expect(status.status.rangeOfCharacter(from: .decimalDigits) == nil, "the status restates a number")
        if case .luteal(confidence: "wide") = status {
            #expect(status.status.contains("wide"), "a wide-band phase reads as a certainty")
        }
    }

    @Test("A28's qualitative plan decodes as one, never as targets")
    func qualitativePlanDecodes() throws {
        let body = Data(#"{"plan":{"kind":"qualitative"}}"#.utf8)
        let plan = try JSONDecoder().decode(APINutritionPlanResponse.self, from: body).plan
        guard case .qualitative = NutritionSummary.project(
            plan: plan, goal: .eatBetter, hideNumbers: false, modeGate: .none
        ) else {
            Issue.record("the route's qualitative answer drew numbers")
            return
        }
    }

    // MARK: - The disclaimer (#374)

    @Test("The summary's disclaimer claims no dietitian review, and points to one instead")
    func disclaimerClaimsNoReview() {
        let line = NutritionSetupView.disclaimer
        #expect(!line.localizedCaseInsensitiveContains("reviewed by"), "the review claim is back")
        #expect(line.contains("does not replace personalized advice from a doctor or registered dietitian"))
    }

    // MARK: - Resume (canvas `sResume`)

    @Test("A started setup resumes on the card, listing what is done and what remains")
    func startedSetupResumesOnTheCard() async {
        let source = RecordingNutritionSource(profile: .partial(goal: .lose, step: .bodyMetrics))
        let model = NutritionSetupModel(source: source, units: .fixed(.metric))
        await model.load()
        #expect(model.phase == .resuming)
        #expect(!source.calls.contains(.plan), "a partial setup asked for a plan")
        #expect(model.resumeSteps.map(\.isDone) == [true, true, true, false, false])
        #expect(
            NutritionSetupView.resumeSentence(model.resumeSteps)
                .hasSuffix("Two steps remain before Eva can show any targets.")
        )
        model.continueSetup()
        #expect(model.phase == .editing)
        #expect(model.step == .bodyMetrics)
    }

    @Test("Goals without a target weight do not list it as remaining; a fresh setup has no card")
    func resumeListsOnlyHerPath() async {
        let model = NutritionSetupModel(
            source: RecordingNutritionSource(profile: .partial(goal: .maintain, step: .mealPattern)),
            units: .fixed(.metric)
        )
        await model.load()
        #expect(model.resumeSteps.map(\.step) == [.goal, .focusAreas, .mealPattern, .bodyMetrics])

        let fresh = NutritionSetupModel(source: RecordingNutritionSource(), units: .fixed(.metric))
        await fresh.load()
        #expect(fresh.phase == .editing, "nothing started, nothing to resume")
    }

    // MARK: - Support

    /// Yields until `condition` holds, bounded so a broken chain fails rather than hangs.
    private static func settle(_ condition: () -> Bool) async {
        var spins = 0
        while !condition() && spins < 1_000 {
            await Task.yield()
            spins += 1
        }
    }

    private static func isNumeric(_ value: Any) -> Bool {
        if value is Double || value is Int || value is Float { return true }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return false }
        return mirror.children.first.map { isNumeric($0.value) } ?? (
            value is Double? || value is Int? || value is Float?
        )
    }
}

// MARK: - A recording source

/// A `NutritionSource` that keeps one profile in memory, merges patches into it the way the
/// route does, and records every call — the A31 test's witness.
@MainActor
final class RecordingNutritionSource: NutritionSource {

    enum Call: Hashable { case body, profile, save, plan }

    private(set) var calls: [Call] = []
    private(set) var patches: [APINutritionProfilePatch] = []
    /// What the route would serve. Assigning it starts the setup, as a first save does.
    var stored: APINutritionProfile { didSet { started = true } }
    var body: APIProfile?
    var plan: APINutritionPlan = .targets(.sample)
    private var started: Bool

    /// Make the next calls fail the way an offline or 503 answer does.
    var failsProfile = false
    var failsSave = false
    var failsPlan = false
    /// While set, each save suspends after it is recorded until `releaseSave()` — so a test
    /// can see whether a second save *started* while the first was still open.
    var holdsSaves = false
    private var heldSaves: [CheckedContinuation<Void, Never>] = []

    struct Unavailable: Error {}

    /// Lets the oldest held save finish.
    func releaseSave() {
        guard !heldSaves.isEmpty else { return }
        heldSaves.removeFirst().resume()
    }

    var heldSaveCount: Int { heldSaves.count }

    init(profile: APINutritionProfile? = nil, body: APIProfile? = .body(weightKg: 64, heightCm: 168)) {
        started = profile != nil
        stored = profile ?? .partial(goal: nil, step: .goal)
        self.body = body
    }

    var bodyProfile: APIProfile? {
        calls.append(.body)
        return body
    }

    func nutritionProfile() async throws -> APINutritionProfile? {
        calls.append(.profile)
        if failsProfile { throw Unavailable() }
        return started ? stored : nil
    }

    func saveNutritionProfile(_ patch: APINutritionProfilePatch) async throws -> APINutritionProfile {
        calls.append(.save)
        patches.append(patch)
        if holdsSaves {
            await withCheckedContinuation { heldSaves.append($0) }
        }
        if failsSave { throw Unavailable() }
        started = true
        stored = APINutritionProfile(
            goal: patch.goal ?? stored.goal,
            focusAreas: patch.focusAreas ?? stored.focusAreas,
            mealPattern: patch.mealPattern ?? stored.mealPattern,
            targetWeightKg: patch.targetWeightKg ?? stored.targetWeightKg,
            hideNumbers: patch.hideNumbers ?? stored.hideNumbers,
            step: patch.step ?? stored.step,
            complete: (patch.step ?? stored.step) == SetupStep.done.rawValue
        )
        return stored
    }

    func nutritionPlan(timeZone: TimeZone) async throws -> APINutritionPlan {
        calls.append(.plan)
        if failsPlan { throw Unavailable() }
        return plan
    }
}

extension APINutritionProfile {
    static func partial(
        goal: APINutritionGoal?,
        step: SetupStep,
        targetWeightKg: Double? = nil,
        hideNumbers: Bool? = nil
    ) -> APINutritionProfile {
        APINutritionProfile(
            goal: goal,
            focusAreas: [],
            mealPattern: goal == nil ? nil : APIMealPattern(mealsPerDay: 3, snacks: false, mealTimes: nil),
            targetWeightKg: targetWeightKg,
            hideNumbers: hideNumbers,
            step: step.rawValue,
            complete: step == .done
        )
    }
}

extension APIProfile {
    static func body(weightKg: Double, heightCm: Double) -> APIProfile {
        APIProfile(
            dateOfBirth: "1994-03-01", weightKg: weightKg, heightCm: heightCm,
            goals: [], conditions: [], medications: "", lifestyle: "lightlyActive", sports: []
        )
    }
}

extension APINutritionTargets {
    static let sample = APINutritionTargets(
        bmrKcal: 1400, tdeeKcal: 1925, calorieTargetKcal: 1636,
        macros: APIMacroTargets(proteinG: 102, fatG: 55, carbG: 180, fibreG: 25),
        weightPlan: APIWeightPlan(targetWeightKg: 60, timelineWeeks: 16, paceKgPerWeek: 0.4)
    )

    /// A plan pinned at the 1,200 kcal floor — the "low-calorie day" a heuristic would key on.
    static let floor = APINutritionTargets(
        bmrKcal: 1200, tdeeKcal: 1400, calorieTargetKcal: 1200,
        macros: APIMacroTargets(proteinG: 96, fatG: 40, carbG: 120, fibreG: 25),
        weightPlan: APIWeightPlan(targetWeightKg: 60, timelineWeeks: 30, paceKgPerWeek: 0.4)
    )
}

extension EvaUnitPreference {
    /// A preference fixed to one system, in a defaults domain nothing else reads.
    static func fixed(_ system: EvaUnitSystem) -> EvaUnitPreference {
        let defaults = UserDefaults(suiteName: "eva.nutrition.tests.\(UUID().uuidString)")!
        let preference = EvaUnitPreference(defaults: defaults, locale: Locale(identifier: "en_GB"))
        preference.choose(system)
        return preference
    }
}

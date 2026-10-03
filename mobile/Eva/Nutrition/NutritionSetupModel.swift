import Foundation
import Observation

/// The Nutrition coach's setup flow (S3, #223): the state machine behind the five steps, the
/// guard cards and the plan summary.
///
/// **The plan summary is one of two projections** (#212, A31), and the qualitative one has no
/// numeric field at all — the same `toCycleEstimate` shape, where a screen *cannot* render a
/// number the type never carried. The two triggers are the hide-numbers preference and A28's
/// Pregnancy/postpartum mode; both reach this one projection, not two mechanisms.
///
/// **A31.** Its only dependency is a `NutritionSource`, which cannot read her logging
/// history; the preference changes only from the toggle she flips (`hideNumbers`) and is
/// saved only with the step she finishes. See `NutritionSource`.
@MainActor
@Observable
final class NutritionSetupModel {

    enum Phase {
        case loading
        /// A setup she started and left (canvas `sResume`): what is done, what remains, and
        /// nothing calculated from it until she continues.
        case resuming
        case editing
        case summary
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var profile: APINutritionProfile?
    private(set) var plan: APINutritionPlan?
    /// The one error the whole flow shows; the user's answer stays editable.
    private(set) var errorMessage: String?

    /// The current step, from the API's own codes (Edge case 1: resume where she left off).
    private(set) var step: SetupStep = .goal

    /// Step 5's draft answer, in her units (#82), and the hide-numbers preference (#212) —
    /// asked on the path, on whichever step ends it (Step 5, or Step 4 for goals 4 and 5).
    var targetEntry: NutritionTargetEntry
    var hideNumbers: Bool = false

    var showCalculation = false

    /// A28's trigger (Pregnancy, the first six postpartum weeks). Nothing supplies it yet:
    /// the account has no stored mode until D10, so every caller passes `.none` today. It is
    /// an input here so the projection is built once and both triggers reach it.
    let modeGate: NutritionModeGate

    private let source: any NutritionSource
    private let units: EvaUnitPreference

    init(
        source: any NutritionSource,
        units: EvaUnitPreference,
        modeGate: NutritionModeGate = .none
    ) {
        self.source = source
        self.units = units
        self.modeGate = modeGate
        targetEntry = NutritionTargetEntry(system: units.system)
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            let profile = try await source.nutritionProfile()
            self.profile = profile
            self.hideNumbers = profile?.hideNumbers ?? false
            self.selectedFocusAreas = profile?.focusAreas ?? []
            self.step = profile.map(Self.step(for:)) ?? .goal
            // Units follow the setting in force now, not the one she typed in last time.
            targetEntry = NutritionTargetEntry(system: units.system)
            if let stored = profile?.targetWeightKg {
                targetEntry.set(kilograms: stored)
            }
            if profile?.complete == true {
                await showSummary()
            } else if let profile, Self.step(for: profile) != .goal {
                // Started and left: say where she is before putting her back in a step.
                phase = .resuming
            } else {
                phase = .editing
            }
        } catch {
            phase = .failed
        }
    }

    // MARK: Resuming (canvas `sResume`)

    /// The steps on her path, each with whether it is behind her. Step 5 is left out when
    /// her goal has no target weight (PRD line 745) — it is not a step that remains.
    var resumeSteps: [ResumeStep] {
        SetupStep.allCases
            .filter { $0 != .done && !($0 == .targetWeight && isSkippingTargetWeight) }
            .map { ResumeStep(step: $0, isDone: $0.ordinal < step.ordinal) }
    }

    /// Back into the step she left, with her answers as they were saved.
    func continueSetup() {
        phase = .editing
    }

    /// Clears the one error line once she acts again.
    private func clearError() { errorMessage = nil }

    // MARK: Steps

    func choose(_ goal: APINutritionGoal) async {
        // A28 (canvas `sPreg`): a weight-change goal is not offered while it is paused.
        guard isAvailable(goal) else { return }
        guard await save(APINutritionProfilePatch(goal: goal, step: SetupStep.focusAreas.rawValue))
        else { return }
        step = .focusAreas
    }

    /// Whether a goal can be chosen now. Weight-change goals are unavailable in Pregnancy and
    /// the first six postpartum weeks (PRD line 757); the stored goal is left as it was —
    /// retained, never cleared and never restored by this model.
    func isAvailable(_ goal: APINutritionGoal) -> Bool {
        modeGate == .none || !goal.isWeightChange
    }

    /// Her focus areas as the screen shows them — updated on the tap, not on the save's
    /// answer, so two quick taps cannot each start from the list before the other.
    private(set) var selectedFocusAreas: [String] = []
    /// The focus-area saves, chained so they reach the server in the order she tapped.
    private var focusSave: Task<Void, Never>?

    /// The canvas `s2` cap (PRD line 726). At three the rest stay visible and disabled —
    /// never silently swapped — and the API refuses a fourth as well (#221).
    static let maxFocusAreas = 3

    func isFocusAreaDisabled(_ code: String) -> Bool {
        !selectedFocusAreas.contains(code) && selectedFocusAreas.count >= Self.maxFocusAreas
    }

    func toggleFocusArea(_ code: String) {
        if let index = selectedFocusAreas.firstIndex(of: code) {
            selectedFocusAreas.remove(at: index)
        } else if selectedFocusAreas.count < Self.maxFocusAreas {
            selectedFocusAreas.append(code)
        } else {
            return
        }
        let areas = selectedFocusAreas
        let previous = focusSave
        focusSave = Task {
            await previous?.value
            await save(APINutritionProfilePatch(focusAreas: areas))
        }
    }

    func chooseMeals(_ count: Int) async {
        guard await save(APINutritionProfilePatch(
            mealPattern: APIMealPattern(mealsPerDay: count, snacks: false, mealTimes: nil),
            step: SetupStep.bodyMetrics.rawValue
        )) else { return }
        step = .bodyMetrics
    }

    func advance() async {
        // A focus-area save still in flight lands before the step marker moves past it.
        await focusSave?.value
        let next = step.next(skippingTargetWeight: isSkippingTargetWeight)
        guard next != .done else {
            // The last step finishes rather than advancing to an empty `.done` screen.
            await finish()
            return
        }
        guard await save(APINutritionProfilePatch(step: next.rawValue)) else { return }
        step = next
    }

    /// Goals 4 and 5 have no target weight (PRD line 745): Step 5 is skipped entirely — and
    /// so is it for every goal while A28 pauses weight change.
    var isSkippingTargetWeight: Bool {
        guard let goal = profile?.goal else { return false }
        return !goal.isWeightChange || modeGate != .none
    }

    /// Whether the current step is the last one, which is where the hide-numbers question is
    /// asked (#212: on the path, so everyone meets it — including goals 4 and 5, whose path
    /// ends at Step 4).
    var isFinalStep: Bool {
        step == .targetWeight || (step == .bodyMetrics && isSkippingTargetWeight)
    }

    /// Whether the last step's answers are complete enough to send.
    var canFinish: Bool {
        isSkippingTargetWeight || targetEntry.kilograms != nil
    }

    /// Saves the last step — the target in kilograms, whatever she typed it in, and the
    /// preference exactly as she left the toggle — then reads the plan.
    func finish() async {
        var patch = APINutritionProfilePatch(hideNumbers: hideNumbers, step: SetupStep.done.rawValue)
        if !isSkippingTargetWeight {
            guard let kilograms = targetEntry.kilograms else { return }
            patch.targetWeightKg = kilograms
        }
        guard await save(patch) else { return }
        await showSummary()
    }

    /// A guard's offered value, in her units, into the field — which stays editable.
    func useOffered(_ refusal: APINutritionRefusal) {
        targetEntry.set(kilograms: refusal.lowestSupportedWeightKg, atLeast: true)
    }

    /// The offered value as the guard's button states it, rounded the way `useOffered` fills it.
    func offeredText(_ refusal: APINutritionRefusal) -> String {
        targetEntry.display(kilograms: refusal.lowestSupportedWeightKg, atLeast: true)
    }

    func back() {
        clearError()
        guard var previous = step.previous else { return }
        if previous == .targetWeight, isSkippingTargetWeight { previous = .bodyMetrics }
        step = previous
    }

    // MARK: Body metrics (Step 4, confirmation)

    // In her units (#82), through the conversion boundary — the stored values are SI.

    /// Her age, from the date of birth on the Sign Up profile — never asked twice (canvas
    /// `s4`). `nil` when there is no profile or the date does not parse.
    var ageYears: Int? {
        guard let wire = source.bodyProfile?.dateOfBirth,
              let birth = ProfileEditorModel.date(fromWire: wire)
        else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: .now).year
    }

    /// Her band's code, so Step 4 can mark it among the four.
    var bandCode: String? { source.bodyProfile?.lifestyle }

    var heightText: String {
        guard let profile = source.bodyProfile else { return "Height not set" }
        return EvaHeightInput(centimeters: profile.heightCm, system: units.system).displayText
    }

    var weightText: String {
        guard let profile = source.bodyProfile else { return "Weight not set" }
        return EvaMassInput(kilograms: profile.weightKg, system: units.system).displayText
    }

    /// The band's label, never its code.
    var bandText: String {
        guard let code = source.bodyProfile?.lifestyle,
              let option = ProfileEditorModel.lifestyleOptions.first(where: { $0.code == code })
        else { return "activity not set" }
        return option.label
    }

    /// Her current weight, as Step 5's read-only "Current" shows it.
    var currentWeightText: String? {
        source.bodyProfile.map {
            EvaMassInput(kilograms: $0.weightKg, system: units.system).displayText
        }
    }

    // MARK: The plan summary

    func showSummary() async {
        do {
            plan = try await source.nutritionPlan(timeZone: .current)
            if case .refused = plan {
                // The target the plan refused brings her back to Step 5, with the guard's
                // offered value on screen and the field still editable (canvas `sGuard`).
                phase = .editing
                step = .targetWeight
            } else {
                errorMessage = nil
                phase = .summary
            }
        } catch {
            errorMessage = "Your plan couldn't be prepared. Try again."
            // Reached from `load()`, there is no step on screen to show the error under.
            if phase == .loading { phase = .failed }
        }
    }

    var refusal: APINutritionRefusal? {
        guard case .refused(let refusal) = plan else { return nil }
        return refusal
    }

    /// One of two projections (#212, A31): hiding the numbers, or A28's Pregnancy/postpartum
    /// mode, leaves the qualitative arm — which has no numeric field at all.
    ///
    /// Driven by the **stored** preference, not the toggle's draft: what hides the numbers is
    /// what the server holds, so a relaunch cannot show them again.
    var summary: NutritionSummary {
        NutritionSummary.project(
            plan: plan,
            goal: profile?.goal ?? .maintain,
            hideNumbers: profile?.hideNumbers == true,
            modeGate: modeGate
        )
    }

    // MARK: Saving

    /// Saves one patch. `false` when it failed, so a step never advances past an answer the
    /// server does not hold.
    @discardableResult
    private func save(_ patch: APINutritionProfilePatch) async -> Bool {
        do {
            let saved = try await source.saveNutritionProfile(patch)
            profile = saved
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Your answer couldn't be saved. Try again."
            return false
        }
    }

    private static func step(for profile: APINutritionProfile) -> SetupStep {
        SetupStep(rawValue: profile.step) ?? .goal
    }
}

/// One line of the resume card: a step on her path, and whether it is behind her.
struct ResumeStep: Identifiable, Equatable {
    let step: SetupStep
    let isDone: Bool

    var id: SetupStep { step }
}

/// A28's restriction on the Nutrition coach (canvas `sPreg`, PRD line 757): weight-change
/// goals and the numbers are paused in Pregnancy and the first six postpartum weeks.
///
/// Its own type rather than `EvaMode`, because "postpartum" is not the trigger — the first
/// six weeks are, and nothing on the device knows the week yet. D10 stores the mode; until
/// then nothing produces anything but `.none`.
enum NutritionModeGate: Equatable, Sendable {
    case none
    case pregnancy
    case earlyPostpartum
}

extension APINutritionGoal {
    /// PRD Step 1 options 1–3, the goals Step 5 asks a target weight for (line 745).
    var isWeightChange: Bool {
        switch self {
        case .lose, .gain, .buildMuscle: true
        case .maintain, .eatBetter: false
        }
    }
}

extension NutritionSummary {
    /// The one projection both triggers reach (#212): the preference, or A28's gate.
    static func project(
        plan: APINutritionPlan?,
        goal: APINutritionGoal,
        hideNumbers: Bool,
        modeGate: NutritionModeGate
    ) -> NutritionSummary {
        let qualitative = NutritionQualitative(goal: goal, guidance: [
            "Focus on your goal and how you feel, not the numbers.",
            "Log your meals and Eva will keep you on track.",
        ])
        switch plan {
        case .targets(let targets) where !hideNumbers && modeGate == .none:
            return .numbers(numbers(from: targets))
        case .targets, .qualitative:
            // The route's own A28 answer and her preference reach the same arm.
            return .qualitative(qualitative)
        case .refused, nil:
            return .qualitative(NutritionQualitative(goal: goal, guidance: []))
        }
    }

    private static func numbers(from targets: APINutritionTargets) -> NutritionNumbers {
        NutritionNumbers(
            // The adjusted number is the one the UI shows (`NutritionAdjustment`'s own
            // contract); the engine's stands when the route served no adjustment.
            calorieTargetKcal: targets.adjustment?.calorieTargetKcal ?? targets.calorieTargetKcal,
            proteinG: targets.macros.proteinG,
            fatG: targets.macros.fatG,
            carbG: targets.macros.carbG,
            fibreG: targets.macros.fibreG,
            targetWeightKg: targets.weightPlan?.targetWeightKg,
            timelineWeeks: targets.weightPlan?.timelineWeeks,
            cycleAdjustment: targets.adjustment.map(NutritionCycleAdjustment.init)
        )
    }
}

/// The summary's cycle-adjustment **status** (canvas `sSum`, "Cycle-aware adjustment") — a
/// state, never the number it moved.
///
/// Two states, because the route serves two: an adjustment with a reason and the phase
/// confidence it was read with, or none. `none` covers both "not luteal today" and "no phase
/// estimate at all" — the route answers both the same way (`APINutritionAdjustment`), so
/// the copy for it must be true of either.
enum NutritionCycleAdjustment: Equatable, Sendable {
    case luteal(confidence: String?)
    case none

    init(_ adjustment: APINutritionAdjustment) {
        self = adjustment.reasonId == APINutritionAdjustment.lutealReason
            ? .luteal(confidence: adjustment.confidence)
            : .none
    }
}

/// The API's setup-progress marker, as the app's own enum — a code rather than a number, so
/// the flow can reorder or insert a screen (the hide-numbers question) without the stored
/// marker changing meaning.
enum SetupStep: String, CaseIterable {
    case goal
    case focusAreas
    case mealPattern
    case bodyMetrics
    case targetWeight
    case done

    /// The next step, in the PRD's order. Step 5 is skipped for goals 4 and 5 (PRD line 745).
    func next(skippingTargetWeight: Bool = false) -> SetupStep {
        switch self {
        case .goal: .focusAreas
        case .focusAreas: .mealPattern
        case .mealPattern: .bodyMetrics
        case .bodyMetrics: skippingTargetWeight ? .done : .targetWeight
        case .targetWeight, .done: .done
        }
    }

    var previous: SetupStep? {
        switch self {
        case .goal: nil
        case .focusAreas: .goal
        case .mealPattern: .focusAreas
        case .bodyMetrics: .mealPattern
        case .targetWeight: .bodyMetrics
        case .done: .targetWeight
        }
    }
}

/// The plan summary, projected one of two ways (#212, A31).
///
/// **The qualitative arm carries no numeric field.** `toCycleEstimate` is the precedent: a
/// screen that forgets to hide the numbers cannot hide them, because the value it is handed
/// has no field to render. Both triggers — the preference, and A28's Pregnancy/postpartum
/// mode — reach this same projection, so the mechanism is built once.
enum NutritionSummary {
    case numbers(NutritionNumbers)
    case qualitative(NutritionQualitative)
}

struct NutritionNumbers {
    let calorieTargetKcal: Double
    let proteinG: Double
    let fatG: Double
    let carbG: Double
    let fibreG: Double
    let targetWeightKg: Double?
    let timelineWeeks: Int?
    /// `nil` when the route served no adjustment (a body from before #361).
    var cycleAdjustment: NutritionCycleAdjustment?
}

/// Qualitative guidance — sentences, never a calorie total, a macro gram, a weight target or
/// deficit wording. The words are the reviewed copy, not generated here.
struct NutritionQualitative {
    let goal: APINutritionGoal
    /// The two or three sentences the qualitative mode shows instead of numbers. `REVIEW`:
    /// this copy is a draft and must be signed off before it ships (the issue's own criterion).
    let guidance: [String]
}

import Foundation
import Observation

/// The Nutrition coach's setup flow (S3, #223): the state machine behind the five steps, the
/// guard cards and the plan summary.
///
/// **The plan summary is one of two projections** (#212, A31), and the qualitative one has no
/// numeric field at all — the same `toCycleEstimate` shape, where a screen *cannot* render a
/// number the type never carried. The two triggers are the hide-numbers preference and A28's
/// Pregnancy/postpartum mode; both reach this one projection, not two mechanisms.
@MainActor
@Observable
final class NutritionSetupModel {

    enum Phase {
        case loading
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

    /// Step 5's draft answer, and the hide-numbers preference (#212) — asked on the path.
    var targetWeightText: String = ""
    var hideNumbers: Bool = false

    var showCalculation = false

    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            let profile = try await session.nutritionProfile()
            self.profile = profile
            self.hideNumbers = profile?.hideNumbers ?? false
            self.step = profile.map(Self.step(for:)) ?? .goal
            if profile?.complete == true {
                await showSummary()
            } else {
                phase = .editing
            }
        } catch {
            phase = .failed
        }
    }

    // MARK: Steps

    func choose(_ goal: APINutritionGoal) async {
        await save(APINutritionProfilePatch(goal: goal, step: SetupStep.focusAreas.rawValue))
        step = .focusAreas
    }

    var selectedFocusAreas: [String] { profile?.focusAreas ?? [] }

    func isFocusAreaDisabled(_ code: String) -> Bool {
        !selectedFocusAreas.contains(code) && selectedFocusAreas.count >= 3
    }

    func toggleFocusArea(_ code: String) {
        var areas = selectedFocusAreas
        if let index = areas.firstIndex(of: code) {
            areas.remove(at: index)
        } else if areas.count < 3 {
            areas.append(code)
        }
        Task {
            await save(APINutritionProfilePatch(focusAreas: areas))
        }
    }

    func chooseMeals(_ count: Int) async {
        await save(APINutritionProfilePatch(
            mealPattern: APIMealPattern(mealsPerDay: count, snacks: false, mealTimes: nil),
            step: SetupStep.bodyMetrics.rawValue
        ))
        step = .bodyMetrics
    }

    func advance() async {
        let skipping = isSkippingTargetWeight
        await save(APINutritionProfilePatch(step: step.next(skippingTargetWeight: skipping).rawValue))
        step = step.next(skippingTargetWeight: skipping)
    }

    /// Goals 4 and 5 have no target weight (PRD line 745): Step 5 is skipped entirely.
    var isSkippingTargetWeight: Bool {
        guard let goal = profile?.goal else { return false }
        return goal == .maintain || goal == .eatBetter
    }

    var targetWeightValue: Double? {
        guard let value = Double(targetWeightText), value > 0 else { return nil }
        return value
    }

    func finish() async {
        guard let targetWeightValue else { return }
        await save(APINutritionProfilePatch(
            targetWeightKg: targetWeightValue,
            hideNumbers: hideNumbers,
            step: SetupStep.done.rawValue
        ))
        await showSummary()
    }

    func back() {
        guard let previous = step.previous else { return }
        step = previous
    }

    func editInProfile() {
        // The body metrics live on the Sign Up profile, edited from Profile (#19). Nothing
        // to write here — this is a navigation seam the caller wires.
    }

    // MARK: Body metrics (Step 4, confirmation)

    var heightText: String {
        guard let profile = session.user?.profile else { return "Height not set" }
        return String(format: "%.0f cm", profile.heightCm)
    }

    var weightText: String {
        guard let profile = session.user?.profile else { return "weight not set" }
        return String(format: "%.1f kg", profile.weightKg)
    }

    var bandText: String {
        guard let band = session.user?.profile?.lifestyle else { return "activity not set" }
        return band
    }

    // MARK: The plan summary

    func showSummary() async {
        do {
            plan = try await session.nutritionPlan()
            if case .refused = plan {
                // The target the plan refused brings her back to Step 5, with the guard's
                // offered value on screen and the field still editable (canvas `sGuard`).
                phase = .editing
                step = .targetWeight
            } else {
                phase = .summary
            }
        } catch {
            errorMessage = "Your plan couldn't be prepared. Try again."
        }
    }

    var refusal: APINutritionRefusal? {
        guard case .refused(let refusal) = plan else { return nil }
        return refusal
    }

    /// One of two projections (#212, A31): hiding the numbers, or A28's Pregnancy/postpartum
    /// mode, leaves the qualitative arm — which has no numeric field at all.
    var summary: NutritionSummary {
        guard case .targets(let targets) = plan else {
            return .qualitative(NutritionQualitative(goal: profile?.goal ?? .maintain, guidance: []))
        }
        if hideNumbers {
            return .qualitative(NutritionQualitative(goal: profile?.goal ?? .maintain, guidance: [
                "Focus on your goal and how you feel, not the numbers.",
                "Log your meals and Eva will keep you on track.",
            ]))
        }
        return .numbers(NutritionNumbers(
            calorieTargetKcal: targets.calorieTargetKcal,
            proteinG: targets.macros.proteinG,
            fatG: targets.macros.fatG,
            carbG: targets.macros.carbG,
            fibreG: targets.macros.fibreG,
            targetWeightKg: targets.weightPlan?.targetWeightKg,
            timelineWeeks: targets.weightPlan?.timelineWeeks
        ))
    }

    // MARK: Saving

    private func save(_ patch: APINutritionProfilePatch) async {
        do {
            let saved = try await session.saveNutritionProfile(patch)
            profile = saved
        } catch {
            errorMessage = "Your answer couldn't be saved. Try again."
        }
    }

    private static func step(for profile: APINutritionProfile) -> SetupStep {
        SetupStep(rawValue: profile.step) ?? .goal
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
}

/// Qualitative guidance — sentences, never a calorie total, a macro gram, a weight target or
/// deficit wording. The words are the reviewed copy, not generated here.
struct NutritionQualitative {
    let goal: APINutritionGoal
    /// The two or three sentences the qualitative mode shows instead of numbers. `REVIEW`:
    /// this copy is a draft and must be signed off before it ships (the issue's own criterion).
    let guidance: [String]
}

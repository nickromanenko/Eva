import Foundation

/// Everything the Nutrition coach's setup flow reads and writes (S3, #223) — and, by
/// omission, everything it cannot.
///
/// **A31 is a property of this type, not a comment.** The hide-numbers preference is set by
/// her own action and nothing else (#212: "Eva never infers it"). The flow's only dependency
/// is this protocol, and it has no way to read her logging history: no events, no meals, no
/// past weights. A heuristic that wanted to fire on "successive low-calorie days, a falling
/// weight" would first have to add a read here, which is a change review sees — and
/// `NutritionSetupModelTests` drives the whole flow through a recording source and fails on
/// any call that is not one of these.
///
/// It is also the seam the `EVA_NUTRITION_PLAN` DEBUG hook wraps, the way
/// `CalendarEventSource` is the seam `EVA_CYCLE_PREDICTION` wraps.
@MainActor
protocol NutritionSource: AnyObject {
    /// The Sign Up profile Step 4 confirms (height, weight, activity band) — read, never
    /// re-asked (PRD lines 736–737). Canonical SI, whatever the device shows.
    var bodyProfile: APIProfile? { get }

    /// The setup answers and progress, or `nil` before setup has started.
    func nutritionProfile() async throws -> APINutritionProfile?

    /// Saves one step's answers. An absent key is left as it was.
    func saveNutritionProfile(_ patch: APINutritionProfilePatch) async throws -> APINutritionProfile

    /// The day's plan for a finished setup: targets, or a refusal with the value to offer.
    func nutritionPlan(timeZone: TimeZone) async throws -> APINutritionPlan
}

extension AppSession: NutritionSource {
    var bodyProfile: APIProfile? { user?.profile }
}

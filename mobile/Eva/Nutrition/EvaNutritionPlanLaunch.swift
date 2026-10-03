#if DEBUG
import Foundation

/// The `EVA_NUTRITION_PLAN` launch hook: hands the setup flow one `GET /me/nutrition/plan`
/// body instead of asking the API for it.
///
/// ```sh
/// SIMCTL_CHILD_EVA_NUTRITION_PLAN='{"plan":{"kind":"refused","refusal":
///   {"reason":"below-bmi-floor","lowestSupportedWeightKg":52.2}}}' \
///   xcrun simctl launch --terminate-running-process $UDID com.evaapp.ios
/// ```
///
/// Same family as `EVA_CYCLE_PREDICTION`, and for the same reason: the route exists (#222)
/// and answers **503 in every environment there is** — the `NUTRITION_*` constants, the
/// luteal percentage and the `CYCLE_*` group are clinical configuration no deployment sets
/// until #26 signs them off with sources. Without a hook there is no way to put a summary or
/// a guard card on screen, for review or for `NutritionSetupUITests`.
///
/// The value is the route's own JSON, decoded by `APINutritionPlanResponse` — the decoder the
/// real path uses. `unavailable` fails every read the way the live route does. It seeds the
/// **plan only**: the setup answers, the hide-numbers preference and the step marker still go
/// to the API and come back from it, so a relaunch test is a test of what the server stored.
/// The guard maths itself is the API's and is tested there (`nutrition-profile.test.ts`).
enum EvaNutritionPlanLaunch {

    static let environmentKey = "EVA_NUTRITION_PLAN"
    static let unavailableValue = "unavailable"

    private static let requested = ProcessInfo.processInfo.environment[environmentKey]

    /// The seeded source, or `nil` when the variable is unset.
    @MainActor
    static func source(wrapping live: any NutritionSource) -> (any NutritionSource)? {
        guard let requested, !requested.isEmpty else { return nil }
        guard requested != unavailableValue,
              let data = requested.data(using: .utf8),
              let response = try? JSONDecoder().decode(APINutritionPlanResponse.self, from: data)
        else {
            // A malformed body is a broken launch, not a state to draw — fail the read the
            // way a live 503 does.
            return SeededNutritionPlanSource(plan: nil, wrapping: live)
        }
        return SeededNutritionPlanSource(plan: response.plan, wrapping: live)
    }
}

/// Answers the plan from a seeded body and forwards everything else to the real source.
@MainActor
final class SeededNutritionPlanSource: NutritionSource {

    private let plan: APINutritionPlan?
    private let live: any NutritionSource

    init(plan: APINutritionPlan?, wrapping live: any NutritionSource) {
        self.plan = plan
        self.live = live
    }

    var bodyProfile: APIProfile? { live.bodyProfile }

    func nutritionProfile() async throws -> APINutritionProfile? {
        try await live.nutritionProfile()
    }

    func saveNutritionProfile(_ patch: APINutritionProfilePatch) async throws -> APINutritionProfile {
        try await live.saveNutritionProfile(patch)
    }

    func nutritionPlan(timeZone: TimeZone) async throws -> APINutritionPlan {
        guard let plan else {
            throw APIError.server(
                code: "SERVICE_UNAVAILABLE",
                message: "Your nutrition plan isn't available right now. Please try again later.",
                status: 503
            )
        }
        return plan
    }
}
#endif

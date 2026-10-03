import Foundation
import Observation

/// Nutrition Settings (canvas `nSet`, #223): where the hide-numbers preference is reversed.
///
/// **It changes only when she flips it, and only to what she flipped it to** (#212). Reading
/// the screen writes nothing; turning it off sends `hideNumbers: false` and nothing else, so
/// no other answer moves with it. A save that fails puts the switch back where the server
/// has it — the screen never shows a state the account does not hold, in either direction.
///
/// Same seam as the setup flow, `NutritionSource`, which cannot read her logging history —
/// A31 holds here as it does there.
@MainActor
@Observable
final class NutritionSettingsModel {

    enum Phase {
        case loading
        case ready
        case failed
    }

    private(set) var phase: Phase = .loading
    /// What the server holds. `false` before setup has started — nothing is hidden by a
    /// preference she has not given.
    private(set) var hideNumbers = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let source: any NutritionSource

    init(source: any NutritionSource) {
        self.source = source
    }

    func load() async {
        phase = .loading
        do {
            hideNumbers = try await source.nutritionProfile()?.hideNumbers ?? false
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    /// Saves her choice, and only her choice.
    func setHideNumbers(_ hide: Bool) async {
        guard hide != hideNumbers, !isSaving else { return }
        let previous = hideNumbers
        hideNumbers = hide
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await source.saveNutritionProfile(
                APINutritionProfilePatch(hideNumbers: hide)
            )
            hideNumbers = saved.hideNumbers ?? false
            errorMessage = nil
        } catch {
            hideNumbers = previous
            errorMessage = "Your change couldn't be saved. Try again."
        }
    }
}

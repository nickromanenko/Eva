import SwiftUI

/// The units setting: what the device shows, and nothing else (#82).
///
/// Starts from `Locale.current.measurementSystem` and is overridden in Profile ▸ Units.
/// The override is written to `UserDefaults` and survives relaunch, and it wins over the
/// locale on every screen from the moment it is set — a device locale disagrees with how
/// someone thinks about her own body more often than it agrees.
///
/// ## Device-local, not on the account
///
/// The canvas' settings note calls this "the account preference", and #82 left the
/// question open with a note that an account field is an always-human schema gate
/// (`docs/AUTONOMY.md`) and should ride with the A8/A12 change to `users/{uid}` rather
/// than open the document twice. Its decision comment then scoped this issue to the
/// locale default, the Settings row and the entry controls, and put any change to what is
/// stored for existing users out of scope. So the preference lives here, on the device.
/// The cost is stated rather than hidden: a second device does not follow it yet. Moving
/// it onto the account later changes where this class reads and writes, and nothing else —
/// no screen and no stored measurement knows where the setting came from.
///
/// This is **not** the `questionnaireCompleted` case GUARDRAILS 24 forbids a local flag
/// for. That one is a fact about the account that the server owns and the client must not
/// second-guess; this is a preference about how this device draws numbers, which no server
/// has an opinion about.
@MainActor
@Observable
final class EvaUnitPreference {

    /// The one the app runs on. Views take it by argument the way they take `AppSession`,
    /// so a preview or a test can hand in its own.
    static let shared = EvaUnitPreference()

    /// `UserDefaults` key. Prefixed like the rest of the app's stored keys.
    static let storageKey = "eva.units.system"

    private let defaults: UserDefaults

    /// What the device's own locale asks for, whether or not it is what is in force.
    /// Kept so Settings can say where the default came from without re-reading `Locale`.
    let localeDefault: EvaUnitSystem

    /// The system in force. Setting it stores the choice; it survives relaunch from then on.
    var system: EvaUnitSystem {
        didSet {
            guard system != oldValue else { return }
            defaults.set(system.rawValue, forKey: Self.storageKey)
        }
    }

    /// Whether the user has chosen, as opposed to inheriting the locale.
    private(set) var isOverridden: Bool

    init(defaults: UserDefaults = .standard, locale: Locale = .current) {
        self.defaults = defaults
        localeDefault = .default(for: locale)

        #if DEBUG
        // Same clean slate `AppSession` gives the Keychain, and for the same reason: a UI
        // test that set an override must not leave it for the next one. Only the UI-test
        // hook clears it — a person's relaunch keeps her choice, which is the point.
        if ProcessInfo.processInfo.environment["EVA_UITEST_RESET"] == "1" {
            defaults.removeObject(forKey: Self.storageKey)
        }
        #endif

        let stored = (defaults.string(forKey: Self.storageKey)).flatMap(EvaUnitSystem.init(rawValue:))
        system = stored ?? localeDefault
        isOverridden = stored != nil
    }

    /// Records an explicit choice. Separate from assigning `system` so the screen says what
    /// it means: after this the locale no longer decides, even if the choice happens to
    /// equal what the locale would have given.
    func choose(_ chosen: EvaUnitSystem) {
        isOverridden = true
        // Written unconditionally: `didSet` skips an unchanged value, and choosing the
        // system the locale already gave has to persist too, or a later trip abroad — or a
        // second read of a locale that changed — would quietly move it back.
        defaults.set(chosen.rawValue, forKey: Self.storageKey)
        system = chosen
    }
}

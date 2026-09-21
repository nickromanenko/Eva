import Foundation

/// Which country's emergency guidance this device shows (#87).
///
/// Follows the device's region and is overridden in Settings › Medical and emergency
/// information. The override is written to `UserDefaults` and survives relaunch, and it
/// wins over the region from the moment it is set — the same shape the units preference
/// took (#82), for the same reason: a device region disagrees with where someone needs
/// her emergency information more often than it agrees (a phone bought on one storefront
/// and carried to another country).
///
/// ## Device-local, and never sent anywhere
///
/// **This is the one setting with a data-minimisation rule attached** (LAUNCH §2.4):
/// the country is never sent to the server — not on an event, not as a query parameter,
/// not logged. The whole per-country guidance table arrives from `GET /refdata` and the
/// resolution happens here, on the device. So the override lives in `UserDefaults` and
/// there is deliberately no API call anywhere in this type: a country on the account
/// would be one more identifier on `users/{uid}` (#87's Risks), and sending it per
/// request would put a health-adjacent fact in every access log.
///
/// This is a preference about which country's *public facts* this device shows — no
/// server has an opinion about it, and GUARDRAILS 24's ban on local flags for
/// server-owned facts does not reach it.
@MainActor
@Observable
final class EvaCountrySetting {

    /// The one the app runs on. Views take it by argument the way they take `AppSession`,
    /// so a preview or a test can hand in its own.
    static let shared = EvaCountrySetting()

    /// `UserDefaults` key. Prefixed like the rest of the app's stored keys.
    static let storageKey = "eva.emergency.country"

    /// The UI-test hook: a per-launch country override, read once here and never
    /// persisted — the same family as `EVA_TODAY_CARD` (`EvaTodayCardLaunch`). A UI test
    /// asserts a *covered* country (`US`) and an *uncovered* one (`DE`) against the
    /// harness API's seeded table without either touching the picker or leaking into
    /// the next launch. DEBUG only; a Release build has neither the read nor the branch.
    static let launchOverrideKey = "EVA_EMERGENCY_COUNTRY"

    private let defaults: UserDefaults

    /// What the device's own region asks for, whether or not it is what is in force.
    /// Kept so Settings can say where the default came from without re-reading `Locale`.
    ///
    /// `Locale.region` is the storefront the device is set to — an ISO 3166-1 alpha-2
    /// code such as `US` or `GB`, which is exactly what the guidance table's entries are
    /// keyed by. `nil` (a device with no region — rare, but a simulator can be) is not
    /// an error: it resolves like any unknown country, to the fallback.
    let regionDefault: String?

    /// The country in force: the override, or the device's region.
    ///
    /// **No `didSet` here, unlike `EvaUnitPreference.system`'s** — and that is not a
    /// style choice. The `@Observable` macro routes assignments through the generated
    /// setter, so an observer would fire on the *initializer's* own assignment and write
    /// the region default into `UserDefaults` on first launch; the next launch would then
    /// read a stored value that nobody chose and report `isOverridden == true`. Every
    /// write is therefore explicit, in `choose(_:)`, and the launch-override assignment
    /// below never persists anything.
    var country: String?

    /// Whether the user has chosen, as opposed to inheriting the region.
    private(set) var isOverridden: Bool

    init(defaults: UserDefaults = .standard, locale: Locale = .current) {
        self.defaults = defaults
        regionDefault = locale.region?.identifier

        #if DEBUG
        // Same clean slate `AppSession` gives the Keychain, and for the same reason: a UI
        // test that set an override must not leave it for the next one. Only the UI-test
        // hook clears it — a person's relaunch keeps her choice, which is the point.
        if ProcessInfo.processInfo.environment["EVA_UITEST_RESET"] == "1" {
            defaults.removeObject(forKey: Self.storageKey)
        }
        #endif

        let stored = defaults.string(forKey: Self.storageKey)
        isOverridden = stored != nil

        #if DEBUG
        // The per-launch hook wins over both, and is not written back: see the constant's
        // comment.
        if let launch = ProcessInfo.processInfo.environment[Self.launchOverrideKey],
           !launch.isEmpty {
            country = launch
            isOverridden = true
            return
        }
        #endif

        country = stored ?? regionDefault
    }

    /// Records an explicit choice, or clears one. Separate from assigning `country` so
    /// the screen can say what it means: choosing the country the region already gave
    /// has to persist too (a later trip abroad must not quietly move it), and clearing
    /// returns to *following the region* rather than to a stale remembered choice.
    ///
    /// Written unconditionally, like `EvaUnitPreference.choose`: a choice equal to what
    /// the region already gave would otherwise be indistinguishable from no choice at
    /// all, which is exactly the state the screen must not claim.
    func choose(_ chosen: String?) {
        isOverridden = chosen != nil
        if let chosen {
            country = chosen
            defaults.set(chosen, forKey: Self.storageKey)
        } else {
            country = regionDefault
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}

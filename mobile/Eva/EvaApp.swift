import SwiftUI

@main
struct EvaApp: App {
    /// Registers for a remote-notification token at launch (#79); the token lands in the
    /// Keychain and `AppSession` sends it to the API after a successful bootstrap.
    @UIApplicationDelegateAdaptor(NotificationRegistrationDelegate.self) private var notifications
    @State private var session = AppSession()
    /// Metric or imperial, from the device locale until Settings overrides it (#82).
    @State private var units = EvaUnitPreference.shared
    /// The country whose emergency guidance the app shows (#87), from the device region
    /// until Settings overrides it.
    @State private var country = EvaCountrySetting.shared

    init() {
        // Builds before #279 loaded the API through the shared `URLSession`, which left
        // health-data responses in `Library/Caches/<bundle id>/Cache.db`. `APIClient` no
        // longer writes there, and nothing else in the app uses the shared cache, so
        // whatever is in it is a leftover to remove rather than something to keep.
        URLCache.shared.removeAllCachedResponses()
    }

    var body: some Scene {
        WindowGroup {
            // The design specimen replaces the whole app when EVA_SPECIMEN=1, so token
            // and component review needs no navigation and no account. Both the branch
            // and everything it reaches are inside `#if DEBUG`; a Release build has no
            // `EvaSpecimenLaunch` to ask and no `EvaSpecimenView` to show.
            //
            // Without the variable this is exactly `EvaRootView(session:)`, which is the
            // switch that used to live here — the normal launch path is untouched.
            #if DEBUG
            if EvaSpecimenLaunch.isEnabled {
                EvaSpecimenView()
            } else {
                EvaRootView(session: session, units: units, country: country)
            }
            #else
            EvaRootView(session: session, units: units, country: country)
            #endif
        }
    }
}

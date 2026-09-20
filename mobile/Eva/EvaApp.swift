import SwiftUI

@main
struct EvaApp: App {
    @State private var session = AppSession()
    /// Metric or imperial, from the device locale until Settings overrides it (#82).
    @State private var units = EvaUnitPreference.shared
    /// The country whose emergency guidance the app shows (#87), from the device region
    /// until Settings overrides it.
    @State private var country = EvaCountrySetting.shared

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

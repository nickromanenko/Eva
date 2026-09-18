import SwiftUI

/// The app's normal root: `AppSession.State` picks the screen, and the session
/// bootstraps as soon as the view appears.
///
/// Extracted from `EvaApp` so the DEBUG `EVA_SPECIMEN` branch has something to be an
/// alternative *to*. The behaviour is unchanged — same states, same screens, same
/// `bootstrap()` on appear.
struct EvaRootView: View {
    let session: AppSession
    /// The device's units setting (#82). Owned by `EvaApp` for the same reason `session`
    /// is: one instance for the app, handed to the two screens that read it.
    let units: EvaUnitPreference

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient.evaScreenBackground.ignoresSafeArea())
            case .signedOut, .needsQuestionnaire:
                OnboardingFlowView(session: session, units: units)
            case .ready:
                EvaTabView(session: session, units: units)
            case .unreachable:
                UnreachableView(session: session)
            }
        }
        .task { await session.bootstrap() }
    }
}

#Preview {
    EvaRootView(session: AppSession(), units: EvaUnitPreference())
}

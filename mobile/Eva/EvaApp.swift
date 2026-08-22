import SwiftUI

@main
struct EvaApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            Group {
                switch session.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient.evaScreenBackground.ignoresSafeArea())
                case .signedOut, .needsQuestionnaire:
                    OnboardingFlowView(session: session)
                case .ready:
                    ContentView(session: session)
                }
            }
            .task { await session.bootstrap() }
        }
    }
}

import SwiftUI

/// The Home tab, still a placeholder.
///
/// This is what `ContentView` used to be — the "Placeholder dashboard" a signed-in user
/// landed on before #159: a wordmark, the account's address, and whether the API answers.
/// It keeps that job and loses the two things the tab bar took over: the navigation stack
/// and the link to Profile.
///
/// **The designed Dashboard is its own set of slices** (`SPEC.home_*` — a priority ladder,
/// a daily card, a glance row, a nudge slot). None of it is #159's, so nothing here
/// pretends to be it.
///
/// The legacy plum-and-serif styling went with the move, and that is not a quiet re-skin
/// of a drifted screen (DESIGN.md §9): the placeholder now sits one tab away from the
/// calendar, so the two are seen together, and a mauve gradient beside the canvas' warm
/// ground reads as a bug rather than as an unfinished screen.
struct HomeStubView: View {

    let session: AppSession

    @State private var apiStatus: APIStatus = .checking

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            VStack(spacing: EvaSpacing.sm) {
                Text("Eva")
                    .evaTextStyle(.h1)
                    .foregroundStyle(Color.evaPrimaryText)
                    .accessibilityIdentifier("home.title")

                if let email = session.user?.email {
                    Text(email)
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaSecondaryText)
                        .accessibilityIdentifier("home.email")
                }

                switch apiStatus {
                case .checking:
                    ProgressView()
                case .ok(let status):
                    Label("API status: \(status)", systemImage: "checkmark.circle")
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaSuccessInk)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaErrorInk)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(EvaSpacing.lg)
        }
        .task { await checkAPI() }
    }

    private func checkAPI() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: API.healthURL)
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            apiStatus = .ok(health.status)
        } catch {
            apiStatus = .failed("API unreachable: \(error.localizedDescription)")
        }
    }
}

private enum APIStatus {
    case checking
    case ok(String)
    case failed(String)
}

private struct HealthResponse: Decodable {
    let status: String
}

/// Where the API lives, for the one caller that asks it a question `APIClient` has no
/// method for. Was declared in `ContentView.swift`, which #159 removed.
enum API {
    static var baseURL: URL { APIClient.default.baseURL }
    static var healthURL: URL { baseURL.appending(path: "health") }
}

#Preview {
    HomeStubView(session: AppSession())
}

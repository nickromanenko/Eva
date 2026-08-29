import SwiftUI

/// Placeholder dashboard (the designed dashboard lands in a later phase).
struct ContentView: View {
    let session: AppSession

    @State private var apiStatus: APIStatus = .checking

    var body: some View {
        // Scaffolding, not design. The canvas reaches Profile through the §7 tab bar,
        // which is #19; until then a push is the smallest honest way in, and the tint
        // keeps the system chrome off the accent blue.
        NavigationStack {
            dashboard
        }
        .tint(Color.evaActionPinkTop)
    }

    private var dashboard: some View {
        ZStack {
            LinearGradient.evaScreenBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Eva")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(LinearGradient.evaPlumPink)
                    .accessibilityIdentifier("dashboard.title")

                if let email = session.user?.email {
                    Text(email)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.evaMuted)
                }

                switch apiStatus {
                case .checking:
                    ProgressView("Connecting to API…")
                case .ok(let status):
                    Label("API status: \(status)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Log out moved to Profile with #55 — the canvas puts it there, and two
                // of them would be two answers to the same question.
                NavigationLink("Profile") {
                    ProfileView(session: session)
                }
                .buttonStyle(.evaText)
                .padding(.top, EvaSpacing.md)
                .accessibilityIdentifier("dashboard.profile")
            }
            .padding()
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

enum API {
    static var baseURL: URL { APIClient.default.baseURL }
    static var healthURL: URL { baseURL.appending(path: "health") }
}

#Preview {
    ContentView(session: AppSession())
}

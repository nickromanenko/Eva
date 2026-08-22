import SwiftUI

/// Placeholder dashboard (the designed dashboard lands in a later phase).
struct ContentView: View {
    let session: AppSession

    @State private var apiStatus: APIStatus = .checking

    var body: some View {
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

                Button("Log out", action: session.logOut)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evaFaint)
                    .padding(.top, 24)
                    .accessibilityIdentifier("dashboard.logout")
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

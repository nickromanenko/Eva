import SwiftUI

struct ContentView: View {
    @State private var apiStatus: APIStatus = .checking

    var body: some View {
        VStack(spacing: 16) {
            Text("Eva")
                .font(.largeTitle.bold())

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
        }
        .padding()
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
    static let baseURL = URL(string: "https://eva-api-uwkxxorika-uc.a.run.app")!
    static let healthURL = baseURL.appending(path: "health")
}

#Preview {
    ContentView()
}

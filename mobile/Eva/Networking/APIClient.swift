import Foundation

/// Minimal async JSON client for the Eva API.
struct APIClient: Sendable {
    var baseURL: URL
    /// Supplies the JWT for authorized requests.
    var token: @Sendable () -> String?

    static let `default` = APIClient(
        baseURL: APIClient.resolveBaseURL(),
        token: { KeychainTokenStore.shared.token }
    )

    private static func resolveBaseURL() -> URL {
        // UI tests / tooling can point the app anywhere.
        if let override = ProcessInfo.processInfo.environment["EVA_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        #if DEBUG
        return URL(string: "http://localhost:3003")!
        #else
        return URL(string: "https://eva-api-uwkxxorika-uc.a.run.app")!
        #endif
    }

    func get<Response: Decodable>(_ path: String, authorized: Bool = false) async throws -> Response {
        try await send(path: path, method: "GET", body: nil as Never?, authorized: authorized)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, authorized: Bool = false
    ) async throws -> Response {
        try await send(path: path, method: "POST", body: body, authorized: authorized)
    }

    func put<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, authorized: Bool = false
    ) async throws -> Response {
        try await send(path: path, method: "PUT", body: body, authorized: authorized)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String, method: String, body: Body?, authorized: Bool
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw APIError.decoding
            }
        }
        if let failure = try? JSONDecoder().decode(APIFailure.self, from: data) {
            throw APIError.server(code: failure.error.code, message: failure.error.message, status: status)
        }
        throw APIError.server(code: "UNKNOWN", message: "Something went wrong (\(status)).", status: status)
    }
}

private struct APIFailure: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
    }
    let error: Payload
}

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

    /// Info.plist key carrying the API host for this build configuration. Written by
    /// XcodeGen from `EVA_API_BASE_URL_DEFAULT` in `mobile/project.yml` — Debug is
    /// `http://localhost:3003`, Release is the Cloud Run URL.
    static let baseURLInfoKey = "EVAAPIBaseURL"

    static func resolveBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL {
        // UI tests / tooling can point the app anywhere. An empty value is the shell
        // idiom for "not set" and falls through; a non-empty one that isn't a URL is a
        // mistake worth shouting about, not worth quietly ignoring.
        if let override = environment["EVA_API_BASE_URL"], !override.isEmpty {
            guard let url = absoluteURL(override) else {
                fatalError("EVA_API_BASE_URL is set to \"\(override)\", which is not an absolute URL.")
            }
            return url
        }
        guard let configured = bundle.object(forInfoDictionaryKey: baseURLInfoKey) as? String,
              let url = absoluteURL(configured) else {
            // Deliberately fatal. Every path here is a broken build, not a broken
            // network: the key is missing, still the literal `$(…)`, or empty because
            // the build setting was not defined for this configuration. The quiet
            // alternative — falling back to localhost — is exactly how a Release build
            // ships pointing at a machine that isn't there, and no test would catch it.
            // `APIClient.default` is resolved while `EvaApp` builds its `AppSession`,
            // so this fails on launch rather than at the first request.
            fatalError(
                "\(baseURLInfoKey) is missing or not an absolute URL. Check "
                + "EVA_API_BASE_URL_DEFAULT in mobile/project.yml and re-run xcodegen."
            )
        }
        return url
    }

    /// A URL only counts if it can actually be requested: `URL(string:)` accepts bare
    /// paths and unsubstituted `$(…)` placeholders as relative URLs.
    private static func absoluteURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme != nil, url.host() != nil else { return nil }
        return url
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

    func delete<Response: Decodable>(_ path: String, authorized: Bool = false) async throws -> Response {
        try await send(path: path, method: "DELETE", body: nil as Never?, authorized: authorized)
    }

    /// `DELETE` with a body, which `DELETE /me` grew when Apple token revocation landed
    /// (#7). Separate from the bodyless overload rather than an optional parameter,
    /// because "no body" and "an empty body" are different requests and the route treats
    /// them the same only by accident.
    func delete<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, authorized: Bool = false
    ) async throws -> Response {
        try await send(path: path, method: "DELETE", body: body, authorized: authorized)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String, method: String, body: Body?, authorized: Bool
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var sentToken = false
        if authorized, let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            sentToken = true
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
        let failure = try? JSONDecoder().decode(APIFailure.self, from: data)
        let message = failure?.error.message ?? "Something went wrong (\(status))."
        // A 401 is only a dead session if this request presented a token **and** the server
        // says the token is what it rejected. Neither half is enough on its own:
        //
        // - the status alone is not, because `POST /auth/signin` answers a wrong password
        //   with 401 INVALID_CREDENTIALS and sends no token, and a nil token under
        //   `authorized: true` is a client bug rather than a session that ended;
        // - the token alone is not, because `POST /me/auth/providers` (#7) carries one and
        //   still answers 401 INVALID_CREDENTIALS when *Apple's or Google's* credential is
        //   refused — an expired `identityToken`, a spent code, a mismatched nonce. Reading
        //   that as a dead session signed the user out of Eva for tapping "Connect Google"
        //   at the wrong moment, and cleared their Keychain doing it.
        //
        // The server has always drawn this line: every session gate answers `UNAUTHORIZED`,
        // and nothing else does. An undecodable body is treated as a dead session, because
        // a 401 we cannot read at all is not something to keep a token through.
        let code = failure?.error.code
        if status == 401, sentToken, code == nil || code == "UNAUTHORIZED" {
            throw APIError.sessionExpired(message: message)
        }
        throw APIError.server(code: failure?.error.code ?? "UNKNOWN", message: message, status: status)
    }
}

private struct APIFailure: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
    }
    let error: Payload
}

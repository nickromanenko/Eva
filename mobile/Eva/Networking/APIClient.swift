import Foundation

/// Minimal async JSON client for the Eva API.
struct APIClient: Sendable {
    var baseURL: URL
    /// Supplies the JWT for authorized requests.
    var token: @Sendable () -> String?
    /// What every request loads through. Injectable so tests can hand in a session that
    /// carries their stub `URLProtocol`, built from the same `sessionConfiguration()`.
    var session: URLSession = APIClient.session

    static let `default` = APIClient(
        baseURL: APIClient.resolveBaseURL(),
        token: { KeychainTokenStore.shared.token }
    )

    /// The session every Eva API call goes through (#279).
    ///
    /// **Not the shared session.** That one writes cacheable responses into
    /// `URLCache.shared`, whose disk store is `Library/Caches/<bundle id>/Cache.db` — and
    /// verifying #58 found it holding `/me`, `/me/events`, `/me/today` and the
    /// `/auth/signin` response with its JWT, surviving sign-out and account deletion.
    /// Everything this API returns is health data (GUARDRAILS 12), so a second,
    /// unmanaged copy of it on disk is the thing to not have.
    ///
    /// The fix is here rather than a `no-store` header on the server because the client
    /// is what writes the disk: turning the cache off at the source covers every route,
    /// error bodies and unauthorized ones like `/auth/signin` included, without relying
    /// on each handler remembering. Nothing is lost — `/refdata` and `/content` revalidate
    /// through their own `version` handshake, and the durable copy is #78's store.
    static let session = URLSession(configuration: sessionConfiguration())

    /// `.ephemeral` keeps cookies and credentials in memory only (the API uses neither,
    /// but nothing should default to disk), and `urlCache = nil` removes the in-memory
    /// response cache too, so there is no cache object for a response to land in at all.
    /// The timeouts are `.default`'s — the 60s request timeout `UnreachableView` and
    /// `OfflineLaunchTests` describe is unchanged.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

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

    /// `query` is percent-encoded onto the path. `GET /me/events?from=&to=` (#159) is the
    /// first route that takes one; appending it to `path` instead would not work, because
    /// `URL.appending(path:)` escapes the `?` into a path character.
    func get<Response: Decodable>(
        _ path: String, query: [URLQueryItem] = [], authorized: Bool = false
    ) async throws -> Response {
        try await send(path: path, method: "GET", query: query, body: nil as Never?, authorized: authorized)
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

    /// A partial update. `PATCH /me/events/{id}` (#160) is the first route that takes one —
    /// it changes an entry's payload and note while leaving everything it was not sent
    /// alone, which is what keeps an edit from moving the entry in the day's list.
    func patch<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, authorized: Bool = false
    ) async throws -> Response {
        try await send(path: path, method: "PATCH", body: body, authorized: authorized)
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

    /// A `GET` whose body is a file rather than a model — `GET /me/export` (#58) is the
    /// first. The bytes are handed back untouched, together with the name the server gave
    /// the file in `Content-Disposition`.
    ///
    /// Failures go through exactly the same mapping as every JSON call: a 401 that ends
    /// the session, a 429 with its `Retry-After`, the error envelope. Only the success
    /// branch differs, and the reason it cannot share `send`'s is that decoding the body
    /// would be both pointless and wrong — the app does not read an export, it hands it
    /// to the user.
    func download(_ path: String, authorized: Bool = false) async throws -> APIDownload {
        let (data, response) = try await perform(
            path: path, method: "GET", body: nil as Never?, authorized: authorized
        )
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        return APIDownload(data: data, filename: Self.filename(fromContentDisposition: disposition))
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String, method: String, query: [URLQueryItem] = [], body: Body?, authorized: Bool
    ) async throws -> Response {
        let (data, _) = try await perform(
            path: path, method: method, query: query, body: body, authorized: authorized
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    /// The request and every failure mapping, shared by `send` and `download`. Returns only
    /// on a 2xx; everything else is thrown as the `APIError` it means.
    private func perform<Body: Encodable>(
        path: String, method: String, query: [URLQueryItem] = [], body: Body?, authorized: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.url(base: baseURL, path: path, query: query))
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
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (200..<300).contains(status), let http {
            return (data, http)
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
        // Every 429 becomes `.rateLimited`, keyed on the status rather than on the code:
        // a throttle that answered with a body we could not decode would otherwise arrive
        // as a generic `.server` and leave the CTA enabled, which is the one behaviour
        // #38 exists to remove.
        //
        // `Retry-After` is read here, where the response is, and turned into an absolute
        // instant immediately. #5 sets it to the whole window as a constant — deliberately,
        // so it leaks nothing about the account — so it is safe to show and safe to trust
        // as an upper bound. Anything unparseable, absent or non-positive becomes `nil`
        // rather than a guess.
        if status == 429 {
            let header = http?.value(forHTTPHeaderField: "Retry-After")
            throw APIError.rateLimited(message: message, retryAt: Self.retryAt(from: header))
        }
        throw APIError.server(code: failure?.error.code ?? "UNKNOWN", message: message, status: status)
    }

    /// The request URL: `baseURL` + `path`, with `query` appended.
    ///
    /// Neither `URLComponents` step below can fail for a URL that is already absolute and
    /// query items that are already strings, so the fallbacks are unreachable rather than
    /// lenient. They return the **query-less** URL on purpose: a route that needs its
    /// parameters answers `400 VALIDATION` without them, which is loud, where silently
    /// substituting a default range would be a wrong calendar nobody could see was wrong.
    static func url(base: URL, path: String, query: [URLQueryItem]) -> URL {
        let withPath = base.appending(path: path)
        guard !query.isEmpty,
              var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false)
        else { return withPath }
        components.queryItems = query
        return components.url ?? withPath
    }

    /// The `filename` parameter of a `Content-Disposition` header, reduced to something
    /// that is safe to offer as a file name — or `nil`, and the caller picks its own.
    ///
    /// Only the quoted and bare `filename=` forms are read. RFC 6266's `filename*=` (an
    /// RFC 8187 encoded name) is not: the API names its files in ASCII
    /// (`eva-export-YYYY-MM-DD.json`), and a parser for a form the server never sends is
    /// code nobody exercises.
    ///
    /// The name is untrusted input even from our own server, because it becomes a path
    /// component the moment it is saved. So anything with a separator in it is cut to its
    /// last component, and a name that is empty, or only dots, after that is refused.
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        for parameter in header.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "filename"
            else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            let name = value
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            guard let name, !name.isEmpty, name.contains(where: { $0 != "." }) else { return nil }
            return name
        }
        return nil
    }

    /// `Retry-After` as an instant, or `nil`.
    ///
    /// Only the delay-seconds form is read. RFC 9110 also allows an HTTP-date, which #5
    /// never sends; parsing one would add a date formatter to serve a case the server
    /// cannot produce, and `nil` here degrades to a banner that says less rather than to a
    /// wrong deadline. A zero or negative value is `nil` for the same reason — a window
    /// that has already passed is not a window.
    static func retryAt(from header: String?, now: Date = Date()) -> Date? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
              seconds > 0
        else { return nil }
        return now.addingTimeInterval(seconds)
    }
}

/// A response body taken as bytes, with the file name the server attached to it.
struct APIDownload: Sendable {
    let data: Data
    /// From `Content-Disposition`, already reduced to a single safe path component. `nil`
    /// when the server named nothing usable.
    let filename: String?
}

private struct APIFailure: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
    }
    let error: Payload
}

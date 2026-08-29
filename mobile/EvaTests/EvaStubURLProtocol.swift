import Foundation
import Synchronization

/// A stub HTTP layer for `APIClient`, which loads through `URLSession.shared`.
///
/// `URLProtocol.registerClass` is the only seam into `URLSession.shared` — a session
/// built from a configuration reads `configuration.protocolClasses` instead, so the
/// global registry is what a client with a hard-coded shared session can be reached
/// through. That keeps the app source untouched: `APIClient.baseURL` and
/// `APIClient.token` are already injectable, so a test client points here and this class
/// answers.
///
/// It only claims requests to `stub.eva.invalid`, for two reasons. Nothing else in the
/// hosting app process — `EvaApp` builds a real `AppSession` and bootstraps at launch —
/// has its traffic silently rewritten. And `.invalid` is guaranteed never to resolve
/// (RFC 2606), so if registration ever stops taking effect these tests fail with
/// `APIError.network` rather than quietly reaching a real server and passing for the
/// wrong reason.
final class EvaStubURLProtocol: URLProtocol {

    static let baseURL = URL(string: "https://stub.eva.invalid")!

    /// What the next request gets back.
    struct Exchange: Sendable {
        var status: Int
        /// The response body, verbatim. A `String` rather than a model so a test can
        /// send a malformed or empty body — which is a case `APIClient` has to handle.
        var body: String
    }

    private struct State: Sendable {
        var exchange: Exchange?
        var isRegistered = false
        var lastAuthorization: String?
        var requestCount = 0
    }

    private static let state = Mutex(State())

    /// Arms the next response and registers the class on first use.
    ///
    /// Also clears the recorded request, so `lastAuthorization` always describes the
    /// exchange the test just set up and never a leftover from the previous one.
    static func stub(status: Int, body: String) {
        let needsRegistration = state.withLock { state -> Bool in
            state.exchange = Exchange(status: status, body: body)
            state.lastAuthorization = nil
            state.requestCount = 0
            let first = !state.isRegistered
            state.isRegistered = true
            return first
        }
        if needsRegistration {
            URLProtocol.registerClass(EvaStubURLProtocol.self)
        }
    }

    /// The `Authorization` header of the last intercepted request, or `nil` if it carried
    /// none. This is the fact the whole 401 rule turns on, so the tests assert on it
    /// directly rather than trusting `authorized:` to mean a token was sent.
    static var lastAuthorization: String? {
        state.withLock { $0.lastAuthorization }
    }

    /// How many requests have been intercepted since the last `stub(status:body:)`.
    /// A rule that signs the user out must not also retry.
    static var requestCount: Int {
        state.withLock { $0.requestCount }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == baseURL.host()
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let exchange = Self.state.withLock { state -> Exchange? in
            state.lastAuthorization = self.request.value(forHTTPHeaderField: "Authorization")
            state.requestCount += 1
            return state.exchange
        }
        guard let exchange, let url = request.url else {
            // No stub armed is a test that forgot to set one up, not a network
            // condition. Failing the load makes it an error the test reports.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: exchange.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        // `.notAllowed`: a cached 401 answering a later request would make these tests
        // depend on their own order.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(exchange.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

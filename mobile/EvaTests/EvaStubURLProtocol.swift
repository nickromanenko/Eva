import Foundation
import Synchronization
import Testing
@testable import Eva

/// A stub HTTP layer for `APIClient`.
///
/// `APIClient` loads through its own session (#279), not `URLSession.shared`, so
/// `URLProtocol.registerClass` — which only reaches the shared session — no longer gets
/// here. A test client passes `session: EvaStubURLProtocol.session` instead: a session
/// built from **the app's own** `APIClient.sessionConfiguration()` with this class put in
/// front of its protocol list. That keeps the stubbed traffic under the exact
/// configuration the app ships — no URL cache, ephemeral storage, the same timeouts — so
/// a test cannot pass on a configuration the app does not use.
///
/// It only claims requests to `stub.eva.invalid`, for two reasons. Nothing else in the
/// hosting app process — `EvaApp` builds a real `AppSession` and bootstraps at launch —
/// has its traffic silently rewritten. And `.invalid` is guaranteed never to resolve
/// (RFC 2606), so if registration ever stops taking effect these tests fail with
/// `APIError.network` rather than quietly reaching a real server and passing for the
/// wrong reason.
///
/// ## Three ways to arm it, in order of how much a test needs to say
///
/// * `stub(status:body:)` / `stubNetworkFailure(_:)` — one answer for whatever asks
///   next. What most tests want.
/// * `stubHeld(status:body:)` — the same, except the answer does not arrive until
///   `releaseHeldRequest()` says so. This is how a test acts *during* a request instead
///   of after it; without it the in-flight window is shorter than the time it takes to
///   get the main actor back, and any test about concurrency is really a test about
///   scheduling luck.
/// * `route { … }` — a different answer per method-and-path, so **two requests can be
///   open at once**. Needed for sequences where one call is still hanging while another
///   completes, which is where the session's generation counter earns its keep.
///
/// ## An unanswerable request is a failed test, not a network condition
///
/// The one design constraint worth stating: a request that matches no rule records an
/// `Issue` before it fails the load. That is not tidiness. `APIError.network` is a
/// *successful* outcome for half the tests in `OfflineLaunchTests` — they assert the app
/// keeps the session when the network is gone — so a stub that quietly answered
/// "unreachable" to a request it did not recognise would let a test pass while proving
/// nothing at all.
final class EvaStubURLProtocol: URLProtocol {

    static let baseURL = URL(string: "https://stub.eva.invalid")!

    /// The session a stubbed `APIClient` loads through. See the type comment.
    static let session: URLSession = {
        let configuration = APIClient.sessionConfiguration()
        configuration.protocolClasses = [EvaStubURLProtocol.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }()

    /// A request this stub can be asked about: method plus path, which is all
    /// `APIClient` varies.
    struct Route: Hashable, Sendable, CustomStringConvertible {
        let method: String
        let path: String

        static func get(_ path: String) -> Route { Route(method: "GET", path: path) }
        static func post(_ path: String) -> Route { Route(method: "POST", path: path) }
        static func put(_ path: String) -> Route { Route(method: "PUT", path: path) }
        static func delete(_ path: String) -> Route { Route(method: "DELETE", path: path) }

        var description: String { "\(method) \(path)" }
    }

    /// What a request gets back.
    enum Outcome: Sendable {
        /// An HTTP response. The body is a `String` rather than a model so a test can
        /// send a malformed or empty one — which is a case `APIClient` has to handle.
        ///
        /// `headers` are merged over the default `Content-Type` (#38): a `429` carries
        /// `Retry-After`, and `APIClient` reads it off the response rather than the body,
        /// so a stub that could only send a body could not exercise that path at all.
        case response(status: Int, body: String, headers: [String: String] = [:])
        /// The load fails before any response exists: no signal, a refused connection, a
        /// captive portal that never answers. `APIClient.send` collapses every one of
        /// these into `APIError.network`, which is the failure #61 turns on — so a test
        /// for it needs a way to produce one that does not depend on the machine's real
        /// network being in any particular state.
        case failure(URLError.Code)
    }

    /// An outcome plus, optionally, the gate that holds it back.
    fileprivate struct Rule: Sendable {
        var outcome: Outcome
        /// Non-nil while the answer is **held**: `startLoading` waits on this before
        /// replying, so a test can act while the request is provably open. One gate per
        /// rule, so holding `GET /me` does not hold `POST /auth/signin`.
        var gate: DispatchSemaphore?
        /// What the response offers the session's cache. `.notAllowed` everywhere except
        /// the #279 tests, which need a response that *could* be stored to prove it is not.
        var storage: URLCache.StoragePolicy = .notAllowed
    }

    /// What was asked, per route. Kept per route as well as in total because a test that
    /// holds one call open while another runs needs to talk about them separately.
    private struct Record: Sendable {
        var count = 0
        var lastAuthorization: String?
    }

    /// The routing table a `route { … }` block builds.
    ///
    /// Built in one call rather than accumulated across several so there is no
    /// half-armed state and no way to inherit the previous test's rules: whatever the
    /// closure describes is exactly what the stub answers, and everything else is an
    /// unrouted request.
    struct Routes {
        fileprivate var rules: [Route: Rule] = [:]

        /// Answers immediately.
        mutating func responds(_ route: Route, status: Int, body: String) {
            rules[route] = Rule(outcome: .response(status: status, body: body))
        }

        /// Answers only once `releaseHeldRequest(route)` is called.
        mutating func held(_ route: Route, status: Int, body: String) {
            rules[route] = Rule(
                outcome: .response(status: status, body: body),
                gate: DispatchSemaphore(value: 0)
            )
        }

        /// Fails at the transport, the way an offline call does.
        mutating func fails(_ route: Route, _ code: URLError.Code = .notConnectedToInternet) {
            rules[route] = Rule(outcome: .failure(code))
        }
    }

    private struct State: Sendable {
        /// Per-route rules, checked first.
        var rules: [Route: Rule] = [:]
        /// Answers anything with no rule of its own. This is what the unkeyed
        /// `stub(...)` family arms, and it is what makes those tests indifferent to
        /// which path they happen to call.
        var catchAll: Rule?
        var records: [Route: Record] = [:]
        var totalCount = 0
        var lastAuthorization: String?
        /// Routes that were asked for and had no rule. Surfaced by `unroutedRequests`
        /// so a test can name them, in addition to the `Issue` recorded at the time.
        var unrouted: [Route] = []
    }

    private static let state = Mutex(State())

    // MARK: - Arming: one answer for whatever asks next

    /// Arms the next response.
    ///
    /// Also clears every previous rule and the recorded requests, so `lastAuthorization`
    /// always describes the exchange the test just set up and never a leftover from the
    /// previous one.
    static func stub(
        status: Int,
        body: String,
        headers: [String: String] = [:],
        storage: URLCache.StoragePolicy = .notAllowed
    ) {
        arm(catchAll: Rule(
            outcome: .response(status: status, body: body, headers: headers),
            storage: storage
        ))
    }

    /// Arms the next request to fail at the transport, the way an offline launch does.
    ///
    /// `.notConnectedToInternet` is the default because it is the case #61 was filed
    /// about; the code is a parameter because `APIClient` must not distinguish between
    /// them and a test should be able to say so.
    static func stubNetworkFailure(_ code: URLError.Code = .notConnectedToInternet) {
        arm(catchAll: Rule(outcome: .failure(code)))
    }

    /// Arms a response that does not arrive until `releaseHeldRequest()` says so.
    ///
    /// Every other stub answers inside `startLoading`, which makes the in-flight window
    /// of a request too short to act in: by the time a test regains the main actor the
    /// call has already landed. Anything about what happens *during* a request — the
    /// overlapping-run guard, logging out mid-retry — needs the request to still be open,
    /// and this is the only way to hold it there without a sleep.
    static func stubHeld(status: Int, body: String) {
        arm(catchAll: Rule(
            outcome: .response(status: status, body: body),
            gate: DispatchSemaphore(value: 0)
        ))
    }

    // MARK: - Arming: a different answer per route

    /// Arms per-route answers, replacing everything previously armed.
    ///
    ///     EvaStubURLProtocol.route {
    ///         $0.held(.get("/me"), status: 401, body: deadToken)
    ///         $0.responds(.post("/auth/signin"), status: 200, body: newSession)
    ///     }
    ///
    /// There is no catch-all afterwards: anything the block did not describe is an
    /// unrouted request, which records an `Issue`. That is deliberate — the reason to
    /// reach for this API at all is that the test cares *which* call is which, so a
    /// silent default would defeat the point.
    static func route(_ build: (inout Routes) -> Void) {
        var routes = Routes()
        build(&routes)
        arm(rules: routes.rules, catchAll: nil)
    }

    private static func arm(rules: [Route: Rule] = [:], catchAll: Rule?) {
        state.withLock { $0 = State(rules: rules, catchAll: catchAll) }
    }

    // MARK: - What was asked

    /// The `Authorization` header of the last intercepted request, or `nil` if it carried
    /// none. This is the fact the whole 401 rule turns on, so the tests assert on it
    /// directly rather than trusting `authorized:` to mean a token was sent.
    static var lastAuthorization: String? {
        state.withLock { $0.lastAuthorization }
    }

    /// The same, for one route — the form a test needs once two calls are in flight and
    /// "the last request" stops being a useful phrase.
    static func lastAuthorization(for route: Route) -> String? {
        state.withLock { $0.records[route]?.lastAuthorization }
    }

    /// How many requests have been intercepted since the last arming.
    /// A rule that signs the user out must not also retry.
    static var requestCount: Int {
        state.withLock { $0.totalCount }
    }

    static func requestCount(for route: Route) -> Int {
        state.withLock { $0.records[route]?.count ?? 0 }
    }

    /// Routes that were asked for and had no rule. Each one also recorded an `Issue` when
    /// it happened; this is here so a test can say so in its own words.
    static var unroutedRequests: [Route] {
        state.withLock { $0.unrouted }
    }

    // MARK: - Held requests

    /// Lets the held catch-all response finish. Safe to call when nothing is held.
    static func releaseHeldRequest() {
        state.withLock { $0.catchAll?.gate }?.signal()
    }

    /// Lets one held route finish. Records an issue rather than doing nothing quietly:
    /// releasing a route that is not held means the test and the stub disagree about
    /// what is armed, and everything after it is untrustworthy.
    static func releaseHeldRequest(
        _ route: Route,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let gate = state.withLock({ $0.rules[route]?.gate }) else {
            Issue.record("No held response is armed for \(route).", sourceLocation: sourceLocation)
            return
        }
        gate.signal()
    }

    /// Suspends until a request has actually reached the stub, so the caller knows the
    /// call is open rather than assuming it. Records an issue instead of hanging: a
    /// request that never arrives is a broken test, not a slow one.
    static func waitForRequestInFlight(
        _ route: Route? = nil,
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now + timeout
        while (route.map { requestCount(for: $0) } ?? requestCount) == 0 {
            guard ContinuousClock.now < deadline else {
                let what = route.map(\.description) ?? "any request"
                Issue.record("\(what) never reached the stub within \(timeout).", sourceLocation: sourceLocation)
                return
            }
            // Yields the main actor, which the caller is almost certainly holding and the
            // task under test needs in order to reach its own await.
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == baseURL.host()
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Set by `stopLoading()`. A held response that is released after its load was
    /// cancelled must not deliver into a client that has moved on.
    private let isCancelled = Mutex(false)

    override func startLoading() {
        let route = Route(
            method: request.httpMethod ?? "GET",
            path: request.url?.path() ?? ""
        )
        let authorization = request.value(forHTTPHeaderField: "Authorization")

        let rule = Self.state.withLock { state -> Rule? in
            state.totalCount += 1
            state.lastAuthorization = authorization
            state.records[route, default: Record()].count += 1
            state.records[route]?.lastAuthorization = authorization
            guard let rule = state.rules[route] ?? state.catchAll else {
                state.unrouted.append(route)
                return nil
            }
            return rule
        }

        guard let rule else {
            // Loud, and deliberately not an `APIError.network`: half of
            // `OfflineLaunchTests` treats a network failure as the *expected* answer, so
            // a stub that quietly failed the load here would let those tests pass without
            // ever exercising the path they name.
            Issue.record("EvaStubURLProtocol has no rule for \(route).")
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        guard let gate = rule.gate else {
            deliver(rule)
            return
        }

        // Waiting happens on a queue of our own, and `startLoading` returns immediately.
        //
        // This is not tidiness — it is the difference between one held request and two.
        // `URLSession` will not begin a second load while a `URLProtocol` is still inside
        // `startLoading`, so blocking here to hold `GET /me` open also stalls the
        // `POST /auth/signin` the test needs to make *during* it, and the two requests
        // that were supposed to overlap end up strictly ordered. Found the slow way: the
        // late-401 test sat for the full 30s backstop and its second request never
        // started until the first gave up.
        //
        // `self` is captured strongly on purpose. The loader's reference is the only
        // other one, and a released response has to have somewhere to be delivered.
        DispatchQueue.global().async {
            _ = gate.wait(timeout: .now() + 30)
            guard !self.isCancelled.withLock({ $0 }) else { return }
            self.deliver(rule)
        }
    }

    private func deliver(_ rule: Rule) {
        switch rule.outcome {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let body, let headers):
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new }
            )!
            // `.notAllowed` by default: a cached 401 answering a later request would make
            // these tests depend on their own order.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: rule.storage)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        isCancelled.withLock { $0 = true }
    }
}

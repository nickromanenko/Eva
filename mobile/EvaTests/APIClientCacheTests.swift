import Foundation
import Testing
@testable import Eva

/// Issue #279: **no API response is written to an HTTP cache.**
///
/// Verifying #58 found `Library/Caches/com.evaapp.ios/Cache.db` holding `/me`,
/// `/me/events`, `/me/today` and the `/auth/signin` JWT, because `APIClient` loaded
/// through the shared session and its default disk-backed `URLCache`. These pin the
/// configuration that replaced it; the stub-driven half is in `ResponseCaching` below.
@Suite("Issue #279 · the API session has no response cache")
struct APIClientCacheTests {

    @Test("the session configuration has no URL cache and never reads one")
    func configurationHasNoCache() {
        let configuration = APIClient.sessionConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// The configuration factory being right proves nothing if the client does not use a
    /// session built from it — which is what reverting to the shared session would do.
    @Test("the default client loads through that session, not the shared one")
    func defaultClientUsesIt() {
        let session = APIClient.default.session

        #expect(session === APIClient.session)
        #expect(session !== URLSession.shared)
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}

extension SessionExpiryTests {

    /// Nested in `SessionExpiryTests` for the reason `OfflineLaunchTests` is: that suite is
    /// `.serialized`, and the stub is one global armed outcome.
    @Suite("Issue #279 · a cacheable response is not kept")
    struct ResponseCaching {

        static let user = #"{"user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true}}"#

        /// Everything a cache could want: explicitly fresh for an hour, and the loader
        /// told it may store the response.
        static func armCacheable() {
            EvaStubURLProtocol.stub(
                status: 200,
                body: user,
                headers: ["Cache-Control": "private, max-age=3600"],
                storage: .allowed
            )
        }

        static let request = URLRequest(url: EvaStubURLProtocol.baseURL.appending(path: "/me"))

        /// The control. Without it the test below could pass because the stub never offers
        /// anything for storage — so first show that the very same response, loaded under
        /// the same configuration with a cache put back, is kept.
        @Test("the same response under a configuration with a cache is stored")
        func controlIsStored() async throws {
            let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
            let configuration = EvaStubURLProtocol.session.configuration
            configuration.urlCache = cache
            configuration.requestCachePolicy = .useProtocolCachePolicy
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            Self.armCacheable()

            _ = try await session.data(for: Self.request)

            // Storing is asynchronous to the load finishing; give it a bounded window.
            let deadline = ContinuousClock.now + .seconds(5)
            while cache.cachedResponse(for: Self.request) == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(cache.cachedResponse(for: Self.request) != nil, "The control never stored anything, so the test below proves nothing")
        }

        @Test("through APIClient, the same response lands in no cache")
        func clientStoresNothing() async throws {
            URLCache.shared.removeAllCachedResponses()
            Self.armCacheable()
            let client = APIClient(
                baseURL: EvaStubURLProtocol.baseURL,
                token: { "a-live-looking-token" },
                session: EvaStubURLProtocol.session
            )

            let _: UserResponse = try await client.get("/me", authorized: true)
            // The same window the control needed, so a slow write is not mistaken for none.
            try await Task.sleep(for: .milliseconds(500))

            #expect(EvaStubURLProtocol.requestCount == 1)
            #expect(client.session.configuration.urlCache == nil)
            #expect(URLCache.shared.cachedResponse(for: Self.request) == nil)
        }

        /// No cache means no cache to *read*, either: a second identical request reaches
        /// the network rather than being answered from anywhere local.
        @Test("a repeated request goes to the network again")
        func repeatReachesNetwork() async throws {
            Self.armCacheable()
            let client = APIClient(
                baseURL: EvaStubURLProtocol.baseURL,
                token: { "a-live-looking-token" },
                session: EvaStubURLProtocol.session
            )

            let _: UserResponse = try await client.get("/me", authorized: true)
            let _: UserResponse = try await client.get("/me", authorized: true)

            #expect(EvaStubURLProtocol.requestCount == 2)
        }
    }
}

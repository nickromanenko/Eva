import Foundation
import Testing

@testable import Eva

/// The sync queue's failure semantics (#78, §8.4): how one `APIError` maps to what the engine
/// does — move on, back off and retry, mark failed, or pause for the session — and the
/// backoff schedule. Pure, so these run without a store or a network.
@Suite("Issue #78 · the sync queue's failure semantics")
struct SyncEngineTests {

    @Test("a 4xx is failed — one bad entry must not block the rest")
    func clientErrorsFail() {
        #expect(syncOutcome(for: .server(code: "VALIDATION", message: "x", status: 400)) == .failed)
        #expect(syncOutcome(for: .server(code: "DAY_ALREADY_LOGGED", message: "x", status: 409)) == .failed)
    }

    @Test("a 5xx is retried — order matters, so the queue blocks")
    func serverErrorsRetry() {
        #expect(syncOutcome(for: .server(code: "INTERNAL", message: "x", status: 500)) == .retry(after: nil))
        #expect(syncOutcome(for: .server(code: "INTERNAL", message: "x", status: 503)) == .retry(after: nil))
    }

    @Test("a 429 carries the server's Retry-After as the wait")
    func rateLimitedCarriesRetryAfter() {
        let at = Date().addingTimeInterval(30)
        #expect(syncOutcome(for: .rateLimited(message: "x", retryAt: at)) == .retry(after: 30))
    }

    @Test("a network failure is retried")
    func networkRetries() {
        #expect(syncOutcome(for: .network) == .retry(after: nil))
    }

    @Test("a dead session pauses the queue and discards nothing")
    func sessionExpiredPauses() {
        #expect(syncOutcome(for: .sessionExpired(message: "x")) == .paused)
    }

    @Test("an undecodable body is failed, not retried")
    func decodingFails() {
        #expect(syncOutcome(for: .decoding) == .failed)
    }

    @Test("the backoff doubles from one second and caps at five minutes")
    func backoffSchedule() {
        #expect(syncBackoff(attempts: 0) == 1)
        #expect(syncBackoff(attempts: 1) == 2)
        #expect(syncBackoff(attempts: 2) == 4)
        #expect(syncBackoff(attempts: 3) == 8)
        #expect(syncBackoff(attempts: 4) == 16)
        #expect(syncBackoff(attempts: 8) == 256)
        #expect(syncBackoff(attempts: 9) == 300)
        #expect(syncBackoff(attempts: 100) == 300)
    }
}

import Foundation
import Testing

@testable import Eva

/// What the app does with a `429 RATE_LIMITED` (#38).
///
/// Before this, `APIClient` mapped it to a generic `.server` and the screen showed its
/// message under a field with the CTA still enabled — so the natural response to "too many
/// attempts" spent another attempt and, on the per-address counter, pushed the window
/// further out. The three pieces below are what stops that: the case, the deadline read
/// from `Retry-After`, and the wording that counts it down.
/// `@MainActor` for `AuthRateLimitedBanner`, which is a `View` and therefore main-actor
/// isolated along with its `message(retryAt:at:)` and `fallbackMessage`. Same reason as
/// `AuthResendCooldownTests`: 16.4 makes it an error, 26.2 a warning.
@Suite("429 RATE_LIMITED")
@MainActor
struct RateLimitedResponseTests {
    private static let throttled = """
        {"error":{"code":"RATE_LIMITED","message":"Too many attempts. Try again later."}}
        """

    // MARK: - Retry-After

    @Test("the delay-seconds form becomes an instant that many seconds out")
    func parsesDelaySeconds() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        let at = APIClient.retryAt(from: "900", now: now)

        #expect(at == now.addingTimeInterval(900))
    }

    @Test("surrounding whitespace does not defeat it")
    func tolerantOfWhitespace() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(APIClient.retryAt(from: " 60 ", now: now) == now.addingTimeInterval(60))
    }

    @Test(
        "anything that is not a positive number of seconds is nil, never a guess",
        arguments: [
            // Absent.
            nil,
            // An HTTP-date. RFC 9110 allows it; #5 never sends one, and parsing it would
            // add a formatter to serve a case the server cannot produce.
            "Wed, 21 Oct 2026 07:28:00 GMT",
            // A window that has already passed is not a window.
            "0",
            "-30",
            "",
            "soon",
        ] as [String?]
    )
    func refusesAnythingElse(header: String?) {
        #expect(APIClient.retryAt(from: header) == nil)
    }

    // MARK: - The mapping

    @Test("a 429 becomes .rateLimited carrying the window, not a .server with a string")
    func mapsToItsOwnCase() async throws {
        EvaStubURLProtocol.stub(
            status: 429,
            body: Self.throttled,
            headers: ["Retry-After": "900"]
        )
        let client = APIClient(baseURL: EvaStubURLProtocol.baseURL, token: { nil })
        let before = Date()

        await #expect(throws: APIError.self) {
            let _: AuthResponse = try await client.post("/auth/signin", body: ["email": "a@b.co"])
        }

        do {
            let _: AuthResponse = try await client.post("/auth/signin", body: ["email": "a@b.co"])
            Issue.record("a 429 did not throw")
        } catch let error as APIError {
            #expect(error.isRateLimited)
            let retryAt = try #require(error.retryAt)
            // Computed from the clock at the moment the response arrived, so it is an
            // absolute deadline rather than a duration a screen has to keep ticking.
            #expect(retryAt.timeIntervalSince(before) >= 899)
            #expect(retryAt.timeIntervalSince(before) <= 905)
            #expect(error.localizedDescription == "Too many attempts. Try again later.")
        }
    }

    @Test("a 429 with no usable Retry-After is still .rateLimited, with no deadline")
    func mapsWithoutAHeader() async throws {
        EvaStubURLProtocol.stub(status: 429, body: Self.throttled)
        let client = APIClient(baseURL: EvaStubURLProtocol.baseURL, token: { nil })

        do {
            let _: AuthResponse = try await client.post("/auth/signin", body: ["email": "a@b.co"])
            Issue.record("a 429 did not throw")
        } catch let error as APIError {
            // The banner still shows — that the request was throttled is true whatever the
            // header said — and the CTA holds nothing, which is the honest answer when the
            // server did not say how long.
            #expect(error.isRateLimited)
            #expect(error.retryAt == nil)
        }
    }

    @Test("a 429 whose body cannot be decoded is still .rateLimited")
    func mapsOnStatusNotCode() async throws {
        // Keyed on the status, not the code: a throttle that answered with a body we could
        // not read would otherwise arrive as a generic `.server` and leave the CTA enabled,
        // which is the one behaviour this issue exists to remove.
        EvaStubURLProtocol.stub(status: 429, body: "not json at all")
        let client = APIClient(baseURL: EvaStubURLProtocol.baseURL, token: { nil })

        do {
            let _: AuthResponse = try await client.post("/auth/signin", body: ["email": "a@b.co"])
            Issue.record("a 429 did not throw")
        } catch let error as APIError {
            #expect(error.isRateLimited)
        }
    }

    @Test("other failures are untouched")
    func leavesOtherStatusesAlone() async throws {
        EvaStubURLProtocol.stub(
            status: 401,
            body: #"{"error":{"code":"INVALID_CREDENTIALS","message":"Wrong email or password"}}"#
        )
        let client = APIClient(baseURL: EvaStubURLProtocol.baseURL, token: { nil })

        do {
            let _: AuthResponse = try await client.post("/auth/signin", body: ["email": "a@b.co"])
            Issue.record("a 401 did not throw")
        } catch let error as APIError {
            #expect(!error.isRateLimited)
            #expect(error.retryAt == nil)
            #expect(error.code == "INVALID_CREDENTIALS")
        }
    }

    // MARK: - What it says

    @Test("the wait is spoken in seconds under a minute, and rounded up")
    func wordsTheWaitInSeconds() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(
            AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(45), at: now)
                == "You can try again in 45 seconds. Nothing about your account has changed."
        )
        // 30.2s reads as 31, never 30: a banner that invites a tap the server still
        // refuses is worse than one that over-states by a second.
        #expect(
            AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(30.2), at: now)
                .contains("31 seconds")
        )
        #expect(
            AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(1), at: now)
                .contains("1 second.")
        )
    }

    @Test("a minute or more is spoken in minutes, rounded up")
    func wordsTheWaitInMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(60), at: now)
            .contains("1 minute."))
        // #5's window is 15 minutes; 61s must not read as "1 minute" when it is not.
        #expect(AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(61), at: now)
            .contains("2 minutes"))
        #expect(AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(900), at: now)
            .contains("15 minutes"))
    }

    @Test("once the window has passed it says so rather than counting below zero")
    func stopsAtZero() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        let message = AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(-5), at: now)

        #expect(message == "You can try again now. Nothing about your account has changed.")
    }

    @Test("every wording carries the sentence that keeps it from reading as blame")
    func neverBlames() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let messages = [
            AuthRateLimitedBanner.fallbackMessage,
            AuthRateLimitedBanner.message(retryAt: now.addingTimeInterval(30), at: now),
            AuthRateLimitedBanner.message(retryAt: now, at: now),
        ]

        for message in messages {
            // §8: describe, do not blame. Someone throttled out of their own health data is
            // told what the situation is and that nothing was lost by it.
            #expect(message.contains("Nothing about your account has changed."))
            #expect(!message.lowercased().contains("you have"))
            #expect(!message.lowercased().contains("too many times"))
        }
    }
}

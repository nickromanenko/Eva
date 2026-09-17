import Foundation
import Testing
@testable import Eva

/// The resend cooldown's arithmetic (#6).
///
/// `AuthResendButton` shows the wait in its own label — "Resend email · 42s" — and
/// disables itself for as long as the count is above zero. So the label and the disabled
/// state are driven by the same number, and the stated contract is that it is **rounded
/// up**: while the button is still disabled the label must never read "0s", which would
/// say the button is ready when it is not (DESIGN.md §2 — never dimming alone).
///
/// A pure static function, so it is worth pinning here rather than waiting 60 seconds in
/// a UI test.
/// `@MainActor` because `AuthResendButton` is a `View`, which makes the whole type —
/// `secondsRemaining` included — main-actor isolated. CI's Xcode 16.4 enforces that where
/// 26.2 only warns, so without this the target does not compile there; see
/// `EvaUITests/EvaUITestCase.swift` for the same split one target over.
@Suite("Issue #6 · the resend cooldown never reads 0s while it is still counting")
@MainActor
struct AuthResendCooldownTests {

    private static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private static func remaining(_ seconds: TimeInterval) -> Int {
        AuthResendButton.secondsRemaining(until: now.addingTimeInterval(seconds), at: now)
    }

    @Test("a fraction of a second left still reads as a second")
    func roundsUp() {
        #expect(Self.remaining(0.1) == 1)
        #expect(Self.remaining(0.9) == 1)
        #expect(Self.remaining(1.0) == 1)
        #expect(Self.remaining(1.1) == 2)
    }

    @Test("exactly elapsed, and past, are both zero — never negative")
    func floorsAtZero() {
        #expect(Self.remaining(0) == 0)
        #expect(Self.remaining(-0.5) == 0)
        #expect(Self.remaining(-3600) == 0)
    }

    @Test("a full cooldown started now counts the whole duration")
    func fullDuration() {
        let ends = AuthResendCooldown.endingNow()
        let counted = AuthResendButton.secondsRemaining(until: ends, at: Date())
        // The clock moves between the two calls, so this is a range, not an equality.
        #expect(counted > 0)
        #expect(counted <= Int(AuthResendCooldown.duration))
    }

    @Test("the cooldown is the server's own throttle, not a second opinion")
    func matchesTheServerWindow() {
        // api/src/config.ts defaults RATE_LIMIT_RESEND_PER_EMAIL_SECONDS to 60. A client
        // cooldown shorter than the server's would enable the button onto a 429.
        #expect(AuthResendCooldown.duration == 60)
    }
}

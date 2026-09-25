import XCTest

/// What the log-in screen does once the server starts refusing (#38).
///
/// The defect: the app already *showed* `429 RATE_LIMITED`'s message — `APIClient` mapped
/// any non-2xx with a readable body to `.server` and the screen printed it under the
/// password field — but it left the CTA enabled and put the text where a credential error
/// goes. So the natural response to "too many attempts" was to tap again, which spends
/// another attempt and pushes the per-address window further out, and the message read as
/// "what you typed is wrong" when the server had not looked at it.
///
/// Driven through the log-in screen rather than sign-up, because sign-up leaves for the
/// activation gate after one submit and there is nowhere to make a second attempt from.
final class RateLimitedUITests: EvaUITestCase {

    /// `RATE_LIMIT_SIGNIN_PER_EMAIL` is 10, so the eleventh attempt on one address is
    /// refused. A margin is added rather than stopping at exactly eleven: the counter is
    /// per API process and this suite is not the only thing signing in against it.
    private static let attemptsUntilThrottled = 14

    func testARefusedLogInHoldsTheCTAInsteadOfInvitingAnotherAttempt() throws {
        let app = launch()
        // An address of this suite's own, so the per-address counter this test fills is
        // not one another case depends on. It is never registered — a wrong password and
        // an unknown address are the same answer (GUARDRAILS 12b), and the throttle counts
        // both the same way.
        let email = Self.freshEmail()

        tap(app.buttons["text.Log in"], in: app)
        XCTAssertTrue(
            app.staticTexts["Welcome back"].appears(within: 15),
            "The cross-link did not reach the log-in screen"
        )
        type(email, into: app.textFields["login.email"], in: app)
        revealAndTypePassword("wrong-password-1", prefix: "login", in: app)

        let cta = app.buttons["primary.Log in"]
        let banner = app.staticTexts["login.rateLimited"]
        let fieldError = app.staticTexts["login.error"]

        var attempts = 0
        while attempts < Self.attemptsUntilThrottled && !banner.exists {
            // `isEnabled` is the loop's own precondition: the moment the CTA goes down is
            // the moment this test is about, and tapping a disabled button would silently
            // do nothing and spin out the loop instead of failing.
            guard cta.isEnabled else { break }
            cta.tap()
            // Each attempt is a live round trip. Waiting on *either* outcome keeps the
            // loop honest — it does not assume which one this attempt got.
            _ = fieldError.appears(within: 15)
            _ = banner.appears(within: 1)
            attempts += 1
        }

        XCTAssertTrue(
            banner.appears(within: 15),
            """
            \(attempts) refused log-ins did not produce the rate-limit banner. Either the \
            server's per-address limit has changed, or the 429 is still being rendered as \
            a field error.
            """
        )
        XCTAssertFalse(
            cta.isEnabled,
            "The CTA is still enabled after a 429 — tapping it spends another attempt"
        )
        // The banner is an information state, not a credential failure: putting a throttle
        // under the password field tells a returning user their own password was refused
        // when the server never checked it.
        XCTAssertFalse(
            fieldError.exists,
            "The 429 was shown as a field error as well as a banner"
        )
        // It says *when*, from `Retry-After` — #5 sets it to the whole window as a
        // constant, so the number is safe to show and tells nobody anything about the
        // account.
        //
        // Every static text carrying the identifier, joined. `EvaInfoBanner` does not
        // combine its children, so the modifier reaches the title and the message
        // separately and which one `.firstMatch` returns is a detail of how the banner
        // happens to be composed today — not something this test should depend on.
        // `.map { $0.label }`, not `.map(\.label)`: `XCUIElement.label` is main-actor
        // isolated, and Swift 6 refuses to form a key path to it — an error, where reading
        // it inside a closure from this already-isolated test is fine.
        let text = app.staticTexts.matching(identifier: "login.rateLimited")
            .allElementsBoundByIndex
            .map { $0.label }
            .joined(separator: " ")
        XCTAssertTrue(
            text.contains("minute") || text.contains("second"),
            "The banner does not say when to come back: \(text)"
        )
        XCTAssertTrue(
            text.contains("Nothing about your account has changed"),
            "The banner dropped the sentence that keeps it from reading as blame: \(text)"
        )
    }
}

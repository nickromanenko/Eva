import XCTest

/// Issue #61: **a launch that cannot reach the API keeps the session.**
///
/// The unit tests in `EvaTests/OfflineLaunchTests.swift` assert the Keychain value
/// through a stubbed `URLSession`. This one is the end-to-end half, and it is the reason
/// the issue is worth a UI test at all: it signs a real account in, takes the API away,
/// gives it back, and asks whether the app is still signed in. Before the fix the second
/// launch destroyed the token and the third landed on onboarding.
///
/// One test, deliberately, in the shape `DeleteAccountUITests` uses: every step depends on
/// the one before it. There is no way to prove a token survived a launch without an
/// account that put one there, and splitting the log-out section off would mean signing up
/// twice to test two ways off the same screen.
///
/// The account is left signed out but alive at the end, for `scripts/e2e-cleanup.ts` to
/// sweep by the `e2e+<uuid>@e2e.evaapp.dev` pattern (GUARDRAILS §16).
final class OfflineLaunchUITests: EvaUITestCase {

    /// Where the app is pointed when it must not be able to reach anything.
    ///
    /// A refused connection on loopback rather than an unresolvable hostname, for three
    /// reasons: it fails in microseconds instead of waiting out a DNS timeout, it cannot
    /// ever start resolving to something real the way a domain can, and it is the same
    /// `localhost` the working API uses — so ATS treats it identically (the app allows
    /// cleartext local networking, and nothing else) and the only difference between this
    /// launch and a healthy one is that nobody answers.
    ///
    /// Port 9 is `discard`, which macOS does not run.
    private static let deadAPI = "http://localhost:9"

    func testALaunchThatCannotReachTheAPIKeepsTheSessionAndComesBackSignedIn() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: A real session to lose

        signUpAndActivate(app, email: email)
        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 10),
            "Did not land on the tab bar"
        )

        // MARK: A launch with nothing to talk to
        //
        // This is the launch that used to sign the user out. It has to be honest about
        // what it knows — the API is unreachable — without claiming the credential is bad.

        relaunch(app, api: Self.deadAPI)
        XCTAssertTrue(
            app.staticTexts["unreachable.title"].waitForExistence(timeout: 20),
            "A launch that could not reach the API showed no retry screen"
        )
        XCTAssertFalse(
            app.textFields["signup.email"].exists,
            "A launch that could not reach the API signed the user out and asked for a password"
        )
        // Acceptance criterion 3: something honest, and not a spinner that never resolves.
        // The wording, not just the element — the same standard `DeleteAccountUITests`
        // holds the delete modal to. "You're still signed in" is the only sentence that
        // tells the user what actually happened, it is the reason they will wait rather
        // than start hunting for their password, and it is true only because of #61. If
        // the behaviour is ever reverted this sentence becomes a lie, and an existence
        // check would keep passing while it was one.
        let body = app.staticTexts["unreachable.body"]
        XCTAssertTrue(body.exists, "The retry screen shows a title with no explanation")
        XCTAssertTrue(
            body.label.contains("still signed in"),
            "The retry screen never tells the user the session survived: \(body.label)"
        )
        XCTAssertFalse(
            app.activityIndicators.firstMatch.exists,
            "The launch resolved to a spinner rather than to a screen"
        )

        // Tapping Try again while the API is still down. It cannot succeed, so what is
        // asserted here is only that failing again neither ejects the user nor leaves the
        // screen. What makes the tap worth making is the section below: `retry()` is
        // `bootstrap()` again, so a retry that damaged the session would show up as the
        // *next* launch landing on onboarding.
        tap(app.buttons["primary.Try again"], in: app)
        XCTAssertTrue(
            app.staticTexts["unreachable.title"].waitForExistence(timeout: 20),
            "Retrying against an API that is still down left the retry screen"
        )
        XCTAssertFalse(
            app.textFields["signup.email"].exists,
            "A retry that failed the same way as the launch signed the user out"
        )

        // MARK: The assertion the issue exists for
        //
        // Same install, same Keychain, no reset — the API is simply back. Everything above
        // is satisfied by an app that showed a nice screen and cleared the token behind
        // it; this is the only step that can tell the difference, and before #61 it landed
        // on onboarding.

        relaunch(app, api: Self.apiBaseURL)
        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 25),
            "The session did not survive a launch that could not reach the API — "
                + "the app came up signed out with the API available again"
        )
        XCTAssertFalse(
            app.textFields["signup.email"].exists,
            "The app reached the tab bar but left onboarding on screen"
        )

        // MARK: The way out of a launch that never works
        //
        // Keeping the token removed the ejection that used to be automatic, so the retry
        // screen needs a door. This half is here rather than in its own test because it
        // needs exactly what the sections above already built: an account, signed in, with
        // a launch that cannot reach the API.

        relaunch(app, api: Self.deadAPI)
        XCTAssertTrue(
            app.staticTexts["unreachable.title"].waitForExistence(timeout: 20),
            "The second unreachable launch showed no retry screen"
        )
        tap(app.buttons["text.Log out"], in: app)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 10),
            "Log out on the retry screen did not reach onboarding, so the screen has no exit"
        )

        // And it was a log out, not a screen change. Against the *live* API: if the token
        // were still there it would validate and this launch would reach the tab bar.
        relaunch(app, api: Self.apiBaseURL)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 25),
            "Logging out of the retry screen left the token in the Keychain — the app signed itself back in"
        )
        XCTAssertFalse(
            app.buttons["tab.calendar"].exists,
            "A relaunch after logging out of the retry screen went straight into the app"
        )
    }

    /// Relaunches the same install with `EVA_UITEST_RESET` **removed**, pointed at
    /// `apiBaseURL`.
    ///
    /// The removal is the whole test. `AppSession.init` clears the Keychain whenever that
    /// variable is set, and a relaunch is a new process and therefore a new session
    /// object — so a relaunch that still carried it would wipe the token before
    /// `bootstrap()` ever read it, and "the token survived" would be a claim about
    /// nothing. `launch()` sets it; this deliberately does not, which makes these the only
    /// launches in the target that see what the previous one left behind.
    ///
    /// The reset used to live inside `bootstrap()`, where it also fired on every tap of
    /// **Try again**. It is once per process now, which narrows the trap but does not
    /// remove it: this helper is still the only thing standing between these launches and
    /// an empty Keychain, and the mutation that deletes the line below still fails.
    ///
    /// Local to this file for the same reason `ProfileLogOutUITests` keeps its own: every
    /// other test wants the clean slate, and a shared helper that skips it is a trap.
    private func relaunch(_ app: XCUIApplication, api apiBaseURL: String) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launchEnvironment["EVA_API_BASE_URL"] = apiBaseURL
        app.launch()
    }
}

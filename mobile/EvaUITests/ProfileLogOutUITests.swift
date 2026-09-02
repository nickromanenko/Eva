import XCTest

/// Log out, which #55 moved off the dashboard and onto Profile.
///
/// The button it replaced was never tested either, so this is not a coverage regression —
/// but the path to it got longer. Signing out now depends on a navigation link and a
/// screen that did not exist before, and an app that cannot sign out is a worse failure
/// than most of what this suite does cover.
///
/// Separate from `DeleteAccountUITests` on purpose: both start on Profile, but one signs
/// out and the other destroys the account, so a single test would have to pick an order
/// and the second half would be testing whatever the first half left behind.
///
/// This one does leave an account for `scripts/e2e-cleanup.ts` to sweep — logging out is
/// not deleting, and the whole point of the last assertion is that the account is still
/// there and still reachable.
final class ProfileLogOutUITests: EvaUITestCase {

    func testLoggingOutFromProfileReturnsToOnboardingAndForgetsTheAccount() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: A signed-in session to end

        signUpAndActivate(app, email: email)
        completeQuestionnaire(app)
        XCTAssertTrue(
            app.staticTexts["You're all set"].waitForExistence(timeout: 15),
            "Questionnaire submission did not reach the done screen"
        )
        tap(app.buttons["primary.Enter Eva"], in: app)
        XCTAssertTrue(
            app.staticTexts["dashboard.title"].waitForExistence(timeout: 10),
            "Did not land on the dashboard"
        )

        // MARK: The path that got longer

        tap(app.buttons["dashboard.profile"], in: app)
        let profileEmail = app.staticTexts["profile.email"]
        XCTAssertTrue(
            profileEmail.waitForExistence(timeout: 10),
            "The dashboard has no way through to Profile, which is now the only way to log out"
        )
        XCTAssertEqual(
            profileEmail.label, email,
            "Profile is showing a different account than the one that just signed up"
        )

        tap(app.buttons["profile.logout"], in: app)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 10),
            "Log out did not return the app to signed-out onboarding"
        )
        // Popping back to the dashboard would also leave Profile behind, and would not be
        // a log out.
        XCTAssertFalse(
            app.staticTexts["dashboard.title"].exists,
            "Log out dismissed Profile but left the user signed in on the dashboard"
        )

        // MARK: The Keychain half
        //
        // Everything above is satisfied by a log out that changed `AppSession.state` and
        // left the token in the Keychain — the user would be back on onboarding now and
        // signed straight back in at next launch. The only way to see the difference is
        // to relaunch *without* `EVA_UITEST_RESET`, which is the one launch in this
        // target that does not wipe the Keychain first, and check the app still comes up
        // signed out.
        relaunchKeepingTheKeychain(app)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 20),
            "The app signed itself back in after a log out — the token survived in the Keychain"
        )
        XCTAssertFalse(
            app.staticTexts["dashboard.title"].exists,
            "A relaunch after log out went straight to the dashboard"
        )

        // The account itself is untouched: log out is not deletion, and a log out that
        // quietly took the account with it would otherwise look identical from here.
        tap(app.buttons["text.Log in"], in: app)
        XCTAssertTrue(
            app.staticTexts["Welcome back"].waitForExistence(timeout: 5),
            "The sign-up screen's cross-link did not reach the log-in screen"
        )
        type(email, into: app.textFields["login.email"], in: app)
        revealAndTypePassword(Self.password, prefix: "login", in: app)
        tap(app.buttons["primary.Log in"], in: app)
        XCTAssertTrue(
            app.staticTexts["dashboard.title"].waitForExistence(timeout: 15),
            "The account could not be logged back into after logging out of it"
        )
    }

    /// Relaunches with the API override but **without** `EVA_UITEST_RESET`, so whatever
    /// the app left in the Keychain is still there when `AppSession.bootstrap()` runs.
    ///
    /// Deliberately local to this test rather than on `EvaUITestCase`: every other test in
    /// the target wants the clean slate, and a shared helper that skips it is a trap.
    private func relaunchKeepingTheKeychain(_ app: XCUIApplication) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launch()
    }
}

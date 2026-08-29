import XCTest

/// The harness every UI test in this target shares: launching the app against the API
/// the harness started, creating a real account, and the element helpers that make
/// XCUITest behave inside a SwiftUI `ScrollView`.
///
/// These began as private helpers on `OnboardingSignUpUITests`. #55 added a second suite
/// that has to reach the dashboard before it can test anything, and one copy of a flow
/// that signs up and answers a questionnaire is the only way both suites keep meaning the
/// same thing by it.
///
/// Every account is `e2e+<uuid>@e2e.evaapp.dev`, which is the pattern
/// `scripts/e2e-cleanup.ts` sweeps at the end of `scripts/verify-mobile.sh` (GUARDRAILS
/// §16). Anything outside it is left behind in a real project.
class EvaUITestCase: XCTestCase {

    /// Eight characters and a digit — the rule the sign-up screen states and the CTA
    /// enforces. The API only enforces the length (#20).
    static let password = "uitest-pass-1"

    override func setUp() {
        super.setUp()
        // Every test here is one sequential flow; a failure halfway through makes the
        // rest of the assertions noise.
        continueAfterFailure = false
    }

    // MARK: - Flow helpers

    static func freshEmail() -> String {
        "e2e+\(UUID().uuidString.lowercased())@e2e.evaapp.dev"
    }

    /// Launches (or relaunches) the app with the Keychain cleared and pointed at the
    /// API the harness started. Pass the same instance back to relaunch it.
    @discardableResult
    func launch(_ existing: XCUIApplication? = nil) -> XCUIApplication {
        let app = existing ?? XCUIApplication()
        app.launchEnvironment["EVA_UITEST_RESET"] = "1"
        // scripts/verify-mobile.sh passes TEST_RUNNER_EVA_API_BASE_URL so the app
        // targets the API the harness actually started; falls back to the DEBUG default.
        let apiBaseURL = ProcessInfo.processInfo.environment["EVA_API_BASE_URL"]
            ?? "http://localhost:3003"
        app.launchEnvironment["EVA_API_BASE_URL"] = apiBaseURL
        print("UI test targeting API at \(apiBaseURL)")
        app.launch()
        return app
    }

    func fillSignUpForm(_ app: XCUIApplication, email: String) {
        type(email, into: app.textFields["signup.email"], in: app)
        revealAndTypePassword(Self.password, prefix: "signup", in: app)
    }

    /// Drives one failed log in from the sign-up screen and returns the message shown.
    ///
    /// Also asserts the failure is a failure: nothing routes onward. Without that, two
    /// successful log-ins would return two empty strings and compare equal — and #55's
    /// deleted-account check would pass for an account that is still there.
    ///
    /// Both destinations are checked because callers arrive with different accounts: an
    /// account that never finished the questionnaire lands on "A little about you", one
    /// that did lands on the dashboard.
    @discardableResult
    func failedLogIn(
        _ app: XCUIApplication,
        email: String,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        tap(app.buttons["text.Log in"], in: app)
        XCTAssertTrue(
            app.staticTexts["Welcome back"].waitForExistence(timeout: 5),
            "The sign-up screen's cross-link did not reach the log-in screen",
            file: file, line: line
        )

        type(email, into: app.textFields["login.email"], in: app)
        revealAndTypePassword(password, prefix: "login", in: app)
        tap(app.buttons["primary.Log in"], in: app)

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 15),
            "A failed log in showed no error at all for \(email)",
            file: file, line: line
        )
        XCTAssertFalse(
            app.staticTexts["A little about you"].exists,
            "A failed log in still routed into the app for \(email)",
            file: file, line: line
        )
        XCTAssertFalse(
            app.staticTexts["dashboard.title"].exists,
            "A failed log in still reached the dashboard for \(email)",
            file: file, line: line
        )
        return error.label
    }

    /// Chips are navigated by `chip.<label>` since #14 gave `ChipToggleButton` an
    /// identifier. They used to be looked up by their label, which still resolves — an
    /// element with both an identifier and a label answers to either — but a test that
    /// keeps using the label would not notice the identifier being dropped again, which
    /// is the thing GUARDRAILS §22 is about.
    func completeQuestionnaire(_ app: XCUIApplication) {
        tap(app.buttons["primary.Continue"], in: app)     // about you
        tap(app.buttons["chip.Energy"], in: app)          // goals
        tap(app.buttons["primary.Continue"], in: app)
        tap(app.buttons["chip.None of these"], in: app)   // health
        tap(app.buttons["chip.No"], in: app)
        tap(app.buttons["primary.Continue"], in: app)
        tap(app.buttons["chip.Active"], in: app)          // lifestyle
        tap(app.buttons["chip.Yoga"], in: app)
        tap(app.buttons["primary.Build my plan"], in: app)
    }

    // MARK: - Element helpers

    /// Reveals the password, then types into it as a plain text field.
    ///
    /// `typeText` into a `SecureField` only ever lands one character (verified on the
    /// iOS 18.5 and 26 simulators), which is why this test used to paste. #3's reveal
    /// button swaps the `SecureField` for a `TextField` carrying the *same*
    /// identifier — so revealing first makes the field typeable and the pasteboard
    /// workaround unnecessary.
    ///
    /// Revealing before the field has focus is deliberate: the reveal button does not
    /// take focus, so this leaves the caret wherever it was and the following tap is
    /// what moves it.
    func revealAndTypePassword(
        _ password: String,
        prefix: String,
        in app: XCUIApplication
    ) {
        tap(app.buttons["\(prefix).password.reveal"], in: app)
        type(password, into: app.textFields["\(prefix).password"], in: app)
    }

    func type(_ text: String, into element: XCUIElement, in app: XCUIApplication) {
        tap(element, in: app)
        element.typeText(text)
    }

    /// Waits for the element, scrolls it into view if it is below the fold, and taps it.
    ///
    /// The scrolling column overflows the frame by about 37 points at the default content
    /// size (DESIGN.md §9a), so a field low on the screen can start just out of reach.
    /// XCUITest's own scroll-to-visible is unreliable inside a SwiftUI `ScrollView`;
    /// swiping is not.
    ///
    /// The swipe goes to the **scroll view**, not to the application. Now that the footer
    /// is pinned outside it, the scroll view is only the top part of the screen — 356 of
    /// 874 points with the keyboard up — and `app.swipeUp()` starts its drag at the app's
    /// centre, which lands in the footer and scrolls nothing. That is why every test in
    /// this file failed on the first run after `dismissKeyboard(in:)` came out: the
    /// workaround was hiding a scroll that never happened, not just a keyboard.
    ///
    /// It only ever swipes **up**. `AuthScreenLayout` sets
    /// `.scrollDismissesKeyboard(.interactively)`, which follows a *downward* drag — so
    /// nothing here can dismiss a keyboard and quietly turn an unreachable footer into a
    /// reachable one. That the footer needs neither is asserted directly, in
    /// `testTheFooterStaysReachableWithTheKeyboardUp`.
    func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Missing element: \(element)", file: file, line: line
        )
        let column = app.scrollViews.firstMatch
        var swipes = 0
        while !element.isHittable && swipes < 4 {
            if column.exists {
                column.swipeUp()
            } else {
                app.swipeUp()
            }
            swipes += 1
        }
        XCTAssertTrue(
            element.isHittable,
            """
            Element never became hittable: \(element)
              element frame: \(element.frame)
              app frame:     \(app.frame)
              keyboard:      \(app.keyboards.element.exists ? "\(app.keyboards.element.frame)" : "none")
            """,
            file: file, line: line
        )
        element.tap()
    }
}

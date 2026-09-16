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

    /// The API the harness actually started. `scripts/verify-mobile.sh` passes it to the
    /// runner as `TEST_RUNNER_EVA_API_BASE_URL`, which xcodebuild forwards with the prefix
    /// stripped; the DEBUG default is the fallback for a run started by hand.
    ///
    /// A property rather than a local in `launch()` because #61's suite relaunches the app
    /// against a host that is not listening and then has to point it back here.
    static let apiBaseURL = ProcessInfo.processInfo.environment["EVA_API_BASE_URL"]
        ?? "http://localhost:3003"

    /// Launches (or relaunches) the app with the Keychain cleared and pointed at the
    /// API the harness started. Pass the same instance back to relaunch it.
    @discardableResult
    func launch(_ existing: XCUIApplication? = nil) -> XCUIApplication {
        let app = existing ?? XCUIApplication()
        app.launchEnvironment["EVA_UITEST_RESET"] = "1"
        app.launchEnvironment["EVA_API_BASE_URL"] = Self.apiBaseURL
        print("UI test targeting API at \(Self.apiBaseURL)")
        app.launch()
        return app
    }

    /// The UI-test mailbox `scripts/verify-mobile.sh` starts beside the API. Same
    /// forwarding as `apiBaseURL`; the DEBUG default is for a run started by hand.
    static let mailboxURL = ProcessInfo.processInfo.environment["EVA_MAILBOX_URL"]
        ?? "http://localhost:3103"

    /// An address and nothing else (#120). Sign-up has no password field: the credential is
    /// chosen on the activation page, in the request that spends the link.
    func fillSignUpForm(_ app: XCUIApplication, email: String) {
        type(email, into: app.textFields["signup.email"], in: app)
    }

    /// Sign up, pass the activation gate, and land on the questionnaire.
    ///
    /// Sign-up creates no account (#120): it sends an address and a link, and the account
    /// comes into existence when that link is spent *with a password*. A simulator has no
    /// mailbox and cannot reach the web form, so both halves are done out of band by
    /// `api/scripts/uitest-mailbox.ts` — which issues a real token and spends it on the
    /// real `POST /auth/activate`, setting `Self.password`.
    ///
    /// The app cannot sign itself in afterwards, and that is not a gap: it never held the
    /// password, because the user never typed one into it. So this signs in the way a
    /// person would, on the log-in screen, with the password they chose on the web.
    ///
    /// Every suite that needs an account goes through here, so the four of them keep
    /// meaning the same thing by "signed up".
    func signUpAndActivate(
        _ app: XCUIApplication,
        email: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        fillSignUpForm(app, email: email)

        let submit = app.buttons["primary.Create account"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(
            submit.isEnabled,
            "Sign-up CTA stayed disabled — form input did not land",
            file: file, line: line
        )
        tap(submit, in: app)

        XCTAssertTrue(
            app.staticTexts["Check your inbox"].waitForExistence(timeout: 15),
            "Sign-up did not reach the activation gate",
            file: file, line: line
        )

        activate(email: email, file: file, line: line)

        signIn(app, email: email, password: Self.password, file: file, line: line)

        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 20),
            "Signing in after activation did not reach the questionnaire",
            file: file, line: line
        )
    }

    /// Asks the mailbox to open the activation link for `email`. Synchronous: the test
    /// has nothing to do until the account is through.
    func activate(email: String, file: StaticString = #filePath, line: UInt = #line) {
        var request = URLRequest(url: URL(string: "\(Self.mailboxURL)/activate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])

        let finished = expectation(description: "mailbox activates \(email)")
        var status = 0
        var failure: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error?.localizedDescription
                ?? data.flatMap { String(data: $0, encoding: .utf8) }
            finished.fulfill()
        }.resume()
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(
            status, 200,
            """
            The UI-test mailbox did not activate \(email): \(failure ?? "no response").
            It is started by scripts/verify-mobile.sh — running xcodebuild directly needs
            it up, or EVA_MAILBOX_URL pointed at one.
            """,
            file: file, line: line
        )
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
    /// Signs in through the log-in screen and asserts it got somewhere.
    ///
    /// Needed since #120: sign-up creates no account and the app never sees a password, so
    /// there is nothing for it to retry with after activation. A person signs in here too —
    /// with the password they chose on the activation page — so the test does what they do.
    func signIn(
        _ app: XCUIApplication,
        email: String,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // From wherever the caller is. After `signUpAndActivate` that is the activation
        // gate, whose way out is "Change email" back to sign-up; from sign-up it is the
        // "Log in" cross-link. Both are tried because the two callers arrive differently.
        if app.buttons["text.Change email"].waitForExistence(timeout: 3) {
            tap(app.buttons["text.Change email"], in: app)
        }
        if app.buttons["text.Log in"].waitForExistence(timeout: 5) {
            tap(app.buttons["text.Log in"], in: app)
        }
        XCTAssertTrue(
            app.staticTexts["Welcome back"].waitForExistence(timeout: 10),
            "Could not reach the log-in screen",
            file: file, line: line
        )
        // Cleared first: `OnboardingModel` is shared across these screens, so the log-in
        // field arrives carrying whatever sign-up put there. `type` appends, which would
        // silently make the address wrong and the failure look like a bad password.
        clearAndType(email, into: app.textFields["login.email"], in: app)
        revealAndTypePassword(password, prefix: "login", in: app)

        // Read back what the form is actually about to send, before it is sent. The server
        // answers a wrong address and a wrong password with the same sentence on purpose
        // (ARCHITECTURE §3), so without this a typing bug in the harness and a real auth
        // regression are the same failure message and take a second run to tell apart.
        let submitted = formContents(app)
        tap(app.buttons["primary.Log in"], in: app)

        let failure = app.staticTexts["login.error"]
        XCTAssertFalse(
            failure.waitForExistence(timeout: 8),
            // The label, not just the fact: "wrong password" and "confirm your email
            // first" are different bugs, and a bare failure cannot tell them apart.
            """
            Signing in after activation failed for \(email): \
            \(failure.exists ? failure.label : "no error shown")
            The form held \(submitted), expected email \(email.debugDescription) and a \
            \(password.count)-character password.
            """,
            file: file, line: line
        )
    }

    /// What the log-in form is holding, for a failure message.
    ///
    /// The password is reported by length, never by value: it is a fixed test constant
    /// today, and a habit of printing password fields is the wrong one to build (GUARDRAILS
    /// 12). Length is enough to separate "appended to a pre-filled field" from "typed into
    /// an empty one", which is the question these failures actually pose.
    func formContents(_ app: XCUIApplication) -> String {
        let email = (app.textFields["login.email"].value as? String)?.debugDescription
            ?? "<unreadable>"
        let password = (app.textFields["login.password"].value as? String)
            .map { "a \($0.count)-character password" }
            // Not "0 characters": a field that cannot be read and one that is empty are
            // different findings, and this string exists to tell findings apart.
            ?? "a password that could not be read"
        return "email \(email), \(password)"
    }

    /// Taps a field, empties it, then types.
    ///
    /// XCUITest has no clear, so this deletes — but it does **not** trust one pass to work.
    /// The previous version sent `value.count` deletes once and typed; on iOS 26 a long
    /// address lost only 18 of its 55 characters to that burst, and the new text was
    /// appended to the remaining 37. The address went to the server malformed, `/auth/signin`
    /// answered "Wrong email or password" — which is what it answers for everything (#21) —
    /// and eight UI tests reported a credential bug that did not exist (#135).
    ///
    /// So: delete what the field says it holds, read it again, repeat. Re-reading is the
    /// whole point; a burst that under-delivers is absorbed by the next pass. Then assert,
    /// so the next iOS change that breaks clearing fails here, loudly, instead of silently
    /// typing into a half-cleared field.
    func clearAndType(
        _ text: String,
        into element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tap(element, in: app)
        let placeholder = element.placeholderValue ?? ""

        var passes = 0
        var previous: String?
        while passes < 10 {
            // **`nil` is not empty.** A value that cannot be read is the one case this whole
            // helper exists for, and coalescing it to `""` would say "already clear", skip
            // the loop, pass the assertion below, and type into a field still holding 37
            // characters — #135 again, silently. So an unreadable field falls out of the
            // loop and fails the assertion instead.
            guard let current = element.value as? String else { break }
            if current.isEmpty || current == placeholder { break }
            // Stop as soon as a pass achieves nothing, rather than repeating an identical
            // no-op nine more times before failing.
            if current == previous { break }
            previous = current

            // **Put the caret at the end first, every pass.** A tap places it where the
            // finger landed, and backspace only deletes what is to its left — which is why
            // the old one-burst version removed the 18 characters before the caret, left the
            // 37 after it, and then stopped: every further delete was a no-op at position 0.
            // Tapping the field's right edge lands past the last glyph.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            passes += 1
        }

        let cleared = element.value as? String
        XCTAssertTrue(
            cleared.map { $0.isEmpty || $0 == placeholder } ?? false,
            """
            Could not clear \(element.identifier) in \(passes) passes — it still holds \
            \(cleared?.debugDescription ?? "a value that could not be read at all"). Typing \
            now would insert at the caret, and the request would fail as a wrong credential \
            rather than as this.
            """,
            file: file, line: line
        )
        element.typeText(text)

        // The pin the helper was missing: what it typed is what the field holds. Everything
        // above is mechanism, and mechanism can be wrong in a way the mechanism cannot see —
        // this is the assertion that would have caught #135 here, in one line, instead of as
        // eight tests reporting a credential failure.
        XCTAssertEqual(
            element.value as? String, text,
            "\(element.identifier) does not hold what was typed into it",
            file: file, line: line
        )
    }

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

    /// Types into a field that is expected to be empty, and says so if it is not.
    ///
    /// `typeText` appends. Every caller here means "put this in the field", so a field that
    /// arrives carrying something makes the request wrong in a way the server reports as a
    /// bad credential — the #135 failure, one helper over. Callers that know a field is
    /// dirty use `clearAndType`; this one refuses to guess.
    func type(
        _ text: String,
        into element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tap(element, in: app)
        let placeholder = element.placeholderValue ?? ""
        let existing = element.value as? String
        XCTAssertTrue(
            // `nil` is not empty here either — an unreadable field is one this helper
            // cannot promise anything about, so it fails rather than types.
            existing.map { $0.isEmpty || $0 == placeholder } ?? false,
            """
            \(element.identifier) already held \
            \(existing.map { "\($0.count) characters" } ?? "a value that could not be read") \
            — typing would insert at the caret. Use `clearAndType` if the caller expects it \
            to arrive dirty, or `append` if it means to add to it.
            """,
            file: file, line: line
        )
        element.typeText(text)
    }

    /// Types onto the end of whatever a field already holds, on purpose.
    ///
    /// The distinction from `type` is the whole point of #135: appending is legitimate —
    /// `testSignUpRejectsABadEmail` builds a valid address out of an invalid one — and it
    /// was also the defect, silently, in a helper whose name said nothing about it. A caller
    /// that means to append now has to say so.
    func append(_ text: String, into element: XCUIElement, in app: XCUIApplication) {
        tap(element, in: app)
        // The same caret placement `clearAndType` needs, and for the same reason: `typeText`
        // inserts wherever the caret is, so without this a centre tap would put the new text
        // *inside* the old — which is the defect this whole change is about, and it would
        // have been reintroduced by the helper named after doing the opposite.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
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

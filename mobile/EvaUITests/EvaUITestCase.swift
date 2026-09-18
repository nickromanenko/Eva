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
///
/// **`@MainActor` on the base class, and nowhere else.** Every XCUITest API this target
/// touches — `XCUIApplication`, `XCUIElement`, `XCUIElementQuery`, `XCUIDevice` — is
/// declared `@MainActor` by the SDK itself (`XCUI_SWIFT_MAIN_ACTOR` in
/// XCUIAutomationDefines.h), so a nonisolated test method cannot legally call any of them.
/// Isolation is inherited by subclasses, so this one annotation covers all nine suites;
/// annotating the methods would say the same thing 200 times.
///
/// It is stated rather than inferred because the two compilers disagree about inferring
/// it. Xcode 26.2 reports the violation as a *warning* and builds anyway; CI's Xcode 16.4
/// reports the identical diagnostic as an *error* and does not. That is why this target
/// had never once compiled in CI (#158's `Full suite` job failed on every run from the day
/// it landed) while building cleanly on the machine it was written on — the same 16.4/26.2
/// split #168 fixed for the app target, which did not reach here. The annotation states
/// what was already true of these APIs; nothing about how the tests run changes.
@MainActor
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
    /// that did lands on the tab bar.
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
    /// **Not for password fields.** The assertions below put the field's contents in their
    /// failure messages, and `XCTAssertEqual` prints both operands — so clearing a revealed
    /// password field would write a plaintext password into a failure log (GUARDRAILS 12).
    /// The value is load-bearing here: seeing the mangled address is how #135 was diagnosed.
    /// A password field that ever needs clearing wants its own helper that reports lengths,
    /// the way `type` and `formContents` do.
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
        focusAtEnd(element, in: app, file: file, line: line)
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

            // **The caret has to be at the end before every burst.** Backspace only deletes
            // what is to its left — which is why the old one-burst version removed the 18
            // characters before the caret, left the 37 after it, and then stopped: every
            // further delete was a no-op at position 0.
            //
            // The first pass already has it there, from `focusAtEnd` above. A later pass does
            // not: the burst it follows ran the caret down to position 0 with the overflow
            // still to its right, so the field has to be tapped again. Skipping it on the
            // first pass is not just economy — a second tap landing on the same field within
            // the double-tap interval selects a word, and `typeText` would then replace the
            // selection instead of inserting at a caret.
            if passes > 0 { caretToEnd(element) }
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
            app.buttons["tab.calendar"].exists,
            "A failed log in still reached the app for \(email)",
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
        tap(app.buttons["chip.None"], in: app)            // hormonal medication (#81)
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
    func append(
        _ text: String,
        into element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The same caret placement `clearAndType` needs, and for the same reason: `typeText`
        // inserts wherever the caret is, so without this a centre tap would put the new text
        // *inside* the old — which is the defect #135 is about, and it would have been
        // reintroduced by the helper named after doing the opposite.
        focusAtEnd(element, in: app, file: file, line: line)

        let placeholder = element.placeholderValue ?? ""
        // A field showing its placeholder holds nothing, the same reading `type` takes.
        // `nil` stays `nil`: a value that cannot be read is not an empty one, and the
        // assertion below is the right place for it to fail.
        let existing = (element.value as? String).map { $0 == placeholder ? "" : $0 }
        element.typeText(text)

        // The pin `clearAndType` has carried since #135, now here too. Everything above is
        // mechanism, and #166 was that mechanism tapping a different screen's cross-link
        // and typing into whatever it landed on. This says, in one line, that the text went
        // onto the end of this field — instead of the test failing three assertions later
        // on a validation result that makes no sense.
        XCTAssertEqual(
            element.value as? String,
            existing.map { $0 + text },
            "\(element.identifier) does not hold what was appended to it",
            file: file, line: line
        )
    }

    /// Waits for the element and scrolls it into view if it is below the fold. Touches
    /// nothing.
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
    ///
    /// ## `isHittable` alone is not enough, and the way it fails is silent (#82)
    ///
    /// The loop used to stop as soon as `isHittable` was true. It is true for an element
    /// that only *overhangs* the bottom of the window: XCUITest clamps the hit point into
    /// the visible sliver, reports the element hittable, and then `tap()` sends the touch
    /// to a point the tab bar is sitting on. Nothing errors — the tap lands, on the wrong
    /// view — and the test fails several assertions later on a screen that never changed.
    ///
    /// That is exactly what #82 hit: one settings row on Profile pushed
    /// `destructive.Delete profile` to `y 827…879` in an 874-point window, and
    /// `DeleteAccountUITests` failed 3 runs in 3 with "the danger card did not open the
    /// confirmation modal". The content scrolled perfectly well; nothing ever scrolled it.
    ///
    /// So the loop also runs while the element's `maxY` is past the window's. A swipe is
    /// what fixes that case, and an element that genuinely cannot move any further falls
    /// out after four and meets the same `isHittable` assertion it always did — so this
    /// only ever adds scrolling, never a new way to fail.
    ///
    /// It does **not** also scroll to make an element *exist*. That is the neighbouring
    /// hole, it is real — a `LazyVGrid`'s cells are absent from the hierarchy until the
    /// scroll comes near them, which is why `chip.None` breaks `completeQuestionnaire` on
    /// `main` since #211 — and it is not this branch's to close. Verified separately, not
    /// assumed: `CalendarLoggingUITests` fails identically on `origin/main` at 73cf0d6
    /// with none of #82 present.
    func scrollIntoView(
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
        var swipes = 0
        while (!element.isHittable || element.frame.maxY > app.frame.maxY) && swipes < 4 {
            swipeColumn(in: app)
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
    }

    /// One swipe of the screen's scrolling column.
    ///
    /// The scroll view rather than the application, for the reason `scrollIntoView`
    /// gives: a pinned footer takes `app.swipeUp()`'s drag and scrolls nothing.
    private func swipeColumn(in app: XCUIApplication) {
        let column = app.scrollViews.firstMatch
        if column.exists {
            column.swipeUp()
        } else {
            app.swipeUp()
        }
    }

    /// Scrolls the element into view and taps its centre.
    func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        scrollIntoView(element, in: app, timeout: timeout, file: file, line: line)
        element.tap()
    }

    /// Focuses a text field and leaves the caret after its last character — in **one** tap.
    ///
    /// `typeText` inserts at the caret, and a tap puts the caret where the finger landed, so
    /// anything that means to add to a field has to land past its last glyph. The field's
    /// trailing edge does that, and — because a tap on an unfocused field also focuses it —
    /// one tap is enough for both.
    ///
    /// **One tap is the fix for #166, not an economy.** This used to tap the centre and then
    /// the trailing edge. The first tap raises the keyboard, and the two halves of the screen
    /// answer that at different speeds: `AuthScreenLayout`'s footer is outside the scroll view
    /// and is re-laid out immediately, while the field is inside it and is *animated* into
    /// view over about 280ms. XCUITest's wait-for-idle returns in the middle of that — measured
    /// at 547ms after the tap, with the field still reported at its old y — so the second tap's
    /// coordinates were resolved against a frame with 189 points of travel left in it. By the
    /// time the touch landed, the footer had moved into the band the field was leaving, and the
    /// tap went to the sign-up screen's "Log in" cross-link. `testSignUpRejectsABadEmail` then
    /// typed into a log-in screen and failed 7 runs in 9.
    ///
    /// So: settle, tap once, settle. `stillFrame` is what makes it safe — a coordinate is only
    /// ever computed from a frame that has stopped moving, and the reflow this tap causes
    /// happens after it has landed rather than under it.
    func focusAtEnd(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        scrollIntoView(element, in: app, timeout: timeout, file: file, line: line)
        caretToEnd(element)
    }

    /// Puts the caret after the last character of an **already focused** field.
    ///
    /// Split out of `focusAtEnd` for `clearAndType`, which has to come back to the end
    /// between delete bursts. On a field whose text overflows, the trailing edge is the last
    /// *visible* glyph rather than the last one — which is why that loop re-reads and repeats
    /// rather than trusting one burst (#135).
    func caretToEnd(_ element: XCUIElement) {
        stillFrame(of: element)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        // And again afterwards, so the reflow this tap causes is over before the caller
        // types into it or reads it back.
        stillFrame(of: element)
    }

    /// `element.frame`, once three consecutive reads agree on it.
    ///
    /// Each read is a fresh accessibility snapshot, which on the iOS 26 simulator costs about
    /// 35ms — so agreement across three of them is roughly 100ms of a screen that is holding
    /// still, and a keyboard-driven reflow moves 17 to 46 points between two of them.
    ///
    /// This is the guard #166 needed: XCUITest's own wait-for-idle does not cover a SwiftUI
    /// scroll animation, so "the app is idle" and "the element is where it will be" are not
    /// the same claim. Returns the last frame it saw if the screen never settles, and leaves
    /// the caller's own assertion to report that — a helper that waits for stillness should
    /// not also decide that stillness was mandatory.
    @discardableResult
    func stillFrame(of element: XCUIElement, timeout: TimeInterval = 5) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var frame = element.frame
        var agreements = 0
        while agreements < 2 && Date() < deadline {
            let next = element.frame
            agreements = next == frame ? agreements + 1 : 0
            frame = next
        }
        return frame
    }
}

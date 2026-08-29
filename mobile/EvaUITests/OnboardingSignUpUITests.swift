import XCTest

/// End-to-end coverage of the auth flow, against a running API and the real Firebase
/// project.
///
/// #3 collapsed the five public screens (welcome → two info screens → method picker →
/// email form) into the canvas' single sign-up screen, plus a log-in screen it
/// cross-links to. This suite is the project's **only** end-to-end coverage, so it
/// asserts the same thing the five-screen version did — sign-up creates a real account
/// and the app routes through the questionnaire to the dashboard — and adds what the new
/// screens made testable: log in for an account that already exists, the sign-up screen's
/// own validation, the duplicate-address error, and that the pinned footer stays
/// reachable with the keyboard up.
///
/// Every account is `e2e+<uuid>@e2e.evaapp.dev`, which is the pattern
/// `scripts/e2e-cleanup.ts` sweeps at the end of `scripts/verify-mobile.sh`. Anything
/// outside it is left behind in a real project.
///
/// The launch, flow and element helpers live on `EvaUITestCase`; they moved there with
/// #55, unchanged, when a second suite needed the same route to the dashboard.
final class OnboardingSignUpUITests: EvaUITestCase {

    /// The rule the password field states as helper text, verbatim from
    /// `CreateAccountStepView.passwordRule`. Duplicated rather than shared because a UI
    /// test cannot import the app target — which is the point: if the screen's wording
    /// changes, this suite should have to notice.
    private static let passwordRule = "At least 8 characters, including one number."

    // MARK: - The core path

    /// The assertion this suite exists for: a real sign-up, the questionnaire it routes
    /// into, and the dashboard on the other side.
    func testSignUpRoutesThroughTheQuestionnaireToTheDashboard() throws {
        let app = launch()
        let email = Self.freshEmail()

        fillSignUpForm(app, email: email)

        // Fail here, not three screens later, if the form did not actually receive input.
        let submit = app.buttons["primary.Create account"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled, "Sign-up CTA stayed disabled — form input did not land")
        tap(submit, in: app)

        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 15),
            "Sign-up did not redirect to the questionnaire"
        )

        completeQuestionnaire(app)

        // Done screen after a successful PUT, then the dashboard.
        XCTAssertTrue(
            app.staticTexts["You're all set"].waitForExistence(timeout: 15),
            "Questionnaire submission did not reach the done screen"
        )
        tap(app.buttons["primary.Enter Eva"], in: app)
        XCTAssertTrue(
            app.staticTexts["dashboard.title"].waitForExistence(timeout: 10),
            "Did not land on the dashboard"
        )
    }

    // MARK: - Log in

    /// Log in for an account that already exists, reached through the sign-up screen's
    /// cross-link — the only way to the log-in screen, since the public flow has no back
    /// button.
    ///
    /// The account is created through the UI in the same test rather than fixtured: a
    /// standing account in the real project would either be swept by
    /// `scripts/e2e-cleanup.ts` or, if named to survive it, be real garbage.
    ///
    /// Landing back on the questionnaire is the assertion, not an accident of ordering:
    /// this account never finished one, and `AppSession` takes
    /// `questionnaireCompleted` from the server. So reaching "A little about you" proves
    /// the sign-in returned a token *and* that the server's answer routed the app.
    func testLogInWithAnExistingAccountResumesTheQuestionnaire() throws {
        let app = launch()
        let email = Self.freshEmail()

        fillSignUpForm(app, email: email)
        tap(app.buttons["primary.Create account"], in: app)
        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 15),
            "Could not create the account this test logs in with"
        )

        // Relaunch with the Keychain cleared: the app is signed out and knows nothing
        // about the account that now exists on the server.
        app.terminate()
        launch(app)

        tap(app.buttons["text.Log in"], in: app)
        XCTAssertTrue(
            app.staticTexts["Welcome back"].waitForExistence(timeout: 5),
            "The sign-up screen's cross-link did not reach the log-in screen"
        )

        type(email, into: app.textFields["login.email"], in: app)
        revealAndTypePassword(Self.password, prefix: "login", in: app)

        let submit = app.buttons["primary.Log in"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled, "Log-in CTA stayed disabled — form input did not land")
        tap(submit, in: app)

        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 15),
            "Log in did not restore the session and route to the unfinished questionnaire"
        )
    }

    /// A failed log in says the same thing whether or not the account exists.
    ///
    /// This is the `login` artboard's spec note, verbatim: "failed login shows one
    /// combined message to avoid leaking which emails exist." It is an acceptance
    /// criterion, not a nicety — a message that differs between "wrong password" and
    /// "no such user" turns the log-in screen into an address-enumeration oracle for
    /// a health app.
    ///
    /// So the assertion is the property itself, not the wording: the same two failures
    /// are driven through the real API and the two messages must be **equal**. Matching
    /// on words would pass for any pair of messages that both happened to contain
    /// "password"; equality cannot. The wording is then checked separately, for the one
    /// thing equality would not catch — a message that echoes the address back.
    ///
    /// The API returns `INVALID_CREDENTIALS` / "Wrong email or password" for both
    /// (`api/src/index.ts`); this asserts the client actually shows one message for both,
    /// which is the half that lives on this screen.
    func testAFailedLogInSaysTheSameThingWhetherTheAccountExistsOrNot() throws {
        let app = launch()
        let registered = Self.freshEmail()

        // A real account, so the wrong-password branch is genuinely reached rather than
        // collapsing into the no-such-user one.
        fillSignUpForm(app, email: registered)
        tap(app.buttons["primary.Create account"], in: app)
        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 15),
            "Could not create the account this test then fails to log into"
        )

        app.terminate()
        launch(app)
        let wrongPassword = failedLogIn(app, email: registered, password: "definitely-not-it-9")

        // An address that was never registered. Still inside the `e2e+*@e2e.evaapp.dev`
        // pattern (GUARDRAILS §16) even though nothing should ever create it — if a
        // future change did, the cleanup sweep would still find it.
        app.terminate()
        launch(app)
        let unknownAddress = failedLogIn(app, email: Self.freshEmail(), password: Self.password)

        XCTAssertEqual(
            wrongPassword, unknownAddress,
            """
            Log in tells the two failures apart, which says whether an address has an \
            account:
              wrong password on a real account: "\(wrongPassword)"
              address that does not exist:      "\(unknownAddress)"
            """
        )
        XCTAssertFalse(
            wrongPassword.contains(registered),
            "The failure message echoes the address back: \(wrongPassword)"
        )
        XCTAssertFalse(
            wrongPassword.isEmpty,
            "login.error is present but empty, so the two failures match on nothing"
        )
    }

    // MARK: - The error the screen will actually meet

    /// A second sign-up for an address that already exists.
    ///
    /// `EMAIL_EXISTS` is a client contract (GUARDRAILS §11) and the most likely real
    /// failure on this screen, and it is the only thing that reaches `signup.error`
    /// today — the canvas' account-linking banner needs Apple sign-in (#7) and nothing
    /// can set it.
    ///
    /// The message is asserted, not just the element: the identifier is shared with the
    /// client-side password rule, so an existence check alone would pass on the wrong
    /// error.
    func testSigningUpTwiceWithTheSameAddressShowsTheServerError() throws {
        let app = launch()
        let email = Self.freshEmail()

        fillSignUpForm(app, email: email)
        tap(app.buttons["primary.Create account"], in: app)
        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 15),
            "Could not create the account this test then duplicates"
        )

        app.terminate()
        launch(app)

        fillSignUpForm(app, email: email)
        tap(app.buttons["primary.Create account"], in: app)

        let error = app.staticTexts["signup.error"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 15),
            "A duplicate address was accepted, or its error never reached the screen"
        )
        XCTAssertTrue(
            error.label.contains("already registered"),
            "signup.error carried something other than EMAIL_EXISTS: \(error.label)"
        )

        // The other half of the split. The password rule is a separate element and stays
        // exactly as it was: a server error must not displace it, and must not be routed
        // onto it. Asserted here as well as in the validation test because the defect the
        // split fixed was one of these two masking the other — a check that cannot tell
        // them apart would not catch it in either direction.
        let passwordRule = app.staticTexts["signup.password.rule"]
        XCTAssertTrue(
            passwordRule.exists,
            "The password rule disappeared when the server error arrived"
        )
        XCTAssertTrue(
            passwordRule.label.contains("8 characters"),
            "signup.password.rule carried the server error instead of the rule: \(passwordRule.label)"
        )
        XCTAssertFalse(
            error.label.contains("8 characters"),
            "signup.error carried the client-side rule: \(error.label)"
        )

        XCTAssertFalse(
            app.staticTexts["A little about you"].exists,
            "A duplicate sign-up still routed into the questionnaire"
        )
    }

    // MARK: - The keyboard

    /// The bug this suite used to work around, asserted instead of worked around.
    ///
    /// The first version of these screens put the CTA, the legal note and the cross-link
    /// inside the same `ScrollView` as the form. The column is taller than a real iPhone
    /// frame, so with the keyboard up the scroll view was already at its content bottom
    /// while the button was still behind the keyboard — unreachable by any amount of
    /// scrolling. `dismissKeyboard(in:)` used to drag it away; that helper is gone, and
    /// this is what replaces it.
    ///
    /// `AuthScreenLayout` now holds the footer outside the scroll view. So the assertion
    /// is the strict one: with the keyboard up and **no swipe and no dismissal of any
    /// kind**, both the CTA and the cross-link are hittable, and neither overlaps the
    /// keyboard's frame. `isHittable` alone would not be enough — an element can report
    /// hittable at a corner that pokes out — so the frames are compared too.
    ///
    /// Sign-up is the screen that had the bug and is the one measured here. Log in draws
    /// the same scaffold, and `testLogInWithAnExistingAccountResumesTheQuestionnaire`
    /// taps its CTA straight after typing into its password field, which is the same
    /// keyboard-up condition without the frame arithmetic.
    func testTheFooterStaysReachableWithTheKeyboardUp() throws {
        let app = launch()

        // Focus ends in the password field — the lowest one, and the worst case.
        fillSignUpForm(app, email: Self.freshEmail())

        let keyboard = app.keyboards.element
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "No keyboard came up, so this test proves nothing"
        )

        let cta = app.buttons["primary.Create account"]
        let crossLink = app.buttons["text.Log in"]

        for (name, element) in [("CTA", cta), ("cross-link", crossLink)] {
            XCTAssertTrue(element.exists, "The \(name) is not on screen with the keyboard up")
            XCTAssertTrue(
                element.isHittable,
                """
                The \(name) is not hittable with the keyboard up, and nothing here scrolled
                or dismissed anything to help it.
                  element frame: \(element.frame)
                  keyboard:      \(keyboard.frame)
                """
            )
            XCTAssertLessThanOrEqual(
                element.frame.maxY, keyboard.frame.minY,
                """
                The \(name) is drawn under the keyboard — \(element.frame) against a
                keyboard at \(keyboard.frame).
                """
            )
        }
    }

    // MARK: - Validation

    /// The sign-up screen's own gate, with no network involved.
    ///
    /// Both fields are only ever appended to, never cleared: a re-tap on a field puts
    /// the caret wherever the tap landed, and past the end of a short string that is the
    /// end — but only reliably so if nothing has to be deleted first.
    ///
    /// Validation runs on blur, so each assertion follows a tap that moves focus off the
    /// field it is about.
    func testSignUpRejectsABadEmailAndAPasswordWithoutADigit() throws {
        let app = launch()

        let submit = app.buttons["primary.Create account"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertFalse(submit.isEnabled, "The CTA is enabled on an empty form")

        // Bad email. The error appears when focus moves to the password field.
        type("not-an-email", into: app.textFields["signup.email"], in: app)
        revealAndTypePassword("evaprimeee", prefix: "signup", in: app)

        let emailError = app.staticTexts["signup.email.error"]
        XCTAssertTrue(
            emailError.waitForExistence(timeout: 3),
            "An address with no @ blurred without showing the email error"
        )

        // Eight characters is not enough on its own — the screen states a digit too.
        // Blur the password by going back to the email field.
        tap(app.textFields["signup.email"], in: app)

        // The rule is **helper text**, on `signup.password.rule`, and it is drawn in
        // every state — so its presence is not the assertion. Two things are.
        //
        // First, the state. The element keeps one identifier and changes its *label*:
        // unmet reads "Not met yet: …", met reads the bare rule. Before that the state
        // was the ink and a decorative `!` alone, so nothing — no test and no screen
        // reader — could tell the two apart.
        //
        // Second, the split. The rule does not reach `signup.error`, which now carries
        // server failures only. Those two shared one identifier until this branch split
        // them, and a showing rule occupied the slot a submission error needed.
        let passwordRule = app.staticTexts["signup.password.rule"]
        XCTAssertTrue(
            passwordRule.waitForExistence(timeout: 3),
            "The password field has no helper rule at all"
        )
        XCTAssertEqual(
            passwordRule.label, "Not met yet: \(Self.passwordRule)",
            "An unmet rule does not announce itself as unmet: \(passwordRule.label)"
        )
        XCTAssertFalse(
            app.staticTexts["signup.error"].exists,
            "An unmet client-side rule reached signup.error, which is for server failures only — the two identifiers are wired together again"
        )

        // The `!` beside it is decoration and must stay out of the accessibility tree —
        // otherwise VoiceOver reads a bare symbol name before the sentence that already
        // says it. Both marks on screen right now (this one and the email error's) are
        // hidden, so the symbol must not appear as an element at all.
        XCTAssertFalse(
            app.images["exclamationmark.circle.fill"].exists,
            "The decorative `!` mark is exposed to VoiceOver; it should be accessibilityHidden"
        )
        XCTAssertFalse(
            submit.isEnabled,
            "The CTA enabled itself for a bad email and a password with no digit"
        )

        // Fix both, in place. The caret is already at the end of each field.
        app.textFields["signup.email"].typeText("@e2e.evaapp.dev")
        tap(app.textFields["signup.password"], in: app)   // blurs the email
        app.textFields["signup.password"].typeText("1")
        tap(app.textFields["signup.email"], in: app)      // blurs the password

        XCTAssertTrue(submit.isEnabled, "The CTA stayed disabled for a valid email and password")
        XCTAssertFalse(emailError.exists, "The email error survived a valid address")
        // The rule does not disappear once it is met — it is helper text, stated up
        // front, and the artboard keeps it on the screen in both states. What changes is
        // the label: the "Not met yet:" prefix comes off, leaving the bare rule. Asserted
        // as equality in both directions, so a label stuck in either state fails.
        XCTAssertTrue(passwordRule.exists, "The password rule vanished once it was met")
        XCTAssertEqual(
            passwordRule.label, Self.passwordRule,
            "A met rule still announces itself as unmet: \(passwordRule.label)"
        )
        XCTAssertFalse(
            app.images["exclamationmark.circle.fill"].exists,
            "A mark is exposed to VoiceOver with nothing on the form in error"
        )
        XCTAssertFalse(
            app.staticTexts["signup.error"].exists,
            "A server-error element appeared with no submission behind it"
        )
    }

}

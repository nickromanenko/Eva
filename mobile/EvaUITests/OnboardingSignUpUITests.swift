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
    /// The password the log-in cases type. The sign-up screen has no password field since
    /// #120 — the rule it used to state lives on the activation page. Duplicated because a UI
    /// test cannot import the app target — which is the point: if the screen's wording
    /// changes, this suite should have to notice.
    private static let passwordRule = "At least 8 characters, including one number."

    // MARK: - The core path

    /// The assertion this suite exists for: a real sign-up, the questionnaire it routes
    /// into, and the dashboard on the other side.
    func testSignUpRoutesThroughTheQuestionnaireToTheDashboard() throws {
        let app = launch()
        let email = Self.freshEmail()

        signUpAndActivate(app, email: email)
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

        signUpAndActivate(app, email: email)

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
        signUpAndActivate(app, email: registered)

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

        // **Activation is needed now** (#120). Signing up creates no account, and an
        // address whose only claim is an unspent link is not taken — anyone may still
        // complete it, which is the denial-of-service half #120 closes. `409` means an
        // address with an *activated* owner, so the account has to be finished first.
        signUpAndActivate(app, email: email)

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

        // The split this used to guard is gone with the field (#120): there is no
        // client-side rule on this screen to be masked by a server error, because there is
        // no password on this screen. What remains worth asserting is that the server error
        // is the *only* thing in the slot.
        XCTAssertFalse(
            error.label.contains("8 characters"),
            "signup.error carried a password rule that this screen no longer states: \(error.label)"
        )

        XCTAssertFalse(
            app.staticTexts["A little about you"].exists,
            "A duplicate sign-up still routed into the questionnaire"
        )
    }

    // MARK: - The activation gate (#6)

    /// The gate as a user meets it after **sign-up**: the link has just gone out, Resend
    /// is on cooldown, and the screen names the address it was sent to. Then the same
    /// screen is driven the rest of the way — activate out of band, come back to the
    /// foreground, and the account is through, without anything touching the app to tell
    /// it so.
    ///
    /// **It used to arrive here from a refused log in instead**, and that is what broke it
    /// (#135). #120 removed the log-in half — an account that never opened its link has no
    /// password, so there is nothing to type — but left two of its assertions behind. One
    /// of them required Resend to be *enabled*, because on that path nothing had been sent;
    /// on this path sign-up has just sent the link, so the cooldown is running and the same
    /// screen was being asked to be in two states at once, twenty lines apart. The test
    /// could not pass, and had not since #120.
    ///
    /// Where the log-in path's own property is covered now: `api/test/auth.test.ts`,
    /// "signin is refused until the address is confirmed", which builds the shape this can
    /// no longer reach.
    func testSignUpLandsOnTheActivationGateWithResendOnCooldown() throws {
        let app = launch()
        let email = Self.freshEmail()

        fillSignUpForm(app, email: email)
        tap(app.buttons["primary.Create account"], in: app)
        XCTAssertTrue(
            app.staticTexts["Check your inbox"].waitForExistence(timeout: 15),
            "Sign-up did not reach the activation gate"
        )
        // Sign-up has just sent one, so the cooldown is already running — the server's
        // own throttle would refuse a second send inside the same minute anyway, and a
        // button that enables onto a 429 is worse than one that says how long to wait.
        XCTAssertFalse(
            app.buttons["activation.resend"].isEnabled,
            "Resend was available immediately after sign-up sent an email"
        )

        // The rest of this case cannot be reached through the app any more (#120): an
        // account that never opened its link has no password, so there is nothing to type
        // on the log-in screen and no way to meet the `403 NOT_ACTIVATED` gate from here.
        //
        // The gate is not gone — it still guards accounts predating #120 and addresses
        // reserved by calling Identity Toolkit directly — and it is covered where those
        // shapes can actually be built: `api/test/auth.test.ts`, "signin is refused until
        // the address is confirmed", which stands one up with the Admin SDK.
        //
        // What is still worth checking here is the half above: sign-up lands on the gate
        // screen with Resend on cooldown.
        // Vacuous on this path — there is no log-in screen in it — and kept anyway, because
        // what it guards is the gate ever rendering itself as a field error. Cheap, and the
        // day the gate is reachable from log in again it stops being vacuous.
        XCTAssertFalse(
            app.staticTexts["login.error"].exists,
            "The activation gate was shown as a log-in field error as well"
        )
        XCTAssertEqual(
            app.staticTexts["activation.email"].label, email,
            "The gate does not show the address the link was sent to"
        )
        XCTAssertFalse(
            app.staticTexts["dashboard.title"].exists,
            "An unconfirmed account reached the dashboard"
        )

        activate(email: email)
        XCUIDevice.shared.press(.home)
        app.activate()

        // **Still on the gate, and that is correct.** This assertion used to be its
        // opposite — the third thing #120 orphaned here. `ActivationStepView.retrySignIn`
        // needs `model.password`, and since #120 sign-up never asks for one: the password is
        // chosen on the activation page, in a browser, which this app never sees. So coming
        // back to the foreground has nothing to retry with, and the screen cannot advance on
        // its own. Before #120 it could, and the old assertion was right then.
        XCTAssertTrue(
            app.staticTexts["Check your inbox"].waitForExistence(timeout: 10),
            "The gate advanced by itself, which would need a password the app is not given"
        )

        // The way through is the one a person takes: back out to log in, and type the
        // password they chose on the activation page. That the account is *through* — the
        // link really did work — is what the rest of this case was for, so it is still
        // asserted, just via the path that exists.
        signIn(app, email: email, password: Self.password)
        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 20),
            "The account did not get in after the link was opened and the password typed"
        )
    }

    // MARK: - Password reset (#6)

    /// "Forgot password?" reaches the request screen and the request is answered the same
    /// way for any address — the app never learns whether one has an account.
    ///
    /// Driven with an address that was never registered, deliberately: if the screen
    /// only advanced for real accounts, this test would fail, and that difference is
    /// exactly the leak `POST /auth/password/forgot` is written to avoid.
    func testForgotPasswordAdvancesForAnAddressThatHasNoAccount() throws {
        let app = launch()

        tap(app.buttons["text.Log in"], in: app)
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        tap(app.buttons["text.Forgot password?"], in: app)

        XCTAssertTrue(
            app.staticTexts["Reset your password"].waitForExistence(timeout: 5),
            "The log-in screen's link did not reach the reset request screen"
        )

        type(Self.freshEmail(), into: app.textFields["forgot.email"], in: app)
        tap(app.buttons["primary.Send reset link"], in: app)

        XCTAssertTrue(
            app.staticTexts["Link sent"].waitForExistence(timeout: 15),
            "A reset request for an unknown address did not advance — the screen is telling callers which addresses exist"
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

    /// Validation runs on blur, so the assertion follows a tap that moves focus off the
    /// field it is about.
    ///
    /// **The password half of this test is gone, not lost** (#120). The sign-up screen has
    /// no password field: sending a credential for an address nobody has proved is the hole
    /// that issue closes, so the password is chosen on the activation page instead. The rule
    /// and its unmet/met announcement live in `website/src/pages/activate.astro`, which a
    /// simulator cannot reach — `api/test/auth.test.ts` pins the server's WEAK_PASSWORD
    /// message against that page's helper text, which is the part that could silently drift.
    func testSignUpRejectsABadEmail() throws {
        let app = launch()

        let submit = app.buttons["primary.Create account"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertFalse(submit.isEnabled, "The CTA is enabled on an empty form")

        // Blur by tapping the CTA's neighbourhood rather than a second field — there is
        // only one field now.
        // Blur without leaving the screen. Tapping the CTA does nothing while it is
        // disabled, and there is no second field to move focus to any more — so the
        // keyboard's Go key is what ends editing.
        type("not-an-email", into: app.textFields["signup.email"], in: app)
        app.textFields["signup.email"].typeText("\n")

        // `signup.error`, not `signup.email.error`. There is one field on this screen now
        // and therefore one message slot, shared by the client's address check and the
        // server's refusal (#120). The old identifier has no producer anywhere in
        // `mobile/Eva/`, so this assertion could only ever time out — a rename with an
        // un-updated call site, which is what GUARDRAILS 22 is about.
        let emailError = app.staticTexts["signup.error"]
        XCTAssertTrue(
            emailError.waitForExistence(timeout: 5),
            "An address with no @ blurred without showing the email error"
        )
        XCTAssertFalse(submit.isEnabled, "The CTA is enabled for an invalid address")

        // A valid address is all the form needs now. `append`, not `type`: this deliberately
        // completes the invalid address above rather than replacing it, and since #135 a
        // helper that appends has to be asked for by name.
        append("@e2e.evaapp.dev", into: app.textFields["signup.email"], in: app)
        XCTAssertTrue(
            submit.isEnabled,
            "A valid address did not enable the CTA — sign-up asks for nothing else"
        )
    }

}

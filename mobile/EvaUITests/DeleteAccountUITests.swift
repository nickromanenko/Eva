import XCTest

/// Issue #55: account deletion is reachable from inside the app, gated behind a typed
/// `DELETE`, and the account is actually gone afterwards.
///
/// Apple requires an app that can create an account to be able to delete one, so this
/// suite is the evidence for a submission requirement, not just for a screen.
///
/// One test, deliberately. Every step below depends on the one before it — there is no
/// way to reach the modal without a real account and a finished questionnaire, and no way
/// to prove the deletion without the credentials that created it. Split into four tests,
/// each would sign up again and the last would still have to do everything the first
/// three did.
///
/// The account this creates deletes itself, so unlike the rest of the suite it should
/// leave nothing for `scripts/e2e-cleanup.ts` to sweep. It still uses the
/// `e2e+<uuid>@e2e.evaapp.dev` pattern (GUARDRAILS §16): a run that fails before step 6
/// leaves a real account behind, and the sweep is what catches that.
final class DeleteAccountUITests: EvaUITestCase {

    /// The word the modal's field has to contain. Duplicated from
    /// `DeleteAccountModal.confirmationWord` rather than shared — a UI test cannot import
    /// the app target, and if the gate's word ever changes this suite should have to
    /// notice.
    private static let confirmationWord = "DELETE"

    func testDeletingAProfileIsGatedOnTypedDELETEAndRemovesTheAccount() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: An account to delete

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

        // MARK: Reachable without contacting support

        tap(app.buttons["dashboard.profile"], in: app)
        let profileEmail = app.staticTexts["profile.email"]
        XCTAssertTrue(
            profileEmail.waitForExistence(timeout: 10),
            "The dashboard has no way through to Profile"
        )
        // Not decoration: it is the only on-screen evidence that the account about to be
        // deleted is the one this test created.
        XCTAssertEqual(
            profileEmail.label, email,
            "Profile is showing a different account than the one that just signed up"
        )

        tap(app.buttons["destructive.Delete profile"], in: app)
        XCTAssertTrue(
            app.staticTexts["delete.title"].waitForExistence(timeout: 5),
            "The danger card did not open the confirmation modal"
        )
        // The wording, not just the element. #55 asks the modal to say plainly what is
        // deleted and that it cannot be undone, and DESIGN.md §8 says describe rather
        // than soften — an existence check passes on an empty label or on the artboard's
        // "within 30 days", which is not what `DELETE /me` does.
        let body = app.staticTexts["delete.body"]
        XCTAssertTrue(body.exists, "The modal does not say what deletion does")
        XCTAssertTrue(
            body.label.contains("cannot be undone"),
            "The modal does not say the deletion is irreversible: \(body.label)"
        )
        XCTAssertFalse(
            body.label.contains("30 days"),
            "The modal promises a 30-day window the API does not give: \(body.label)"
        )

        // MARK: The gate

        let confirm = app.buttons["delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(
            confirm.isEnabled,
            "The confirm button is live before anything has been typed"
        )

        // Lowercase. The field does not autocapitalize, so reaching capitals costs a
        // deliberate shift, and that cost is the gate — which means the gate is only real
        // if the lowercase word is refused. An existence check on the button, or one that
        // only ever typed the right word, would pass on a gate that is not there at all.
        let field = app.textFields["delete.confirmation"]
        type(Self.confirmationWord.lowercased(), into: field, in: app)
        XCTAssertFalse(
            confirm.isEnabled,
            "Typing `\(Self.confirmationWord.lowercased())` enabled the confirm button — the gate is case-insensitive, "
                + "so it can be tapped through by reflex"
        )

        // Back to an empty field, then the word as the modal asks for it. Deleting is
        // unavoidable here: the check is whitespace-trimmed but not otherwise forgiving,
        // so appending would leave `deleteDELETE` and prove nothing.
        field.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.confirmationWord.count)
        )
        field.typeText(Self.confirmationWord)

        // The button's enabled state follows a SwiftUI state update, so it is waited for
        // rather than read. A bare read can win the race and fail a working gate.
        wait(
            for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: confirm)],
            timeout: 5
        )

        // MARK: Return is not confirmation
        //
        // The gate is two deliberate acts: type the word, then press the destructive
        // button. The field's return key is labelled `done`, and the likeliest reason to
        // press it is wanting the keyboard out of the way so the button underneath it is
        // visible — so a return that confirmed would collapse the gate into the single
        // reflex keystroke #55's Risks section names. Found by the security review; this
        // is what stops it coming back.
        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.exists, "No keyboard is up, so pressing return here would prove nothing")
        field.typeText("\n")
        // Evidence the keystroke was actually delivered, and the behaviour the fix puts
        // in its place. Without this, everything below would pass just as happily for a
        // return key that never arrived — which is the shape of a test that cannot fail.
        XCTAssertTrue(
            keyboard.waitForNonExistence(timeout: 5),
            "Return did not dismiss the keyboard, so there is no evidence the key was delivered"
        )
        // Waited for rather than read: a return that confirmed would take a network round
        // trip to reach onboarding, and an immediate read would win that race and pass.
        XCTAssertFalse(
            app.textFields["signup.email"].waitForExistence(timeout: 5),
            "Pressing return deleted the account — the typed-DELETE gate collapsed into one keystroke"
        )
        XCTAssertTrue(
            app.staticTexts["delete.title"].exists,
            "The modal left the screen without the confirm button ever being pressed"
        )
        XCTAssertTrue(
            confirm.isEnabled,
            "Return cleared the field or disabled the confirm button, so the gate now has to be re-passed"
        )

        // MARK: The client half

        tap(confirm, in: app)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 20),
            "A confirmed deletion did not return the app to signed-out onboarding"
        )
        XCTAssertFalse(
            app.staticTexts["delete.error"].exists,
            "The delete request failed: \(app.staticTexts["delete.error"].label)"
        )

        // MARK: The server half
        //
        // The point of this test. Everything above is satisfied by a client that cleared
        // its own Keychain and showed the onboarding screen — which is exactly what a
        // `DELETE /me` that silently failed would look like. The account has to be gone
        // on the server, and the only way to ask that from here is to try to use it.
        app.terminate()
        launch(app)
        let message = failedLogIn(app, email: email, password: Self.password)
        XCTAssertFalse(
            message.isEmpty,
            "login.error is present but empty, so the log-in failure is not evidence of anything"
        )
    }
}

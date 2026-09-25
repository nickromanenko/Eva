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
/// A second test (#59) covers the one failure the modal cannot report itself: a delete
/// whose credential has died, which signs the app out and takes the modal with it.
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
        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 10),
            "Did not land on the tab bar"
        )

        // MARK: Reachable without contacting support

        tap(app.buttons["tab.profile"], in: app)
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

        // MARK: Export is offered (#58)
        //
        // Present, labelled, and live — the canvas draws it next to the confirmation and
        // #58 is what makes it real. It is tapped further down, once DELETE has been
        // typed, because coming back from it with the gate intact is the case that
        // matters.
        XCTAssertTrue(
            app.staticTexts["delete.exportNote"].exists,
            "The modal does not offer export before deletion"
        )
        let export = app.buttons["delete.export"]
        XCTAssertTrue(export.exists, "There is no \"Export data instead\" button")
        XCTAssertEqual(export.label, "Export data instead")
        XCTAssertTrue(export.isEnabled, "The export button is not live")

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
        // so appending would leave `deleteDELETE` and prove nothing — which is exactly what
        // #135 did elsewhere, so this goes through the helper that verifies the field
        // emptied rather than hand-rolling the delete and hoping.
        clearAndType(Self.confirmationWord, into: field, in: app)

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

        // MARK: Export, and back (#58)
        //
        // With the gate already passed, so this is the case that matters: someone who has
        // typed DELETE, has second thoughts, takes a copy first — and must come back to a
        // modal that is exactly as they left it. The export is fetched from the real
        // route, so the save sheet appearing is also evidence `GET /me/export` answered
        // this account with a complete file; an error would put `delete.exportError` up
        // instead.
        tap(export, in: app)
        let saveSheet = app.buttons["Save"]
        if !saveSheet.waitForExistence(timeout: 20) {
            let exportError = app.staticTexts["delete.exportError"]
            XCTFail(
                exportError.exists
                    ? "The export failed: \(exportError.label)"
                    : "Tapping \"Export data instead\" opened no save sheet"
            )
        }
        // The picker's own Cancel where the OS draws one; otherwise the sheet is swiped
        // away, which is the other way a person dismisses it and takes the same cleanup.
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            top.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)
            ))
        }
        XCTAssertTrue(
            saveSheet.waitForNonExistence(timeout: 10),
            "The save sheet did not go away when cancelled"
        )
        XCTAssertTrue(
            app.staticTexts["delete.title"].exists,
            "Cancelling the export took the delete modal down with it"
        )
        XCTAssertFalse(
            app.staticTexts["delete.exportError"].exists,
            "Cancelling the save sheet was reported as a failed export"
        )
        XCTAssertEqual(
            field.value as? String, Self.confirmationWord,
            "Exporting cleared the typed confirmation, so the gate has to be passed again"
        )
        XCTAssertTrue(
            confirm.isEnabled,
            "Exporting disabled the confirm button — offering export made deletion harder to reach"
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

    /// Issue #59: a delete whose credential has died must not look like a delete that
    /// worked.
    ///
    /// The session is killed for real, on the server, while the modal is open — the
    /// mailbox resets the password to the one it already is, and a reset ends every other
    /// session (#76). So `DELETE /me` goes out carrying a token the app believes in and the
    /// live API answers 401, which is the path the issue describes and not a stand-in for
    /// it. The app is expected to sign out (the central rule, unchanged) *and* to say on
    /// the screen it lands on that nothing was deleted.
    ///
    /// Then the two halves a banner alone cannot prove: the account really is still there
    /// — logging back in reaches the app — and doing what the banner says works, which is
    /// also what removes the account this test made.
    func testADeleteRefusedForADeadSessionSaysTheProfileWasNotDeleted() throws {
        let app = launch()
        let email = Self.freshEmail()

        signUpAndActivate(app, email: email)
        openDeleteModal(app)
        passTheGate(app)

        // MARK: The credential dies behind the app's back

        endSessionsOutOfBand(email: email)
        tap(app.buttons["delete.confirm"], in: app)

        // MARK: What the user is told

        let reason = app.staticTexts["login.signedOutReason"]
        XCTAssertTrue(
            reason.waitForExistence(timeout: 20),
            app.textFields["signup.email"].exists
                ? "A refused delete returned to sign-up in silence — exactly what a deletion that worked looks like"
                : "A refused delete did not reach the signed-out screen with a reason"
        )
        // Log in, not sign-up: the account exists, and signing back in is the remedy.
        XCTAssertTrue(
            app.staticTexts["Welcome back"].exists,
            "The reason is shown, but not on the log-in screen"
        )
        // Joined for the same reason `RateLimitedUITests` joins: `EvaInfoBanner` does not
        // combine its title and message, so the identifier reaches each separately.
        let text = app.staticTexts.matching(identifier: "login.signedOutReason")
            .allElementsBoundByIndex
            .map { $0.label }
            .joined(separator: " ")
        XCTAssertTrue(
            text.contains("not deleted"),
            "The banner does not say the profile was not deleted: \(text)"
        )
        XCTAssertTrue(
            text.contains("Log in") && text.contains("again"),
            "The banner does not say what to do next: \(text)"
        )

        // MARK: The account survived

        signIn(app, email: email, password: Self.password)
        XCTAssertTrue(
            app.buttons["tab.home"].waitForExistence(timeout: 20),
            "Logging back in after a refused delete did not reach the app — the account may be gone"
        )

        // MARK: Doing what the banner says works

        openDeleteModal(app)
        passTheGate(app)
        tap(app.buttons["delete.confirm"], in: app)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 20),
            "The retried deletion did not return the app to sign-up"
        )
        XCTAssertFalse(
            app.staticTexts["login.signedOutReason"].exists,
            "A deletion that worked was reported as refused"
        )
    }

    /// Profile ▸ Delete profile, and the modal is up.
    private func openDeleteModal(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["tab.profile"], in: app, file: file, line: line)
        tap(app.buttons["destructive.Delete profile"], in: app, file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["delete.title"].waitForExistence(timeout: 5),
            "The danger card did not open the confirmation modal",
            file: file, line: line
        )
    }

    /// Types the word, dismisses the keyboard, and waits for the confirm button to go live.
    private func passTheGate(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["delete.confirmation"]
        type(Self.confirmationWord, into: field, in: app, file: file, line: line)
        field.typeText("\n")
        wait(
            for: [expectation(
                for: NSPredicate(format: "isEnabled == true"),
                evaluatedWith: app.buttons["delete.confirm"]
            )],
            timeout: 5
        )
    }
}

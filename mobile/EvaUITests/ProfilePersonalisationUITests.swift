import XCTest

/// Personalisation after #19: no post-auth questionnaire, a dismissible nudge on Home, and
/// the profile completed from Profile.
///
/// Two of #19's acceptance criteria had no test until here — "a test covers dismiss → still
/// dismissed after relaunch" and "`EvaUITests` covers reaching and completing personalisation
/// from Profile". `ProfileActivityUITests` drives two of the six rows and never looks at
/// Home; `api/test/profile-nudge.test.ts` proves the flag is stored, but not that the app
/// reads it back.
///
/// ## Why the relaunches are two different launches
///
/// The nudge disappears the moment `POST /me/profile-nudge/dismiss` answers, so the screen
/// right after the tap proves nothing about *storage*: an app that kept the dismissal in
/// memory, or dropped the server's flag and remembered its own, looks identical there. The
/// relaunches are where the difference shows.
///
/// * **Same install, Keychain kept** (`relaunchKeepingSession`) — the relaunch the criterion
///   names. A new process, a new `AppSession`, and the user it holds is whatever `GET /me`
///   answers.
/// * **Keychain cleared, signed in again** (`launch()` + `signIn`) — the nearest a simulator
///   gets to a reinstall or a second device: nothing of the old session survives on the
///   device, so a nudge that stays away can only be reading the server.
final class ProfilePersonalisationUITests: EvaUITestCase {

    // MARK: - Dismiss, and it stays dismissed

    func testADismissedNudgeStaysDismissedAcrossRelaunchAndANewSignIn() throws {
        let app = launch()
        let email = Self.freshEmail()
        signUpAndActivate(app, email: email)

        // A new account has answered nothing, so the nudge is owed and on Home.
        let dismiss = app.buttons["nudge.dismiss"]
        XCTAssertTrue(
            dismiss.appears(within: 15),
            "A new account with no profile reached Home without the profile nudge"
        )
        XCTAssertTrue(
            app.staticTexts["Make Eva yours"].exists,
            "The nudge's dismiss is on screen without the nudge it dismisses"
        )

        tap(dismiss, in: app)
        XCTAssertTrue(
            dismiss.disappears(within: 15),
            "Dismissing the profile nudge did not take it off Home"
        )

        // MARK: Relaunch — same install, same session

        relaunchKeepingSession(app)
        assertOnHomeWithoutNudge(app, after: "a relaunch that kept the session")

        // MARK: A fresh sign-in — the reinstall / second-device case

        launch(app)
        signIn(app, email: email, password: Self.password)
        passConsentGate(app)
        assertOnHomeWithoutNudge(app, after: "signing in again with the Keychain cleared")

        // MARK: Dismissing blocked nothing — Profile still saves

        tap(app.buttons["tab.profile"], in: app)
        saveEditor(row: "profile.medications", choosing: "chip.None", in: app)
        XCTAssertEqual(
            app.buttons["profile.medications"].label, "Hormonal medications",
            "Profile's Medications row drew a value it never had"
        )
    }

    // MARK: - Reached from the nudge, completed from Profile

    func testCompletingPersonalisationFromProfileClearsTheNudgeAndIsKept() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail())

        // Reaching it: the nudge's own action is the route a new user is offered.
        let addDetails = app.buttons["text.Add details"]
        XCTAssertTrue(
            addDetails.appears(within: 15),
            "A new account with no profile reached Home without the profile nudge"
        )
        tap(addDetails, in: app)
        XCTAssertTrue(
            app.buttons["profile.medications"].appears(within: 10),
            "The nudge's Add details did not land on Profile's personalisation rows"
        )

        // Completing it: every row, one editor at a time. Medications goes first because
        // every editor re-sends the whole profile and `parseProfile` refuses an unanswered
        // medication — the order a user who starts anywhere else is told about by the rule
        // line, not one this test is here to check.
        saveEditor(row: "profile.medications", choosing: "chip.None", in: app)
        saveEditor(row: "profile.goals", choosing: "chip.Energy", in: app)
        saveEditor(row: "profile.activity", choosing: "chip.Lightly active", in: app)
        saveEditor(row: "profile.sports", choosing: "chip.Running", in: app)
        saveEditor(row: "profile.health", choosing: "chip.None of these", in: app)
        // Body measurements opens on an adult date of birth and a height and weight, so
        // Save with the defaults is a complete answer.
        saveEditor(row: "profile.bodyMeasurements", choosing: nil, in: app)

        assertProfileRowsShowTheAnswers(app, after: "saving each editor")

        // The profile exists now, so the nudge is no longer owed — without a dismissal.
        tap(app.buttons["tab.home"], in: app)
        XCTAssertTrue(
            app.staticTexts["home.greeting"].appears(within: 10),
            "Home did not come back after completing the profile"
        )
        XCTAssertFalse(
            app.buttons["nudge.dismiss"].appears(within: 3),
            "The profile nudge is still on Home after every Profile row was saved"
        )

        // Kept: a new process seeds Profile from `GET /me`, so these rows are the server's.
        relaunchKeepingSession(app)
        assertOnHomeWithoutNudge(app, after: "a relaunch after completing the profile")
        tap(app.buttons["tab.profile"], in: app)
        assertProfileRowsShowTheAnswers(app, after: "a relaunch")
    }

    // MARK: - Helpers

    /// Opens one Personal profile row, optionally picks a chip, saves, and waits for the
    /// editor to leave — `ProfileEditorScreen` dismisses only after the PUT succeeds, and
    /// stays put with the API's refusal under Save otherwise.
    private func saveEditor(
        row identifier: String,
        choosing chip: String?,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.buttons[identifier]
        tap(row, in: app, file: file, line: line)
        let save = app.buttons["primary.Save"]
        XCTAssertTrue(
            save.appears(within: 10),
            "\(identifier) did not open its editor",
            file: file, line: line
        )
        if let chip {
            tap(app.buttons[chip], in: app, file: file, line: line)
        }
        XCTAssertTrue(
            save.isEnabled,
            "\(identifier)'s Save is held after answering it",
            file: file, line: line
        )
        tap(save, in: app, file: file, line: line)
        XCTAssertTrue(
            save.disappears(within: 15),
            "Saving \(identifier) did not return to Profile — the API refused the body, "
                + "or the save never finished",
            file: file, line: line
        )
        XCTAssertTrue(
            row.appears(within: 5),
            "Saving \(identifier) did not come back to Profile",
            file: file, line: line
        )
    }

    /// The rows that draw a value, drawing the ones the completion test chose. The other
    /// three rows draw none by design (`ProfileView.personalProfileSection`).
    private func assertProfileRowsShowTheAnswers(
        _ app: XCUIApplication,
        after moment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = [
            ("profile.goals", "Goals & lifestyle, 1 active"),
            ("profile.activity", "Activity, Lightly active"),
            ("profile.sports", "Preferred sports, 1"),
        ]
        for (identifier, label) in expected {
            let row = app.buttons[identifier]
            scrollIntoView(row, in: app, file: file, line: line)
            XCTAssertEqual(
                row.label, label,
                "\(identifier) does not show what was saved, after \(moment)",
                file: file, line: line
            )
        }
    }

    /// Home is up, the user is loaded, and the nudge is not there.
    ///
    /// `.ready` is only reached once `GET /me` has answered, so by the time the tab bar
    /// exists the nudge's condition has been read. The short wait is for the render, not the
    /// request.
    private func assertOnHomeWithoutNudge(
        _ app: XCUIApplication,
        after moment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.buttons["tab.home"].appears(within: 25),
            "Did not reach the app after \(moment)",
            file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts["home.greeting"].appears(within: 10),
            "Home is not on screen after \(moment)",
            file: file, line: line
        )
        XCTAssertFalse(
            app.buttons["nudge.dismiss"].appears(within: 3),
            "The profile nudge came back after \(moment)",
            file: file, line: line
        )
    }

    /// Relaunches the same install with `EVA_UITEST_RESET` **removed**, so the Keychain —
    /// and the session in it — survives into the new process.
    ///
    /// Local to this file for the reason `OfflineLaunchUITests` and `ProfileLogOutUITests`
    /// keep their own: every other test wants the clean slate, and a shared helper that
    /// skips it is a trap.
    private func relaunchKeepingSession(_ app: XCUIApplication) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launchEnvironment["EVA_API_BASE_URL"] = Self.apiBaseURL
        app.launch()
    }
}

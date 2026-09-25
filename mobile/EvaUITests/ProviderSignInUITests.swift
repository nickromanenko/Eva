import XCTest

/// Issue #118: the provider sign-in surfaces #7 added, which shipped with identifiers and
/// no test — the Apple and Google buttons on both auth screens, Profile's connected-accounts
/// rows, and the delete modal's Apple revocation note.
///
/// **Presence and text only.** Apple's own sheet cannot run in a simulator
/// (`docs/PROVIDER-SIGNIN.md`), and Google's goes to the network, so nothing here taps a
/// provider button. What can regress silently without either is the part this covers: a
/// button that lost its label, a connected row that does not follow `authProviders`, and —
/// the case the issue names — the revocation note appearing for an account that has no
/// Apple identity to revoke.
///
/// An Apple-connected account is made by `linkAppleOutOfBand`, which attaches a placeholder
/// `apple.com` identity on the server. It is real to `GET /me` and useless to Apple, which
/// is why the second test cancels the delete modal rather than confirming it: confirming an
/// Apple-connected deletion asks Apple for a fresh authorization first.
///
/// Separate from `DeleteAccountUITests`, which is about deleting; this never deletes, and
/// its account is left for `scripts/e2e-cleanup.ts` (GUARDRAILS §16).
final class ProviderSignInUITests: EvaUITestCase {

    /// No account needed: the signed-out screens are where the buttons live.
    func testBothProviderButtonsArePresentAndLabelledOnSignUpAndLogIn() throws {
        let app = launch()

        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 20),
            "The app did not open on sign-up"
        )
        assertProviderButtons(on: "sign-up", in: app)

        tap(app.buttons["text.Log in"], in: app)
        XCTAssertTrue(
            app.staticTexts["Welcome back"].waitForExistence(timeout: 5),
            "The sign-up screen's cross-link did not reach the log-in screen"
        )
        assertProviderButtons(on: "log-in", in: app)
    }

    /// One account, both sides of the condition: password-only first, then the same account
    /// with Apple attached. The same account on purpose — the only thing that changes between
    /// the two halves is `authProviders`, so the only explanation for the note appearing is
    /// the one the modal is meant to react to.
    func testConnectedAccountsAndTheAppleNoteFollowAuthProviders() throws {
        let app = launch()
        let email = Self.freshEmail()
        signUpAndActivate(app, email: email)

        // MARK: Password only

        openProfile(app)
        assertConnectedRow("Email and password", in: app)
        // Absence is only evidence once the card has rendered, which the row above proves.
        XCTAssertFalse(
            element("profile.connected.Apple", in: app).exists,
            "A password-only account is shown as connected to Apple"
        )
        XCTAssertFalse(
            element("profile.connected.Google", in: app).exists,
            "A password-only account is shown as connected to Google"
        )
        // Both providers are still attachable.
        XCTAssertTrue(app.buttons["profile.connect.apple"].exists, "Profile offers no way to attach Apple")
        XCTAssertTrue(app.buttons["profile.connect.google"].exists, "Profile offers no way to attach Google")

        openDeleteModal(app)
        XCTAssertFalse(
            element("delete.appleNote", in: app).exists,
            "The delete modal tells a password-only account that Apple will ask to confirm"
        )
        closeDeleteModal(app)

        // MARK: Apple attached

        linkAppleOutOfBand(email: email)
        // The session's user is read at launch; relaunching keeps the Keychain so the app
        // signs itself in and reads `GET /me` afresh, now with `apple.com` in it.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launch()
        XCTAssertTrue(
            app.buttons["tab.home"].waitForExistence(timeout: 20),
            "Relaunching with the session kept did not reach the app"
        )

        openProfile(app)
        assertConnectedRow("Email and password", in: app)
        assertConnectedRow("Apple", in: app)
        XCTAssertFalse(
            element("profile.connected.Google", in: app).exists,
            "Attaching Apple also showed Google as connected"
        )
        XCTAssertFalse(
            app.buttons["profile.connect.apple"].exists,
            "Profile still offers to attach Apple to an account that has it"
        )
        XCTAssertTrue(app.buttons["profile.connect.google"].exists, "Profile stopped offering Google")

        openDeleteModal(app)
        let note = app.staticTexts.matching(identifier: "delete.appleNote")
        XCTAssertTrue(
            note.firstMatch.waitForExistence(timeout: 5),
            "The delete modal does not warn an Apple-connected account that Apple will ask to confirm"
        )
        // Joined: `EvaInfoBanner` does not combine its title and message, so the identifier
        // reaches each separately — the same reading `DeleteAccountUITests` takes.
        let text = note.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(text.contains("Apple will ask you to confirm"), "The note's title changed: \(text)")
        XCTAssertTrue(
            text.contains("deleted either way"),
            "The note no longer says dismissing Apple's sheet does not stop the deletion: \(text)"
        )
        // Not confirmed: the placeholder identity cannot answer Apple's sheet.
        closeDeleteModal(app)
    }

    // MARK: - Helpers

    private func assertProviderButtons(
        on screen: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (identifier, label) in [("auth.apple", "Continue with Apple"), ("auth.google", "Continue with Google")] {
            let button = app.buttons[identifier]
            XCTAssertTrue(
                button.waitForExistence(timeout: 5),
                "The \(screen) screen has no \(identifier) button",
                file: file, line: line
            )
            XCTAssertEqual(button.label, label, "\(identifier) on \(screen)", file: file, line: line)
            XCTAssertTrue(button.isEnabled, "\(identifier) on \(screen) is not live", file: file, line: line)
        }
    }

    private func assertConnectedRow(
        _ method: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = element("profile.connected.\(method)", in: app)
        scrollIntoView(row, in: app, file: file, line: line)
        XCTAssertEqual(row.label, "\(method), connected", file: file, line: line)
    }

    private func openProfile(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["tab.profile"], in: app, file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["profile.email"].waitForExistence(timeout: 10),
            "Profile did not open",
            file: file, line: line
        )
    }

    /// Profile ▸ Delete profile, and the modal has rendered its body — the export note is
    /// drawn in the same pass as the Apple note, so an absence read after it means something.
    private func openDeleteModal(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["destructive.Delete profile"], in: app, file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["delete.title"].waitForExistence(timeout: 5),
            "The danger card did not open the confirmation modal",
            file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts["delete.exportNote"].exists,
            "The modal's body has not rendered",
            file: file, line: line
        )
    }

    private func closeDeleteModal(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["text.Cancel"], in: app, file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["delete.title"].waitForNonExistence(timeout: 5),
            "Cancel did not close the delete modal",
            file: file, line: line
        )
    }
}

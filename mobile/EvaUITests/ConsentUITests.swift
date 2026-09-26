import XCTest

/**
 * The consent screen (#86): what it asks, what it refuses to skip, and where it can be
 * undone. The API refuses health writes server-side regardless of what this screen does
 * (`consent.test.ts`); what is under test here is the screen's own promises — neither
 * toggle pre-selected, no way past the first one unconsented, and the withdrawal's
 * consequence stated before it is confirmed.
 */
final class ConsentUITests: EvaUITestCase {

    /// The core path: a new account lands on the screen with both toggles off, cannot
    /// continue without the first, and can continue with it.
    func testConsentIsAskedAndRequired() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail(), consent: false)

        // Neither toggle is pre-selected. Consent that arrives switched on is not
        // consent (A21), and this is the assertion the AC asks for by name.
        XCTAssertEqual(app.switches["consent.store"].value as? String, "0")
        XCTAssertEqual(app.switches["consent.share"].value as? String, "0")

        // Continue without the first toggle does not proceed, and says why.
        tap(app.buttons["primary.Continue"], in: app)
        XCTAssertTrue(
            app.staticTexts["consent.message"].waitForExistence(timeout: 3),
            "Continuing without the store consent gave no message and moved nowhere"
        )
        XCTAssertFalse(
            app.buttons["tab.home"].exists,
            "The app opened with no collect consent on record"
        )

        // The second toggle is not the one Eva needs, and does not open the app either.
        tap(app.switches["consent.share"], in: app)
        tap(app.buttons["primary.Continue"], in: app)
        XCTAssertFalse(
            app.buttons["tab.home"].exists,
            "The app opened on the share consent alone"
        )

        // The first toggle is. (The message is still up and does not need dismissing:
        // turning the store toggle on is what clears it.)
        tap(app.switches["consent.store"], in: app)
        tap(app.buttons["primary.Continue"], in: app)
        XCTAssertTrue(
            app.buttons["tab.home"].waitForExistence(timeout: 20),
            "Continuing with the store consent did not reach the app"
        )
    }

    /// Withdrawal is reachable from Settings › Privacy, and the consequence — the freeze,
    /// not a delete — is stated before the confirmation, not after the fact.
    func testWithdrawalStatesItsConsequenceBeforeConfirming() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail())

        tap(app.buttons["tab.profile"], in: app)
        XCTAssertTrue(
            app.buttons["profile.privacy"].waitForExistence(timeout: 5),
            "Profile drew no Privacy row"
        )
        tap(app.buttons["profile.privacy"], in: app)

        // The collect consent this account gave on the screen is the state the row shows.
        XCTAssertTrue(
            app.staticTexts["privacy.collect.state"].waitForExistence(timeout: 5),
            "Privacy drew no state for the collect consent"
        )
        // "2026-08-30" is ConsentPolicy.version, spelled out: the UI-test target cannot
        // see app internals, and pinning the string is the point — a copy change that
        // forgets to bump the version shows up here.
        XCTAssertEqual(
            app.staticTexts["privacy.collect.state"].label,
            "On · Consent 2026-08-30"
        )

        // Both rows can be in the same state at once (the helper granted the share
        // consent too), so each row's action carries its own identifier rather than the
        // title-derived one the shared button components would give it.
        tap(app.buttons["privacy.collect.withdraw"], in: app)
        // The consequence, before anything is confirmed. Found by a substring rather
        // than an identifier: a system confirmationDialog exposes its message as text,
        // and the exact copy is the screen's own test.
        let consequence = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "collecting anything new")
        ).firstMatch
        XCTAssertTrue(
            consequence.waitForExistence(timeout: 5),
            "The withdrawal dialog did not state what withdrawal does"
        )

        // Confirming freezes: the state reads Paused, and the way back is on the same row.
        // In the sheet, not `app.buttons["Withdraw"]`: the row that opened the dialog is
        // still in the tree behind it with the same label, and the plain query matches
        // both.
        tap(app.sheets.buttons["Withdraw"], in: app)
        // Waited on the label, not the element: the row already exists reading "On", and
        // the change lands only after the request does. An existence wait followed by a
        // read races that request, and loses whenever nothing else pads the gap.
        let paused = expectation(
            for: NSPredicate(format: "label == %@", "Paused · Consent 2026-08-30"),
            evaluatedWith: app.staticTexts["privacy.collect.state"]
        )
        wait(for: [paused], timeout: 10)
    }
}

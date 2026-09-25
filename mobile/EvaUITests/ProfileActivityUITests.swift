import XCTest

/// Profile ▸ Activity end to end (#221): the band is a code on the wire and a label on
/// screen, and the editor's Save waits for one.
///
/// The unit tests in `LifestyleCodeTests` pin the model — which code a chip stores, what the
/// row value is. This is the half they cannot reach: that the view actually holds Save, that
/// the chip the view draws is wired to that model, and that the API takes what it is sent.
///
/// Medications is answered first, through its own editor, on purpose. Every editor re-sends
/// the whole profile, and `parseProfile` refuses an unanswered medication, so a fresh account
/// could not save Activity at all otherwise. That first save also goes out with the band
/// **unanswered**, which is the other #221 contract: a save from another editor must not be
/// refused for a question she has not reached yet.
final class ProfileActivityUITests: EvaUITestCase {

    func testActivityHoldsSaveUntilABandIsPickedAndTheRowShowsItsLabel() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail())
        tap(app.buttons["tab.profile"], in: app)

        // Medications first, with the band still unanswered.
        tap(app.buttons["profile.medications"], in: app)
        tap(app.buttons["chip.None"], in: app)
        let save = app.buttons["primary.Save"]
        tap(save, in: app)
        // The editor leaving is the success signal: `ProfileEditorScreen` dismisses only after
        // the PUT succeeds, and stays put with the API's refusal under Save otherwise.
        XCTAssertTrue(
            save.disappears(within: 15),
            "Saving medications with the activity band unanswered did not return to Profile — "
                + "the API refused the body, or the save never finished"
        )
        let activityRow = app.buttons["profile.activity"]
        XCTAssertTrue(activityRow.appears(within: 5), "Profile has no Activity row")
        XCTAssertEqual(activityRow.label, "Activity", "An unanswered band drew a value on the row")

        // Activity: Save is held until a band is picked.
        tap(activityRow, in: app)
        XCTAssertTrue(save.appears(within: 10), "Activity did not open its editor")
        XCTAssertFalse(save.isEnabled, "Activity's Save is open before any band is picked")

        tap(app.buttons["chip.Lightly active"], in: app)
        XCTAssertTrue(save.isEnabled, "Picking a band left Activity's Save held")
        tap(save, in: app)

        // Back on Profile, the row names the band in words, never as its code.
        XCTAssertTrue(
            save.disappears(within: 15),
            "Saving Activity did not return to Profile — the API refused what the chip sent"
        )
        XCTAssertTrue(activityRow.appears(within: 5), "Profile has no Activity row")
        XCTAssertEqual(activityRow.label, "Activity, Lightly active")
    }
}

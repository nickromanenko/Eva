import XCTest

/// The units setting end to end (#82): the locale picks it, Settings overrides it, and
/// the override wins on a screen the locale would have decided differently.
///
/// ## Where the body metrics live now
///
/// #19 moved the questionnaire into Profile, so the weight and height steppers this suite
/// reads live on Profile ▸ Body measurements rather than on a post-auth step. That means a
/// session is needed to reach them — the suite signs up, where it used to open the
/// questionnaire with no account.
///
/// ## The locale is set the way the simulator sets it
///
/// `-AppleLocale` / `-AppleLanguages` are read out of the argument domain of
/// `UserDefaults`, which is how a scheme or a simulator's own Language & Region setting
/// reaches `Locale.current`. The app is not told which units to use — it is told where it
/// is, and `EvaUnitSystem.default(for:)` decides, which is the thing under test.
final class UnitsUITests: EvaUITestCase {

    // MARK: Locale decides, with no override

    func testAUSLocaleTypesWeightInPoundsAndHeightInFeetAndInches() throws {
        let app = launch(locale: "en_US", language: "en-US")
        signUpAndActivate(app, email: Self.freshEmail())
        openBodyMeasurements(app)

        XCTAssertTrue(
            element("stepper.weight.pounds", in: app).exists,
            "A US locale is not offering pounds"
        )
        XCTAssertTrue(
            element("stepper.height.feet", in: app).exists,
            "A US locale is not offering feet"
        )
        XCTAssertTrue(
            element("stepper.height.inches", in: app).exists,
            """
            A US locale is offering feet without inches — a height in feet alone is the \
            decimal box LAUNCH §4.2 forbids, one field short.
            """
        )
        XCTAssertFalse(
            element("stepper.height.centimeters", in: app).exists,
            "A US locale is still offering centimeters"
        )
        XCTAssertFalse(
            element("stepper.weight.kilograms", in: app).exists,
            "A US locale is still offering kilograms"
        )

        // 168 cm is 5 ft 6 in — the acceptance criterion's own example, on screen.
        XCTAssertEqual(element("stepper.height.feet.value", in: app).value as? String, "5 feet")
        XCTAssertEqual(element("stepper.height.inches.value", in: app).value as? String, "6 inches")
        XCTAssertEqual(element("stepper.weight.pounds.value", in: app).value as? String, "141 pounds")
    }

    func testABritishLocaleTypesWeightInKilogramsAndHeightInCentimeters() throws {
        // `Locale.MeasurementSystem` calls en_GB `.uk`, and the obvious reading of that is
        // stones. #82's acceptance criterion says otherwise — "with `en_GB`, kg and cm" —
        // and this is the test that holds the app to it.
        let app = launch(locale: "en_GB", language: "en-GB")
        signUpAndActivate(app, email: Self.freshEmail())
        openBodyMeasurements(app)

        XCTAssertTrue(
            element("stepper.weight.kilograms", in: app).exists,
            "A British locale is not offering kilograms"
        )
        XCTAssertTrue(
            element("stepper.height.centimeters", in: app).exists,
            "A British locale is not offering centimeters"
        )
        XCTAssertFalse(
            element("stepper.height.feet", in: app).exists,
            "A British locale is offering feet"
        )
        XCTAssertFalse(
            element("stepper.weight.stones", in: app).exists,
            "A British locale defaulted to stones — the default is metric everywhere but the US"
        )

        XCTAssertEqual(element("stepper.weight.kilograms.value", in: app).value as? String, "64 kilograms")
        XCTAssertEqual(element("stepper.height.centimeters.value", in: app).value as? String, "168 centimeters")
    }

    // MARK: The override beats the locale, and outlives the launch

    func testTheSettingsOverrideBeatsTheLocaleAndSurvivesRelaunch() throws {
        let app = launch(locale: "en_US", language: "en-US")
        signUpAndActivate(app, email: Self.freshEmail())

        // The locale is in force on the way in: a US device types height in feet.
        openBodyMeasurements(app)
        XCTAssertTrue(
            element("stepper.height.feet", in: app).exists,
            "A US locale did not reach Body measurements in feet"
        )

        // Back to Profile, then the Units row.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["profile.units"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Profile has no Units row")
        XCTAssertEqual(
            row.label, "Units, Imperial",
            "The Units row is not showing what the US locale gave it"
        )

        tap(row, in: app)
        let metric = app.buttons["units.option.metric"]
        XCTAssertTrue(metric.waitForExistence(timeout: 10), "The Units row did not open its screen")
        XCTAssertTrue(
            app.buttons["units.option.imperial"].isSelected,
            "The Units screen opened with nothing selected, or with the wrong option selected"
        )
        tap(metric, in: app)
        XCTAssertTrue(metric.isSelected, "Choosing Metric did not select it")

        // Back to Profile — the row is the one place the setting is visible from outside.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The back button did not return to Profile")
        XCTAssertEqual(
            row.label, "Units, Metric",
            "The Units row did not follow the choice made on the screen behind it"
        )

        // MARK: The override, on a screen the locale would have decided differently
        //
        // Relaunching *without* `EVA_UITEST_RESET` keeps the stored choice; the reset hook
        // is what clears it, so a relaunch that keeps it is a relaunch a real user would
        // have. The locale arguments stay, so this is still a US device — and Body
        // measurements has to come up metric.

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launch()

        openBodyMeasurements(app)
        XCTAssertTrue(
            element("stepper.height.centimeters", in: app).waitForExistence(timeout: 20),
            """
            After a relaunch on a US device, Body measurements is not in the units the user \
            chose — either the override did not survive, or the locale is still winning.
            """
        )
        XCTAssertFalse(
            element("stepper.height.feet", in: app).exists,
            "The US locale beat the explicit override after a relaunch"
        )
        XCTAssertTrue(
            element("stepper.weight.kilograms", in: app).exists,
            "Height followed the override and weight did not"
        )
    }

    // MARK: - Launch helpers

    /// The app on a device with this locale.
    private func launch(locale: String, language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += Self.localeArguments(locale: locale, language: language)
        return launch(app)
    }

    /// What the simulator itself passes when its Language & Region is set, and what a
    /// scheme's "Application Language" option passes. Both keys: `-AppleLocale` alone
    /// leaves the language list disagreeing with it.
    private static func localeArguments(locale: String, language: String) -> [String] {
        ["-AppleLocale", locale, "-AppleLanguages", "(\(language))"]
    }
}

import XCTest

/// The units setting end to end (#82): the locale picks it, Settings overrides it, and
/// the override wins on a screen the locale would have decided differently.
///
/// ## Why two of these need no account
///
/// `EVA_ONBOARDING_STEP=2` opens the questionnaire's first step with no session, so the
/// two locale tests never sign up, never reach the API and never leave an account for the
/// cleanup sweep. That is not only cheaper: a suite that signs up cannot tell a units
/// regression from #208's missing `api/node_modules`, because both present as a failure
/// at sign-up.
///
/// The third test does need Profile, and Profile needs a session, so it signs up like
/// `ProfileLogOutUITests` does.
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
        let app = launchQuestionnaire(locale: "en_US", language: "en-US")

        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 20),
            "EVA_ONBOARDING_STEP did not open the questionnaire"
        )

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
        let app = launchQuestionnaire(locale: "en_GB", language: "en-GB")

        XCTAssertTrue(
            app.staticTexts["A little about you"].waitForExistence(timeout: 20),
            "EVA_ONBOARDING_STEP did not open the questionnaire"
        )

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
        let app = XCUIApplication()
        app.launchArguments += Self.localeArguments(locale: "en_US", language: "en-US")
        launch(app)

        let email = Self.freshEmail()
        signUpAndActivate(app, email: email)

        // The locale is in force on the way in: this is the same assertion as the first
        // test, made on the account path so the override below has something to beat.
        XCTAssertTrue(
            element("stepper.height.feet", in: app).waitForExistence(timeout: 10),
            "A US locale did not reach the questionnaire in feet"
        )

        completeQuestionnaire(app)
        XCTAssertTrue(
            app.staticTexts["You're all set"].waitForExistence(timeout: 15),
            "Questionnaire submission did not reach the done screen"
        )
        tap(app.buttons["primary.Enter Eva"], in: app)

        // MARK: Profile ▸ Units

        tap(app.buttons["tab.profile"], in: app)
        let row = app.buttons["profile.units"]
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "Profile has no Units row — the canvas puts one in Eva experience"
        )
        XCTAssertEqual(
            row.label, "Units, Imperial",
            "The Units row is not showing what the US locale gave it"
        )

        tap(row, in: app)
        let metric = app.buttons["units.option.metric"]
        XCTAssertTrue(
            metric.waitForExistence(timeout: 10),
            "The Units row did not open a screen with the options on it"
        )
        XCTAssertTrue(
            app.buttons["units.option.imperial"].isSelected,
            "The Units screen opened with nothing selected, or with the wrong option selected"
        )
        tap(metric, in: app)
        XCTAssertTrue(metric.isSelected, "Choosing Metric did not select it")

        // Back to Profile — the row is the one place the setting is visible from outside.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "The back button did not return to Profile"
        )
        XCTAssertEqual(
            row.label, "Units, Metric",
            "The Units row did not follow the choice made on the screen behind it"
        )

        // MARK: The override, on a screen the locale would have decided differently
        //
        // Logging out and relaunching *without* `EVA_UITEST_RESET` is the only way to see
        // the difference: the reset hook is what clears the stored choice, so a relaunch
        // that keeps it is a relaunch a real user would have. The locale arguments stay,
        // so this is still a US device — and the questionnaire has to come up metric.

        tap(app.buttons["profile.logout"], in: app)
        XCTAssertTrue(
            app.textFields["signup.email"].waitForExistence(timeout: 10),
            "Log out did not return the app to signed-out onboarding"
        )

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launchEnvironment["EVA_ONBOARDING_STEP"] = "2"
        app.launch()

        XCTAssertTrue(
            element("stepper.height.centimeters", in: app).waitForExistence(timeout: 20),
            """
            After a relaunch on a US device, the questionnaire is not in the units the \
            user chose — either the override did not survive, or the locale is still \
            winning.
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

    /// The questionnaire's first step, on a device with this locale, with no account.
    private func launchQuestionnaire(locale: String, language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EVA_UITEST_RESET"] = "1"
        app.launchEnvironment["EVA_API_BASE_URL"] = Self.apiBaseURL
        app.launchEnvironment["EVA_ONBOARDING_STEP"] = "2"
        app.launchArguments += Self.localeArguments(locale: locale, language: language)
        app.launch()
        return app
    }

    /// What the simulator itself passes when its Language & Region is set, and what a
    /// scheme's "Application Language" option passes. Both keys: `-AppleLocale` alone
    /// leaves the language list disagreeing with it.
    private static func localeArguments(locale: String, language: String) -> [String] {
        ["-AppleLocale", locale, "-AppleLanguages", "(\(language))"]
    }

    /// An element by identifier, whatever XCUITest decided to call its type.
    ///
    /// A `StepperCard` row is an accessibility *container* and its value is an element
    /// built out of two `Text`s, and which of `otherElements` / `staticTexts` each lands
    /// in is an implementation detail of SwiftUI's accessibility tree — one that has
    /// moved between iOS releases before. The identifier is the contract (GUARDRAILS 22);
    /// the element type is not.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

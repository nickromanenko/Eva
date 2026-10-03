import XCTest

/// The Nutrition coach's setup flow (S3, #223), end to end against the API the harness
/// started: the answers, the step marker and the hide-numbers preference are written to and
/// read back from the server, so a relaunch here is a relaunch a person would have.
///
/// **The plan is seeded** with `EVA_NUTRITION_PLAN`: `GET /me/nutrition/plan` answers 503 in
/// every environment until #26 sets the constants, so without the hook no summary and no
/// guard card can be reached. The hook hands over the route's own JSON through the app's own
/// decoder; the guard maths that produces a refusal is the API's, and is tested there.
///
/// Elements are found by identifier, never by the drafted copy — the goal titles, the guard
/// message, the hide-numbers question and the focus labels are all awaiting human sign-off
/// (`REVIEW` in `NutritionSetupView`) and will change.
///
/// **Not here: the Pregnancy / postpartum restriction** (canvas `sPreg`). No account has a
/// mode yet — D10 stores it, and until then the API serves `cycle` to everyone — so the
/// restriction is unreachable through the app. It is covered at the model, where the gate is
/// an input (`NutritionSetupModelTests.pregnancyPausesWeightGoals`,
/// `bothTriggersReachOneProjection`).
final class NutritionSetupUITests: EvaUITestCase {

    // MARK: - Resume, and no target from partial data (canvas `sResume`, PRD line 677)

    func testAnAbandonedSetupResumesAtItsStepAndShowsNoTargetUntilComplete() throws {
        let app = launch(locale: "en_GB", language: "en-GB", plan: Self.targetsPlan)
        signUpAndActivate(app, email: Self.freshEmail())
        openSetup(app)

        tap(element("nutrition.goal.lose", in: app), in: app)
        waitForStep(2, title: "nutrition.focus.title", in: app)

        // MARK: Focus areas cap at three; the rest stay listed and disabled (canvas `s2`)

        let codes = [
            "vegetablesAndFibre", "lessUltraProcessed", "ironDeficiencyAnaemia", "moreProtein",
            "lessSugar", "regularMeals", "moreWater", "lessCaffeine", "lessAlcohol", "boneHealth",
            "digestion", "pmsCravings", "eatEnoughOnPeriod", "lessSalt", "vegetarianVeganBalance",
            "steadyEnergy", "skin",
        ]
        for code in codes.prefix(3) {
            tap(focus(code, in: app), in: app)
            XCTAssertTrue(waitUntil { self.focus(code, in: app).isSelected }, "\(code) did not select")
        }
        for code in codes.dropFirst(3) {
            let chip = focus(code, in: app)
            XCTAssertTrue(chip.exists, "\(code) was removed at the cap — it must stay visible")
            XCTAssertFalse(chip.isEnabled, "\(code) is still choosable past three")
        }
        for code in codes.prefix(3) {
            XCTAssertTrue(focus(code, in: app).isSelected, "\(code) was swapped out")
        }

        tap(element("nutrition.focus.continue", in: app), in: app)
        waitForStep(3, title: "nutrition.meals.title", in: app)

        // MARK: Back navigation keeps the answers

        tap(app.buttons["nutrition.back"], in: app)
        waitForStep(2, title: "nutrition.focus.title", in: app)
        XCTAssertTrue(focus(codes[0], in: app).isSelected, "Back lost the focus areas")
        tap(element("nutrition.focus.continue", in: app), in: app)
        waitForStep(3, title: "nutrition.meals.title", in: app)

        tap(element("nutrition.meals.3", in: app), in: app)
        waitForStep(4, title: "nutrition.body.title", in: app)
        assertNoTarget(in: app, "mid-flow")

        // MARK: Abandon and relaunch: Step 4, and still nothing calculated

        relaunch(app)
        openSetup(app, expecting: "nutrition.body.title")
        waitForStep(4, title: "nutrition.body.title", in: app)
        assertNoTarget(in: app, "after resuming a partial setup")
        capture("nutrition-resumed")

        // The control: the same assertion fails once setup *is* complete, so it is not
        // passing because numbers can never be on this screen.
        tap(element("nutrition.body.confirm", in: app), in: app)
        waitForStep(5, title: "nutrition.target.title", in: app)
        type("60", into: app.textFields["nutrition.target.kilograms"], in: app)
        tap(element("nutrition.target.finish", in: app), in: app)
        XCTAssertTrue(
            element("nutrition.summary.numbers", in: app).waitForExistence(timeout: 20),
            "A finished setup showed no targets"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kcal'")).firstMatch.exists,
            "The finished summary carries no calorie target — the no-target check above proves nothing"
        )
    }

    // MARK: - The guard keeps the field editable and offers a value (canvas `sGuard`)

    func testABelowFloorTargetKeepsTheFieldEditableAndOffersAValueInHerUnits() throws {
        // A US device: the target is typed in pounds and the offer is stated in pounds (#82).
        let app = launch(locale: "en_US", language: "en-US", plan: Self.refusedPlan)
        signUpAndActivate(app, email: Self.freshEmail())
        openSetup(app)
        walkToTargetWeight(app, goal: "lose")

        let pounds = app.textFields["nutrition.target.pounds"]
        XCTAssertTrue(pounds.exists, "A US device is not asked for the target in pounds")
        XCTAssertFalse(
            app.textFields["nutrition.target.kilograms"].exists,
            "A US device is asked for kilograms"
        )

        // 100 lb at any adult height is under BMI 18.5; the seeded refusal is the API's
        // answer for it (lowest supported 52.2 kg).
        type("100", into: pounds, in: app)
        tap(element("nutrition.target.finish", in: app), in: app)

        let offer = app.buttons["nutrition.guard.offer"]
        XCTAssertTrue(offer.waitForExistence(timeout: 20), "The refusal drew no guard card")
        XCTAssertTrue(element("nutrition.guard.message", in: app).exists, "The guard has no message")
        // 52.2 kg is 115.08 lb; 115 lb would be refused again, so the offer rounds up.
        XCTAssertTrue(offer.label.contains("116 lb"), "The offered value: \(offer.label)")
        XCTAssertFalse(
            element("nutrition.summary.title", in: app).exists,
            "A refused target reached the summary"
        )

        // Eva does not lock the field: it still holds her value and still takes input.
        XCTAssertTrue(pounds.isEnabled, "The guard locked the field")
        XCTAssertEqual(pounds.value as? String, "100", "The guard replaced her value without asking")
        tap(offer, in: app)
        XCTAssertEqual(pounds.value as? String, "116", "Taking the offer did not fill the field")
        clearAndType("120", into: pounds, in: app)
        capture("nutrition-guard")
    }

    // MARK: - Hide the numbers: asked on the path, survives relaunch (#212)

    func testHiddenNumbersStayHiddenAfterRelaunchAndGoalFourSkipsStepFive() throws {
        let app = launch(locale: "en_GB", language: "en-GB", plan: Self.targetsPlan)
        signUpAndActivate(app, email: Self.freshEmail())
        openSetup(app)

        // Goal 4: Step 5 is skipped entirely (PRD line 745), so Step 4 ends the path and is
        // where the preference is asked.
        tap(element("nutrition.goal.maintain", in: app), in: app)
        waitForStep(2, title: "nutrition.focus.title", in: app)
        tap(element("nutrition.focus.continue", in: app), in: app)
        waitForStep(3, title: "nutrition.meals.title", in: app)
        tap(element("nutrition.meals.2", in: app), in: app)
        waitForStep(4, title: "nutrition.body.title", in: app)

        let hide = app.switches["nutrition.hideNumbers"]
        XCTAssertTrue(hide.exists, "The hide-numbers preference is not asked on goal 4's path")
        tap(hide, in: app)
        XCTAssertTrue(waitUntil { (hide.value as? String) == "1" }, "The preference did not turn on")
        tap(element("nutrition.body.confirm", in: app), in: app)

        XCTAssertTrue(
            element("nutrition.summary.qualitative", in: app).waitForExistence(timeout: 20),
            "Goal 4 did not go from Step 4 to the summary"
        )
        XCTAssertFalse(
            element("nutrition.target.title", in: app).exists,
            "Goal 4 was asked for a target weight"
        )
        assertQualitative(in: app, "with the preference on")
        capture("nutrition-qualitative")

        // Relaunch: the preference is the server's, so the numbers stay hidden.
        relaunch(app)
        openSetup(app, expecting: "nutrition.summary.title")
        XCTAssertTrue(
            element("nutrition.summary.qualitative", in: app).waitForExistence(timeout: 20),
            "After a relaunch the summary is not qualitative — the numbers came back"
        )
        assertQualitative(in: app, "after a relaunch")
    }

    // MARK: - Assertions

    /// PRD line 677: nothing calculated or displayed from partial data.
    private func assertNoTarget(in app: XCUIApplication, _ when: String) {
        // Searched below; absent, the kcal search would pass for want of anything to search.
        XCTAssertTrue(
            app.scrollViews["nutrition.scroll"].exists,
            "The setup's column is not on screen \(when)"
        )
        XCTAssertFalse(element("nutrition.summary.title", in: app).exists, "A summary showed \(when)")
        XCTAssertFalse(element("nutrition.summary.numbers", in: app).exists, "Targets showed \(when)")
        XCTAssertFalse(
            app.scrollViews["nutrition.scroll"].staticTexts
                .containing(NSPredicate(format: "label CONTAINS[c] 'kcal'")).firstMatch.exists,
            "A calorie number is on screen \(when)"
        )
    }

    /// #212's list, against everything on screen: no calorie total, no macro gram, no weight
    /// target, no deficit wording — and no digit at all, so a number in a new sentence fails.
    private func assertQualitative(in app: XCUIApplication, _ when: String) {
        XCTAssertFalse(element("nutrition.summary.numbers", in: app).exists, "Numbers drawn \(when)")
        // The sheet's own column — Home stays in the hierarchy underneath, with its date.
        let sheet = app.scrollViews["nutrition.scroll"]
        XCTAssertTrue(sheet.exists, "The setup's column is not on screen \(when)")
        let labels = sheet.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(labels.isEmpty, "Nothing to check \(when) — the assertion would pass vacuously")
        for label in labels {
            XCTAssertNil(
                label.rangeOfCharacter(from: .decimalDigits),
                "A number is on the qualitative summary \(when): \(label.debugDescription)"
            )
            for word in ["kcal", "calorie", "protein", "deficit", " kg", " lb"] {
                XCTAssertFalse(
                    label.localizedCaseInsensitiveContains(word),
                    "\(word.debugDescription) is on the qualitative summary \(when): \(label.debugDescription)"
                )
            }
        }
    }

    // MARK: - Flow helpers

    /// Home's meals shortcut opens the setup.
    private func openSetup(_ app: XCUIApplication, expecting identifier: String = "nutrition.goal.title") {
        let meals = app.buttons["home.shortcut.meals"]
        XCTAssertTrue(meals.waitForExistence(timeout: 20), "Home has no meals shortcut")
        tap(meals, in: app)
        XCTAssertTrue(
            element(identifier, in: app).waitForExistence(timeout: 20),
            "The setup did not open on \(identifier)"
        )
    }

    private func walkToTargetWeight(_ app: XCUIApplication, goal: String) {
        tap(element("nutrition.goal.\(goal)", in: app), in: app)
        waitForStep(2, title: "nutrition.focus.title", in: app)
        tap(element("nutrition.focus.continue", in: app), in: app)
        waitForStep(3, title: "nutrition.meals.title", in: app)
        tap(element("nutrition.meals.3", in: app), in: app)
        waitForStep(4, title: "nutrition.body.title", in: app)
        XCTAssertFalse(
            app.switches["nutrition.hideNumbers"].exists,
            "The preference is asked at Step 4 although Step 5 follows"
        )
        tap(element("nutrition.body.confirm", in: app), in: app)
        waitForStep(5, title: "nutrition.target.title", in: app)
        XCTAssertTrue(app.switches["nutrition.hideNumbers"].exists, "Step 5 does not ask the preference")
    }

    private func waitForStep(_ number: Int, title: String, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            element(title, in: app).waitForExistence(timeout: 20),
            "Step \(number) (\(title)) did not appear", file: file, line: line
        )
        XCTAssertEqual(
            app.staticTexts["nutrition.step"].label, "Step \(number) of 5",
            "The progress line disagrees with the step on screen", file: file, line: line
        )
    }

    private func focus(_ code: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["nutrition.focus.\(code)"]
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    // MARK: - Launch helpers

    private func launch(locale: String, language: String, plan: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLocale", locale, "-AppleLanguages", "(\(language))"]
        app.launchEnvironment["EVA_NUTRITION_PLAN"] = plan
        return launch(app)
    }

    /// The same install, Keychain **kept** — a person reopening the app.
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime =
            ProcessInfo.processInfo.environment["EVA_UITEST_KEEP_SCREENSHOTS"] == "1"
            ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }

    /// `GET /me/nutrition/plan`'s body for a finished lose-weight setup.
    private static let targetsPlan = """
        {"plan":{"kind":"targets","targets":{"bmrKcal":1400,"tdeeKcal":1925,\
        "calorieTargetKcal":1636,"macros":{"proteinG":102,"fatG":55,"carbG":180,"fibreG":25},\
        "weightPlan":{"targetWeightKg":60,"timelineWeeks":16,"paceKgPerWeek":0.4}}}}
        """

    /// The route's refusal for a target under BMI 18.5 (`nutrition-profile.test.ts`).
    private static let refusedPlan = """
        {"plan":{"kind":"refused","refusal":{"reason":"below-bmi-floor","lowestSupportedWeightKg":52.2}}}
        """
}

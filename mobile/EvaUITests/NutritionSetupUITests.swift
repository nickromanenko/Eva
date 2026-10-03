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
        // The resume card first (canvas `sResume`): what is done, what remains, no target.
        openSetup(app, expecting: "nutrition.resume.title")
        assertNoTarget(in: app, "on the resume card")
        for (step, done) in [
            ("goal", true), ("focusAreas", true), ("mealPattern", true),
            ("bodyMetrics", false), ("targetWeight", false),
        ] {
            let row = element("nutrition.resume.step.\(step)", in: app)
            XCTAssertTrue(row.exists, "The resume card does not list \(step)")
            XCTAssertEqual(
                row.label.hasSuffix(", done"), done,
                "\(step) is shown as \(done ? "not done" : "done"): \(row.label)"
            )
        }
        capture("nutrition-resume-card")
        tap(element("nutrition.resume.continue", in: app), in: app)
        waitForStep(4, title: "nutrition.body.title", in: app)
        assertNoTarget(in: app, "after resuming a partial setup")
        // Step 4 confirms her profile rather than asking for it (canvas `s4`).
        for id in ["nutrition.body.height", "nutrition.body.weight", "nutrition.body.age"] {
            XCTAssertTrue(element(id, in: app).exists, "Step 4 has no \(id)")
        }
        XCTAssertFalse(
            app.textFields["nutrition.body.weight"].isEnabled,
            "Step 4 takes input — the weight is edited in Profile"
        )
        // A fresh account has answered no activity band, and none is marked for her.
        for code in ["mostlySitting", "lightlyActive", "active", "veryActive"] {
            XCTAssertFalse(
                element("nutrition.body.activity.\(code)", in: app).isSelected,
                "\(code) is marked although she has given no band"
            )
        }
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

        // MARK: The summary's rows (canvas `sSum`): fibre, target weight, the adjustment status

        for row in ["fibre", "targetWeight", "cycleAdjustment", "calories"] {
            XCTAssertTrue(
                element("nutrition.summary.\(row)", in: app).exists,
                "The summary has no \(row) row"
            )
        }
        // The adjusted number is the one shown (the seeded luteal 1,718), not the engine's 1,636.
        XCTAssertTrue(
            element("nutrition.summary.calories", in: app).label.contains("1,718"),
            "The summary does not show the adjusted target: "
                + element("nutrition.summary.calories", in: app).label
        )
        // The seeded luteal, wide-band adjustment reads as one, with its confidence.
        let status = element("nutrition.summary.cycleAdjustment", in: app).label
        XCTAssertTrue(status.contains("On · luteal phase"), "A luteal adjustment does not say so: \(status)")
        XCTAssertTrue(status.contains("wide estimate"), "A wide-band phase reads as a certainty: \(status)")
        assertNoReviewClaim(in: app)
        capture("nutrition-summary")
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
        XCTAssertTrue(element("nutrition.guard.title", in: app).exists, "The guard has no title")
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
        let app = launch(locale: "en_GB", language: "en-GB", plan: Self.unadjustedPlan)
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
        assertNoReviewClaim(in: app)
        capture("nutrition-qualitative")

        // Relaunch: the preference is the server's, so the numbers stay hidden.
        relaunch(app)
        openSetup(app, expecting: "nutrition.summary.title")
        XCTAssertTrue(
            element("nutrition.summary.qualitative", in: app).waitForExistence(timeout: 20),
            "After a relaunch the summary is not qualitative — the numbers came back"
        )
        assertQualitative(in: app, "after a relaunch")

        // MARK: Reversed from Nutrition Settings (canvas `nSet`) — and only from there

        relaunch(app)
        // A fresh account has no stored height or weight; one Profile save gives it the
        // editor's, so the Body metrics row has a value it could show.
        saveAProfile(app)
        let setting = openNutritionSettings(app)
        XCTAssertTrue(
            waitUntil { (setting.value as? String) == "1" },
            "Nutrition Settings does not show the stored preference: \(String(describing: setting.value))"
        )
        // Hidden numbers: the Body metrics row names Profile, and carries no weight.
        let bodyRow = app.buttons["nutrition.settings.bodyMetrics"]
        XCTAssertTrue(bodyRow.exists, "Nutrition Settings has no Body metrics row")
        XCTAssertTrue(bodyRow.label.contains("Set in Profile"), "Body metrics row: \(bodyRow.label)")
        XCTAssertNil(
            bodyRow.label.rangeOfCharacter(from: .decimalDigits),
            "A height or weight is on Nutrition Settings with the numbers hidden: \(bodyRow.label)"
        )
        capture("nutrition-settings")
        tap(setting, in: app)
        XCTAssertTrue(
            waitUntil { (setting.value as? String) == "0" && setting.isEnabled },
            "The preference did not turn off"
        )
        // Turned off by her, the values come back — the control for the check above.
        XCTAssertTrue(
            waitUntil { bodyRow.label.contains(" kg") && bodyRow.label.contains(" cm") },
            "Turning the preference off did not bring the body metrics back: \(bodyRow.label)"
        )

        // Turned off by her, the numbers are back — and they stay back across a relaunch.
        relaunch(app)
        openSetup(app, expecting: "nutrition.summary.title")
        XCTAssertTrue(
            element("nutrition.summary.numbers", in: app).waitForExistence(timeout: 20),
            "Turning the preference off in Settings did not bring the numbers back"
        )
        // The seeded plan was not adjusted: the status must not claim it was.
        let status = element("nutrition.summary.cycleAdjustment", in: app)
        XCTAssertTrue(status.exists, "The summary has no cycle-adjustment row")
        XCTAssertTrue(status.label.contains("Not applied today"), "Unadjusted status: \(status.label)")
        XCTAssertFalse(status.label.contains("On ·"), "An unadjusted day reads as adjusted: \(status.label)")
        relaunch(app)
        let again = openNutritionSettings(app)
        XCTAssertTrue(
            waitUntil { (again.value as? String) == "0" },
            "The preference turned itself back on after a relaunch"
        )
    }

    /// Profile ▸ Medications ▸ None ▸ Save. Every Profile editor re-sends the whole profile,
    /// so this stores one — with the editor's default height and weight — and medications is
    /// the editor a fresh account can save (`ProfileActivityUITests`).
    private func saveAProfile(_ app: XCUIApplication) {
        let profile = app.buttons["tab.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "No Profile tab")
        tap(profile, in: app)
        tap(app.buttons["profile.medications"], in: app)
        tap(app.buttons["chip.None"], in: app)
        let save = app.buttons["primary.Save"]
        tap(save, in: app)
        XCTAssertTrue(save.waitForNonExistence(timeout: 15), "Saving the profile did not return to Profile")
    }

    /// Profile ▸ Eva experience ▸ Nutrition Settings, and its hide-numbers switch once the
    /// server's value has loaded.
    private func openNutritionSettings(_ app: XCUIApplication) -> XCUIElement {
        let profile = app.buttons["tab.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "No Profile tab")
        tap(profile, in: app)
        tap(app.buttons["profile.nutrition"], in: app)
        let setting = app.switches["nutrition.settings.hideNumbers"]
        XCTAssertTrue(setting.waitForExistence(timeout: 20), "Nutrition Settings has no switch")
        XCTAssertTrue(waitUntil { setting.isEnabled }, "The switch never loaded")
        return setting
    }

    // MARK: - Assertions

    /// #374: the summary once said plans are "reviewed by a registered dietitian", which no
    /// plan is. The disclaimer is on screen, and nothing on the summary makes that claim.
    private func assertNoReviewClaim(in app: XCUIApplication) {
        let sheet = app.scrollViews["nutrition.scroll"]
        XCTAssertTrue(
            element("nutrition.summary.disclaimer", in: app).exists,
            "The summary has no disclaimer — the absence below would prove nothing"
        )
        XCTAssertFalse(
            sheet.staticTexts
                .containing(NSPredicate(format: "label CONTAINS[c] 'reviewed by a registered dietitian'"))
                .firstMatch.exists,
            "The summary still claims a dietitian reviewed the plan"
        )
    }

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

    /// `GET /me/nutrition/plan`'s body for a finished lose-weight setup, in a luteal phase
    /// estimated on a wide band — the shape `adjustNutritionPlan` serves (#224).
    private static let targetsPlan = """
        {"plan":{"kind":"targets","targets":{"bmrKcal":1400,"tdeeKcal":1925,\
        "calorieTargetKcal":1636,"macros":{"proteinG":102,"fatG":55,"carbG":180,"fibreG":25},\
        "weightPlan":{"targetWeightKg":60,"timelineWeeks":16,"paceKgPerWeek":0.4}},\
        "adjustment":{"calorieTargetKcal":1718,"reasonId":"luteal_adjustment","confidence":"wide"}}}
        """

    /// A finished goal-4 setup on a day nothing adjusted: no weight plan, and the route's
    /// empty adjustment — which it serves alike for "not luteal" and "no phase estimate".
    private static let unadjustedPlan = """
        {"plan":{"kind":"targets","targets":{"bmrKcal":1400,"tdeeKcal":1925,\
        "calorieTargetKcal":1925,"macros":{"proteinG":102,"fatG":64,"carbG":230,"fibreG":25},\
        "weightPlan":null},\
        "adjustment":{"calorieTargetKcal":1925,"reasonId":null,"confidence":null}}}
        """

    /// The route's refusal for a target under BMI 18.5 (`nutrition-profile.test.ts`).
    private static let refusedPlan = """
        {"plan":{"kind":"refused","refusal":{"reason":"below-bmi-floor","lowestSupportedWeightKg":52.2}}}
        """
}

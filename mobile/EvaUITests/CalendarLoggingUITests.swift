import XCTest

/// Issue #160: **the other half of the core loop — logging, editing, deleting, undoing.**
///
/// One test, in the shape the rest of this target uses, because every step needs the one
/// before it: there is nothing to edit until something is logged, and nothing to undo until
/// something is deleted. It runs against the real API the harness started, so what it
/// proves is the whole round trip — a draft built on the device, a payload the route
/// accepted, and the server's own copy of the entry back on the grid.
///
/// **Nothing here is written over HTTP.** C1's suite had to `POST /me/events` itself
/// because the app could not log anything; this one must not, or it would be testing the
/// same thing C1 already does. Every entry below is created by tapping.
///
/// The account is left alive for `scripts/e2e-cleanup.ts` to sweep by the
/// `e2e+<uuid>@e2e.evaapp.dev` pattern (GUARDRAILS §16).
final class CalendarLoggingUITests: EvaUITestCase {

    // MARK: - Cleaning up the health data this test creates

    /// The account this test made. `nil` until sign-up has succeeded — a run that failed
    /// before then logged nothing either.
    private var createdAccountEmail: String?

    /// Deletes the account, **and with it every entry this test tapped in.**
    ///
    /// The same obligation `CalendarUITests` took on in C1 and for the same reason:
    /// `scripts/e2e-cleanup.ts` deletes `users/{uid}` and Firestore does not cascade into
    /// its `events/` subcollection, so without this every run would orphan health-data
    /// documents in the real project permanently (GUARDRAILS 12 and 16). `DELETE /me` runs
    /// `deleteAllUserEvents`, which hard-deletes the subcollection — the per-entry route is
    /// a *soft* delete and would leave the payloads exactly where they are.
    ///
    /// The token is fetched here rather than kept from the test body, because this suite
    /// never signs in over HTTP: it logs everything by tapping, which is the whole point of
    /// it. `tearDown`, not the end of the body, so a failure half-way through still cleans
    /// up — `continueAfterFailure` is false, so the body stops where it fails.
    ///
    /// The body runs on the main actor, which is where XCTest already calls it.
    ///
    /// `tearDown()` cannot simply be annotated: an override inherits the isolation of the
    /// declaration it overrides, and `XCTestCase.tearDown()` is nonisolated Objective-C, so
    /// `@MainActor override` is rejected outright — "has different actor isolation from
    /// nonisolated overridden declaration". But everything below is `@MainActor`, because
    /// `EvaUITestCase` is.
    ///
    /// `assumeIsolated` states the thread this already runs on and *checks* it, rather than
    /// asserting it unsafely. It adds no failure mode the suite did not already have: the
    /// test methods are `@MainActor` too, so a tearDown reached off the main thread would
    /// mean the test body had already trapped on the way in.
    override func tearDown() {
        MainActor.assumeIsolated {
            defer {
                createdAccountEmail = nil
                super.tearDown()
            }
            guard let email = createdAccountEmail else { return }
            guard let token = bearerToken(email: email) else {
                XCTFail("Could not sign in to clean up \(email); its entries are orphaned")
                return
            }

            var request = URLRequest(url: URL(string: "\(Self.apiBaseURL)/me")!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (status, body) = send(request)

            XCTAssertEqual(
                status, 200,
                """
                DELETE /me answered \(status) for \(email): \(body ?? "no body").
                The entries this test logged are still in Firestore, and the cleanup sweep does
                not reach a user's events subcollection.
                """
            )
        }
    }

    /// Signs in over HTTP purely so `tearDown` has something to authorize with.
    private func bearerToken(email: String) -> String? {
        var request = URLRequest(url: URL(string: "\(Self.apiBaseURL)/auth/signin")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["email": email, "password": Self.password]
        )
        let (status, body) = send(request)
        guard status == 200, let data = body?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["token"] as? String
    }

    /// A synchronous request. A semaphore rather than an `XCTestExpectation`, because
    /// expectations in `tearDown` are fragile and this has nothing to do while it waits.
    private func send(_ request: URLRequest) -> (status: Int, body: String?) {
        let finished = DispatchSemaphore(value: 0)
        var status = 0
        var body: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = error?.localizedDescription ?? data.flatMap { String(data: $0, encoding: .utf8) }
            finished.signal()
        }.resume()
        guard finished.wait(timeout: .now() + 30) == .success else { return (0, "no response") }
        return (status, body)
    }

    // MARK: - The test

    func testLoggingEditingDeletingAndUndo() throws {
        let app = launch()
        let email = Self.freshEmail()
        // Armed before anything is logged, so `tearDown` can always reach what this run
        // wrote — including a run that fails part-way through.
        createdAccountEmail = email

        signUpAndActivate(app, email: email)
        completeQuestionnaire(app)
        XCTAssertTrue(
            app.staticTexts["You're all set"].waitForExistence(timeout: 15),
            "Questionnaire submission did not reach the done screen"
        )
        tap(app.buttons["primary.Enter Eva"], in: app)
        // Home is the landing tab since #99; the calendar is one tap away.
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 20),
            "The Calendar tab did not reach the calendar"
        )

        let today = Self.todayISO()

        // MARK: The picker knows which day it is writing to

        openPicker(app)
        XCTAssertTrue(
            app.staticTexts["log.targetDay"].waitForExistence(timeout: 10),
            "The log picker does not state the day it is logging to"
        )
        capture("01-log-picker")

        // …and offers a way to change it, which `SPEC.picker` asks for by name.
        tapInSheet(app.buttons["log.changeDate"], in: app)
        XCTAssertTrue(
            app.datePickers["log.datePicker"].waitForExistence(timeout: 10)
                || app.otherElements["log.datePicker"].waitForExistence(timeout: 1),
            "Change date opened no date picker"
        )
        tapInSheet(app.buttons["log.changeDate"], in: app)

        // MARK: Log a period day

        tap(app.buttons["log.type.cycle"], in: app)
        XCTAssertTrue(
            app.buttons["log.flow.medium"].waitForExistence(timeout: 10),
            "Choosing Menstrual cycle did not open the flow sheet"
        )
        tapInSheet(app.buttons["log.flow.medium"], in: app)
        capture("02-log-flow")
        tapInSheet(app.buttons["primary.Save"], in: app)

        XCTAssertTrue(
            entryRow(app, "Menstrual cycle").waitForExistence(timeout: 20),
            "Saving a flow entry did not put it on the selected day"
        )
        XCTAssertTrue(
            entryRow(app, "Menstrual cycle").label.contains("Medium flow"),
            "The saved entry does not say what was logged: "
            + entryRow(app, "Menstrual cycle").label
        )
        // …and the grid redrew without a reload, which is #160's first criterion.
        let todayCell = app.buttons["calendar.day.\(today)"]
        XCTAssertTrue(
            todayCell.label.contains("Medium flow logged"),
            "The grid cell did not pick up the entry that was just saved: \(todayCell.label)"
        )
        // The toast confirms in words, and names the day it landed on.
        XCTAssertTrue(
            app.otherElements["calendar.toast"].exists
                || app.staticTexts["Menstrual cycle saved to \(Self.todayLabel())"].exists,
            "Saving showed no confirmation"
        )

        // MARK: Re-opening the day edits rather than logging a second

        openPicker(app)
        let cycleRow = app.buttons["log.type.cycle"]
        XCTAssertTrue(cycleRow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            cycleRow.label.contains("Already logged"),
            "The picker does not say the day already has a cycle entry: \(cycleRow.label)"
        )
        tap(cycleRow, in: app)
        XCTAssertTrue(
            app.buttons["primary.Save changes"].waitForExistence(timeout: 10),
            "Re-opening a logged day offered to create a second entry instead of editing"
        )
        tapInSheet(app.buttons["log.flow.heavy"], in: app)
        tapInSheet(app.buttons["primary.Save changes"], in: app)

        XCTAssertTrue(
            waitForLabel(entryRow(app, "Menstrual cycle"), containing: "Heavy flow"),
            "The edit did not change the entry: " + entryRow(app, "Menstrual cycle").label
        )
        XCTAssertEqual(
            app.staticTexts["calendar.day.count"].label, "1 entry",
            "Editing created a second entry instead of replacing the first"
        )

        // MARK: Log body signals, with a symptom from /refdata

        openPicker(app)
        tap(app.buttons["log.type.bodySignals"], in: app)
        XCTAssertTrue(
            app.buttons["scale.Energy.2"].waitForExistence(timeout: 10),
            "Choosing Body signals did not open the scales"
        )
        tapInSheet(app.buttons["scale.Energy.2"], in: app)
        tapInSheet(app.buttons["scale.Sleep.4"], in: app)
        XCTAssertEqual(
            app.staticTexts["scale.Energy.readout"].label, "Low · 2 of 5",
            "The scale readout does not describe the point that was chosen"
        )

        // The symptom chips are reference data, so the test picks whichever one the
        // catalogue happens to offer first rather than naming a code this build does not
        // own. That the list arrived at all is asserted separately.
        XCTAssertFalse(
            app.staticTexts["log.symptoms.unavailable"].exists,
            "The symptom catalogue did not load, so nothing here tested /refdata"
        )
        let chip = firstChip(in: "log.symptoms", app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "No symptom chips were drawn")
        let symptomLabel = chip.label
        tapInSheet(chip, in: app)
        capture("03-log-body-signals")
        tapInSheet(app.buttons["primary.Save"], in: app)

        let bodyRow = entryRow(app, "Body signals")
        XCTAssertTrue(
            bodyRow.waitForExistence(timeout: 20),
            "Saving body signals did not put them on the selected day"
        )
        XCTAssertTrue(
            bodyRow.label.contains("Energy Low"),
            "The entry does not describe the rating that was chosen: \(bodyRow.label)"
        )
        XCTAssertTrue(
            bodyRow.label.localizedCaseInsensitiveContains(symptomLabel),
            "The entry does not list the symptom that was tapped (\(symptomLabel)): "
            + bodyRow.label
        )
        XCTAssertEqual(app.staticTexts["calendar.day.count"].label, "2 entries")

        // MARK: Delete, and undo

        tapOnCalendar(actionButton("delete", on: bodyRow), in: app)
        let undo = app.buttons["toast.Undo"]
        let existed = undo.waitForExistence(timeout: 15)
        capture("04-delete-undo")
        XCTAssertTrue(
            existed,
            // What the toast says is the difference between "the delete failed" and "Undo
            // was withdrawn", and those are different bugs.
            "Deleting an entry offered no Undo. Toast: \(toastDescription(app))"
        )
        XCTAssertFalse(
            entryRow(app, "Body signals").exists,
            "The deleted entry is still listed on the day"
        )

        tap(app.buttons["toast.Undo"], in: app)
        XCTAssertTrue(
            entryRow(app, "Body signals").waitForExistence(timeout: 20),
            "Undo did not restore the entry"
        )
        XCTAssertEqual(
            app.staticTexts["calendar.day.count"].label, "2 entries",
            "Undo restored the wrong number of entries"
        )

        // MARK: #50 — Undo is not offered once the day has been re-logged
        //
        // Deleting the one-per-day cycle entry and then logging that day again overwrites
        // the very document the delete soft-deleted, so `restore` would answer
        // 409 DAY_ALREADY_LOGGED. The button has to be gone before it can be tapped.

        tapOnCalendar(
            actionButton("delete", on: entryRow(app, "Menstrual cycle")), in: app
        )
        XCTAssertTrue(
            app.buttons["toast.Undo"].waitForExistence(timeout: 15),
            "Deleting the cycle entry offered no Undo"
        )
        openPicker(app)
        tap(app.buttons["log.type.cycle"], in: app)
        tapInSheet(app.buttons["log.flow.light"], in: app)
        tapInSheet(app.buttons["primary.Save"], in: app)

        XCTAssertTrue(
            waitForLabel(entryRow(app, "Menstrual cycle"), containing: "Light flow"),
            "Re-logging the day did not replace the deleted entry"
        )
        XCTAssertFalse(
            app.buttons["toast.Undo"].exists,
            "Undo was still offered after the day had been logged again (#50)"
        )

        // MARK: Sport — the other type that can go on today
        //
        // Not one-per-day, so this is also the path where a second entry of a type is a
        // second entry rather than a replacement.

        openPicker(app)
        tap(app.buttons["log.type.sport"], in: app)
        let activity = firstChip(in: "log.activities", app)
        XCTAssertTrue(
            activity.waitForExistence(timeout: 10),
            "The sport sheet drew no activities, so /refdata did not reach it"
        )
        let activityLabel = activity.label
        tapInSheet(activity, in: app)
        tapInSheet(app.buttons["log.intensity.medium"], in: app)
        tapInSheet(app.buttons["primary.Save"], in: app)

        let sportRow = entryRow(app, "Sport")
        XCTAssertTrue(
            sportRow.waitForExistence(timeout: 20),
            "Saving a workout did not put it on the selected day"
        )
        XCTAssertTrue(
            sportRow.label.localizedCaseInsensitiveContains(activityLabel),
            "The entry does not name the activity that was chosen (\(activityLabel)): "
            + sportRow.label
        )
        XCTAssertEqual(app.staticTexts["calendar.day.count"].label, "3 entries")

        // MARK: A future day offers appointments only, visibly

        scrollCalendarToTop(app)
        tap(app.buttons["calendar.nextMonth"], in: app)
        let futureDay = Self.firstOfNextMonthISO()
        // The first of next month can still be today's month-mate in the grid; the 20th is
        // unambiguously ahead of today wherever the run starts.
        let aheadCell = app.buttons["calendar.day.\(Self.dayOfNextMonthISO(20))"]
        XCTAssertTrue(
            aheadCell.waitForExistence(timeout: 15),
            "Paging forward did not reach \(futureDay)'s month"
        )
        tap(aheadCell, in: app)
        openPicker(app)

        XCTAssertTrue(
            app.buttons["log.type.appointment"].waitForExistence(timeout: 10),
            "The picker did not open on a future day"
        )
        XCTAssertTrue(
            app.buttons["log.type.appointment"].isEnabled,
            "Appointments were refused on a future day"
        )
        for type in ["cycle", "bodySignals", "sport"] {
            let row = app.buttons["log.type.\(type)"]
            XCTAssertFalse(
                row.isEnabled,
                "\(type) was offered on a future day, so the refusal would be silent"
            )
            XCTAssertTrue(
                row.label.contains("Only appointments can be logged ahead"),
                "\(type) is dimmed on a future day but does not say why: \(row.label)"
            )
        }
        capture("05-future-day")

        // MARK: …and an appointment actually saves on it
        //
        // The exception the whole date policy exists for, proved end to end rather than
        // inferred from the row being tappable.

        tapInSheet(app.buttons["log.type.appointment"], in: app)
        let apptType = firstChip(in: "log.appointmentTypes", app)
        XCTAssertTrue(
            apptType.waitForExistence(timeout: 10),
            "The appointment sheet drew no types, so /refdata did not reach it"
        )
        let apptTypeLabel = apptType.label
        tapInSheet(apptType, in: app)

        let question = "Ask about the cramping pattern"
        tapInSheet(app.textFields["log.question.text"], in: app)
        app.textFields["log.question.text"].typeText(question)
        tapInSheet(app.buttons["secondary.Add"], in: app)
        XCTAssertTrue(
            app.staticTexts[question].waitForExistence(timeout: 5),
            "Adding a question did not list it"
        )
        capture("06-log-appointment")
        tapInSheet(app.buttons["primary.Save appointment"], in: app)

        let apptRow = entryRow(app, "Doctor appointment")
        XCTAssertTrue(
            apptRow.waitForExistence(timeout: 20),
            "Saving an appointment on a future day did not put it on that day"
        )
        XCTAssertTrue(
            apptRow.label.contains("1 question to bring"),
            "The appointment does not carry the question that was added: \(apptRow.label)"
        )
        XCTAssertTrue(
            apptRow.label.localizedCaseInsensitiveContains(apptTypeLabel),
            // The assertion the first run was missing: it tapped the reminder instead of a
            // type, saved a typeless appointment, and passed.
            "The appointment does not name the type that was chosen (\(apptTypeLabel)): "
            + apptRow.label
        )
        XCTAssertEqual(
            app.staticTexts["calendar.day.count"].label, "1 entry",
            "The appointment did not land on the future day that was selected"
        )

        // MARK: The picker's own dismissal

        openPicker(app)
        // The picker has no close button — the artboard draws none, and the sheet's own
        // grabber is the way out. Asserted rather than assumed, because removing the ×
        // would otherwise leave a sheet with no exit if the drag indicator ever went.
        XCTAssertFalse(app.buttons["log.close"].exists, "The picker grew a close button")
        app.descendants(matching: .any)
            .matching(identifier: "log.sheet").firstMatch.swipeDown(velocity: .fast)
        XCTAssertTrue(
            app.buttons["calendar.log"].waitForExistence(timeout: 10),
            "Swiping the picker down did not return to the calendar"
        )
    }

    // MARK: - Steps

    /// Opens the log picker from the calendar's floating button, waiting out whatever
    /// toast the previous step left over it.
    ///
    /// **Through `tap(_:in:)` rather than `XCUIElement.tap()`.** This was the one call site
    /// in the target that tapped bare, and a bare tap is the gap #82 and #214 closed
    /// everywhere else: it sends a touch to wherever the last snapshot put the element,
    /// having asserted nothing about whether the element can actually receive one. The
    /// shared helper checks `isHittable` and the window's bottom edge first. On this screen
    /// the FAB is always hittable and well clear of the bar — measured at
    /// `(356, 782, 60, 60)` in a 440×956 window, 16pt above a bar that starts at 858 — so
    /// the helper does no scrolling here. What it adds is the assertion, and a failure that
    /// names an unreachable button instead of one that says the sheet did not open.
    ///
    /// **The failure carries the screen with it (#192).** "Tapping Log did not open the
    /// picker sheet" says what did not happen and nothing about why, and the state that
    /// would answer it — where the button was, which tab ended up selected, whether the
    /// calendar had finished loading — is gone by the time anyone reads a CI log. The
    /// accessibility snapshot XCTest captures on failure goes into an xcresult that
    /// `test-mobile.yml` does not upload, so on CI there is nothing to read at all. That
    /// cost this issue two days, and `pickerFailure` is what it should have said.
    private func openPicker(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons["calendar.log"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 15),
            "The calendar has no Log button", file: file, line: line
        )
        XCTAssertTrue(
            button.isEnabled,
            "The Log button is still disabled — C2 is what turns it on",
            file: file, line: line
        )
        tap(button, in: app, file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["log.targetDay"].waitForExistence(timeout: 10),
            "Tapping Log did not open the picker sheet.\n\(pickerFailure(app, button))",
            file: file, line: line
        )
    }

    /// What was on screen when the picker did not open.
    ///
    /// Three questions, because #192 could not answer any of them from a CI log and each
    /// points at a different bug. **Did the touch land somewhere else** — the FAB is the
    /// trailing-most control above the bar, so a tap that missed low lands on Profile, and
    /// `tapOnCalendar` records that exact thing happening once already. **Was the button
    /// where the test thought it was** — its frame against the window's, which is what
    /// #214's clamping trap hides. **Had the calendar finished loading** — `calendar.empty`
    /// needs `hasHistory`, which is `nil` until the first read answers, so neither it nor
    /// the summary being on screen means the load is still in flight.
    ///
    /// Matched on identifier through `descendants(matching: .any)` rather than by element
    /// type, the way `entryRow` and `firstChip` do: a diagnostic that reports `false`
    /// because it guessed `otherElements` for a `staticText` is worse than no diagnostic.
    private func pickerFailure(_ app: XCUIApplication, _ button: XCUIElement) -> String {
        func onScreen(_ identifier: String) -> Bool {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
        }
        let selected = ["home", "calendar", "profile"]
            .first { app.buttons["tab.\($0)"].isSelected } ?? "none"
        return """
          Log button:   \(button.frame) hittable=\(button.isHittable) \
        enabled=\(button.isEnabled)
          window:       \(app.frame)
          selected tab: \(selected) — "profile" means the touch landed on the tab bar
          calendar:     grid=\(onScreen("calendar.grid")) \
        loaded=\(onScreen("calendar.empty") || onScreen("calendar.summary")) \
        loadError=\(onScreen("calendar.loadError"))
          log sheet:    \(onScreen("log.sheet"))
        """
    }

    // MARK: - Elements

    /// Taps something in the calendar's scrolling column, clear of the tab bar.
    ///
    /// `EvaUITestCase.tap` stops swiping the moment `isHittable` turns true, and on this
    /// screen that is not enough: the day's Edit and Delete buttons sit in the middle of a
    /// long column, and an element whose activation point lands in the tab bar's safe-area
    /// inset reports hittable and then hands the tap to the tab bar. The first run of this
    /// test deleted nothing and switched to Profile, which is a failure that looks exactly
    /// like a broken delete.
    ///
    /// So the element has to be **above the bar**, not merely hittable, before it is tapped.
    private func tapOnCalendar(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 15),
            "Missing element on the calendar: \(element)", file: file, line: line
        )
        // The tab bar plus the home indicator, with room for the floating Log button that
        // sits above them.
        let floor = app.frame.maxY - 190
        var swipes = 0
        while element.frame.maxY > floor && swipes < 8 {
            app.scrollViews.firstMatch.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(
            element.isHittable && element.frame.maxY <= floor,
            """
            Could not bring \(element.identifier) clear of the tab bar in \(swipes) swipes.
              element frame: \(element.frame)
              app frame:     \(app.frame)
            """,
            file: file, line: line
        )
        element.tap()
    }

    /// Scrolls the calendar's column back to the header.
    ///
    /// `EvaUITestCase.tap` only ever swipes **up**, deliberately — on the auth screens a
    /// downward drag dismisses the keyboard and would quietly turn an unreachable footer
    /// into a reachable one. The calendar has no keyboard and the month steppers are at the
    /// top, so this test needs the other direction and says so here rather than loosening
    /// the shared helper.
    private func scrollCalendarToTop(_ app: XCUIApplication) {
        let header = app.buttons["calendar.monthPicker"]
        var swipes = 0
        while !header.isHittable && swipes < 8 {
            app.scrollViews.firstMatch.swipeDown()
            swipes += 1
        }
    }

    /// The first chip in one catalogue-backed field.
    ///
    /// The labels are reference data, so a test must not name one — but "the first `chip.`
    /// button on the sheet" is not the same thing either: the sport sheet also draws
    /// duration chips and the appointment sheet draws the reminder as one. The first run of
    /// this test toggled the reminder off believing it had chosen an appointment type, and
    /// the save still passed. So the field is addressed, then its own chips.
    private func firstChip(
        in field: String,
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let container = app.descendants(matching: .any).matching(identifier: field).firstMatch
        XCTAssertTrue(
            container.waitForExistence(timeout: 10),
            "The \(field) field is not on screen", file: file, line: line
        )
        return container.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chip.'"))
            .element(boundBy: 0)
    }

    /// What the calendar's toast is currently saying, for a failure message.
    private func toastDescription(_ app: XCUIApplication) -> String {
        let toast = app.descendants(matching: .any)
            .matching(identifier: "calendar.toast").firstMatch
        guard toast.exists else { return "no toast on screen" }
        let labels = toast.descendants(matching: .staticText)
            .allElementsBoundByIndex.map { $0.label }
        return toast.label.isEmpty ? labels.joined(separator: " / ") : toast.label
    }

    /// A day-detail row, found by the words it announces rather than by an id the test
    /// cannot know.
    ///
    /// C1 keyed rows on the **entry's id** — two sport entries on one day are legal, so a
    /// row keyed on the type would collide. Nothing here ever sees an id: this suite logs
    /// by tapping and never calls the API. So the row is matched on its label, which is the
    /// sentence the row announces, and `actionButton(_:on:)` reads the id back off the row
    /// it found. That keeps the test independent of both the type name's spelling and the
    /// server's id scheme.
    private func entryRow(_ app: XCUIApplication, _ typeName: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                    "calendar.entry.", typeName
                )
            )
            .firstMatch
    }

    /// The Edit or Delete button belonging to one row.
    private func actionButton(
        _ action: String,
        on row: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "No row to take \(action) from", file: file, line: line
        )
        let id = row.identifier.replacingOccurrences(of: "calendar.entry.", with: "")
        return row.descendants(matching: .button)["calendar.\(action).\(id)"]
    }

    /// Waits for an element's *label* to change, which `waitForExistence` cannot do: an
    /// edit replaces the row's contents while the row itself stays on screen the whole time.
    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 20
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            _ = element.waitForExistence(timeout: 0.5)
        }
        return false
    }

    /// Taps inside the log sheet, scrolling **the sheet** rather than the calendar behind it.
    ///
    /// `EvaUITestCase.tap` swipes `app.scrollViews.firstMatch`, which is the calendar's
    /// column while a sheet is up — so a Save button below the fold of a tall sheet would
    /// never come into reach and the failure would read as a missing button.
    private func tapInSheet(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "Missing element in the log sheet: \(element)", file: file, line: line
        )
        let sheet = app.descendants(matching: .any)
            .matching(identifier: "log.sheet").firstMatch
        var swipes = 0
        while !element.isHittable && swipes < 6 {
            if sheet.exists { sheet.swipeUp() } else { app.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(
            element.isHittable,
            """
            Never became hittable inside the sheet: \(element)
              element frame: \(element.frame)
              app frame:     \(app.frame)
            """,
            file: file, line: line
        )
        element.tap()
    }

    // MARK: - Screenshots

    /// Attaches what is on screen to the result bundle. `.deleteOnSuccess`, so a green CI
    /// run carries nothing and a red one carries the screen it failed on;
    /// `EVA_UITEST_KEEP_SCREENSHOTS=1` keeps them on a pass, which is how these sheets were
    /// read against the canvas.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime =
            ProcessInfo.processInfo.environment["EVA_UITEST_KEEP_SCREENSHOTS"] == "1"
            ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }

    // MARK: - Dates
    //
    // The test computes the same wall-clock day the app does: both read the simulator's
    // zone, which is the host's.

    private static func todayISO() -> String { iso(Date()) }

    private static func todayLabel() -> String {
        Date().formatted(.dateTime.day().month(.wide))
    }

    private static func firstOfNextMonthISO() -> String { dayOfNextMonthISO(1) }

    private static func dayOfNextMonthISO(_ day: Int) -> String {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: start)!
        let parts = calendar.dateComponents([.year, .month], from: nextMonth)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, day)
    }

    private static func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

import XCTest

/// Issue #159: **the calendar is the app's landing surface, and it shows what was logged.**
///
/// One test, in the shape the other suites in this target use, because every step needs
/// the one before it: there is no calendar without an activated account, nothing to select
/// without an entry, and no way to get an entry onto the device except through the API the
/// app reads.
///
/// That last part is why this suite talks to the API directly. **C1 cannot log anything** —
/// the log picker is C2 (#160) — so the only way to put an entry on the grid is to write it
/// the way another device would have: sign in over HTTP, `POST /me/events`, relaunch. It
/// also makes the cold-launch path the one under test, which is the acceptance criterion's
/// own wording: *a signed-in user lands on a tab bar, and Calendar shows the current month*.
///
/// The account is left alive for `scripts/e2e-cleanup.ts` to sweep by the
/// `e2e+<uuid>@e2e.evaapp.dev` pattern (GUARDRAILS §16).
final class CalendarUITests: EvaUITestCase {

    func testTheCalendarLandsPagesAndShowsWhatWasLogged() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: An account, and the landing surface

        signUpAndActivate(app, email: email)
        completeQuestionnaire(app)
        XCTAssertTrue(
            app.staticTexts["You're all set"].waitForExistence(timeout: 15),
            "Questionnaire submission did not reach the done screen"
        )
        tap(app.buttons["primary.Enter Eva"], in: app)

        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 15),
            "Entering the app did not reach the tab bar"
        )
        XCTAssertTrue(app.buttons["tab.home"].exists, "The tab bar has no Home tab")
        XCTAssertTrue(app.buttons["tab.profile"].exists, "The tab bar has no Profile tab")
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 15),
            "Calendar is not the landing tab — the month grid is not on screen"
        )

        let today = Self.todayISO()
        XCTAssertTrue(
            app.buttons["calendar.day.\(today)"].waitForExistence(timeout: 10),
            "The grid is not showing the current month: no cell for \(today)"
        )
        XCTAssertTrue(
            app.buttons["calendar.day.\(today)"].label.contains("Today"),
            "Today is not marked: \(app.buttons["calendar.day.\(today)"].label)"
        )

        // MARK: Zero data is explorable, and says so without blocking anything

        XCTAssertTrue(
            app.staticTexts["calendar.empty"].waitForExistence(timeout: 10)
                || app.otherElements["calendar.empty"].waitForExistence(timeout: 1),
            "A brand-new account was not shown the first-log card"
        )
        capture("01-calendar-empty")
        // The pointer at the Log button — the whole of `SPEC.calEmpty` that is visible.
        XCTAssertTrue(
            app.staticTexts["calendar.logPointer"].exists,
            "The empty state showed no pointer at the Log button"
        )
        // …and nothing is in the way of exploring. A modal would make the grid unhittable.
        XCTAssertTrue(
            app.buttons["calendar.day.\(today)"].isHittable,
            "Something is covering the grid on an empty calendar"
        )

        // MARK: Paging

        let currentMonthTitle = app.buttons["calendar.monthPicker"].label
        tap(app.buttons["calendar.nextMonth"], in: app)
        let nextMonthFirst = Self.firstOfNextMonthISO()
        XCTAssertTrue(
            app.buttons["calendar.day.\(nextMonthFirst)"].waitForExistence(timeout: 10),
            "Tapping Next month did not page the grid to \(nextMonthFirst)"
        )
        XCTAssertNotEqual(
            app.buttons["calendar.monthPicker"].label, currentMonthTitle,
            "The grid paged but the header still names the old month"
        )

        // Back again by swipe, which is the artboard's own gesture for this.
        app.otherElements["calendar.grid"].swipeRight()
        XCTAssertTrue(
            app.buttons["calendar.day.\(today)"].waitForExistence(timeout: 10),
            "Swiping right did not page back to the current month"
        )

        // MARK: The month picker

        tap(app.buttons["calendar.monthPicker"], in: app)
        XCTAssertTrue(
            app.otherElements["calendar.monthPickerCard"].waitForExistence(timeout: 10)
                || app.staticTexts["Jump to month"].waitForExistence(timeout: 1),
            "Tapping the header did not open the month picker"
        )
        capture("02-month-picker")
        let december = "\(Self.currentYear())-12"
        tap(app.buttons["calendar.month.\(december)"], in: app)
        XCTAssertTrue(
            app.buttons["calendar.day.\(december)-01"].waitForExistence(timeout: 10),
            "The month picker did not jump to \(december)"
        )

        // MARK: An entry to select
        //
        // Written over the API because C1 has no way to write one. A flow entry washes the
        // cell; a body-signals entry adds a corner mark. Both land on today.

        let token = try apiToken(email: email)
        try logEvent(token: token, body: [
            "type": "cycle",
            "localDate": today,
            "loggedAt": "\(today)T07:10:00",
            "timeZone": TimeZone.current.identifier,
            "payload": ["flow": "light"]
        ])
        try logEvent(token: token, body: [
            "type": "bodySignals",
            "localDate": today,
            "loggedAt": "\(today)T08:30:00",
            "timeZone": TimeZone.current.identifier,
            "payload": ["energy": 2, "symptoms": []]
        ])

        // A cold launch, keeping the Keychain: the same path a returning user takes, and
        // the only way to make the calendar re-read the range it has already cached.
        relaunchKeepingTheKeychain(app)
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 25),
            "A relaunch with a stored session did not land on the calendar"
        )

        let todayCell = app.buttons["calendar.day.\(today)"]
        XCTAssertTrue(todayCell.waitForExistence(timeout: 20))
        // The cell says what is on it in words, not only in 6pt coloured shapes — which is
        // the accessibility half of "position and shape, never colour alone".
        XCTAssertTrue(
            todayCell.label.contains("Light flow logged"),
            "The cell does not announce the logged flow: \(todayCell.label)"
        )
        XCTAssertTrue(
            todayCell.label.contains("Body signals logged"),
            "The cell does not announce the logged body signals: \(todayCell.label)"
        )

        // MARK: Selecting it lists it

        tap(todayCell, in: app)
        XCTAssertTrue(
            app.staticTexts["calendar.day.count"].waitForExistence(timeout: 10),
            "Selecting a day showed no detail for it"
        )
        XCTAssertEqual(
            app.staticTexts["calendar.day.count"].label, "2 entries",
            "The day detail is not describing the day that was selected"
        )
        let cycleRow = entryRow(app, "Menstrual cycle")
        XCTAssertTrue(
            cycleRow.waitForExistence(timeout: 10),
            "The selected day does not list the cycle entry"
        )
        XCTAssertTrue(
            cycleRow.label.contains("Light flow"),
            "The cycle entry does not say what was logged: \(cycleRow.label)"
        )
        XCTAssertTrue(
            entryRow(app, "Body signals").exists,
            "The selected day does not list the body-signals entry"
        )

        capture("03-calendar-with-entries")
        // And the first-log card is gone, because there is now a first log.
        XCTAssertFalse(
            app.staticTexts["calendar.logPointer"].exists,
            "The first-log pointer stayed after an entry was logged"
        )
    }

    // MARK: - Screenshots

    /// Attaches what is on screen to the result bundle.
    ///
    /// `.deleteOnSuccess`, so a green CI run carries nothing — but a failed one carries the
    /// screen it failed on, which is the thing that is otherwise impossible to get back
    /// from a headless runner. `EVA_UITEST_KEEP_SCREENSHOTS=1` keeps them on a pass, which
    /// is how the calendar was read against the canvas.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime =
            ProcessInfo.processInfo.environment["EVA_UITEST_KEEP_SCREENSHOTS"] == "1"
            ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }

    // MARK: - Elements

    /// A day-detail row. Each row is one combined accessibility element, so it is found by
    /// identifier across element types rather than by guessing which one SwiftUI chose.
    private func entryRow(_ app: XCUIApplication, _ typeName: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "calendar.entry.\(typeName)")
            .firstMatch
    }

    // MARK: - Dates
    //
    // The test computes the same wall-clock day the app does. Both read the simulator's
    // zone, which is the host's.

    private static func todayISO() -> String {
        iso(Date())
    }

    private static func firstOfNextMonthISO() -> String {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        return iso(calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    private static func currentYear() -> Int {
        Calendar.current.component(.year, from: Date())
    }

    private static func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    // MARK: - Writing an entry the way another device would

    /// Signs in over HTTP and returns the bearer token.
    private func apiToken(
        email: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let body = try post(
            path: "/auth/signin",
            token: nil,
            json: ["email": email, "password": Self.password],
            file: file, line: line
        )
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = object["token"] as? String
        else {
            XCTFail("POST /auth/signin returned no token", file: file, line: line)
            throw XCTSkip("no token")
        }
        return token
    }

    private func logEvent(
        token: String,
        body: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        _ = try post(path: "/me/events", token: token, json: body, file: file, line: line)
    }

    /// A synchronous POST, in the shape `EvaUITestCase.activate(email:)` uses: the test has
    /// nothing to do until the write lands.
    @discardableResult
    private func post(
        path: String,
        token: String?,
        json: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.apiBaseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)

        let finished = expectation(description: "POST \(path)")
        var status = 0
        var data = Data()
        var transportError: String?
        URLSession.shared.dataTask(with: request) { body, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            data = body ?? Data()
            transportError = error?.localizedDescription
            finished.fulfill()
        }.resume()
        wait(for: [finished], timeout: 30)

        XCTAssertTrue(
            (200..<300).contains(status),
            // The body is the API's own error envelope — a code and a message, never an
            // entry's contents (GUARDRAILS 12).
            """
            POST \(path) answered \(status): \
            \(transportError ?? String(data: data, encoding: .utf8) ?? "no body")
            """,
            file: file, line: line
        )
        return data
    }

    /// Relaunches with the API override but **without** `EVA_UITEST_RESET`, so the stored
    /// session survives and `bootstrap()` signs the app back in.
    ///
    /// Local to this file for the reason `ProfileLogOutUITests` keeps its own copy: every
    /// other launch in the target wants the clean slate, and a shared helper that skips it
    /// is a trap.
    private func relaunchKeepingTheKeychain(_ app: XCUIApplication) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launch()
    }
}

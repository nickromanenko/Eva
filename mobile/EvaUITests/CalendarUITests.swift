import XCTest

/// Issue #159: **the calendar is one tab away, and it shows what was logged.**
///
/// It was the landing surface until #99 built the Dashboard and Home took the first tab
/// back; the tap that gets here is now part of the flow rather than absent from it.
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
/// **This suite deletes its own account**, which is not what the other four do — see
/// `tearDown`. It is the only one that writes health data, and the cleanup sweep does not
/// reach a user's `events/` subcollection.
final class CalendarUITests: EvaUITestCase {

    // MARK: - Cleaning up the health data this test creates

    /// The account this test made, and its bearer token, kept so `tearDown` can destroy
    /// both. `nil` until `apiToken(email:)` has succeeded — a run that failed before then
    /// created no entries either.
    private var createdAccountEmail: String?
    private var createdAccountToken: String?

    /// Deletes the account, **and with it the events this test wrote.**
    ///
    /// This suite is the first thing in the repo to `POST /me/events` against the real
    /// Firebase project, and `scripts/e2e-cleanup.ts` deletes `users/{uid}` but not its
    /// `events/` subcollection — Firestore does not cascade. Left alone, every
    /// `verify-mobile.sh` run would orphan health-data documents permanently
    /// (GUARDRAILS 12 and 16).
    ///
    /// `DELETE /me` rather than `DELETE /me/events/{id}` per entry, for two reasons: the
    /// per-entry route is a **soft** delete, so the document and its payload stay exactly
    /// where they are; and `DELETE /me` runs `deleteAllUserEvents`, which hard-deletes the
    /// whole subcollection (`api/src/events.ts`), so it also sweeps anything an earlier
    /// failed run of this test left behind on the same account.
    ///
    /// It runs in `tearDown`, not at the end of the test body, so a failure half-way through
    /// still cleans up — `continueAfterFailure` is false, so the body stops where it fails.
    /// It asserts, because a silent failure here is the orphaning it exists to prevent.
    ///
    /// The body runs on the main actor — see `CalendarLoggingUITests.tearDown()` for why
    /// this is a checked `assumeIsolated` rather than a `@MainActor` annotation on the
    /// override, which Swift rejects.
    override func tearDown() {
        MainActor.assumeIsolated {
            defer {
                createdAccountEmail = nil
                createdAccountToken = nil
                super.tearDown()
            }
            guard let token = createdAccountToken else { return }

            var request = URLRequest(url: URL(string: "\(Self.apiBaseURL)/me")!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            // A semaphore rather than an `XCTestExpectation`: expectations in `tearDown` are
            // fragile, and this has nothing to do while it waits.
            let finished = DispatchSemaphore(value: 0)
            var status = 0
            var body: String?
            URLSession.shared.dataTask(with: request) { data, response, error in
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                body = error?.localizedDescription ?? data.flatMap { String(data: $0, encoding: .utf8) }
                finished.signal()
            }.resume()
            let arrived = finished.wait(timeout: .now() + 30) == .success

            XCTAssertTrue(arrived, "DELETE /me never answered; this run's logged entries are orphaned")
            XCTAssertEqual(
                status, 200,
                """
                DELETE /me answered \(status) for \(createdAccountEmail ?? "?"): \(body ?? "no body").
                The entries this test logged are still in Firestore, and the cleanup sweep does
                not reach a user's events subcollection.
                """
            )
        }
    }

    func testTheCalendarLandsPagesAndShowsWhatWasLogged() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: An account, and the landing surface

        signUpAndActivate(app, email: email)

        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 15),
            "Entering the app did not reach the tab bar"
        )
        XCTAssertTrue(app.buttons["tab.home"].exists, "The tab bar has no Home tab")
        XCTAssertTrue(app.buttons["tab.profile"].exists, "The tab bar has no Profile tab")

        // **Home is the landing tab since #99.** C1 landed here because the Dashboard was
        // unbuilt and a placeholder in front of the one real screen was worse than the
        // canvas' own order; D4 built it, so the calendar is now one tap away. What this
        // suite is about — the grid, the paging, the marks — is unchanged.
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 15),
            "The Calendar tab does not show the month grid"
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
        // The FAB is drawn and **live** since C2 (#160) wired its picker. It was asserted
        // as disabled in C1 so that turning it on had to come past a failing test, which
        // is what happened; the assertion is inverted rather than deleted, so the pointer
        // never again points at something inert. What it opens is covered by
        // `CalendarLoggingUITests`.
        XCTAssertTrue(app.buttons["calendar.log"].exists, "The empty state has no Log button to point at")
        XCTAssertTrue(
            app.buttons["calendar.log"].isEnabled,
            "The log button is disabled — the empty state is pointing at a control that "
                + "does nothing"
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
        // Never the month already on screen. `CalendarModel.show(_:)` returns early when the
        // month has not changed, so picking December would have passed every December
        // without the picker navigating anywhere.
        let beforeJump = app.buttons["calendar.monthPicker"].label
        let targetMonth = Self.currentMonthNumber() == 12 ? 6 : 12
        let target = String(format: "%04d-%02d", Self.currentYear(), targetMonth)
        tap(app.buttons["calendar.month.\(target)"], in: app)
        XCTAssertTrue(
            app.buttons["calendar.day.\(target)-01"].waitForExistence(timeout: 10),
            "The month picker did not jump to \(target)"
        )
        XCTAssertNotEqual(
            app.buttons["calendar.monthPicker"].label, beforeJump,
            "The month picker put a day on screen but the header still names the old month"
        )

        // MARK: An entry to select
        //
        // Written over the API because C1 has no way to write one. A flow entry washes the
        // cell; a body-signals entry adds a corner mark. Both land on today.

        let token = try apiToken(email: email)
        let cycleID = try logEvent(token: token, body: [
            "type": "cycle",
            "localDate": today,
            "loggedAt": "\(today)T07:10:00",
            "timeZone": TimeZone.current.identifier,
            "payload": ["flow": "light"]
        ])
        let bodySignalsID = try logEvent(token: token, body: [
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
            app.buttons["tab.calendar"].waitForExistence(timeout: 25),
            "A relaunch with a stored session did not reach the tab bar"
        )
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 25),
            "A relaunch with a stored session did not reach the calendar"
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
        let cycleRow = entryRow(app, id: cycleID)
        XCTAssertTrue(
            cycleRow.waitForExistence(timeout: 10),
            "The selected day does not list the cycle entry \(cycleID)"
        )
        XCTAssertTrue(
            cycleRow.label.contains("Light flow"),
            "The cycle entry does not say what was logged: \(cycleRow.label)"
        )
        XCTAssertTrue(
            entryRow(app, id: bodySignalsID).exists,
            "The selected day does not list the body-signals entry \(bodySignalsID)"
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

    /// A day-detail row, by the entry's own id.
    ///
    /// Each row is one combined accessibility element, so it is found by identifier across
    /// element types rather than by guessing which one SwiftUI chose. The id rather than the
    /// type name, because the type name is display copy: two sport entries on one day would
    /// collide, and localising the day detail would break this file.
    private func entryRow(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "calendar.entry.\(id)")
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

    private static func currentMonthNumber() -> Int {
        Calendar.current.component(.month, from: Date())
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
        // Armed before a single entry is written, so `tearDown` can always reach what this
        // test is about to create.
        createdAccountEmail = email
        createdAccountToken = token
        return token
    }

    /// Writes one entry and returns the id the API stored it under.
    ///
    /// The id is what the day detail addresses its rows by, so the test navigates to the
    /// exact entry it created rather than to a row named after a piece of display copy.
    @discardableResult
    private func logEvent(
        token: String,
        body: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let response = try post(path: "/me/events", token: token, json: body, file: file, line: line)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let event = object["event"] as? [String: Any],
              let id = event["id"] as? String
        else {
            XCTFail("POST /me/events returned no event id", file: file, line: line)
            throw XCTSkip("no event id")
        }
        return id
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

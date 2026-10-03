import XCTest

/// Issue #78: **logging works offline, and what was logged reaches the server exactly once.**
///
/// ARCHITECTURE §8 end to end, against the real API the harness started. "Offline" here is
/// the real thing, not a stub: the app is relaunched with `EVA_API_BASE_URL` at a port
/// nothing listens on, so every request fails in `URLSession` the way a plane's does. The
/// app has no other way to be offline mid-session, so each test relaunches the same install
/// **without** `EVA_UITEST_RESET` — the Keychain and the store survive, as they do for her —
/// and the way into the app from the retry screen is the canvas' **Continue offline**.
///
/// The server's side is read over HTTP with the account's own credentials: "exactly once"
/// is a claim about Firestore, and only the API can answer it.
///
/// Every account is deleted in `tearDown` — `DELETE /me` hard-deletes the events
/// subcollection, which the e2e sweep does not reach (GUARDRAILS 12, 16).
final class OfflineSyncUITests: EvaUITestCase {

    /// Port 9 (discard): nothing listens on it, so a connection is refused at once rather
    /// than timing out — the same dead host `OfflineLaunchUITests` uses.
    private static let deadAPI = "http://localhost:9"

    private var createdAccountEmail: String?
    /// The token `serverEvents` reads with, signed in once per test.
    private var serverToken: String?

    override func tearDown() {
        MainActor.assumeIsolated {
            defer {
                createdAccountEmail = nil
                serverToken = nil
                super.tearDown()
            }
            guard let email = createdAccountEmail else { return }
            guard let token = serverToken ?? bearerToken(email: email) else {
                XCTFail("Could not sign in to clean up \(email); its entries are orphaned")
                return
            }
            var request = URLRequest(url: URL(string: "\(Self.apiBaseURL)/me")!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (status, body) = send(request)
            XCTAssertEqual(status, 200, "DELETE /me answered \(status) for \(email): \(body ?? "no body")")
        }
    }

    // MARK: - The tests

    /// Acceptance criterion 2: logged with the API unreachable, visible in the calendar at
    /// once, and on the server exactly once after reconnecting.
    func testAnEntryLoggedOfflineLandsOnTheServerOnce() throws {
        let app = launch()
        let email = Self.freshEmail()
        createdAccountEmail = email
        signUpAndActivate(app, email: email)
        warmCalendar(app)

        // MARK: Offline: the API is unreachable
        goOffline(app)
        let activity = logSport(app)

        let row = entryRow(app, "Sport")
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "An entry logged with the API unreachable is not on the calendar"
        )
        XCTAssertTrue(
            row.label.localizedCaseInsensitiveContains(activity),
            "The offline entry does not say what was logged: \(row.label)"
        )
        // No "server has 0" check here: the app is pointed at a dead port, so it could not
        // fail. The claim that matters is the one after reconnecting — exactly one.

        // MARK: Back online: the queue drains
        relaunch(app, api: Self.apiBaseURL)
        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 25),
            "The relaunch with the API back did not reach the app"
        )
        let landed = waitForServerEvents(email: email, count: 1)
        XCTAssertEqual(landed.count, 1, "The queued entry did not reach the server once: \(landed)")
        // …and stays once: nothing still queued sends it again.
        sleep(4)
        let settled = serverEvents(email: email)
        XCTAssertEqual(settled.count, 1, "The entry reached the server more than once: \(settled)")
        XCTAssertEqual(settled.first?["type"] as? String, "sport")
        XCTAssertNotNil(settled.first?["idempotencyKey"] as? String,
                        "The entry was created without the device's idempotencyKey")

        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(entryRow(app, "Sport").waitForExistence(timeout: 15))
        XCTAssertEqual(
            app.staticTexts["calendar.day.count"].label, "1 entry",
            "The synced entry is drawn twice — once from the store, once from the server"
        )
    }

    /// Acceptance criterion 3: the same queued entry sent twice is one server document.
    ///
    /// `EVA_SYNC_DROP_ACKS=1` makes the app throw away the server's answer to every send, as
    /// a connection that drops after the write would: the create lands, the device never
    /// hears so, and the entry stays queued and is sent again — on every backoff, and once
    /// more after the relaunch that finally keeps the answer.
    func testReplayingAQueuedEntryTwiceProducesOneServerDocument() throws {
        let app = launch()
        let email = Self.freshEmail()
        createdAccountEmail = email
        signUpAndActivate(app, email: email)
        warmCalendar(app)

        // MARK: Every acknowledgement lost
        relaunch(app, api: Self.apiBaseURL, environment: ["EVA_SYNC_DROP_ACKS": "1"])
        XCTAssertTrue(app.buttons["tab.calendar"].waitForExistence(timeout: 25))
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(app.otherElements["calendar.grid"].waitForExistence(timeout: 20))
        logSport(app)
        XCTAssertTrue(entryRow(app, "Sport").waitForExistence(timeout: 10))

        // The first send reached the server — which is what makes the next one a replay.
        let first = waitForServerEvents(email: email, count: 1)
        XCTAssertEqual(first.count, 1, "The first send never landed: \(first)")
        // The backoff re-sends at 1 s and 2 s; each is the same entry, under the same key.
        sleep(5)
        XCTAssertEqual(serverEvents(email: email).count, 1, "A replayed create wrote a second document")

        // The device still holds it as unsent — Log out says so (§8.5) — so a replay is
        // still owed. Cancelled: the store must survive for the next launch.
        tap(app.buttons["tab.profile"], in: app)
        tap(app.buttons["profile.logout"], in: app)
        XCTAssertTrue(
            app.staticTexts["1 entry has not synced yet"].waitForExistence(timeout: 10),
            "Log out did not warn about the entry still in the queue"
        )
        // iOS 26 draws the dialog without a Cancel button on some sizes; tapping outside
        // it is the cancel either way.
        if app.buttons["Cancel"].firstMatch.exists {
            app.buttons["Cancel"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        XCTAssertFalse(
            app.textFields["signup.email"].waitForExistence(timeout: 3),
            "Cancelling the log-out confirmation logged out anyway"
        )

        // MARK: Answers kept again: the replay that finally lands
        relaunch(app, api: Self.apiBaseURL)
        XCTAssertTrue(app.buttons["tab.calendar"].waitForExistence(timeout: 25))
        sleep(5)
        let after = serverEvents(email: email)
        XCTAssertEqual(after.count, 1, "Replaying the queued entry produced \(after.count) documents")
        XCTAssertEqual(
            after.first?["id"] as? String, first.first?["id"] as? String,
            "The replay was answered with a different document than the first send wrote"
        )

        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(entryRow(app, "Sport").waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["calendar.day.count"].label, "1 entry")

        // Nothing is queued any more, so Log out goes straight through.
        tap(app.buttons["tab.profile"], in: app)
        tap(app.buttons["profile.logout"], in: app)
        XCTAssertFalse(
            app.staticTexts["1 entry has not synced yet"].waitForExistence(timeout: 3),
            "Log out still warned about an entry the server had acknowledged"
        )
    }

    /// Acceptance criterion 4 (GUARDRAILS 21): `EVA_UITEST_RESET` is "a fresh install", and a
    /// fresh install has no store. An entry queued before the reset is neither drawn after
    /// it nor ever sent.
    func testUITestResetClearsTheStore() throws {
        let app = launch()
        let email = Self.freshEmail()
        createdAccountEmail = email
        signUpAndActivate(app, email: email)
        warmCalendar(app)

        goOffline(app)
        logSport(app)
        XCTAssertTrue(entryRow(app, "Sport").waitForExistence(timeout: 10))

        // A relaunch *with* the reset, against the live API.
        app.terminate()
        app.launchEnvironment["EVA_UITEST_RESET"] = "1"
        app.launchEnvironment["EVA_API_BASE_URL"] = Self.apiBaseURL
        app.launch()
        signIn(app, email: email, password: Self.password)
        XCTAssertTrue(app.buttons["tab.calendar"].waitForExistence(timeout: 25))
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(app.otherElements["calendar.grid"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "calendar.empty").firstMatch
                .waitForExistence(timeout: 20),
            "The calendar is not empty after EVA_UITEST_RESET — the store survived the reset"
        )
        XCTAssertFalse(entryRow(app, "Sport").exists, "An entry from before the reset is still drawn")
        sleep(3)
        XCTAssertEqual(serverEvents(email: email).count, 0, "A queued entry from before the reset was sent")
    }

    // MARK: - Steps

    /// Opens the calendar once while online, so the catalogues are on the device before
    /// the API goes away — the sport sheet cannot offer an activity it has never seen.
    private func warmCalendar(_ app: XCUIApplication) {
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(app.otherElements["calendar.grid"].waitForExistence(timeout: 20))
        openPicker(app)
        tap(app.buttons["log.type.sport"], in: app)
        XCTAssertTrue(
            firstChip(in: "log.activities", app).waitForExistence(timeout: 15),
            "The activity catalogue never loaded online"
        )
        tapInSheet(app.buttons["log.close"], in: app)
    }

    /// Relaunches against a dead API and takes **Continue offline**.
    private func goOffline(_ app: XCUIApplication) {
        relaunch(app, api: Self.deadAPI)
        XCTAssertTrue(
            app.staticTexts["unreachable.title"].waitForExistence(timeout: 20),
            "A launch against a dead API did not reach the retry screen"
        )
        tap(app.buttons["secondary.Continue offline"], in: app)
        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 10),
            "Continue offline did not reach the app"
        )
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(app.otherElements["calendar.grid"].waitForExistence(timeout: 20))
    }

    /// Logs one workout on the selected day (today) and returns the activity's label.
    @discardableResult
    private func logSport(_ app: XCUIApplication) -> String {
        openPicker(app)
        tap(app.buttons["log.type.sport"], in: app)
        let activity = firstChip(in: "log.activities", app)
        XCTAssertTrue(
            activity.waitForExistence(timeout: 10),
            "The sport sheet drew no activities — the cached catalogue did not reach it"
        )
        let label = activity.label
        tapInSheet(activity, in: app)
        tapInSheet(app.buttons["log.intensity.medium"], in: app)
        tapInSheet(app.buttons["primary.Save"], in: app)
        return label
    }

    /// Opens the log picker with one tap — no retry. A Log button that does not answer
    /// its first tap is a failure here, not something to tap past (#372).
    private func openPicker(_ app: XCUIApplication) {
        let button = app.buttons["calendar.log"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "The calendar has no Log button")
        tap(button, in: app)
        XCTAssertTrue(
            app.staticTexts["log.targetDay"].waitForExistence(timeout: 10),
            "Tapping Log did not open the picker"
        )
    }

    /// Relaunches the same install with `EVA_UITEST_RESET` **removed**, so the Keychain and
    /// the store survive — the launches this suite is about. Local, as in the other suites
    /// that need one: every other test wants the clean slate.
    private func relaunch(
        _ app: XCUIApplication,
        api apiBaseURL: String,
        environment: [String: String] = [:]
    ) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launchEnvironment.removeValue(forKey: "EVA_SYNC_DROP_ACKS")
        app.launchEnvironment["EVA_API_BASE_URL"] = apiBaseURL
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
    }

    // MARK: - Elements

    private func entryRow(_ app: XCUIApplication, _ typeName: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "calendar.entry.", typeName
            ))
            .firstMatch
    }

    private func firstChip(in field: String, _ app: XCUIApplication) -> XCUIElement {
        let container = app.descendants(matching: .any).matching(identifier: field).firstMatch
        _ = container.waitForExistence(timeout: 10)
        return container.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chip.'"))
            .element(boundBy: 0)
    }

    /// Taps inside the log sheet, scrolling the sheet rather than the calendar behind it.
    private func tapInSheet(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing element in the log sheet: \(element)")
        let sheet = app.descendants(matching: .any).matching(identifier: "log.sheet").firstMatch
        var swipes = 0
        while !element.isHittable && swipes < 6 {
            if sheet.exists { sheet.swipeUp() } else { app.swipeUp() }
            swipes += 1
        }
        element.tap()
    }

    // MARK: - The server's side

    /// The account's entries for the window around today, straight from the API.
    private func serverEvents(email: String) -> [[String: Any]] {
        // One sign-in per account, not one per poll: `/auth/signin` is throttled, and a
        // 429 here would read as the app's failure.
        if serverToken == nil { serverToken = bearerToken(email: email) }
        guard let token = serverToken else {
            XCTFail("Could not sign in over HTTP to read \(email)'s entries")
            return []
        }
        let calendar = Calendar.current
        let from = Self.iso(calendar.date(byAdding: .day, value: -3, to: Date())!)
        let to = Self.iso(calendar.date(byAdding: .day, value: 3, to: Date())!)
        var request = URLRequest(url: URL(string: "\(Self.apiBaseURL)/me/events?from=\(from)&to=\(to)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (status, body) = send(request)
        guard status == 200, let data = body?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]]
        else {
            XCTFail("GET /me/events answered \(status): \(body ?? "no body")")
            return []
        }
        return events
    }

    /// Polls until the server holds `count` entries, or 30 s pass.
    private func waitForServerEvents(email: String, count: Int) -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(30)
        var events = serverEvents(email: email)
        while events.count < count && Date() < deadline {
            sleep(1)
            events = serverEvents(email: email)
        }
        return events
    }

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

    private static func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

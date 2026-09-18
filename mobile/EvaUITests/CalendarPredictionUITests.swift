import XCTest

/// Issue #206: **a prediction is never drawn like a fact, and the grid says so in words.**
///
/// The epic's Risks put it plainly — *"a prediction drawn like a fact is the failure mode of
/// this whole feature, and it is a visual failure that no API test can catch"*. Half of that
/// is the drawing, which `CalendarPredictionRenderTests` measures in luminance so the
/// distinction survives without hue. The other half is **which days got it**, and no pixel
/// test can check that: a grid that dashed the wrong week would render perfectly.
///
/// So this suite reads the cells' own accessibility labels. The artboard emits
/// `'Predicted period'` and `'Predicted fertile window'` per cell; the app emits the same
/// strings, and an assertion on them is the colour-blind rule made checkable rather than
/// asserted — every claim below would hold for a reader who cannot separate the pink cell
/// from the pistachio one.
///
/// ## Why the prediction is seeded
///
/// `GET /me/cycle/predictions` exists (#205) and **answers 503 in every environment there
/// is**: A25–A27's constants are unset until #26 signs them off with sources, and
/// `CycleRulesUnsetError` is a refusal, not a bug. So there is no account, anywhere, that
/// this test could log its way into a prediction on. `EVA_CYCLE_PREDICTION` hands the
/// calendar one response body — see `EvaCyclePredictionLaunch` for why it is a body rather
/// than a named fixture — and the **entries are real** throughout, written over the API the
/// way `CalendarUITests` writes them, because a predicted cell next to a logged one is the
/// whole thing under test.
///
/// One account, walked through six states by relaunching, for the reason `HomeUITests`
/// gives: a case per state would be an account per state.
///
/// **This suite deletes its own account**, like `CalendarUITests` and for the same reason —
/// it writes health data, and `scripts/e2e-cleanup.ts` does not reach a user's `events/`
/// subcollection.
final class CalendarPredictionUITests: EvaUITestCase {

    private var createdAccountEmail: String?
    private var createdAccountToken: String?

    // MARK: - The days this test predicts

    /// A day of the **current** month, as `YYYY-MM-DD`.
    ///
    /// Fixed days of the month rather than offsets from today, and that is about what
    /// XCUITest can reach rather than about dates. The grid draws the surrounding month's
    /// days as context and they are `accessibilityHidden` and not buttons (the artboard's
    /// `onClick:()=>{}`) — so "today + 6" is unfindable for the last week of every month,
    /// and this suite would pass for three weeks and fail for one. Every day named below is
    /// ≤ 28, so it exists in every month and is always a cell of the month on screen.
    ///
    /// The arithmetic is the **test's**, which is the point: #206's constraint is that the
    /// app derives no date, so composing a response body is work that belongs out here,
    /// exactly as it belongs to `cycle.ts` in production.
    private static func dayOfThisMonth(_ day: Int) -> String {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d-%02d", now.year!, now.month!, day)
    }

    /// A three-day fertile window and a **single** predicted period day after it — one day,
    /// because `cycle.ts` gives a next-period start and deliberately no period length.
    private static var fertileDays: [String] { [20, 21, 22].map(dayOfThisMonth) }
    private static var predictedPeriodDay: String { dayOfThisMonth(25) }
    /// The days either side of the predicted start, which must stay untouched.
    private static var periodNeighbours: [String] { [24, 26, 27].map(dayOfThisMonth) }

    /// The day this test logs a real period on: the 1st of this month, which is the only
    /// day that is both inside the month on screen and never in the future — logging beyond
    /// today is refused by the date policy (C2), and an adjacent month's cell is not a
    /// button.
    private static var loggedDay: String { dayOfThisMonth(1) }

    private static func body(
        confidence: String?,
        withheld: String?,
        drawsDays: Bool
    ) -> String {
        let fertile = drawsDays ? fertileDays.map { "\"\($0)\"" }.joined(separator: ",") : ""
        let period = drawsDays ? "\"\(predictedPeriodDay)\"" : ""
        // A range wide enough that every month the grid can reach is inside it, so the
        // seeded source is asked once rather than once per page. The echo is not under test
        // — `CalendarPredictionTests` covers clipping and caching against a source that
        // clips the way the route does.
        let year = Calendar.current.component(.year, from: Date())
        return """
        {"from":"\(year - 1)-01-01","to":"\(year + 1)-12-31",
         "predictedPeriod":[\(period)],"fertileWindow":[\(fertile)],"peak":[],
         "confidence":\(confidence.map { "\"\($0)\"" } ?? "null"),
         "withheld":\(withheld.map { "\"\($0)\"" } ?? "null")}
        """
    }

    func testAPredictionIsDrawnAsAPredictionAndNeverAsAFact() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: An account with one logged period day, so there is a fact to compare against

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

        let loggedDay = Self.loggedDay
        let token = try apiToken(email: email)
        try logEvent(token: token, body: [
            "type": "cycle",
            "localDate": loggedDay,
            "loggedAt": "\(loggedDay)T07:10:00",
            "timeZone": TimeZone.current.identifier,
            "payload": ["flow": "medium"]
        ])

        // MARK: A prediction, at the narrow band

        relaunch(app, prediction: Self.body(confidence: "narrow", withheld: nil, drawsDays: true))
        openCalendar(app)

        // The logged day says "logged" and does **not** say "Predicted". This is the
        // sentence the whole feature turns on: an estimate must never be announced the way
        // a fact is.
        let logged = app.buttons["calendar.day.\(loggedDay)"]
        XCTAssertTrue(logged.waitForExistence(timeout: 20), "No cell for the logged day")
        XCTAssertTrue(
            logged.label.contains("Medium flow logged"),
            "The logged day does not announce what was logged: \(logged.label)"
        )
        XCTAssertFalse(
            logged.label.contains("Predicted"),
            "A logged day is being announced as a prediction: \(logged.label)"
        )

        // …and every predicted day says "Predicted" and does **not** say "logged".
        for day in Self.fertileDays {
            let cell = app.buttons["calendar.day.\(day)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "No cell for \(day)")
            XCTAssertTrue(
                cell.label.contains("Predicted fertile window"),
                "\(day) is in the fertile window and does not say so: \(cell.label)"
            )
            XCTAssertFalse(
                cell.label.contains("logged"),
                "A predicted day is being announced as logged: \(cell.label)"
            )
        }

        let predicted = app.buttons["calendar.day.\(Self.predictedPeriodDay)"]
        XCTAssertTrue(predicted.waitForExistence(timeout: 10))
        XCTAssertTrue(
            predicted.label.contains("Predicted period"),
            "The predicted period day does not say so: \(predicted.label)"
        )

        // **The predicted period is one day.** `cycle.ts` produces a start and no length,
        // so the days on either side of it must be untouched — the cheapest way for this
        // feature to start inventing data is a client that paints "a period" around it.
        for day in Self.periodNeighbours {
            let neighbour = app.buttons["calendar.day.\(day)"]
            XCTAssertTrue(neighbour.waitForExistence(timeout: 10), "No cell for \(day)")
            XCTAssertFalse(
                neighbour.label.contains("Predicted"),
                """
                \(neighbour.label) — a day next to the predicted start is drawn as \
                predicted. The API returns one day, and the client extended it.
                """
            )
        }

        // The card above the grid states the estimate, and the legend states the notice.
        let summary = summaryCard(app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "No summary card over a prediction")
        let narrowCard = summary.label
        XCTAssertTrue(
            narrowCard.localizedCaseInsensitiveContains("estimate"),
            "The summary card does not call the prediction an estimate: \(narrowCard)"
        )
        assertTheLegendCarriesTheNotice(app)
        assertTheLegendListsTheArtboardsThreeMarks(app)
        capture("01-prediction-narrow")

        // MARK: The wide band reads differently, and never as a certainty

        relaunch(app, prediction: Self.body(confidence: "wide", withheld: nil, drawsDays: true))
        openCalendar(app)
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "No summary card at the wide band")
        let wideCard = summary.label
        XCTAssertNotEqual(
            wideCard, narrowCard,
            """
            A27's two confidence bands render the identical card. A prediction from a few \
            logged cycles is being shown with the same certainty as one from many.
            """
        )
        XCTAssertTrue(
            wideCard.localizedCaseInsensitiveContains("wide"),
            "The wide band does not say it is wide: \(wideCard)"
        )
        // The days are still drawn — a wide band is a hedged prediction, not a withheld one.
        XCTAssertTrue(
            app.buttons["calendar.day.\(Self.predictedPeriodDay)"].label.contains("Predicted period")
        )
        capture("02-prediction-wide")

        // MARK: Withheld — nothing is drawn, and each reason says its own thing

        var withheldCards: Set<String> = []
        for reason in ["no-flow-logged", "too-few-counted-cycles", "irregular-cycles"] {
            relaunch(app, prediction: Self.body(confidence: nil, withheld: reason, drawsDays: false))
            openCalendar(app)

            XCTAssertTrue(
                summary.waitForExistence(timeout: 20),
                "\(reason) drew an empty grid with no explanation on it"
            )
            withheldCards.insert(summary.label)

            // Nothing on the grid is announced as predicted. Every cell, not a sample:
            // "withheld draws nothing" is a claim about the whole month.
            for cell in app.buttons.allElementsBoundByIndex
            where cell.identifier.hasPrefix("calendar.day.") {
                XCTAssertFalse(
                    cell.label.contains("Predicted"),
                    "\(reason) still drew a prediction on \(cell.identifier): \(cell.label)"
                )
            }
            // …and the logged day is still there. Withholding an estimate never hides data.
            XCTAssertTrue(
                app.buttons["calendar.day.\(loggedDay)"].label.contains("Medium flow logged"),
                "Withholding the estimate also hid what she logged"
            )
            capture("03-withheld-\(reason)")
        }

        XCTAssertEqual(
            withheldCards.count, 3,
            """
            The three withheld reasons produced \(withheldCards.count) distinct cards. \
            "You have not logged a period", "there are not enough cycles yet" and "your \
            cycles vary too much" are three different facts about her data.
            """
        )

        // MARK: The route being unavailable is not the same as a prediction being withheld

        relaunch(app, prediction: "unavailable")
        openCalendar(app)
        XCTAssertTrue(
            app.buttons["calendar.day.\(loggedDay)"].waitForExistence(timeout: 20),
            "A 503 from the prediction route took the calendar down with it"
        )
        XCTAssertFalse(
            summary.exists,
            """
            A prediction request that never landed produced a card anyway. An unavailable \
            route says nothing about her cycles, and the card would be putting words in it.
            """
        )
        XCTAssertFalse(
            app.otherElements["calendar.loadError"].exists,
            "An unavailable prediction was reported as a failed load of her entries"
        )
        capture("04-prediction-unavailable")
    }

    // MARK: - Assertions used more than once

    /// The summary card, found across element types.
    ///
    /// `.accessibilityElement(children: .combine)` leaves SwiftUI free to publish the card
    /// as an `otherElement` or as a `staticText` depending on what it merged, and which one
    /// it picks is not a thing this suite is testing — `CalendarUITests` hedges the same way
    /// for `calendar.empty`.
    private func summaryCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "calendar.summary")
            .firstMatch
    }

    /// PRD §Phase 1: *"at the point of use and not only in the T&Cs"*, which A27 puts on
    /// the calendar legend.
    ///
    /// Found among **the legend's own elements**, by its words, rather than by an
    /// identifier of its own. `accessibilityIdentifier` on the legend card propagates to
    /// everything inside it and the outer one wins, so a line inside it cannot carry a
    /// distinct id — and asserting the sentence is inside the legend is what the
    /// requirement actually says. An identifier would only prove a hook exists.
    private func assertTheLegendCarriesTheNotice(_ app: XCUIApplication) {
        let legend = app.staticTexts.matching(identifier: "calendar.legend")
        XCTAssertTrue(
            legend.firstMatch.waitForExistence(timeout: 10),
            "The calendar legend is not on screen at all"
        )
        let lines = legend.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(
            lines.contains { $0.localizedCaseInsensitiveContains("not a contraceptive method") },
            """
            The legend does not state that the fertile window is not a contraceptive \
            method. It draws one, so PRD §Phase 1 requires the sentence beside it. \
            Legend lines: \(lines)
            """
        )
        // …and it names the thing it is about, so it reads as information about the window
        // rather than as a disclaimer attached to the screen.
        XCTAssertTrue(
            lines.contains {
                $0.localizedCaseInsensitiveContains("not a contraceptive method")
                    && $0.localizedCaseInsensitiveContains("fertile window")
            },
            "The notice does not name the fertile window: \(lines)"
        )
    }

    /// The three rows the artboard's legend lists and the grid could not draw.
    ///
    /// C1 listed none of them, #206 drew the predicted period and the fertile window, and
    /// #80 drew the third. The rule `CalendarLegend` has followed since C1 is that a row and
    /// its mark ship together — so this is the assertion that the legend has stopped
    /// describing anything the app cannot do, checked on the rendered card rather than on
    /// the enum, because the enum has listed labels that no `ForEach` reached before.
    private func assertTheLegendListsTheArtboardsThreeMarks(_ app: XCUIApplication) {
        let legend = app.staticTexts.matching(identifier: "calendar.legend")
        XCTAssertTrue(
            legend.firstMatch.waitForExistence(timeout: 10),
            "The calendar legend is not on screen at all"
        )
        let lines = legend.allElementsBoundByIndex.map(\.label)
        // Substrings the notice under the fertile-window row cannot also satisfy — it names
        // the window in prose, so a bare "fertile window" would pass with the row deleted.
        for row in ["Predicted period", "Fertile window (predicted", "Positive test"] {
            XCTAssertTrue(
                lines.contains { $0.localizedCaseInsensitiveContains(row) },
                "The legend has no row for \(row). Legend lines: \(lines)"
            )
        }
    }

    // MARK: - Navigation

    private func openCalendar(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["tab.calendar"].waitForExistence(timeout: 25),
            "A relaunch with a stored session did not reach the tab bar"
        )
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 25),
            "The Calendar tab does not show the month grid"
        )
    }

    /// Relaunches with a seeded prediction, **keeping the Keychain** so the session
    /// survives — see `OfflineLaunchUITests.relaunch` for that trick and its trap.
    private func relaunch(_ app: XCUIApplication, prediction: String) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launchEnvironment["EVA_CYCLE_PREDICTION"] = prediction
        app.launch()
    }

    // MARK: - Screenshots

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime =
            ProcessInfo.processInfo.environment["EVA_UITEST_KEEP_SCREENSHOTS"] == "1"
            ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }

    // MARK: - Writing an entry the way another device would

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
        createdAccountEmail = email
        createdAccountToken = token
        return token
    }

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
            // The API's own error envelope — a code and a message, never an entry's
            // contents (GUARDRAILS 12).
            """
            POST \(path) answered \(status): \
            \(transportError ?? String(data: data, encoding: .utf8) ?? "no body")
            """,
            file: file, line: line
        )
        return data
    }

    // MARK: - Cleaning up the health data this test creates

    /// Deletes the account, and with it the `cycle` entry this test wrote.
    ///
    /// `DELETE /me` rather than the per-entry route, which is a **soft** delete and would
    /// leave the payload where it is — see `CalendarUITests.tearDown` for the full argument
    /// and for why this is a checked `assumeIsolated` rather than an annotation.
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
                The entry this test logged is still in Firestore, and the cleanup sweep does
                not reach a user's events subcollection.
                """
            )
        }
    }
}

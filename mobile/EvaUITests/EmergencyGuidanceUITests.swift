import XCTest

/// Issue #87: the escalation card's guidance line is the country's own wording, and an
/// uncovered country gets the neutral fallback — **never another country's number**.
///
/// The card is a canvas fixture (`EVA_TODAY_CARD=home_flag`) but the guidance table is
/// not: the app fetches it from the harness API's seeded `refdata/` and resolves the
/// country given per launch through `EVA_EMERGENCY_COUNTRY` — the DEBUG hook
/// `EvaCountrySetting` reads instead of the picker, so a test can name an uncovered
/// region without one. A covered run therefore proves the whole chain (fetch → resolve
/// → substitute), and the uncovered run pins the safety property: Germany's card says
/// "contact your provider or a local urgent care service" and carries no 911.
///
/// One test walks both regions by relaunching the same install — the account and its
/// session survive a relaunch without `EVA_UITEST_RESET`, the same trick `HomeUITests`
/// uses, and the fixture card is identical across launches, so the only thing that can
/// move the guidance line is the country.
final class EmergencyGuidanceUITests: EvaUITestCase {

    /// Fragments of the seeded wording (`api/scripts/seed-refdata.ts`). If the seed's
    /// copy changes, these change with it — that is the point: the card shows what the
    /// table says, not what the test remembers.
    private static let coveredFragment = "call 911 now."
    private static let fallbackFragment =
        "Contact your provider or a local urgent care service for guidance."
    /// The fixture card's own line — what an uncovered card must *not* still say, since
    /// the fixture's wording ("your maternity provider or local urgent care service") is
    /// how the canvas drew it, not how the fallback reads.
    private static let fixtureFragment =
        "Contact your maternity provider or local urgent care service"

    func testTheFlagCardShowsTheCountrysWordingOrTheFallback() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail())

        // MARK: A covered country: the card carries the number the table holds

        relaunch(app, card: "home_flag", country: "US")
        let covered = app.otherElements["home.card"]
        XCTAssertTrue(covered.waitForExistence(timeout: 20), "The flag card never drew")
        XCTAssertTrue(
            covered.label.contains(Self.coveredFragment),
            "A US card did not show the US wording: \(covered.label)"
        )
        XCTAssertTrue(
            covered.label.contains("You logged reduced fetal movement today"),
            "The substitution rewrote more than the guidance line: \(covered.label)"
        )
        XCTAssertFalse(
            covered.label.contains(Self.fixtureFragment),
            "A US card still shows the fixture's neutral line — the table did not reach it"
        )

        // MARK: An uncovered country: the fallback, and never another country's number

        relaunch(app, card: "home_flag", country: "DE")
        let uncovered = app.otherElements["home.card"]
        XCTAssertTrue(uncovered.waitForExistence(timeout: 20), "The flag card never drew")
        XCTAssertTrue(
            uncovered.label.contains(Self.fallbackFragment),
            "An uncovered region did not resolve to the fallback: \(uncovered.label)"
        )
        XCTAssertFalse(
            uncovered.label.contains(Self.coveredFragment),
            "An uncovered region was shown the US emergency number"
        )
        XCTAssertFalse(
            uncovered.label.contains("999"), "An uncovered region was shown a number at all"
        )

        app.terminate()
    }

    /// The Settings screen: the same resolution, read from the other side — the canvas'
    /// "Medical and emergency information" row, its wording, the number, the country's
    /// support resources, and the line that says the choice stays on the device.
    func testTheEmergencyInformationScreenShowsTheResolvedCountry() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail())

        relaunch(app, card: nil, country: "US")
        tap(app.buttons["tab.profile"], in: app)

        let row = app.buttons["profile.emergency"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Profile has no emergency row")
        tap(row, in: app)

        let wording = app.staticTexts["emergency.wording"]
        XCTAssertTrue(wording.waitForExistence(timeout: 10), "The screen has no guidance line")
        XCTAssertTrue(
            wording.label.contains(Self.coveredFragment),
            "A US device's screen does not show the US wording: \(wording.label)"
        )

        let number = app.staticTexts["emergency.number"]
        XCTAssertTrue(number.waitForExistence(timeout: 5), "A covered screen shows no number")
        XCTAssertTrue(
            number.label.contains("911"), "The number is not the country's: \(number.label)"
        )

        // One support row of the country's list — the seeded US pair, by its identifier
        // prefix rather than a whole label, so a resource edit does not blind the test.
        let support = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'emergency.support.'")
        ).firstMatch
        XCTAssertTrue(support.exists, "A covered country lists no support resources")

        XCTAssertTrue(
            app.staticTexts["emergency.privacyNote"].exists,
            "The screen never says the country stays on the device"
        )
    }

    // MARK: - Helpers

    /// Relaunches the same install with the session **kept**, one canvas state, and the
    /// per-launch country the picker is not needed for. Removing `EVA_UITEST_RESET` is
    /// what keeps the session alive across the launch (see `HomeUITests.relaunch`).
    private func relaunch(_ app: XCUIApplication, card: String?, country: String) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        if let card {
            app.launchEnvironment["EVA_TODAY_CARD"] = card
        } else {
            app.launchEnvironment.removeValue(forKey: "EVA_TODAY_CARD")
        }
        app.launchEnvironment["EVA_EMERGENCY_COUNTRY"] = country
        app.launch()
    }
}

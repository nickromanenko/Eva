import XCTest

/// Issue #379: **only the tab on screen is in the accessibility tree.**
///
/// `EvaTabView` keeps all three tabs alive and stacks them, so an inactive tab is still a
/// view — at `opacity(0)`, behind the one on screen. Until #379 its content stayed in the
/// accessibility tree wherever SwiftUI hosted it in UIKit (a `ScrollView`, a
/// `NavigationStack`): VoiceOver could move onto rows nobody could see, and XCUITest could
/// judge a visible button covered by text from another tab and tap its corner (#372).
///
/// XCUITest reads the same tree VoiceOver walks, so "no element from an inactive tab is
/// in the tree" is asserted directly: on each tab, identifiers that exist **only** in the
/// other two must not resolve to any element. Each identifier is one that sits inside its
/// tab's scroll view or pushed screen — the places the old hiding did not reach — and each
/// is first shown to exist on its own tab, so an absence cannot pass because an identifier
/// was renamed.
///
/// One account, like the rest of the suite; it is left signed in for
/// `scripts/e2e-cleanup.ts` to sweep (GUARDRAILS §16). Nothing here writes health data.
final class TabAccessibilityUITests: EvaUITestCase {

    /// An identifier inside each tab's scroll content.
    private static let homeOnly = "home.greeting"
    private static let calendarOnly = "calendar.monthPicker"
    private static let profileOnly = "profile.email"
    /// A row on a screen Profile pushes — its own UIKit-hosted page.
    private static let pushedOnly = "units.option.metric"

    func testOnlyTheTabOnScreenIsInTheAccessibilityTree() throws {
        let app = launch()
        signUpAndActivate(app, email: Self.freshEmail())

        // MARK: Home

        XCTAssertTrue(
            element(Self.homeOnly, in: app).waitForExistence(timeout: 15),
            "Home's greeting is not in the tree on Home — the identifier has moved"
        )
        assertAbsent([Self.calendarOnly, Self.profileOnly], on: "Home", in: app)

        // MARK: Calendar

        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(
            element(Self.calendarOnly, in: app).waitForExistence(timeout: 15),
            "The calendar's month picker is not in the tree on Calendar — the identifier has moved"
        )
        assertAbsent([Self.homeOnly, Self.profileOnly], on: "Calendar", in: app)

        // MARK: Profile, and a screen it pushes

        tap(app.buttons["tab.profile"], in: app)
        XCTAssertTrue(
            element(Self.profileOnly, in: app).waitForExistence(timeout: 15),
            "Profile's email is not in the tree on Profile — the identifier has moved"
        )
        assertAbsent([Self.homeOnly, Self.calendarOnly], on: "Profile", in: app)

        let units = app.buttons["profile.units"]
        scrollIntoView(units, in: app)
        tap(units, in: app)
        XCTAssertTrue(
            element(Self.pushedOnly, in: app).waitForExistence(timeout: 10),
            "The Units row did not open its screen"
        )
        assertAbsent([Self.homeOnly, Self.calendarOnly], on: "Profile ▸ Units", in: app)

        // Leaving the pushed screen up and switching away is the hardest case: the screen
        // is a page of the Profile tab's own navigation stack, hosted apart from the tab.
        tap(app.buttons["tab.home"], in: app)
        XCTAssertTrue(
            element(Self.homeOnly, in: app).waitForExistence(timeout: 15),
            "Switching back to Home did not show Home"
        )
        assertAbsent(
            [Self.calendarOnly, Self.profileOnly, Self.pushedOnly],
            on: "Home, with Units pushed on Profile",
            in: app
        )

        // MARK: The tab bar's own buttons still work as one element each
        //
        // #378's attempt split buttons' labels into separate child elements, which moved
        // their hit points. The tab bar is the cheapest place to see that regress: each
        // item is one button whose label is its title.
        XCTAssertEqual(app.buttons["tab.calendar"].label, "Calendar")
        tap(app.buttons["tab.calendar"], in: app)
        XCTAssertTrue(
            app.buttons["calendar.log"].waitForExistence(timeout: 10),
            "Switching to Calendar did not show its Log button"
        )
        assertAbsent([Self.homeOnly, Self.profileOnly, Self.pushedOnly], on: "Calendar again", in: app)
    }

    /// Fails for each identifier that resolves to any element at all — on screen or off,
    /// of any type — while `tab` is showing.
    private func assertAbsent(
        _ identifiers: [String],
        on tab: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in identifiers {
            XCTAssertFalse(
                element(identifier, in: app).exists,
                "\(identifier) is in the accessibility tree while \(tab) is showing",
                file: file, line: line
            )
        }
    }
}

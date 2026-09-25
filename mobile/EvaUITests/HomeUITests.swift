import XCTest

/// Issue #99: **a signed-in user lands on Home, and the card she reads is the one the
/// store holds.**
///
/// ## One test, many launches
///
/// `CalendarUITests` and `OfflineLaunchUITests` are both one test for the same reason, and
/// it applies hardest here: every assertion below needs an activated account, and an
/// account costs a sign-up, a mailbox round trip, a sign-in and a questionnaire. #99 asks
/// for a case per canvas state; a case per state would be one account per state. So the
/// account is made once and the states are walked by **relaunching** the same install with
/// a different `EVA_TODAY_CARD`, and every assertion in that loop names the state it was
/// drawing so one failure out of eleven is still legible.
///
/// Relaunching without `EVA_UITEST_RESET` is what keeps the session — see
/// `OfflineLaunchUITests.relaunch`, which is where that trick and its trap are documented.
///
/// ## Why a seeded card at all
///
/// `GET /me/today` is D3 (#98) and does not exist, and the words it will serve come from a
/// `content/` collection #97 will not seed without a reviewer's name on the copy. Without
/// the hook there is no state to assert and no tone to regress against — which is exactly
/// what #99's Risks section says about `flag` and `quiet`, whose data path is D10's.
///
/// The account is left signed in but alive at the end, for `scripts/e2e-cleanup.ts` to
/// sweep by the `e2e+<uuid>@e2e.evaapp.dev` pattern (GUARDRAILS §16). Nothing here writes
/// health data — the cards are fixtures inside the app — so there is no `events/`
/// subcollection to clean up the way `CalendarUITests` has.
final class HomeUITests: EvaUITestCase {

    /// The canvas states this walks, and one sentence from each that could only have come
    /// from that card. Short enough to survive `staticTexts` matching, long enough to be
    /// unique across the fourteen.
    ///
    /// `home_d` … `home_edu` are #99's own list. `home_flag` and `home_loss` are on it
    /// because they carry the two tones nothing else can reach until D10 (#99, Risks).
    private static let states: [(state: String, line: String)] = [
        ("home_a", "Start with your first log"),
        ("home_b", "Eva is still learning your cycle"),
        ("home_c", "Your current phase cannot be estimated reliably"),
        ("home_d", "Many women notice higher energy around now"),
        ("home_e", "You logged low energy this morning after a poor night’s sleep"),
        ("home_f", "Your period is later than predicted"),
        ("home_g", "You logged low energy and a headache today"),
        ("home_h", "You’ve logged low mood for three consecutive days"),
        ("home_edu", "Why sleep can affect appetite more than willpower"),
        ("home_flag", "You logged reduced fetal movement today"),
        ("home_loss", "Pregnancy tracking has ended")
    ]

    /// The canvas' cycle `banners` set, which `EvaTodayCardFixtures` seeds under `home_d`.
    private static let cycleBanners: [(title: String, meta: String)] = [
        ("Why appetite can change before your period", "Nutrition · 4 min read"),
        ("How to adjust training when sleep is low", "Movement · 5 min read"),
        ("Iron, energy and the days after your period", "Nutrition · 6 min read")
    ]

    func testHomeIsTheLandingTabAndDrawsTheStoredCard() throws {
        let app = launch()
        let email = Self.freshEmail()

        // MARK: An account, and where it lands

        signUpAndActivate(app, email: email)

        XCTAssertTrue(
            app.buttons["tab.home"].waitForExistence(timeout: 15),
            "Entering the app did not reach the tab bar"
        )
        // #99's first acceptance criterion, and the reason #159's note about Calendar
        // being the landing tab is now spent: the Dashboard exists, so Home is first.
        XCTAssertTrue(
            app.staticTexts["home.greeting"].waitForExistence(timeout: 15),
            "Home is not the landing tab — its header is not on screen"
        )
        XCTAssertTrue(app.buttons["home.profile"].exists, "The Home header has no profile button")
        XCTAssertTrue(
            app.buttons["home.notifications"].exists,
            "The Home header has no notifications button"
        )
        XCTAssertFalse(
            app.buttons["home.notifications"].isEnabled,
            "The notifications button is live — it is inert until §Notifications is sliced"
        )

        // MARK: The live API's rail, end to end (#102)
        //
        // No fixture on this launch: this is `GET /me/today` itself, and whatever it answers
        // today, no rail can come of it. On the real project it currently answers **503**
        // (the cycle rules are unset, #26/#176), and once it answers 200 every seeded banner
        // still has an empty URL, so the server selects none and sends `banners: []`. So this
        // asserts only that the live path draws no rail; the decoded-empty case is
        // `TodayBannerTests` and the seeded `none` state below. Whichever state the day
        // resolved to, it has to have resolved before absence means anything.
        XCTAssertTrue(
            app.otherElements["home.card"].waitForExistence(timeout: 20)
                || app.otherElements["home.noCard"].exists
                || app.staticTexts["home.noCard"].exists
                || app.otherElements["home.loadError"].exists
                || app.staticTexts["home.loadError"].exists,
            "Home's first read never resolved"
        )
        XCTAssertFalse(
            app.otherElements["home.banners"].exists,
            "The live API served no openable banners, and Home still drew the rail"
        )

        // MARK: The cold start a real device meets first
        //
        // `content/` is unseeded (#97 refuses without a reviewer), so `GET /me/today` has
        // no words to fill a card with. That is a state with a screen, not a spinner and
        // not a blank.

        relaunch(app, card: "none")
        XCTAssertTrue(
            app.otherElements["home.noCard"].waitForExistence(timeout: 20)
                || app.staticTexts["home.noCard"].waitForExistence(timeout: 1),
            "A day with no card showed neither a card nor an explanation"
        )
        XCTAssertFalse(
            app.activityIndicators.firstMatch.exists,
            "A day with no card resolved to a spinner rather than to a screen"
        )
        // #102: no banners → the "Worth reading" section is absent, not an empty header.
        XCTAssertFalse(
            app.otherElements["home.banners"].exists,
            "A day with no banners drew the Worth reading section"
        )
        XCTAssertFalse(
            app.staticTexts["home.banners.title"].exists,
            "A day with no banners drew the Worth reading header"
        )

        // MARK: Every state the canvas draws

        for (state, line) in Self.states {
            relaunch(app, card: state)
            let card = app.otherElements["home.card"]
            XCTAssertTrue(card.waitForExistence(timeout: 20), "\(state) drew no card")
            // The card is **one** element and the whole sentence is its label — PRD
            // §Dashboard, Accessibility: "a single readable block, not a set of decorative
            // fragments". Reading the state's own line out of that label asserts both
            // halves at once. Every message names the state, since the eleven of them
            // share one test body.
            XCTAssertTrue(
                card.label.contains(line),
                "\(state)'s card does not read \"\(line)\": \(card.label)"
            )
            XCTAssertTrue(
                card.label.hasPrefix("Today."),
                "\(state)'s card is not announced as the canvas' aria string: \(card.label)"
            )
        }

        // MARK: The Worth reading rail (#102)
        //
        // `home_d` seeds the canvas' cycle set. The rail's words are the server's, so each
        // card is asserted by the title and meta the fixture carries, in display order.

        relaunch(app, card: "home_d")
        let rail = app.otherElements["home.banners"]
        XCTAssertTrue(rail.waitForExistence(timeout: 20), "home_d drew no Worth reading rail")
        XCTAssertTrue(
            app.staticTexts["home.banners.title"].exists,
            "The rail has no Worth reading header"
        )
        let learn = app.buttons["text.Learn"]
        XCTAssertTrue(learn.exists, "The rail's Learn link is not drawn")
        XCTAssertFalse(learn.isEnabled, "Learn is live — the Learn tab does not exist")
        XCTAssertTrue(
            learn.label.contains("Not available yet"),
            "The disabled Learn link does not say why: \(learn.label)"
        )

        var lastX = -CGFloat.infinity
        for (index, item) in Self.cycleBanners.enumerated() {
            let banner = app.buttons["home.banner.fixture_home_d_\(index + 1)"]
            // Off-screen cards are still in the tree; `exists`, not `isHittable`.
            XCTAssertTrue(banner.waitForExistence(timeout: 5), "Banner \(index + 1) is not drawn")
            // VoiceOver reads the title, then the meta (#102) — one element, one label.
            XCTAssertEqual(
                banner.label, "\(item.title), \(item.meta)",
                "Banner \(index + 1) does not read title then meta"
            )
            XCTAssertGreaterThanOrEqual(
                banner.frame.height, 44, "Banner \(index + 1) is under §1's 44pt target"
            )
            XCTAssertGreaterThan(
                banner.frame.minX, lastX, "Banner \(index + 1) is out of display order"
            )
            lastX = banner.frame.minX
        }

        // Tap opens the article in Safari, in the app; Done comes back to Home.
        let first = app.buttons["home.banner.fixture_home_d_1"]
        tap(first, in: app)
        let done = app.buttons["Done"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 15),
            "Tapping a banner did not open its article in SFSafariViewController"
        )
        XCTAssertFalse(
            rail.exists && rail.isHittable,
            "The article did not cover Home"
        )
        done.tap()
        XCTAssertTrue(
            rail.waitForExistence(timeout: 10) && app.otherElements["home.card"].exists,
            "Done did not return to Home"
        )

        // MARK: The actions — two that work, and the rest drawn and disabled

        relaunch(app, card: "home_a")
        let logNow = app.buttons["primary.Log now"]
        XCTAssertTrue(logNow.waitForExistence(timeout: 20), "home_a has no Log now action")
        XCTAssertTrue(logNow.isEnabled, "Log now is disabled — it reaches the calendar's picker")
        XCTAssertTrue(
            app.buttons["secondary.Open Calendar"].isEnabled,
            "Open Calendar is disabled — it reaches the Calendar tab"
        )

        relaunch(app, card: "home_c")
        // `secondary.`, not `primary.`: the artboard styles the first action as the
        // primary, and this one cannot be taken — see `TodayCardView`, which narrows that
        // rule to actions that work.
        let viewHistory = app.buttons["secondary.View cycle history"]
        XCTAssertTrue(
            viewHistory.waitForExistence(timeout: 20),
            "home_c's secondary action is not drawn — a disabled action is still drawn (#99)"
        )
        XCTAssertFalse(
            viewHistory.isEnabled,
            "View cycle history is live — its screen is D11 and does not exist"
        )
        XCTAssertTrue(
            viewHistory.label.contains("Not available yet"),
            "A disabled action does not say why: \(viewHistory.label)"
        )

        // MARK: Log now reaches the calendar's picker, and Open Calendar the tab

        relaunch(app, card: "home_a")
        tap(app.buttons["primary.Log now"], in: app)
        // The picker's own first row. Its `log.sheet` identifier is on a `ScrollView`, so
        // it resolves as `app.scrollViews` rather than `otherElements` — a row is the
        // unambiguous signal, and it is what `CalendarLoggingUITests` navigates by.
        XCTAssertTrue(
            app.buttons["log.type.cycle"].waitForExistence(timeout: 10),
            "Log now did not open the calendar's log picker"
        )

        relaunch(app, card: "home_a")
        tap(app.buttons["secondary.Open Calendar"], in: app)
        XCTAssertTrue(
            app.otherElements["calendar.grid"].waitForExistence(timeout: 10),
            "Open Calendar did not select the Calendar tab"
        )

        // MARK: A refresh with nothing new leaves the card alone
        //
        // PRD §Dashboard, Other requirements 3 and Edge cases 5. The seeded source answers
        // the identical card every time, which is what D3 promises for a day whose data has
        // not changed — so this is the real case rather than a simulation of one.

        relaunch(app, card: "home_d")
        let card = app.otherElements["home.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "home_d drew no card")
        let before = card.label
        pullToRefresh(app)
        XCTAssertEqual(
            card.label, before,
            "Pull-to-refresh rewrote the card. It updates on new data, not on refresh."
        )

        // MARK: Offline over a cached card
        //
        // `EVA_TODAY_REFRESH=offline` lands the first read and fails every one after it —
        // the only way to reach `home_off` from a test, since a card has to *be* cached
        // before it can be a cached card and a test cannot take the network away mid-launch.

        relaunch(app, card: "home_d", refresh: "offline")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The first read did not land a card")
        let cached = card.label
        pullToRefresh(app)

        // A `staticText`: the bar combines its dot and its sentence into one element, and a
        // combined element resolves as text rather than as a container.
        let bar = app.staticTexts["home.offline"]
        XCTAssertTrue(
            bar.waitForExistence(timeout: 10),
            "A refresh with no network showed no offline bar"
        )
        XCTAssertTrue(
            bar.label.hasPrefix("Offline · showing your cached briefing from "),
            "The offline bar carries no sync timestamp: \(bar.label)"
        )
        XCTAssertTrue(card.exists, "Going offline blanked the cached card")
        XCTAssertEqual(cached, card.label, "Going offline rewrote the cached card")
        XCTAssertFalse(
            app.activityIndicators.firstMatch.exists,
            "Going offline replaced the cached card with a spinner"
        )
    }

    // MARK: - Helpers

    /// Relaunches the same install with the Keychain **kept**, seeding one canvas state.
    ///
    /// Removing `EVA_UITEST_RESET` is what keeps the session alive across the launch;
    /// `OfflineLaunchUITests` documents why, and the trap is the same one — a relaunch that
    /// still carried it would wipe the token and land on onboarding.
    private func relaunch(_ app: XCUIApplication, card: String, refresh: String? = nil) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "EVA_UITEST_RESET")
        app.launchEnvironment["EVA_TODAY_CARD"] = card
        if let refresh {
            app.launchEnvironment["EVA_TODAY_REFRESH"] = refresh
        } else {
            app.launchEnvironment.removeValue(forKey: "EVA_TODAY_REFRESH")
        }
        app.launch()
    }

    /// Drags the Home column down far enough to trip `.refreshable`.
    ///
    /// The scroll view, not the application: `app.swipeDown()` starts its drag at the app's
    /// centre, which on this screen is the card rather than the scrolling column, and a
    /// drag that starts on a button does not always become a scroll.
    private func pullToRefresh(_ app: XCUIApplication) {
        // By identifier, not `firstMatch`: `EvaTabView` keeps all three screens alive, so
        // there are three scroll views in the hierarchy and the first one is not reliably
        // this screen's.
        let column = app.scrollViews["home.scroll"]
        XCTAssertTrue(column.waitForExistence(timeout: 10), "Home has no scrolling column")
        let start = column.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = column.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        // Slow, and held at the bottom. A flick is a scroll; `.refreshable` only engages
        // for a drag that crosses the threshold and stays there long enough to commit.
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
        // The refresh has to finish before the card's label is read back, or "unchanged"
        // would be asserted about a card the refresh had not reached yet.
        _ = app.otherElements["home.card"].waitForExistence(timeout: 5)
    }
}

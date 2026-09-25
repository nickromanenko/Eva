import Foundation
import Testing
@testable import Eva

/// Issue #100: **the shortcuts row is labelled from what `GET /me/today` says, and reads a
/// document that says nothing as the row at rest.**
///
/// Three claims, none about pixels. The *decoding* — three new top-level keys, which an older
/// API does not send and a day stored before #100 sends as `null`, and neither may fail the
/// card. The *labels* — the contract's rules, exhaustively across modes, because the first
/// shortcut is the one place the PRD makes a label contextual. And the *holding* — the facts
/// belong to the day's document, so they follow the card's rules in `HomeModel`.
@Suite("Issue #100 · the shortcuts row, as decoded, labelled and held")
@MainActor
struct TodayShortcutsTests {

    private func decode(_ json: String) throws -> EvaTodayResponse {
        try JSONDecoder().decode(EvaTodayResponse.self, from: Data(json.utf8))
    }

    private static let card = #""card":{"title":"Many women notice higher energy around now"}"#

    // MARK: - Decoding

    @Test("All three facts decode from the top level of the day's document")
    func theFactsDecode() throws {
        let response = try decode("""
        {"date":"2026-09-25",\(Self.card),"mode":"postpartum","periodOngoing":true,"nutritionSetUp":true}
        """)
        #expect(response.shortcuts == EvaTodayShortcuts(
            mode: .postpartum, periodOngoing: true, nutritionSetUp: true
        ))
        #expect(response.card != nil)
    }

    @Test("Every mode the API names decodes", arguments: EvaMode.allCases)
    func everyModeDecodes(mode: EvaMode) throws {
        let response = try decode(#"{"date":"2026-09-25",\#(Self.card),"mode":"\#(mode.rawValue)"}"#)
        #expect(response.shortcuts.mode == mode)
    }

    /// A day stored before #100: `mode` is `cycle`, the other two `null` — which the
    /// contract says means `false`.
    @Test("A day stored before #100 — null facts — reads as the row at rest")
    func nullFactsAreFalse() throws {
        let response = try decode("""
        {"date":"2026-09-25",\(Self.card),"mode":"cycle","periodOngoing":null,"nutritionSetUp":null}
        """)
        #expect(response.shortcuts == .resting)
        #expect(response.shortcuts.logLabel == "Log")
        #expect(response.shortcuts.mealsLabel == "Set up meals")
    }

    /// An API older than #100 sends none of the keys. The card must still draw.
    @Test("An API older than #100 — no keys at all — reads as the row at rest, card intact")
    func missingKeysAreTheRestingRow() throws {
        let response = try decode(#"{"date":"2026-09-25",\#(Self.card)}"#)
        #expect(response.shortcuts == .resting)
        #expect(response.card?.title == "Many women notice higher energy around now")
    }

    @Test("A wrong type or an unknown mode never fails the day's document")
    func malformedFactsAreTolerated() throws {
        let response = try decode("""
        {"date":"2026-09-25",\(Self.card),"mode":"lunar","periodOngoing":"yes","nutritionSetUp":1}
        """)
        #expect(response.shortcuts == .resting)
        #expect(response.card != nil)

        let numericMode = try decode(#"{"date":"2026-09-25",\#(Self.card),"mode":3}"#)
        #expect(numericMode.shortcuts.mode == .cycle)
    }

    // MARK: - The first label (PRD §Dashboard → Shortcuts 2)

    @Test(
        "Log feed in postpartum; Log period while her period runs; Log otherwise",
        arguments: EvaMode.allCases, [false, true]
    )
    func firstLabel(mode: EvaMode, periodOngoing: Bool) {
        let label = EvaTodayShortcuts(mode: mode, periodOngoing: periodOngoing).logLabel
        let expected = mode == .postpartum ? "Log feed" : (periodOngoing ? "Log period" : "Log")
        #expect(label == expected, "\(mode), periodOngoing \(periodOngoing): \(label)")
    }

    // MARK: - The meals shortcut (PRD §Dashboard → Shortcuts 3)

    @Test("Set up → Scan meal and no setup card; not set up → Set up meals and the card")
    func mealsShortcut() {
        let setUp = EvaTodayShortcuts(nutritionSetUp: true)
        #expect(setUp.mealsLabel == "Scan meal")
        #expect(!setUp.showsMealSetupCard)

        let notSetUp = EvaTodayShortcuts(nutritionSetUp: false)
        #expect(notSetUp.mealsLabel == "Set up meals")
        #expect(notSetUp.showsMealSetupCard)
    }

    // MARK: - Held with the card

    private static let zone = TimeZone(identifier: "Europe/Lisbon")!
    private static let day = EvaDay(year: 2026, month: 9, day: 25)

    private func model(_ source: RecordingTodayCardSource) -> HomeModel {
        HomeModel(source: source, timeZone: { Self.zone }, clock: { Date(timeIntervalSince1970: 0) })
    }

    private func response(
        _ shortcuts: EvaTodayShortcuts,
        card: EvaTodayCard? = .coldStartFixture
    ) -> EvaTodayResponse {
        EvaTodayResponse(date: Self.day, contentVersion: "v1", card: card, shortcuts: shortcuts)
    }

    /// `nil` until read, so the screen can keep the setup card off a cold start rather than
    /// flash it at someone whose meals are set up.
    @Test("Unknown until the first read; then the document's facts")
    func arrivesWithTheCard() async {
        let facts = EvaTodayShortcuts(mode: .cycle, periodOngoing: true, nutritionSetUp: true)
        let model = model(RecordingTodayCardSource(response: response(facts)))
        #expect(model.shortcuts == nil)

        await model.start()

        #expect(model.shortcuts == facts)
    }

    @Test("A failed refresh keeps the facts, as it keeps the card")
    func aFailedRefreshKeepsThem() async {
        let facts = EvaTodayShortcuts(mode: .postpartum, nutritionSetUp: true)
        let source = RecordingTodayCardSource(response: response(facts))
        let model = model(source)
        await model.start()

        source.failure = APIError.network
        await model.refresh()

        #expect(model.shortcuts == facts)
    }

    @Test("A day with no card still carries its facts")
    func aDayWithNoCardCarriesThem() async {
        let facts = EvaTodayShortcuts(periodOngoing: true)
        let model = model(RecordingTodayCardSource(response: response(facts, card: nil)))
        await model.start()
        #expect(model.state == .noCard)
        #expect(model.shortcuts == facts)
    }

    @Test("New facts on a refresh replace the old")
    func aRefreshWithNewFactsReplacesThem() async {
        let source = RecordingTodayCardSource(response: response(.resting))
        let model = model(source)
        await model.start()

        let later = EvaTodayShortcuts(nutritionSetUp: true)
        source.response = response(later)
        await model.refresh()

        #expect(model.shortcuts == later)
    }

    // MARK: - Routing

    /// The `Log` shortcut asks for today (#100); the Today card's actions keep asking for the
    /// selected day (#160), which is the default.
    @Test("The router carries which day a log request is for")
    func routerCarriesTheDay() {
        let router = EvaTabRouter()
        router.openCalendarLogPicker()
        #expect(router.selection == .calendar)
        #expect(router.calendarLogDay == .selected)
        #expect(router.calendarLogRequests == 1)

        router.show(.home)
        router.openCalendarLogPicker(on: .today)
        #expect(router.selection == .calendar)
        #expect(router.calendarLogDay == .today)
        #expect(router.calendarLogRequests == 2)
    }

    @Test("showToday pages the calendar back to today's month and selects today")
    func calendarShowsToday() async {
        let today = EvaDay(year: 2026, month: 8, day: 18)
        let model = CalendarModel(source: RecordingCalendarSource(), today: today)
        await model.start()
        await model.showPreviousMonth()
        await model.showPreviousMonth()
        #expect(model.visibleMonth == EvaMonth(year: 2026, month: 6))

        await model.showToday()

        #expect(model.visibleMonth == today.evaMonth)
        #expect(model.selectedDay == today)
    }

    // MARK: - Tone and framing (PRD §Dashboard, quoted in #100)

    /// "No comparison to other users, no scores for the person, no streaks." Every label the
    /// row can show, checked.
    @Test("No shortcut label carries a score, a percentage, a count or a streak")
    func noLabelScoresAnybody() {
        var labels: Set<String> = ["Calendar", "Eva Chat"]
        for mode in EvaMode.allCases {
            for period in [false, true] {
                for meals in [false, true] {
                    let facts = EvaTodayShortcuts(mode: mode, periodOngoing: period, nutritionSetUp: meals)
                    labels.insert(facts.logLabel)
                    labels.insert(facts.mealsLabel)
                }
            }
        }
        for label in labels {
            for forbidden in ["streak", "score", "%", "of ", "step"] {
                #expect(!label.lowercased().contains(forbidden), "\(label) contains \"\(forbidden)\"")
            }
        }
    }
}

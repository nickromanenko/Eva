import Foundation
import Testing
@testable import Eva

/// Issue #102: **the "Worth reading" rail is whatever the day's document carries, and a
/// rail that is missing or malformed never costs the card.**
///
/// Two halves. The decoding — `banners` is always present from a D7 server, but an older
/// API, a document stored before D7, or a broken item must still leave Home drawable. And
/// the model — the rail is part of the same stored document as the card, so it keeps the
/// card's rules: not rewritten by a refresh with nothing new, not emptied by a failed read.
///
/// **Decision, documented here and on `EvaTodayBanner`:** an item that is not a sound
/// banner (missing field, empty title, a URL that is not absolute `https://`) is *dropped*
/// and the rest of the rail kept, rather than rejecting the payload. `SFSafariViewController`
/// raises on any non-http(s) scheme, so the https check is a crash guard as well as the
/// contract.
@Suite("Issue #102 · the Worth reading rail, as decoded and as held")
@MainActor
struct TodayBannerTests {

    private func decode(_ json: String) throws -> EvaTodayResponse {
        try JSONDecoder().decode(EvaTodayResponse.self, from: Data(json.utf8))
    }

    private static let card = #"{"title":"Start with your first log"}"#

    // MARK: - Decoding

    @Test("Present: every item decodes, in the order the server sent")
    func presentDecodesInOrder() throws {
        let response = try decode("""
        {
          "date": "2026-09-25",
          "card": \(Self.card),
          "banners": [
            { "id": "b2", "title": "Why appetite can change before your period",
              "meta": "Nutrition · 4 min read", "url": "https://learn.example.com/appetite" },
            { "id": "b1", "title": "How to adjust training when sleep is low",
              "meta": "Movement · 5 min read", "url": "https://learn.example.com/sleep?x=1" }
          ]
        }
        """)

        #expect(response.banners.map(\.id) == ["b2", "b1"])
        let first = try #require(response.banners.first)
        #expect(first.title == "Why appetite can change before your period")
        #expect(first.meta == "Nutrition · 4 min read")
        #expect(first.url == URL(string: "https://learn.example.com/appetite"))
        // The card is untouched by the rail beside it.
        #expect(response.card?.title == "Start with your first log")
    }

    @Test("Empty: no rail, and the card still decodes")
    func emptyIsNoRail() throws {
        let response = try decode(#"{"date":"2026-09-25","card":\#(Self.card),"banners":[]}"#)
        #expect(response.banners.isEmpty)
        #expect(response.card != nil)
    }

    /// An API from before D7, or a cached document stored before it, has no key at all.
    @Test("Missing key, or null: no rail, and the card still decodes")
    func missingOrNullIsNoRail() throws {
        let missing = try decode(#"{"date":"2026-09-25","card":\#(Self.card)}"#)
        #expect(missing.banners.isEmpty)
        #expect(missing.card != nil)

        let null = try decode(#"{"date":"2026-09-25","card":\#(Self.card),"banners":null}"#)
        #expect(null.banners.isEmpty)
        #expect(null.card != nil)
    }

    @Test("Not an array: no rail, never a failed day")
    func wrongShapeIsNoRail() throws {
        let response = try decode(#"{"card":\#(Self.card),"banners":{"id":"b1"}}"#)
        #expect(response.banners.isEmpty)
        #expect(response.card != nil)
    }

    /// The decision: drop the bad item, keep the sound ones. Each of these is one reason
    /// an item is refused; the one sound item among them must survive all of them.
    @Test("A bad item is dropped and the rest of the rail kept")
    func badItemsAreDropped() throws {
        let response = try decode("""
        {
          "card": \(Self.card),
          "banners": [
            { "id": "empty-url", "title": "A", "meta": "M", "url": "" },
            { "id": "relative", "title": "A", "meta": "M", "url": "/learn/appetite" },
            { "id": "http", "title": "A", "meta": "M", "url": "http://learn.example.com/a" },
            { "id": "script", "title": "A", "meta": "M", "url": "javascript:alert(1)" },
            { "id": "scheme", "title": "A", "meta": "M", "url": "eva://open" },
            { "id": "no-host", "title": "A", "meta": "M", "url": "https:///path" },
            { "id": "no-title", "title": "", "meta": "M", "url": "https://learn.example.com/a" },
            { "id": "no-meta", "title": "A", "url": "https://learn.example.com/a" },
            { "title": "No id", "meta": "M", "url": "https://learn.example.com/a" },
            { "id": 7, "title": "A", "meta": "M", "url": "https://learn.example.com/a" },
            "not an object",
            { "id": "sound", "title": "Iron, energy and the days after your period",
              "meta": "Nutrition · 6 min read", "url": "HTTPS://learn.example.com/iron" }
          ]
        }
        """)

        #expect(response.banners.map(\.id) == ["sound"])
        #expect(response.card != nil)
    }

    @Test("A repeated id keeps its first occurrence")
    func duplicateIdsKeepTheFirst() throws {
        let response = try decode("""
        {
          "banners": [
            { "id": "b1", "title": "First", "meta": "M", "url": "https://learn.example.com/1" },
            { "id": "b1", "title": "Second", "meta": "M", "url": "https://learn.example.com/2" }
          ]
        }
        """)
        #expect(response.banners.map(\.title) == ["First"])
    }

    // MARK: - What VoiceOver reads

    @Test("VoiceOver reads the title, then the meta")
    func accessibilityLabelIsTitleThenMeta() throws {
        let banner = try #require(EvaTodayBanner(
            id: "b1",
            title: "Why appetite can change before your period",
            meta: "Nutrition · 4 min read",
            url: URL(string: "https://learn.example.com/appetite")!
        ))
        #expect(banner.accessibilityLabel
            == "Why appetite can change before your period, Nutrition · 4 min read")

        let bare = try #require(EvaTodayBanner(
            id: "b2", title: "A title", meta: "", url: URL(string: "https://example.com")!
        ))
        #expect(bare.accessibilityLabel == "A title")
    }

    // MARK: - The model: the rail keeps the card's rules

    private static let zone = TimeZone(identifier: "Europe/Lisbon")!
    private static let day = EvaDay(year: 2026, month: 9, day: 25)

    private static let rail: [EvaTodayBanner] = [
        EvaTodayBanner(
            id: "b1", title: "Why appetite can change before your period",
            meta: "Nutrition · 4 min read", url: URL(string: "https://learn.example.com/1")!
        ),
        EvaTodayBanner(
            id: "b2", title: "How to adjust training when sleep is low",
            meta: "Movement · 5 min read", url: URL(string: "https://learn.example.com/2")!
        )
    ].compactMap { $0 }

    private func response(
        card: EvaTodayCard? = .coldStartFixture,
        banners: [EvaTodayBanner] = rail,
        day: EvaDay = day
    ) -> EvaTodayResponse {
        EvaTodayResponse(date: day, contentVersion: "v1", card: card, banners: banners)
    }

    private func model(_ source: RecordingTodayCardSource) -> HomeModel {
        HomeModel(source: source, timeZone: { Self.zone }, clock: { Date(timeIntervalSince1970: 0) })
    }

    @Test("The rail arrives with the card")
    func railArrivesWithTheCard() async {
        let model = model(RecordingTodayCardSource(response: response()))
        #expect(model.banners.isEmpty)

        await model.start()

        #expect(model.banners == Self.rail)
    }

    @Test("A day with no banners has no rail")
    func noBannersIsNoRail() async {
        let model = model(RecordingTodayCardSource(response: response(banners: [])))
        await model.start()
        #expect(model.banners.isEmpty)
        #expect(model.card == .coldStartFixture)
    }

    @Test("A failed refresh leaves the rail on screen, as it leaves the card")
    func aFailedRefreshKeepsTheRail() async {
        let source = RecordingTodayCardSource(response: response())
        let model = model(source)
        await model.start()

        source.failure = APIError.network
        await model.refresh()

        #expect(model.banners == Self.rail)
        #expect(model.showsOfflineBar)
    }

    /// Same rule as the card's: a same-day response that has lost the card is not a reason
    /// to take anything off the screen.
    @Test("A same-day response without a card leaves the rail alone")
    func aCardlessSameDayResponseKeepsTheRail() async {
        let source = RecordingTodayCardSource(response: response())
        let model = model(source)
        await model.start()

        source.response = response(card: nil, banners: [])
        await model.refresh()

        #expect(model.banners == Self.rail)
    }

    @Test("New data that changes the rail replaces it; a new day replaces it too")
    func aChangedDocumentReplacesTheRail() async {
        let source = RecordingTodayCardSource(response: response())
        let model = model(source)
        await model.start()

        source.response = response(banners: [Self.rail[1]])
        await model.refresh()
        #expect(model.banners.map(\.id) == ["b2"])

        source.response = response(card: nil, banners: [], day: EvaDay(year: 2026, month: 9, day: 26))
        await model.refresh()
        #expect(model.banners.isEmpty)
        #expect(model.state == .noCard)
    }
}

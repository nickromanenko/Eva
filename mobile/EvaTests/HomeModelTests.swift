import Foundation
import Testing
@testable import Eva

/// Issue #99: **the card does not change on refresh, and a failed read never empties the
/// screen.**
///
/// Both are PRD §Dashboard promises with a device half and a server half. D3 owns the
/// server half (a refresh with nothing new returns a byte-identical document); this suite
/// is the device half, and it is the half that is easy to get wrong invisibly — an
/// `@Observable` model that reassigns an identical card on every pull re-renders the
/// screen while every byte on the wire stays the same, and nothing about the pixels looks
/// different enough to notice.
///
/// The cold-start states are here too. They are the ones a real device meets first: the
/// `content/` collection is unseeded until its copy is reviewed (#97), so "the server has
/// no card" is the common path rather than an edge.
@Suite("Issue #99 · the Home tab's card state")
@MainActor
struct HomeModelTests {

    private static let zone = TimeZone(identifier: "Europe/Lisbon")!
    private static let day = EvaDay(year: 2026, month: 8, day: 18)

    private func model(
        _ source: RecordingTodayCardSource,
        at instant: Date = Date(timeIntervalSince1970: 1_755_936_720)
    ) -> HomeModel {
        HomeModel(source: source, timeZone: { Self.zone }, clock: { instant })
    }

    // MARK: - The cold start

    @Test("Before anything is read there is nothing to draw and no card to protect")
    func startsLoading() {
        let model = model(RecordingTodayCardSource(card: nil))
        #expect(model.state == .loading)
        #expect(model.card == nil)
        #expect(!model.showsOfflineBar)
        #expect(model.lastSyncedAt == nil)
    }

    @Test("A card arrives and is what the screen draws")
    func aCardLands() async {
        let source = RecordingTodayCardSource(card: .coldStartFixture)
        let model = model(source)

        await model.start()

        #expect(model.state == .card(.coldStartFixture))
        #expect(model.date == Self.day)
        #expect(model.contentVersion == "v1")
        #expect(model.cardRevision == 1)
        #expect(source.zones == [Self.zone.identifier])
    }

    /// The path a device is on today. `content/` holds nothing, so the day resolves and
    /// there is no card for it — which is a state with its own screen, not an error and
    /// not a spinner that never ends.
    @Test("A day with no card is its own state, not a failure")
    func noCardIsItsOwnState() async {
        let model = model(RecordingTodayCardSource(card: nil))

        await model.start()

        #expect(model.state == .noCard)
        #expect(model.cardRevision == 0)
        // It reached the server, so it is not offline — the distinction the offline bar
        // depends on.
        #expect(!model.showsOfflineBar)
        #expect(model.lastSyncedAt != nil)
    }

    @Test("A cold start with no network says so, and offers the read again")
    func aColdStartThatCannotReachTheAPI() async {
        let source = RecordingTodayCardSource(card: .coldStartFixture)
        source.failure = APIError.network
        let model = model(source)

        await model.start()

        #expect(model.state == .unavailable(APIError.network.localizedDescription))
        #expect(model.isOffline)
        // Nothing cached, so nothing to caption: the bar is about a card, and there is none.
        #expect(!model.showsOfflineBar)
        #expect(model.lastSyncedAt == nil)

        // And the banner's Retry is a real retry.
        source.failure = nil
        await model.refresh()
        #expect(model.state == .card(.coldStartFixture))
        #expect(!model.isOffline)
    }

    /// A 500 or an undecodable body is not being offline, and saying "offline" about
    /// either would be a guess about the user's connection.
    @Test("Only a network failure is offline")
    func onlyNetworkFailuresAreOffline() async {
        let source = RecordingTodayCardSource(card: nil)
        source.failure = APIError.server(code: "INTERNAL", message: "Something went wrong.", status: 500)
        let model = model(source)

        await model.start()

        #expect(model.state == .unavailable("Something went wrong."))
        #expect(!model.isOffline)
    }

    /// A dead session is already being handled: `AppSession.authorized` logs out and the
    /// root view switches away. Putting an error on a screen that is being torn down would
    /// alarm someone who is simply being signed out.
    @Test("An expired session leaves the screen alone")
    func anExpiredSessionIsNotAnError() async {
        let source = RecordingTodayCardSource(card: nil)
        source.failure = APIError.sessionExpired(message: "Your session expired.")
        let model = model(source)

        await model.start()

        #expect(model.state == .loading)
        #expect(!model.isOffline)
    }

    // MARK: - "It updates on new data, not on refresh"

    /// PRD §Dashboard, Other requirements 3 and Edge cases 5. The assertion is
    /// `cardRevision`, not `state`: two equal cards compare equal whether or not the model
    /// wrote one over the other, and it is the *write* that re-renders the screen.
    @Test("A refresh that brings the same card changes nothing on screen")
    func refreshWithNothingNewChangesNothing() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let model = model(source)

        await model.start()
        let revisionAfterFirstRead = model.cardRevision

        await model.refresh()
        await model.refresh()

        // It asked — three times — and the screen never changed.
        #expect(source.reads == 3)
        #expect(model.cardRevision == revisionAfterFirstRead)
        #expect(model.state == .card(.phaseFixture))
    }

    /// The other half of the same rule: new data *does* change it. A card that differs in
    /// one word is a different card.
    @Test("A refresh that brings new data replaces the card")
    func refreshWithNewDataReplacesTheCard() async {
        let source = RecordingTodayCardSource(card: .coldStartFixture)
        let model = model(source)
        await model.start()

        source.response = EvaTodayResponse(
            date: Self.day, generatedAt: "later", contentVersion: "v1", card: .phaseFixture
        )
        await model.refresh()

        #expect(model.state == .card(.phaseFixture))
        #expect(model.cardRevision == 2)
    }

    @Test("A refresh before the first read has landed is a no-op, not a second request")
    func refreshBeforeTheFirstReadDoesNothing() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let model = model(source)

        await model.refresh()

        #expect(source.reads == 0)
        #expect(model.state == .loading)
    }

    @Test("A second appearance re-uses the card it already has")
    func startIsIdempotent() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let model = model(source)

        await model.start()
        await model.start()

        #expect(source.reads == 1)
    }

    /// Two reads racing would write the same state twice from two places. The parking
    /// source is what makes the guard reachable at all — without it the first read returns
    /// before the second is asked for.
    @Test("Two reads at once are one request")
    func readsAreSingleFlight() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        source.suspends = true
        let model = model(source)

        async let first: Void = model.start()
        while !source.isParked { await Task.yield() }
        await model.start()
        source.release()
        await first

        #expect(source.reads == 1)
    }

    // MARK: - Offline over a cached card

    /// `SPEC.home_off`: "Offline shows the cached daily card with an explicit sync
    /// timestamp, not a stale-looking blank." #99: "a blank or a spinner never appears
    /// when a card exists".
    @Test("Losing the network keeps the card and adds the bar")
    func offlineKeepsTheCard() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let landedAt = Date(timeIntervalSince1970: 1_755_936_720)
        let model = HomeModel(source: source, timeZone: { Self.zone }, clock: { landedAt })

        await model.start()
        source.failure = APIError.network
        await model.refresh()

        #expect(model.state == .card(.phaseFixture))
        #expect(model.showsOfflineBar)
        // The timestamp is the moment the card landed, not the moment the refresh failed.
        #expect(model.lastSyncedAt == landedAt)
        #expect(model.cardRevision == 1)
    }

    @Test("Getting the network back takes the bar away")
    func comingBackOnlineClearsTheBar() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let model = model(source)
        await model.start()
        source.failure = APIError.network
        await model.refresh()
        #expect(model.showsOfflineBar)

        source.failure = nil
        await model.refresh()

        #expect(!model.showsOfflineBar)
        #expect(!model.isOffline)
    }

    /// The reading of "does not change on repeated opens" that is easy to miss: a response
    /// that has *lost* the card is not a reason to take it off the screen either.
    @Test("A refresh that answers with no card leaves the card where it is")
    func aRefreshNeverEmptiesTheCard() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let model = model(source)
        await model.start()

        source.response = EvaTodayResponse(
            date: Self.day, generatedAt: "later", contentVersion: "v1", card: nil
        )
        await model.refresh()

        #expect(model.state == .card(.phaseFixture))
    }

    /// The one thing that may empty it: the local date rolled over. That day genuinely has
    /// no card yet, and showing yesterday's under today's header would be the stale-looking
    /// screen `SPEC.home_off` is against.
    @Test("A new local date with no card replaces the card")
    func aNewDayWithNoCardClearsIt() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        let model = model(source)
        await model.start()

        source.response = EvaTodayResponse(
            date: Self.day.adding(days: 1), generatedAt: "later", contentVersion: "v1", card: nil
        )
        await model.refresh()

        #expect(model.state == .noCard)
        #expect(model.date == Self.day.adding(days: 1))
    }

    // MARK: - The zone, not the date

    /// The server resolves "today" from the zone, exactly as the events routes do. Reading
    /// it per request rather than capturing it is what makes a user who lands somewhere
    /// else get the card for the date her device now says.
    @Test("The zone is read at every request, not captured once")
    func theZoneIsReadPerRequest() async {
        let source = RecordingTodayCardSource(card: .phaseFixture)
        var zone = TimeZone(identifier: "Europe/Lisbon")!
        let model = HomeModel(source: source, timeZone: { zone }, clock: { Date() })

        await model.start()
        zone = TimeZone(identifier: "Pacific/Auckland")!
        await model.refresh()

        #expect(source.zones == ["Europe/Lisbon", "Pacific/Auckland"])
    }
}

/// An in-memory `EmergencyGuidanceSource` that records what the Home tab asked it for,
/// the same way `RecordingTodayCardSource` does for the card (#87).
@MainActor
private final class RecordingGuidanceSource: EmergencyGuidanceSource {

    private(set) var reads = 0
    /// `nil` makes every read fail, the way a dead network or a pre-table API does.
    let table: [EvaRefData.EmergencyEntry]?

    init(table: [EvaRefData.EmergencyEntry]?) {
        self.table = table
    }

    func emergencyGuidance() async -> [EvaRefData.EmergencyEntry]? {
        reads += 1
        return table
    }
}

@MainActor
extension HomeModelTests {

    // MARK: - The guidance table (#87)

    private func guidanceModel(
        _ source: RecordingTodayCardSource,
        guidance: RecordingGuidanceSource
    ) -> HomeModel {
        HomeModel(
            source: source,
            guidanceSource: guidance,
            timeZone: { Self.zone },
            clock: { Date(timeIntervalSince1970: 1_755_936_720) }
        )
    }

    @Test("The guidance table loads with the card, and a refresh does not fetch it again")
    func guidanceLoadsOncePerModel() async {
        let guidance = RecordingGuidanceSource(table: [])
        let model = guidanceModel(
            RecordingTodayCardSource(card: .phaseFixture), guidance: guidance
        )

        await model.start()
        #expect(model.emergencyGuidance != nil)
        #expect(guidance.reads == 1)

        await model.refresh()
        #expect(guidance.reads == 1)
    }

    @Test("A failed guidance read is not an error state, and the next refresh retries it")
    func failedGuidanceReadRetriesOnRefresh() async {
        let guidance = RecordingGuidanceSource(table: nil)
        let model = guidanceModel(
            RecordingTodayCardSource(card: .phaseFixture), guidance: guidance
        )

        await model.start()
        #expect(model.emergencyGuidance == nil)
        // The card is standing and the screen is not in a failure state — the failed
        // read is the card keeping its own wording, nothing louder.
        #expect(model.state == .card(.phaseFixture))

        await model.refresh()
        #expect(guidance.reads == 2)
        // `nil` is also the "still failing" answer, and the card is still standing.
        #expect(model.emergencyGuidance == nil)
        #expect(model.state == .card(.phaseFixture))
    }

    @Test("A model with no guidance source renders the card and nothing else")
    func noGuidanceSourceLeavesTheCardAlone() async {
        let model = HomeModel(
            source: RecordingTodayCardSource(card: .phaseFixture),
            timeZone: { Self.zone },
            clock: { Date() }
        )

        await model.start()
        #expect(model.state == .card(.phaseFixture))
        #expect(model.emergencyGuidance == nil)
    }
}

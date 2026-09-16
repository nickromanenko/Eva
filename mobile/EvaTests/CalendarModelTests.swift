import Foundation
import Testing
@testable import Eva

/// Issue #159: **`GET /me/events` is called once per visible range, not per day.**
///
/// #159's Risks section is what this suite is for: "a per-day request pattern would be
/// invisible here and painful in C2". Invisible is the operative word — 42 requests and 1
/// request draw the same screen, and nothing about the calendar looks wrong until the
/// slice that writes to it arrives. So the request shape is asserted directly, as counts
/// and ranges, rather than inferred from the pixels it produces.
@Suite("Issue #159 · the calendar fetches by range and caches by month")
@MainActor
struct CalendarModelTests {

    /// Records what was asked for. Not a stubbed `URLSession`: the claim under test is
    /// about *requests*, and the global URL-protocol stub is shared with every other suite
    /// in this target, so a count read through it would be a count of everybody's traffic.
    @MainActor
    final class RecordingSource: CalendarEventSource {
        private(set) var ranges: [ClosedRange<EvaDay>] = []
        private(set) var refDataCalls = 0
        var events: [EvaEvent] = []
        var failure: (any Error)?

        func events(from: EvaDay, through to: EvaDay) async throws -> [EvaEvent] {
            ranges.append(from...to)
            if let failure { throw failure }
            return events.filter { (from...to).contains($0.localDate) }
        }

        func refData() async throws -> EvaRefData {
            refDataCalls += 1
            return EvaRefData(version: "v1", catalogues: EvaRefData.Catalogues())
        }
    }

    static let today = EvaDay(year: 2026, month: 8, day: 18)

    static func event(
        _ id: String,
        on day: EvaDay,
        _ detail: EvaEventDetail = .cycle(.flow(.light))
    ) -> EvaEvent {
        EvaEvent(id: id, detail: detail, localDate: day, loggedAt: "\(day.isoDate)T08:30:00")
    }

    // MARK: - The request shape

    @Test("One request paints the first screen, whatever is on it")
    func firstLoadIsOneRequest() async throws {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(source.ranges.count == 1, "The first load made \(source.ranges.count) requests")
        let range = try #require(source.ranges.first)
        // It covers every cell the grid draws, including the days either side of August.
        let grid = EvaMonthGrid(month: EvaMonth(year: 2026, month: 8))
        #expect(range.contains(grid.visibleRange.lowerBound))
        #expect(range.contains(grid.visibleRange.upperBound))
        // …and it is inside the API's own cap, which rejects anything wider.
        #expect(range.upperBound.days(since: range.lowerBound) <= CalendarModel.historyWindowDays)
    }

    @Test("Paging inside what is already cached asks for nothing")
    func pagingWithinTheCacheIsFree() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        #expect(source.ranges.count == 1)

        // The first load reaches about thirteen months back, so half a year of paging is
        // already on the device — there and back again.
        for _ in 0..<6 { await model.showPreviousMonth() }
        #expect(model.visibleMonth == EvaMonth(year: 2026, month: 2))
        for _ in 0..<6 { await model.showNextMonth() }

        #expect(model.visibleMonth == EvaMonth(year: 2026, month: 8))
        #expect(source.ranges.count == 1, "Paging re-fetched months it already had")
    }

    @Test("Paging past the cache asks once, for the months that are missing")
    func pagingBeyondTheCacheFetchesTheGap() async throws {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()

        // Far enough forward that nothing around it has been seen.
        await model.show(EvaMonth(year: 2027, month: 6))

        #expect(source.ranges.count == 2)
        let gap = try #require(source.ranges.last)
        let grid = EvaMonthGrid(month: EvaMonth(year: 2027, month: 6))
        #expect(gap.contains(grid.visibleRange.lowerBound))
        #expect(gap.contains(grid.visibleRange.upperBound))

        // Arriving at the same month a second time asks for nothing.
        await model.show(EvaMonth(year: 2027, month: 5))
        await model.show(EvaMonth(year: 2027, month: 6))
        #expect(source.ranges.count <= 3, "Re-visiting a fetched month re-fetched it")
        #expect(source.ranges.last == gap || source.ranges.count == 3)
    }

    /// The failure this suite exists to prevent, stated as a bound rather than as a shape:
    /// forty-two cells must never cost forty-two requests.
    @Test("A year of paging never costs a request per day")
    func pagingNeverDegradesToPerDay() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()

        for _ in 0..<24 { await model.showNextMonth() }

        // At most one request per page, never one per cell. The bound is the shape of the
        // claim: a month is fetched, not a day.
        #expect(source.ranges.count <= 25,
                "24 months of paging took \(source.ranges.count) requests")
        for range in source.ranges {
            #expect(range.lowerBound <= range.upperBound,
                    "A range was sent with from after to, which the API rejects")
            #expect(range.upperBound.days(since: range.lowerBound) >= 27,
                    "A request covered \(range), which is narrower than a month")
            #expect(range.upperBound.days(since: range.lowerBound)
                    <= CalendarModel.historyWindowDays,
                    "A request covered \(range), which the API rejects as too wide")
        }
    }

    @Test("The catalogue is fetched once, not once per page")
    func refDataIsFetchedOnce() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()
        await model.showNextMonth()
        await model.start()

        #expect(source.refDataCalls == 1)
        #expect(model.refData != nil)
    }

    // MARK: - What the grid reads back

    @Test("Entries land on the day they were logged, and on no other")
    func eventsAreIndexedByTheirOwnDay() async {
        let day = EvaDay(year: 2026, month: 8, day: 12)
        let source = RecordingSource()
        source.events = [
            Self.event("a", on: day, .bodySignals(EvaBodySignalsPayload(energy: 2))),
            Self.event("b", on: day, .sport(EvaSportPayload(
                activity: "yoga", durationMin: 30, intensity: .light
            ))),
            Self.event("c", on: EvaDay(year: 2026, month: 8, day: 13))
        ]
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.events(on: day).map(\.id) == ["a", "b"])
        // Marks come back in one fixed order, so a cell never redraws them in a new one.
        #expect(model.glyphs(on: day) == [.bodySignals, .sport])
        #expect(model.cycleMark(on: day) == nil)
        #expect(model.cycleMark(on: EvaDay(year: 2026, month: 8, day: 13)) == .flow(.light))
        #expect(model.events(on: EvaDay(year: 2026, month: 8, day: 14)).isEmpty)
    }

    /// A range is the authority for the days inside it — it **replaces** them rather than
    /// merging into them.
    ///
    /// This is reachable, not theoretical. The first load's window starts mid-month, so
    /// its earliest month holds days in the index without being cached; paging to that
    /// month fetches a range that overlaps them. A merge would show every entry in the
    /// overlap twice, and would never be able to take one off the grid, because a response
    /// that no longer contains an entry says nothing about it.
    @Test("An overlapping range replaces the days it covers rather than adding to them")
    func overlappingRangesReplaceRatherThanMerge() async throws {
        // Which month the window half-covers depends on where `today` falls, so it is read
        // back from the request rather than assumed.
        let probe = RecordingSource()
        await CalendarModel(source: probe, today: Self.today).start()
        let window = try #require(probe.ranges.first)
        let day = window.lowerBound
        let partialMonth = day.evaMonth
        #expect(!partialMonth.isFullyCovered(from: window.lowerBound, to: window.upperBound),
                "\(partialMonth) is fully covered, so this test is not testing an overlap")

        // Still logged when the overlapping range comes back: one entry, not two.
        let kept = RecordingSource()
        kept.events = [Self.event("a", on: day)]
        let keeping = CalendarModel(source: kept, today: Self.today)
        await keeping.start()
        #expect(keeping.events(on: day).count == 1)
        await keeping.show(partialMonth)
        #expect(kept.ranges.count == 2, "The half-covered month was treated as cached")
        #expect(keeping.events(on: day).map(\.id) == ["a"],
                "An overlapping re-fetch duplicated an entry")

        // Gone by the time the overlapping range comes back: off the grid.
        let removed = RecordingSource()
        removed.events = [Self.event("a", on: day)]
        let removing = CalendarModel(source: removed, today: Self.today)
        await removing.start()
        #expect(removing.events(on: day).count == 1)
        removed.events = []
        await removing.show(partialMonth)
        #expect(removing.events(on: day).isEmpty,
                "A re-fetch kept an entry the server no longer sends")
    }

    // MARK: - The empty state

    /// "Log your first period to start predictions" is a claim about the account. Showing
    /// it to someone who logged one four months ago is a false statement about her own
    /// data, which is exactly what DESIGN.md §8 rules out — so it is answered from the
    /// wide first range, not from whatever month happens to be on screen.
    @Test("The empty state waits for an answer, and an empty month is not one")
    func emptyStateIsAboutTheAccount() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        #expect(model.hasHistory == nil, "The empty state was decided before anything loaded")
        #expect(!model.showsEmptyState)

        await model.start()
        #expect(model.hasHistory == false)
        #expect(model.showsEmptyState)
    }

    @Test("One entry anywhere in the year is enough to answer it")
    func historyAnywhereClearsTheEmptyState() async {
        let source = RecordingSource()
        source.events = [Self.event("a", on: EvaDay(year: 2026, month: 4, day: 2))]
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.hasHistory == true)
        #expect(!model.showsEmptyState, "A user with history was told to log her first period")
        // …even though the month on screen has nothing on it.
        #expect(model.events(on: Self.today).isEmpty)
    }

    @Test("A month with no entries never un-answers it")
    func anEmptyMonthDoesNotReinstateTheEmptyState() async {
        let source = RecordingSource()
        source.events = [Self.event("a", on: EvaDay(year: 2026, month: 8, day: 2))]
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        #expect(model.hasHistory == true)

        await model.show(EvaMonth(year: 2028, month: 1))

        #expect(model.hasHistory == true, "Paging to an empty month claimed the account was empty")
        #expect(!model.showsEmptyState)
    }

    // MARK: - Failure

    @Test("A failed load says so and leaves the calendar standing")
    func failureIsReportedWithoutLosingTheScreen() async {
        let source = RecordingSource()
        source.failure = APIError.network
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.loadState == .failed(APIError.network.localizedDescription))
        // Unanswered, not answered "no": a request that failed says nothing about whether
        // the account has history, and the empty state must not fill the gap.
        #expect(model.hasHistory == nil)
        #expect(!model.showsEmptyState)
        #expect(model.grid.cells.count == 42, "The grid went away with the request")
    }

    @Test("Retry clears the failure once the request lands")
    func retryRecovers() async {
        let source = RecordingSource()
        source.failure = APIError.network
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()

        source.failure = nil
        source.events = [Self.event("a", on: Self.today)]
        // The error card's own action. Nothing is cached after a failed first load, so
        // this is the history window again rather than a no-op.
        await model.retry()

        #expect(model.loadState == .idle)
        #expect(model.hasHistory == true)
        #expect(model.events(on: Self.today).count == 1)
    }

    /// A dead session is already being handled one layer up — `AppSession.authorized` logs
    /// out and the root view switches away. An error card on the way out would flash a
    /// failure at someone who is being signed out.
    @Test("A dead session is not drawn as a calendar error")
    func sessionExpiryIsNotAnErrorCard() async {
        let source = RecordingSource()
        source.failure = APIError.sessionExpired(message: "Missing or invalid token")
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.loadState == .idle)
    }

    // MARK: - Selection

    @Test("Selection follows the page onto a day that exists")
    func selectionSurvivesAShortMonth() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()

        model.select(EvaDay(year: 2026, month: 8, day: 31))
        await model.show(EvaMonth(year: 2026, month: 9))
        #expect(model.selectedDay == EvaDay(year: 2026, month: 9, day: 30))

        model.select(EvaDay(year: 2026, month: 1, day: 31))
        await model.show(EvaMonth(year: 2026, month: 2))
        #expect(model.selectedDay == EvaDay(year: 2026, month: 2, day: 28))
    }

    /// Future days are selectable — #159's scope says so, and C2 is what disables *logging*
    /// on them. Nothing here may refuse a day for being ahead of today.
    @Test("A future day can be selected")
    func futureDaysAreSelectable() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()

        let future = EvaDay(year: 2027, month: 3, day: 4)
        await model.show(future.evaMonth)
        model.select(future)

        #expect(model.selectedDay == future)
    }
}

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

    /// Records what was asked for, and — when asked to — **holds the call open**.
    ///
    /// Not a stubbed `URLSession`: the claim under test is about *requests*, and the global
    /// URL-protocol stub is shared with every other suite in this target, so a count read
    /// through it would be a count of everybody's traffic.
    ///
    /// `suspends` is the half that matters for the single-flight path. Without it this
    /// source returns without ever suspending, so `isFetching` is never true when a second
    /// call arrives and the whole queue-and-re-run branch is unreachable from a test — which
    /// is how the dropped-fetch defect shipped with a green suite.
    @MainActor
    final class RecordingSource: CalendarEventSource {
        private(set) var ranges: [ClosedRange<EvaDay>] = []
        private(set) var refDataCalls = 0
        var events: [EvaEvent] = []
        var failure: (any Error)?

        /// While true, every `events(from:through:)` parks until `release()` lets it go.
        var suspends = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        var isParked: Bool { !parked.isEmpty }

        func events(from: EvaDay, through to: EvaDay) async throws -> [EvaEvent] {
            ranges.append(from...to)
            if suspends {
                await withCheckedContinuation { parked.append($0) }
            }
            if let failure { throw failure }
            return events.filter { (from...to).contains($0.localDate) }
        }

        func refData() async throws -> EvaRefData {
            refDataCalls += 1
            return EvaRefData(version: "v1", catalogues: EvaRefData.Catalogues())
        }

        /// Lets every held call return, then yields so they actually run.
        func release() async {
            let waiting = parked
            parked = []
            for continuation in waiting { continuation.resume() }
            for _ in 0..<8 { await Task.yield() }
        }

        /// Suspends until request number `count` has arrived **and is parked at the
        /// network**, so the test acts during a request rather than hoping to.
        ///
        /// Records an issue instead of hanging: a request that never arrives is a broken
        /// test, not a slow one.
        func waitUntilParked(
            afterRequests count: Int,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            for _ in 0..<2_000 {
                if ranges.count >= count && isParked { return }
                await Task.yield()
            }
            Issue.record(
                "Only \(ranges.count) request(s) arrived, parked: \(isParked)",
                sourceLocation: sourceLocation
            )
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
        //
        // The literal, not the constant. `MAX_RANGE_DAYS` lives in `api/src/index.ts` and
        // nothing links the two numbers, so comparing the client's constant to itself
        // proved only that arithmetic works. Written out, a change to either side has to
        // come past this line.
        #expect(CalendarModel.historyWindowDays == 400,
                "The API caps a range at 400 days (MAX_RANGE_DAYS in api/src/index.ts)")
        #expect(range.upperBound.days(since: range.lowerBound) <= 400)
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

        // One step back needs the month before *that*, which nothing has asked for yet.
        await model.show(EvaMonth(year: 2027, month: 5))
        #expect(source.ranges.count == 3,
                "Paging back off the edge of the cache should cost exactly one request")

        // Arriving back at a month already fetched asks for nothing at all.
        await model.show(EvaMonth(year: 2027, month: 6))
        #expect(source.ranges.count == 3, "Re-visiting a fetched month re-fetched it")
    }

    /// Two claims a cache-less or per-day model both fail.
    ///
    /// The first bound used to be "at most one request per page", which is exactly what a
    /// model with no cache at all makes — it passed for the wrong reason. Paging *back*
    /// over the same two years is the assertion with a cache in it: twenty-four more pages
    /// over ground already walked, and not one more request.
    @Test("Paging asks for months, and never asks twice for the same one")
    func pagingFetchesMonthsAndUsesTheCache() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()

        for _ in 0..<24 { await model.showNextMonth() }
        let afterGoingOut = source.ranges.count
        #expect(model.visibleMonth == EvaMonth(year: 2028, month: 8))

        for _ in 0..<24 { await model.showPreviousMonth() }

        #expect(model.visibleMonth == Self.today.evaMonth)
        #expect(source.ranges.count == afterGoingOut,
                """
                Paging back over months already fetched cost \
                \(source.ranges.count - afterGoingOut) more requests
                """)

        // And every request was for a month or more of days, never for one day.
        for range in source.ranges {
            #expect(range.lowerBound <= range.upperBound,
                    "A range was sent with from after to, which the API rejects")
            #expect(range.upperBound.days(since: range.lowerBound) >= 27,
                    "A request covered \(range), which is narrower than a month")
            #expect(range.upperBound.days(since: range.lowerBound) <= 400,
                    "A request covered \(range), which the API rejects as too wide")
        }
    }

    // MARK: - A load that is still in the air

    /// **The defect this whole section exists for.** One tap on the month picker during the
    /// 400-day first load used to leave that month with zero requests, ever: the second
    /// `fetch` saw `isFetching` and returned, nothing re-ran, and the user got a silently
    /// empty calendar on the app's landing screen with no spinner and nothing to retry.
    ///
    /// It needs a source that actually suspends — see `RecordingSource.suspends`. With one
    /// that returns immediately, `isFetching` is never true at the second call and this
    /// path cannot be reached at all, which is how it shipped green.
    @Test("A month change during an in-flight load is finished, not dropped")
    func pagingDuringAnInFlightLoadIsNotLost() async {
        let november = EvaMonth(year: 2026, month: 11)
        let source = RecordingSource()
        source.suspends = true
        source.events = [Self.event("a", on: EvaDay(year: 2026, month: 11, day: 4))]
        let model = CalendarModel(source: source, today: Self.today)

        let firstLoad = Task { await model.start() }
        await source.waitUntilParked(afterRequests: 1)

        // The tap, while the first request is provably still open.
        await model.show(november)
        #expect(model.visibleMonth == november)
        #expect(source.ranges.count == 1, "A second request started while the first was open")

        // The first lands. The second has to follow it without anyone asking again.
        await source.release()
        await source.waitUntilParked(afterRequests: 2)
        await source.release()
        await firstLoad.value

        #expect(source.ranges.count == 2,
                "The month tapped during the load was never requested")
        #expect(source.ranges.last?.contains(november.firstDay) == true)
        #expect(model.events(on: EvaDay(year: 2026, month: 11, day: 4)).count == 1,
                "The calendar is empty for the month the user actually paged to")
        #expect(model.loadState == .idle)
    }

    /// Paging three times during one load leaves the user somewhere, and that somewhere is
    /// what gets fetched — not each month on the way. The re-run reads the month that is
    /// visible when the network answers, so the two the user passed through cost nothing.
    @Test("Only where the user ended up is fetched, not every month passed through")
    func onlyTheFinalMonthIsFetchedAfterAnInFlightLoad() async {
        let source = RecordingSource()
        source.suspends = true
        let model = CalendarModel(source: source, today: Self.today)

        let firstLoad = Task { await model.start() }
        await source.waitUntilParked(afterRequests: 1)

        await model.show(EvaMonth(year: 2027, month: 4))
        await model.show(EvaMonth(year: 2027, month: 5))
        await model.show(EvaMonth(year: 2027, month: 6))
        #expect(source.ranges.count == 1)

        await source.release()
        await source.waitUntilParked(afterRequests: 2)
        await source.release()
        await firstLoad.value

        #expect(source.ranges.count == 2, "Each month paged through was fetched separately")
        let caught = try? #require(source.ranges.last)
        #expect(caught?.contains(EvaDay(year: 2027, month: 6, day: 1)) == true)
        #expect(model.loadState == .idle)
    }

    /// The re-run is skipped, not retried forever, when the month the user landed on was
    /// already cached — otherwise a page-during-load into cached ground would spin.
    @Test("A change into already-cached months during a load asks for nothing extra")
    func pagingIntoTheCacheDuringALoadAsksForNothing() async {
        let source = RecordingSource()
        source.suspends = true
        let model = CalendarModel(source: source, today: Self.today)

        let firstLoad = Task { await model.start() }
        await source.waitUntilParked(afterRequests: 1)
        // Inside the 400-day window the first load is already asking for.
        await model.show(EvaMonth(year: 2026, month: 5))
        await source.release()
        await firstLoad.value

        #expect(source.ranges.count == 1)
        #expect(model.loadState == .idle, "The reload loop left the screen loading")
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

    // MARK: - The day it is

    /// `today` is read once when the model is built, and `EvaTabView` keeps the calendar
    /// alive across tab switches — so without a way to move it the app rings yesterday's
    /// cell, and announces it as "Today", from midnight until the process restarts.
    ///
    /// This pins the model's half. The view's half — `significantTimeChangeNotification`
    /// and the scene phase in `CalendarView` — is not reachable from a unit test and is
    /// stated as untested on #159.
    @Test("Today moves when the day does, and the grid follows it")
    func todayCanBeRefreshed() async {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        #expect(model.today == Self.today)

        let tomorrow = Self.today.adding(days: 1)
        model.refreshToday(tomorrow)

        #expect(model.today == tomorrow)
        // Nothing else moves with it: the user's selection and the month they were looking
        // at are theirs, and a date rollover must not take them somewhere else.
        #expect(model.selectedDay == Self.today)
        #expect(model.visibleMonth == Self.today.evaMonth)
        #expect(source.ranges.count == 1, "A date rollover triggered a refetch")
    }

    /// Midnight at the end of a month moves the grid's idea of today into the next one.
    @Test("Today can cross a month boundary")
    func todayCrossesAMonthBoundary() async {
        let lastOfAugust = EvaDay(year: 2026, month: 8, day: 31)
        let model = CalendarModel(source: RecordingSource(), today: lastOfAugust)

        model.refreshToday(EvaDay(year: 2026, month: 9, day: 1))

        #expect(model.today == EvaDay(year: 2026, month: 9, day: 1))
        // The grid stays where the user left it — September's "today" is simply not drawn
        // on an August page, which is correct.
        #expect(model.visibleMonth == EvaMonth(year: 2026, month: 8))
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

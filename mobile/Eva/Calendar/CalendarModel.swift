import Foundation

/// Where the calendar gets its data.
///
/// `AppSession` is the only conformance and the only one there should be — it owns the
/// token and the 401 rule, and a second implementation in app code would be a second way
/// to talk to the API. It exists as a protocol so the caching above can be tested for what
/// it actually claims: **how many requests, over which ranges**. Asserting that through a
/// stubbed `URLSession` would measure the same thing at three layers' remove, through
/// global state shared with every other suite in the target.
@MainActor
protocol CalendarEventSource {
    func events(from: EvaDay, through to: EvaDay) async throws -> [EvaEvent]
    func refData() async throws -> EvaRefData
}

extension AppSession: CalendarEventSource {}

/// What the calendar screen knows: which month is showing, which day is selected, and the
/// entries for the days it has actually fetched.
///
/// ## Fetch by range, cache by month
///
/// The one structural decision in C1, and #159's Risks section says why it matters more
/// than the pixels: every later calendar slice reads through this. A month grid draws 42
/// cells spanning up to three months, so the unit that is fetched is a **range** and the
/// unit that is remembered is a **month** — ask for a month that is already cached and no
/// request happens at all, ask for three that are not and exactly one request covers them.
/// A request per visible day would look identical on this screen and become forty-two
/// round trips per page once C2 is writing into it.
///
/// ## Why the first load is wider than the first screen
///
/// The empty state is a claim about the *account*, not about the month on screen: "Log
/// your first period to start predictions" shown to someone who logged one four months ago
/// is a false statement about her own data, which is the class of thing DESIGN.md §8 exists
/// to prevent. There is no "do I have any history" route, so the first load asks for the
/// widest window the API allows (400 days), ending at the end of next month. One
/// request answers both questions, and it warms thirteen months of cache on the way —
/// after it, paging inside the last year costs nothing.
@MainActor
@Observable
final class CalendarModel {

    enum LoadState: Equatable {
        case idle
        case loading
        /// The message is the API's, or `APIError`'s own wording for a failed load.
        case failed(String)
    }

    /// The API's cap on one range (`MAX_RANGE_DAYS` in `api/src/index.ts`). The first
    /// load asks for exactly this much, minus one, since the server measures `to - from`.
    static let historyWindowDays = 400

    /// What day it is where the user is, captured once per screen appearance.
    private(set) var today: EvaDay
    private(set) var visibleMonth: EvaMonth
    private(set) var selectedDay: EvaDay
    private(set) var loadState: LoadState = .idle
    private(set) var refData: EvaRefData?

    /// Whether the account has anything in the last `historyWindowDays`.
    ///
    /// `nil` until the first range has answered — the empty state must not flash on a
    /// screen that has simply not loaded yet, and "we do not know" is a third state, not
    /// a synonym for "no".
    private(set) var hasHistory: Bool?

    private var eventsByDay: [EvaDay: [EvaEvent]] = [:]
    private var loadedMonths: Set<EvaMonth> = []

    private let source: any CalendarEventSource

    /// True from the first request of a run until the last one lands — including the
    /// reloads queued behind it. It is what makes `fetch` single-flight.
    private var isFetching = false

    /// Set when a load was asked for while one was already running. The run that is in
    /// flight picks it up when it lands; see `fetch`.
    ///
    /// A flag rather than a queued range, because the only thing worth reloading is
    /// whatever the *current* visible month needs by the time the network answers — the
    /// month the user paged through on the way there is not on screen any more.
    private var reloadRequested = false

    init(source: any CalendarEventSource, today: EvaDay = .today()) {
        self.source = source
        self.today = today
        self.visibleMonth = today.evaMonth
        self.selectedDay = today
    }

    // MARK: - Reading

    var grid: EvaMonthGrid { EvaMonthGrid(month: visibleMonth) }

    /// The entries logged on a day, in the order the API returned them (by `loggedAt`).
    func events(on day: EvaDay) -> [EvaEvent] { eventsByDay[day] ?? [] }

    /// The corner marks a day cell draws, at most one per type, in a fixed order so the
    /// same day never redraws its marks in a different sequence.
    func glyphs(on day: EvaDay) -> [EvaEventGlyph] {
        let logged = Set(events(on: day).compactMap { $0.type.glyph })
        return EvaEventGlyph.allCases.filter(logged.contains)
    }

    /// The cycle entry for a day, if there is one. At most one exists: `cycle` is a
    /// one-per-day type on the server, stored at a deterministic document id.
    func cycleMark(on day: EvaDay) -> EvaCycleMark? {
        for event in events(on: day) {
            if case .cycle(let mark) = event.detail { return mark }
        }
        return nil
    }

    /// Whether the empty state should be on screen: the account has no history *and* the
    /// question has been answered.
    var showsEmptyState: Bool { hasHistory == false }

    // MARK: - Navigation

    func select(_ day: EvaDay) {
        selectedDay = day
    }

    /// Re-reads what day it is.
    ///
    /// `today` is captured at init and the calendar is kept alive across tab switches, so
    /// without this the app rings yesterday's cell — and announces it as "Today" — from
    /// midnight until the process restarts. The same call covers a time-zone change, which
    /// moves the user's wall clock for exactly the same reason.
    func refreshToday(_ day: EvaDay = .today()) {
        guard day != today else { return }
        today = day
    }

    /// Pages to a month and loads whatever it needs. Selecting follows the page so the
    /// detail below the grid always describes a day the grid is drawing: the same day of
    /// the month where that day exists, the last day otherwise (31 January → 28 February).
    func show(_ month: EvaMonth) async {
        guard month != visibleMonth else { return }
        visibleMonth = month
        selectedDay = EvaDay(
            year: month.year,
            month: month.month,
            day: min(selectedDay.day, month.dayCount)
        )
        await loadVisibleRange()
    }

    func showNextMonth() async { await show(visibleMonth.next) }
    func showPreviousMonth() async { await show(visibleMonth.previous) }

    // MARK: - Loading

    /// The screen's first load. Idempotent — a second appearance re-uses the cache.
    func start() async {
        async let catalogue: Void = loadRefDataIfNeeded()
        if loadedMonths.isEmpty {
            await loadHistoryWindow()
        } else {
            await loadVisibleRange()
        }
        await catalogue
    }

    /// The error card's only action. Re-asks for whatever is still missing.
    func retry() async {
        if hasHistory == nil {
            await loadHistoryWindow()
        } else {
            await loadVisibleRange()
        }
        await loadRefDataIfNeeded()
    }

    /// The first request: the visible grid, plus as much history as one range may carry.
    ///
    /// It ends at the end of *next* month rather than at the last cell the grid draws, so
    /// that the first load leaves the same three-month neighbourhood cached that
    /// `loadVisibleRange` would ask for. Ending at the grid's own edge left next month
    /// half-covered, and paging one month away and back then cost a request for a month
    /// whose days were already on the device.
    private func loadHistoryWindow() async {
        let to = visibleMonth.next.lastDay
        let from = to.adding(days: -(Self.historyWindowDays - 1))
        await fetch(from: from, to: to, answersHistory: true)
    }

    /// Whatever months the current page needs and the cache has not got, or `nil` when
    /// it already has all of them.
    ///
    /// The month either side as well as the month itself, which is a superset of what the
    /// grid draws (a 42-cell grid reaches at most one month each way) and makes paging
    /// back over ground already walked cost nothing. One range for all of them: three
    /// adjacent months are contiguous by construction, so their union is a single range.
    private func missingVisibleRange() -> (from: EvaDay, to: EvaDay)? {
        let wanted = [visibleMonth.previous, visibleMonth, visibleMonth.next]
        let missing = wanted.filter { !loadedMonths.contains($0) }
        guard let first = missing.min(), let last = missing.max() else { return nil }
        return (first.firstDay, last.lastDay)
    }

    private func loadVisibleRange() async {
        guard let range = missingVisibleRange() else { return }
        await fetch(from: range.from, to: range.to, answersHistory: false)
    }

    /// Single-flight, and it **finishes what was asked for while it was in flight**.
    ///
    /// Two concurrent fetches would race to write the same days, so only one runs at a
    /// time. The version of this that only had the guard *dropped* the second ask: one tap
    /// on the month picker during the 400-day first load left that month with zero
    /// requests, ever — no spinner, no error, nothing to retry, and a blank calendar on the
    /// app's landing screen until the user happened to page away and back. The comment that
    /// used to sit here claimed the opposite and nothing implemented it.
    ///
    /// So the second ask sets `reloadRequested`, and the run that is holding the flight
    /// re-reads what the *now* visible month needs and goes again. A `while`, not an `if`:
    /// paging three more times during the reload has to be picked up too. It terminates
    /// because each pass either fetches months it then marks loaded, or finds nothing
    /// missing and falls straight out.
    ///
    /// There is no generation counter any more. There was one, and it was dead: only this
    /// method bumped it and `isFetching` already serialised every bump, so the guards could
    /// never be false. Nothing here needs one — a response is applied by the day it belongs
    /// to, so it is correct for whatever month the user is now looking at.
    private func fetch(from: EvaDay, to: EvaDay, answersHistory: Bool) async {
        if isFetching {
            reloadRequested = true
            return
        }
        isFetching = true
        defer { isFetching = false }

        await perform(from: from, to: to, answersHistory: answersHistory)

        while reloadRequested {
            reloadRequested = false
            guard let range = missingVisibleRange() else { continue }
            await perform(from: range.from, to: range.to, answersHistory: false)
        }
    }

    /// One request, and what it does to the screen's state. Only `fetch` calls this, and
    /// only ever one call at a time.
    private func perform(from: EvaDay, to: EvaDay, answersHistory: Bool) async {
        loadState = .loading
        do {
            let events = try await source.events(from: from, through: to)
            apply(events, coveringFrom: from, to: to)
            if answersHistory {
                hasHistory = !events.isEmpty
            } else if !events.isEmpty {
                // A narrow range may only ever *prove* history, never disprove it.
                hasHistory = true
            }
            loadState = .idle
        } catch let error as APIError {
            // A dead session is already being handled: `AppSession.authorized` has logged
            // out and the root view has switched away from this screen. Showing an error
            // card on the way out would flash a failure at someone who is being signed
            // out, which is a different and more alarming message. `.idle` rather than a
            // bare return: leaving `.loading` would strand a spinner on a screen that is
            // still in the view hierarchy while the switch happens.
            if case .sessionExpired = error {
                loadState = .idle
                return
            }
            loadState = .failed(error.localizedDescription)
        } catch {
            loadState = .failed(APIError.decoding.localizedDescription)
        }
    }

    /// Replaces everything in the fetched range, rather than merging into it.
    ///
    /// Replacing is what makes a re-fetch able to *remove* an entry: a merge would leave
    /// a deleted event on the grid forever, because the response that no longer contains
    /// it says nothing about it. The range is the authority for the days inside it.
    private func apply(_ events: [EvaEvent], coveringFrom from: EvaDay, to: EvaDay) {
        eventsByDay = eventsByDay.filter { $0.key < from || $0.key > to }
        for event in events {
            eventsByDay[event.localDate, default: []].append(event)
        }
        // A month only counts as cached when the range held all of it. The first load's
        // window starts mid-month, and caching that month as complete would leave the
        // days before the cut permanently blank.
        var month = from.evaMonth
        while month <= to.evaMonth {
            if month.isFullyCovered(from: from, to: to) { loadedMonths.insert(month) }
            month = month.next
        }
    }

    private func loadRefDataIfNeeded() async {
        guard refData == nil else { return }
        // A catalogue that will not load is not an error the calendar stops for: the grid
        // and the day list still work, and `EvaRefData?.label(for:in:)` falls back to the
        // stored code. Failing the whole screen because the *labels* are late would be a
        // worse answer than showing the entries with plainer words.
        refData = try? await source.refData()
    }
}

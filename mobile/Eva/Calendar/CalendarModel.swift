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

    // The write half (#160). Each answers with the server's copy of the entry, which is
    // what goes on the grid — see `AppSession`'s note on why the local draft will not do.
    func createEvent(_ write: EvaEventWrite) async throws -> EvaEvent
    func upsertBodySignals(_ write: EvaBodySignalsWrite) async throws -> EvaEvent
    func updateEvent(id: String, _ write: EvaEventWrite) async throws -> EvaEvent
    func deleteEvent(id: String) async throws
    func restoreEvent(id: String) async throws -> EvaEvent
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

    /// The one message the calendar shows after a write (#160), and the canvas' own
    /// affordance for undoing a delete.
    ///
    /// One at a time, replaced rather than queued, which is what the artboard draws — and
    /// which is also why a save quietly retires the delete toast that preceded it.
    struct Toast: Equatable, Identifiable {
        let id: UUID
        /// Describes what happened. Never congratulates, never counts (DESIGN.md §8).
        let message: String
        /// The soft-deleted entry Undo would bring back, when there is one.
        ///
        /// Holding the entry is not the same as promising the button: whether Undo is
        /// still honest is asked of `canRestore(_:)` every time it is drawn, because the
        /// answer changes underneath it — see `offersUndo`.
        let restorable: EvaEvent?

        init(message: String, restorable: EvaEvent? = nil) {
            self.id = UUID()
            self.message = message
            self.restorable = restorable
        }
    }

    /// How long a toast stays. Not a canvas value — the artboard specifies no motion and
    /// no duration anywhere (DESIGN.md §9c) — so this is the platform's own convention,
    /// stretched because the Undo inside it is the only way back from a delete.
    static let toastDuration: Duration = .seconds(8)

    private(set) var toast: Toast?

    private var eventsByDay: [EvaDay: [EvaEvent]] = [:]
    private var loadedMonths: Set<EvaMonth> = []
    private var toastTask: Task<Void, Never>?

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

    /// The day's existing entry of a one-per-day type, if it has one.
    ///
    /// This is what makes the picker edit instead of duplicating: the server keeps one
    /// `cycle` and one `bodySignals` per day, so offering "log body signals" on a day that
    /// already has them would silently replace them. The sheet opens on the entry instead.
    func onePerDayEntry(_ type: EvaEventType, on day: EvaDay) -> EvaEvent? {
        guard type.isOnePerDay else { return nil }
        return events(on: day).first { $0.type == type }
    }

    // MARK: - Writing

    /// Creates or edits one entry and puts the server's answer on the grid.
    ///
    /// `editing` is the id of the entry being replaced, or `nil` for a new one. The route
    /// differs three ways and the caller should not have to know which: an edit is a
    /// `PATCH`, a new body-signals entry is the day-addressed upsert, and everything else
    /// is a create.
    ///
    /// Throws whatever the API threw. Nothing is written to the cache on a failure, so a
    /// sheet that shows the error is showing it about a calendar that has not changed.
    @discardableResult
    func save(_ write: EvaEventWrite, editing id: String? = nil) async throws -> EvaEvent {
        let saved: EvaEvent
        if let id {
            saved = try await source.updateEvent(id: id, write)
        } else if case .bodySignals(let payload) = write.payload {
            saved = try await source.upsertBodySignals(EvaBodySignalsWrite(
                payload: payload,
                localDate: write.localDate,
                note: write.note,
                idempotencyKey: write.idempotencyKey,
                timeZone: write.timeZone
            ))
        } else {
            saved = try await source.createEvent(write)
        }
        absorb(saved)
        show(toast: Toast(message: Self.savedMessage(for: saved)))
        return saved
    }

    /// Soft-deletes one entry and offers Undo for as long as Undo is true.
    ///
    /// Reports through the toast rather than by throwing, unlike `save`: the sheet that
    /// saves is still open and still holding what the user typed, so an error belongs on
    /// it — a delete is one tap on a row that is already gone from under the finger, and
    /// the toast is the only surface left.
    func delete(_ event: EvaEvent) async {
        do {
            try await source.deleteEvent(id: event.id)
            remove(event.id, on: event.localDate)
            show(toast: Toast(
                message: "\(CalendarEntryPresentation.typeName(for: event.type)) deleted",
                restorable: event
            ))
        } catch let error as APIError {
            if case .sessionExpired = error { return }
            show(toast: Toast(message: error.localizedDescription))
        } catch {
            show(toast: Toast(message: APIError.decoding.localizedDescription))
        }
    }

    /// Whether Undo may still be offered for a soft-deleted entry (#50).
    ///
    /// **Asked every time, never cached.** A one-per-day entry lives at a document id
    /// derived from its day, so logging that day again does not add a second entry — it
    /// overwrites the deleted one. There is then nothing left to restore, and the API says
    /// so with `409 DAY_ALREADY_LOGGED`. The rule is not "has the user tapped save since":
    /// a re-fetch can bring in an entry another device wrote, and the button has to stop
    /// being offered for that too.
    func canRestore(_ event: EvaEvent) -> Bool {
        guard event.type.isOnePerDay else { return true }
        return !events(on: event.localDate).contains { $0.type == event.type }
    }

    /// Whether the toast on screen should be drawing its Undo button.
    var offersUndo: Bool {
        guard let restorable = toast?.restorable else { return false }
        return canRestore(restorable)
    }

    /// Undo. Brings a soft-deleted entry back and puts it on the grid again.
    ///
    /// The `DAY_ALREADY_LOGGED` arm is not defensive noise — it is the race the button
    /// cannot close on its own. `canRestore(_:)` answers from this device's cache, and
    /// another device can retake the day between the toast appearing and the tap. The
    /// server refuses, and the user is told what happened rather than left with a button
    /// that appeared to do nothing.
    func undoDelete() async {
        guard let event = toast?.restorable else { return }
        do {
            absorb(try await source.restoreEvent(id: event.id))
            show(toast: Toast(
                message: "\(CalendarEntryPresentation.typeName(for: event.type)) restored"
            ))
        } catch let error as APIError {
            if case .sessionExpired = error { return }
            show(toast: Toast(message: error.localizedDescription))
        } catch {
            show(toast: Toast(message: APIError.decoding.localizedDescription))
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    /// Puts a message on screen and takes it off again after `toastDuration`.
    ///
    /// The id is compared before clearing, so a toast that has already been replaced by a
    /// newer one cannot be dismissed by the older one's timer.
    private func show(toast newToast: Toast) {
        toastTask?.cancel()
        toast = newToast
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled, let self, self.toast?.id == newToast.id else { return }
            self.toast = nil
        }
    }

    /// What the toast says after a save. The canvas' own shape — what was logged, and the
    /// day it landed on — because a save that silently succeeds on the *wrong* day is the
    /// mistake this sentence exists to catch.
    private static func savedMessage(for event: EvaEvent) -> String {
        let day = event.localDate.formattingDate.formatted(
            EvaDay.formatStyle.day().month(.wide)
        )
        return "\(CalendarEntryPresentation.typeName(for: event.type)) saved to \(day)"
    }

    /// Files a server-returned entry into the day index, replacing whatever it supersedes.
    ///
    /// Three things are replaced, and each is a real case rather than a precaution:
    /// the same id anywhere (an edit, which for a sport or an appointment may also have
    /// moved the day); the day's existing entry of a one-per-day type (a re-log, which the
    /// server has already overwritten at rest); and nothing else. The day is then re-sorted
    /// by `loggedAt`, so the list reads in the order a fresh `GET /me/events` would return.
    private func absorb(_ event: EvaEvent) {
        for (day, entries) in eventsByDay where entries.contains(where: { $0.id == event.id }) {
            eventsByDay[day] = entries.filter { $0.id != event.id }
        }
        var day = eventsByDay[event.localDate] ?? []
        if event.type.isOnePerDay {
            day.removeAll { $0.type == event.type }
        }
        day.append(event)
        eventsByDay[event.localDate] = day.sorted {
            ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
        }

        // The account demonstrably has history now, whatever the first range said. Without
        // this the first entry a brand-new user logs would appear on a grid still telling
        // her to log her first period.
        hasHistory = true
        // The day detail follows what was just written, so the entry is on screen the
        // moment the sheet closes. The month is deliberately left alone: everything is
        // logged to the selected day, the selection always follows the page, and adjacent
        // months' cells are not tappable — so a write can never land outside the month
        // being drawn, and paging here would only be able to page somewhere unloaded.
        selectedDay = event.localDate
    }

    private func remove(_ id: String, on day: EvaDay) {
        eventsByDay[day] = (eventsByDay[day] ?? []).filter { $0.id != id }
    }

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

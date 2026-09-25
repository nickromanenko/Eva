import Foundation

/// Where the Home tab gets its card.
///
/// The same seam `CalendarEventSource` is, for the same reason and with the same single
/// conformance: `AppSession` owns the token and the 401 rule, and a second implementation
/// in app code would be a second way to talk to the API. It is a protocol so that the two
/// claims this screen actually makes — *a refresh that brings nothing new leaves the card
/// alone*, and *a read that fails leaves the card on screen* — can be tested as what the
/// model asks for and what it does with the answer, rather than through a stubbed
/// `URLSession` shared with every other suite in the target.
///
/// **It is also where the local store arrives.** ARCHITECTURE §8.1 says screens read the
/// store and only the sync engine talks to the API; #78 builds that store, and `LocalTodayCard`
/// is already reserved for this card, keyed by date. When it lands it becomes the
/// implementation of this protocol and `AppSession` moves behind the sync engine. Nothing
/// in `HomeModel` changes for it.
@MainActor
protocol TodayCardSource {
    /// The card for the user's local date. `GET /me/today?timeZone=` (#98).
    ///
    /// The zone, not the date: the server resolves "today" from it exactly as the events
    /// routes do (ARCHITECTURE §4's two kinds of time), and answers with the date it
    /// resolved. A device that sends its own date would be asserting the answer.
    func todayCard(timeZone: TimeZone) async throws -> EvaTodayResponse
}

extension AppSession: TodayCardSource {}

/// Where the Home tab gets the per-country emergency guidance table (#87).
///
/// A second seam beside `TodayCardSource` rather than a second method on it, because the
/// two facts have different half-lives: the card is generated once per day, the guidance
/// table is server-edited refdata — and the fixture source that seeds canvas states
/// (`SeededTodayCardSource`) answers cards and deliberately not guidance, which a shared
/// protocol would force it to fake.
@MainActor
protocol EmergencyGuidanceSource {
    /// The whole per-country table, or `nil` when it cannot be had. **Takes no country
    /// argument, on purpose**: which country resolves it is decided on this device
    /// (`EvaCountrySetting`) and is never sent to the server (LAUNCH §2.4). A parameter
    /// here would be the bug the acceptance criteria forbid.
    func emergencyGuidance() async -> [EvaRefData.EmergencyEntry]?
}

extension AppSession: EmergencyGuidanceSource {}

/// What the Home tab knows: the day's card, whether the last read reached the API, and
/// when it last did.
///
/// ## The one rule this type exists to keep
///
/// PRD §Dashboard, Other requirements 3: "The card is generated once per day and cached,
/// so it is available offline and does not change on repeated opens." Edge cases 5: "It
/// updates on new data, not on refresh."
///
/// The server half of that is D3's (a refresh with nothing new returns a byte-identical
/// document). The device half is `set(_:)` below: **state is only ever assigned when it
/// actually differs.** `@Observable` invalidates on every write, equal or not, so a model
/// that reassigned an identical card on each pull would re-render the screen and the rule
/// would be true of the bytes and false of the pixels. `cardRevision` is that rule made
/// readable — it counts card *replacements*, so a test can assert a refresh changed
/// nothing without asserting something about SwiftUI's diffing.
///
/// ## A failed read never empties the screen
///
/// #99: "a blank or a spinner never appears when a card exists". So a read that throws
/// leaves whatever is on screen exactly where it is, and only says so through the offline
/// bar. The error state is reachable only from the cold start, where there is nothing to
/// protect.
@MainActor
@Observable
final class HomeModel {

    /// What the Home tab has to draw.
    enum CardState: Equatable {
        /// Nothing read yet. The only state that shows a spinner, and unreachable once a
        /// card has been read once.
        case loading
        /// A card.
        case card(EvaTodayCard)
        /// The server answered, and has no card for this date. The honest cold start
        /// until `content/` is seeded (#97 refuses to seed copy nobody has signed off).
        case noCard
        /// Nothing to draw and the last read failed. Carries the API's own wording.
        case unavailable(String)
    }

    private(set) var state: CardState = .loading

    /// Whether the last read failed for want of a network.
    ///
    /// Only `APIError.network` sets it. A 500 or a body that will not decode is not being
    /// offline, and saying "offline" about either of them would be a guess about the
    /// user's connection.
    private(set) var isOffline = false

    /// When a read last landed. What the offline bar's timestamp states.
    ///
    /// The device's own sync time, not the card's `generatedAt` — the bar says "showing
    /// your cached briefing from 08:12", which is a claim about this copy, not about when
    /// the server wrote it.
    ///
    /// **It does not survive a launch yet.** The cache is this object, so a cold start
    /// with no network has no card and no timestamp and shows the cold-start state
    /// instead. #78's `LocalTodayCard` is what makes it outlive the process.
    private(set) var lastSyncedAt: Date?

    /// How many times the card has been *replaced*. See the type comment.
    private(set) var cardRevision = 0

    /// The local date the card on screen belongs to, as the server resolved it.
    private(set) var date: EvaDay?
    /// The `content/` version the card was filled from (#97). Recorded, not rendered.
    private(set) var contentVersion: String?

    /// The per-country emergency guidance table (#87), as `GET /refdata` served it this
    /// launch. Held **whole** — which country resolves it is decided at render time from
    /// `EvaCountrySetting`, so a country changed in Settings shows on the flag card the
    /// moment she comes back, without a refresh. `nil` while not yet read or when the
    /// read failed, which the card renders as "keep your own wording" — the neutral
    /// fallback sentence, not a blank escalation.
    private(set) var emergencyGuidance: [EvaRefData.EmergencyEntry]?

    /// The day's "Worth reading" rail (D7, #102). Empty means the section is not drawn.
    ///
    /// It belongs to the same stored document as the card, so it follows the card's rules
    /// exactly: replaced only when it differs, kept when a refresh fails, and kept when a
    /// same-day response arrives without a card — see `apply(_:)`. Like the card, it lives
    /// in this object until #78's store makes it outlive the process.
    private(set) var banners: [EvaTodayBanner] = []

    /// What labels the shortcuts row (D5, #100), or `nil` until a document has been read.
    ///
    /// Part of the same stored document as the card and the rail, so it follows their rules:
    /// replaced only when it differs, kept when a refresh fails, kept when a same-day response
    /// arrives without a card. `nil` rather than `.resting` before the first read so the
    /// screen can tell "the payload says meals are not set up" — which draws the setup card —
    /// from "nothing has been read yet", which must not flash one at someone who has set them
    /// up. The row itself is drawn either way, at rest.
    private(set) var shortcuts: EvaTodayShortcuts?

    var card: EvaTodayCard? {
        if case .card(let card) = state { return card }
        return nil
    }

    /// The offline bar is about a card being *cached*, so it only appears over one.
    /// Offline with nothing cached is the cold start, and `unavailable` says that instead.
    var showsOfflineBar: Bool { isOffline && card != nil }

    private let source: any TodayCardSource
    /// Where the guidance table comes from (#87). `nil` — the fixtures, previews, and
    /// every unit test that constructs a model without one — means the card renders
    /// exactly what the server sent, which is the neutral wording anyway.
    private let guidanceSource: (any EmergencyGuidanceSource)?
    /// Read per request, never captured: a user who flies somewhere else gets the card for
    /// the date her device now says, which is the same rule `localDate` follows.
    private let timeZone: @MainActor () -> TimeZone
    private let clock: @MainActor () -> Date
    /// Single-flight. A pull-to-refresh landing on top of the first load would race two
    /// writes into the same state.
    private var isReading = false

    init(
        source: any TodayCardSource,
        guidanceSource: (any EmergencyGuidanceSource)? = nil,
        timeZone: @escaping @MainActor () -> TimeZone = { .current },
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.source = source
        self.guidanceSource = guidanceSource
        self.timeZone = timeZone
        self.clock = clock
    }

    // MARK: - Loading

    /// The screen's first read. Idempotent — a second appearance re-uses what is in hand.
    func start() async {
        guard card == nil else { return }
        await read()
    }

    /// Pull-to-refresh, a return to the foreground, and midnight.
    ///
    /// Asks for a newer card. Whether one arrives is D3's answer, and whether the screen
    /// changes is `set(_:)`'s.
    ///
    /// A no-op while the very first read is still in flight: there is nothing to refresh
    /// yet, and `start()` is already doing it. A first read that *failed* is refreshable —
    /// that is the retry.
    func refresh() async {
        guard state != .loading || lastSyncedAt != nil else { return }
        await read()
    }

    private func read() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }

        do {
            let response = try await source.todayCard(timeZone: timeZone())
            lastSyncedAt = clock()
            isOffline = false
            apply(response)
        } catch let error as APIError {
            // A dead session is already being handled: `AppSession.authorized` has logged
            // out and the root view has switched away from this screen. Putting an error
            // on it on the way out would alarm someone who is simply being signed out.
            if case .sessionExpired = error { return }
            fail(with: error)
        } catch {
            fail(with: APIError.decoding)
        }

        await loadGuidanceIfNeeded()
    }

    /// The guidance table, once per launch of this model (#87).
    ///
    /// Read **after** the card, never instead of it: a failed guidance read is not an
    /// error state, it is the card keeping its own wording. Successful reads are not
    /// repeated — the table is refdata, and #78's cached copy is what makes a refresh
    /// cheaper than a re-fetch; until then one fetch per model lifetime is the same
    /// budget the calendar's catalogue lives on.
    private func loadGuidanceIfNeeded() async {
        guard emergencyGuidance == nil, let guidanceSource else { return }
        emergencyGuidance = await guidanceSource.emergencyGuidance()
    }

    private func fail(with error: APIError) {
        if case .network = error { isOffline = true } else { isOffline = false }
        // The card on screen stays on screen. Only a cold start has nothing to protect.
        guard card == nil else { return }
        set(.unavailable(error.localizedDescription))
    }

    private func apply(_ response: EvaTodayResponse) {
        let isNewDay = response.date != nil && response.date != date
        date = response.date ?? date
        contentVersion = response.contentVersion

        guard let incoming = response.card else {
            // **A refresh never empties a card.** "The card does not change on repeated
            // opens" cuts both ways: a response that has lost the card is not a reason to
            // take it off the screen. Rolling over to a new local date is, because that
            // day genuinely has no card yet.
            if card == nil || isNewDay {
                set(.noCard)
                setBanners(response.banners)
                setShortcuts(response.shortcuts)
            }
            return
        }
        set(.card(incoming))
        setBanners(response.banners)
        setShortcuts(response.shortcuts)
    }

    /// The shortcut facts' only writer, with the rail's equality guard.
    private func setShortcuts(_ new: EvaTodayShortcuts) {
        guard shortcuts != new else { return }
        shortcuts = new
    }

    /// The rail's only writer. The same equality guard as `set(_:)`, for the same reason:
    /// `@Observable` invalidates on every write, and a refresh with nothing new must not
    /// redraw the rail any more than the card.
    private func setBanners(_ new: [EvaTodayBanner]) {
        guard banners != new else { return }
        banners = new
    }

    /// The only writer of `state`, and the only place `cardRevision` moves.
    ///
    /// The equality guard is the rule, not an optimisation — see the type comment.
    private func set(_ new: CardState) {
        guard state != new else { return }
        state = new
        if case .card = new { cardRevision += 1 }
    }
}

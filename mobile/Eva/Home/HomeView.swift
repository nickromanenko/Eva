import SwiftUI

/// The Home tab — the first screen a signed-in user sees, and the Dashboard's first slice.
///
/// D4 (#99) draws the header, the offline bar and the Today card. The shortcut row (D5),
/// the nudge slot (D6), the banner rail (D7) and the glance row (D8) are drawn on the same
/// artboard and are **not** here; each is its own slice, and each hangs off this one.
///
/// ## What is on screen when there is no card
///
/// The card's words come from the `content/` collection, which #97 refuses to seed until a
/// clinician has signed the copy off. So "the server has no card for today" is not an edge
/// case on this screen — for now it is the common case, and it gets a state of its own
/// rather than a spinner that never resolves or a blank where a card should be.
///
/// Four states, and only one of them ever shows a spinner:
///
/// | State | On screen |
/// |---|---|
/// | first read in flight | a card-shaped surface with a spinner |
/// | a card | the card |
/// | read, no card for today | an information banner saying so |
/// | nothing read, and the read failed | §7's error card with Retry |
///
/// A failed read *never* replaces a card that is already up (#99: "a blank or a spinner
/// never appears when a card exists"); it puts the offline bar above it instead.
struct HomeView: View {

    let session: AppSession
    let router: EvaTabRouter

    @State private var model: HomeModel
    @Environment(\.scenePhase) private var scenePhase

    init(session: AppSession, router: EvaTabRouter) {
        self.session = session
        self.router = router
        #if DEBUG
        // `EVA_TODAY_CARD` seeds a canvas state so the states can be reviewed and tested
        // before `GET /me/today` exists. Absent — which is every build that is not a UI
        // test or a screenshot run — this is `session` and nothing below knows the
        // difference. See `EvaTodayCardLaunch`.
        _model = State(initialValue: HomeModel(source: EvaTodayCardLaunch.seeded ?? session))
        #else
        _model = State(initialValue: HomeModel(source: session))
        #endif
    }

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.md) {
                    HomeHeader(
                        email: session.user?.email,
                        openProfile: { router.show(.profile) }
                    )

                    if model.showsOfflineBar {
                        HomeOfflineBar(syncedAt: model.lastSyncedAt)
                    }

                    card

                    if session.user?.needsProfileNudge == true {
                        ProfileNudgeView(
                            onAddDetails: { router.show(.profile) },
                            onDismiss: {
                                // Optimistic: the server flag is what keeps it gone on the
                                // next device, and a failed write only means it may ask
                                // again — which is "takes no for an answer" at the API's
                                // best effort, never a block on anything else.
                                Task { try? await session.dismissProfileNudge() }
                            }
                        )
                    }
                }
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.xxs)
                .padding(.bottom, EvaSpacing.xxl)
            }
            // "Pull-to-refresh asks the sync engine for a newer card; the view re-renders
            // only when the store changes" (#99). The asking is here; the not-changing is
            // `HomeModel.set(_:)`, which is the only writer of the card and refuses an
            // equal value.
            .refreshable { await model.refresh() }
            // Every tab's screen stays alive in `EvaTabView`, so there are three scroll
            // views in the hierarchy at once and `app.scrollViews.firstMatch` is not
            // necessarily this one. The identifier is how `EvaUITests` pulls on the right
            // column (GUARDRAILS 22).
            .accessibilityIdentifier("home.scroll")
        }
        .task { await model.start() }
        // Coming back to the app asks again. D3 answers a byte-identical document when
        // nothing has changed, so this costs a request and never a redraw.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refresh() }
        }
        // Midnight and time-zone changes, the same signal the calendar re-reads "today"
        // from: the card is keyed by the user's local date, so crossing one invalidates it.
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification
            )
        ) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: - The card, or what stands in for it

    @ViewBuilder
    private var card: some View {
        switch model.state {
        case .loading:
            loadingCard
        case .card(let card):
            TodayCardView(card: card, perform: perform)
        case .noCard:
            noCardBanner
        case .unavailable(let message):
            failureBanner(message)
        }
    }

    /// The first read, before anything has arrived.
    ///
    /// A card-shaped surface rather than a bare spinner, so the screen does not jump when
    /// the card lands. Reachable only from a cold start — once a card exists, nothing
    /// returns here.
    private var loadingCard: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: Self.loadingCardHeight)
            .padding(EvaSpacing.lg)
            .evaCardSurface()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading today's card")
            .accessibilityIdentifier("home.loading")
    }

    /// Roughly the height of a two-line card, so the surface does not resize under the
    /// reader when the real one arrives. Not a canvas value — the canvas draws no loading
    /// state for this card (DESIGN.md §9c: skeletons are specified, none is built).
    private static let loadingCardHeight: CGFloat = 96

    /// The server answered and has nothing for today.
    ///
    /// **This copy is not on the canvas.** The artboard draws fourteen cards and no empty
    /// state for the card slot, because in the design there is always a card — `home_a` is
    /// the zero-data one. In the built system there is a second way to have none: the
    /// `content/` collection is empty until its copy is reviewed (#97), and a device
    /// cannot invent a card out of an empty store. So this states the fact and offers the
    /// one thing that is true — that logging is what Eva reads — without promising when a
    /// card will appear. Replace it with the canvas' words the moment it draws some.
    private var noCardBanner: some View {
        EvaInfoBanner(
            title: "No card for today yet",
            message: "Eva writes one a day from what you have logged. "
                + "Pull down to check again."
        ) {
            TextButton(title: "Open Calendar") { router.show(.calendar) }
        }
        .accessibilityIdentifier("home.noCard")
    }

    /// Nothing read, and the read failed.
    ///
    /// Information-toned rather than error-toned, for the reason the calendar's failed
    /// load is (DESIGN.md §9a): nothing the user did was wrong and nothing about her data
    /// changed — a request did not land.
    private func failureBanner(_ message: String) -> some View {
        EvaInfoBanner(title: "Today's card didn't load", message: message) {
            TextButton(title: "Try again") {
                Task { await model.refresh() }
            }
        }
        .accessibilityIdentifier("home.loadError")
    }

    /// Where a working card action goes.
    ///
    /// Only the two targets #99 names as built are handled; everything else is disabled at
    /// the button and never reaches here. `default` rather than an exhaustive list, so a
    /// target added later is inert here until it is deliberately wired.
    private func perform(_ target: EvaTodayCardTarget) {
        switch target {
        case .logPicker: router.openCalendarLogPicker()
        case .calendar: router.show(.calendar)
        default: break
        }
    }
}

#Preview {
    HomeView(session: AppSession(), router: EvaTabRouter())
}

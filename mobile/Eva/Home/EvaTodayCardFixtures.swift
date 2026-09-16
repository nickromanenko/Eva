#if DEBUG
import Foundation

/// The `EVA_TODAY_CARD` launch hook: seeds the Home tab with one canvas state.
///
/// ```sh
/// SIMCTL_CHILD_EVA_TODAY_CARD=home_b xcrun simctl launch --terminate-running-process <udid> com.evaapp.ios
/// ```
///
/// Same family as `EVA_ONBOARDING_STEP`, `EVA_UITEST_RESET` and `EVA_SPECIMEN`: read once
/// from `ProcessInfo`, DEBUG only, whole file inside `#if DEBUG` so a Release build has
/// neither the type nor the branch in `HomeView` that reads it.
///
/// ## Why the Home tab needs one at all
///
/// `GET /me/today` is D3 (#98) and does not exist, and the words it will serve come from a
/// `content/` collection #97 will not seed without a reviewer's name on the copy. So there
/// is no way to get any of the fourteen canvas states onto a screen — including the four
/// tones, two of which belong to a mode (D10) that is months away. #99 asks for a fixture
/// hook by name for exactly this reason, and it is what `EvaUITests` drives.
///
/// The fixtures are the canvas' own `CARDS` copy, with the slot values it draws already in
/// them, which is what a filled card from D3 will look like.
enum EvaTodayCardLaunch {

    /// Names one of `EvaTodayCardFixtures.all`, or `none` for "the server has a day but no
    /// card" — the cold start a device meets while `content/` is unseeded.
    static let environmentKey = "EVA_TODAY_CARD"

    /// `offline` makes every read after the first fail as if there were no network, which
    /// is the only way to reach the `home_off` bar from a UI test: a card has to land
    /// before it can be a *cached* card, and a test cannot take the network away mid-launch.
    static let refreshKey = "EVA_TODAY_REFRESH"

    private static let requestedState = ProcessInfo.processInfo.environment[environmentKey]
    private static let requestedRefresh = ProcessInfo.processInfo.environment[refreshKey]

    /// The seeded source, or `nil` when the variable is unset and the app should talk to
    /// the API like any other build.
    ///
    /// **One instance for the process**, not one per call. `HomeView.init` runs on every
    /// evaluation of `EvaTabView`'s body, and the source counts reads — a fresh one each
    /// time would reset that count, and `EVA_TODAY_REFRESH=offline`, which is "fail every
    /// read after the first", would quietly stop failing.
    @MainActor
    static let seeded: (any TodayCardSource)? = {
        guard let requestedState, !requestedState.isEmpty else { return nil }
        return SeededTodayCardSource(
            card: requestedState == "none" ? nil : EvaTodayCardFixtures.all[requestedState],
            goesOfflineAfterFirstRead: requestedRefresh == "offline"
        )
    }()
}

/// A `TodayCardSource` that answers from a fixture instead of the API.
///
/// It answers the **identical** card every time, which is what D3 promises for a day whose
/// data has not changed — so a pull-to-refresh against this source is the real "nothing
/// new" case and not a simulation of one.
@MainActor
final class SeededTodayCardSource: TodayCardSource {

    private let card: EvaTodayCard?
    private let goesOfflineAfterFirstRead: Bool
    private(set) var reads = 0

    init(card: EvaTodayCard?, goesOfflineAfterFirstRead: Bool = false) {
        self.card = card
        self.goesOfflineAfterFirstRead = goesOfflineAfterFirstRead
    }

    func todayCard(timeZone: TimeZone) async throws -> EvaTodayResponse {
        reads += 1
        if goesOfflineAfterFirstRead && reads > 1 { throw APIError.network }
        return EvaTodayResponse(
            date: EvaDay.today(in: timeZone),
            generatedAt: "seeded",
            contentVersion: "seeded",
            card: card
        )
    }
}

/// The canvas' fourteen cards, keyed by the artboard's rail key.
///
/// Verbatim from `CARDS` in `docs/design/Eva App.dc.html`, with the slot values the canvas
/// itself fills in. These are copies of the copy the `content/` collection will own (#97's
/// `TEMPLATES` holds the same strings with `{slots}` still in them) — they live here only
/// so that a state can be put on a screen before that collection is seeded, and they are
/// not user-facing in any build that ships.
enum EvaTodayCardFixtures {

    static let all: [String: EvaTodayCard] = [
        "home_d": EvaTodayCard(
            templateId: "phase_energy", rung: "phase",
            kicker: "Cycle day 13 · likely approaching ovulation",
            title: "Many women notice higher energy around now",
            line2: "This is a tendency across cycles, not a prediction about your day.",
            line3: "If that matches how you feel, a harder training session may be an option.",
            actions: [EvaTodayCardAction(label: "View cycle details")]
        ),
        "home_e": EvaTodayCard(
            templateId: "signal_overrides_phase", rung: "pattern",
            kicker: "Cycle day 13",
            title: "You logged low energy this morning after a poor night’s sleep",
            line2: "Although energy can be higher around this phase, your own log comes first.",
            line3: "Sleep, stress and iron affect daily energy more than cycle phase. "
                + "A lighter session may feel more manageable today.",
            actions: [EvaTodayCardAction(label: "Review this morning’s log")]
        ),
        "home_a": EvaTodayCard(
            templateId: "cold_start", rung: "setup",
            title: "Start with your first log",
            line2: "Log your period or today’s body signals so Eva can begin recognizing "
                + "patterns that are specific to you.",
            actions: [
                EvaTodayCardAction(label: "Log now"),
                EvaTodayCardAction(label: "Open Calendar")
            ]
        ),
        "home_b": EvaTodayCard(
            templateId: "still_learning", rung: "phase",
            kicker: "Cycle tracking · 1 of 3 cycles",
            title: "Eva is still learning your cycle",
            line2: "Log two more periods to help estimate your cycle phases more reliably. "
                + "Until then, no phase is shown.",
            actions: [EvaTodayCardAction(label: "Open Calendar")]
        ),
        "home_c": EvaTodayCard(
            templateId: "irregular", rung: "phase",
            kicker: "Cycle tracking",
            title: "Your current phase cannot be estimated reliably",
            line2: "Your recent cycle lengths vary significantly, so Eva will not show a "
                + "confident prediction.",
            actions: [EvaTodayCardAction(label: "View cycle history")]
        ),
        "home_f": EvaTodayCard(
            templateId: "late_period", rung: "pattern",
            kicker: "Cycle day 33",
            title: "Your period is later than predicted",
            line2: "Eva cannot determine the reason from cycle data alone.",
            actions: [
                EvaTodayCardAction(label: "Log period"),
                EvaTodayCardAction(label: "Log test")
            ]
        ),
        "home_g": EvaTodayCard(
            templateId: "signals_today", rung: "pattern",
            kicker: "Logged today",
            title: "You logged low energy and a headache today",
            line2: "A slower pace or additional rest may feel more appropriate.",
            actions: [EvaTodayCardAction(label: "Review what I logged")]
        ),
        "home_h": EvaTodayCard(
            templateId: "mood_pattern", rung: "pattern",
            kicker: "Pattern · last 3 days",
            title: "You’ve logged low mood for three consecutive days",
            line2: "Sleep has also been below your usual level during the same period. "
                + "Eva can see the pattern but not its cause.",
            line3: "Consider checking in with yourself, or talking it through with someone "
                + "you trust.",
            actions: [EvaTodayCardAction(label: "View pattern")]
        ),
        "home_edu": EvaTodayCard(
            templateId: "educational", rung: "education", tone: .edu,
            kicker: "Today’s read",
            title: "Why sleep can affect appetite more than willpower",
            line2: "Educational content, not personalized insight — nothing new in your "
                + "logs today.",
            meta: "Nutrition · 4 min read",
            actions: [EvaTodayCardAction(label: "Read article")]
        ),
        "home_plan": EvaTodayCard(
            templateId: "planning_window", rung: "phase",
            kicker: "Planning · cycle day 18",
            title: "Your fertile window most likely closed two days ago",
            line2: "Based on your last three cycles. Confidence is moderate — cycle lengths "
                + "varied by four days.",
            line3: "Two more logged cycles would narrow this estimate.",
            actions: [EvaTodayCardAction(label: "View window details")]
        ),
        "home_preg": EvaTodayCard(
            templateId: "pregnancy_appointment", rung: "milestone",
            kicker: "Pregnancy · week 20, day 2",
            title: "Your anatomy scan is scheduled for tomorrow, 09:15",
            line2: "Dr. Almeida · Santa Maria maternity unit.",
            line3: "Your saved questions are ready to review.",
            actions: [EvaTodayCardAction(label: "View appointment")]
        ),
        "home_flag": EvaTodayCard(
            templateId: "red_flag", rung: "flag", tone: .flag,
            kicker: "Logged 14:20 today",
            title: "You logged reduced fetal movement today",
            line2: "Contact your maternity provider or local urgent care service for "
                + "guidance. Eva cannot assess this.",
            actions: [
                EvaTodayCardAction(label: "View contact options"),
                EvaTodayCardAction(label: "Review what I logged")
            ]
        ),
        "home_post": EvaTodayCard(
            templateId: "postpartum_check", rung: "milestone",
            kicker: "Postpartum · day 42",
            title: "Your 6-week check is on Friday, 11:00",
            line2: "Recovery, feeding and mood can all be discussed at this appointment.",
            line3: "You can review your symptoms and prepare questions beforehand.",
            actions: [EvaTodayCardAction(label: "Prepare questions")]
        ),
        "home_loss": EvaTodayCard(
            templateId: "loss_ended", rung: "milestone", tone: .quiet,
            title: "Pregnancy tracking has ended",
            line2: "Your previous data remains private and can be reviewed or deleted "
                + "from Settings.",
            actions: [EvaTodayCardAction(label: "View support resources")]
        )
    ]
}
#endif

import Foundation

// The three facts the Dashboard's shortcuts row (D5, #100) is labelled from, as
// `GET /me/today` carries them beside the card.
//
// ## The device reads them; it never works them out
//
// #100, Risks: "A contextual label computed on the device from raw events duplicates C11's
// period boundaries in Swift, untestably. It comes from the payload or it is `Log`." So
// whether her period is running today is `periodOngoing` — C11's own boundary, computed on
// the server — and nothing here looks at an event. The same for the mode and for whether
// the Nutrition coach setup is finished.
//
// ## Tolerant, because the day's document can be older than this build — or this build older
// than the route
//
// D3 stores the document once a day and never rebuilds it to add a field, so a day stored
// before #100 answers `mode: "cycle"` and `null` for the other two. An API older than #100
// sends none of the three keys at all. Neither may fail the day's document: the card has to
// draw whatever the shortcuts know. So a key that is missing, `null`, or of the wrong type
// reads as the row's resting state — `Log`, `Set up meals` — which is what the contract
// asks `null` to mean.

/// The mode a day's card was built in (PRD §Modes). Only `postpartum` changes a label today.
enum EvaMode: String, Sendable, CaseIterable {
    case cycle
    case planning
    case pregnancy
    case postpartum
    case loss

    /// Absent or unrecognised means `cycle` — the mode every account is in until D10 stores
    /// one, and the one that labels nothing specially. A mode added on the server later must
    /// not blank the row.
    init(wireValue: String?) {
        self = wireValue.flatMap(EvaMode.init(rawValue:)) ?? .cycle
    }
}

/// What the shortcuts row knows about today.
struct EvaTodayShortcuts: Equatable, Sendable {
    let mode: EvaMode
    /// Whether her logged period is still running today — C11's `periodOngoing` (#100).
    /// `null` on the wire (a day stored before #100) reads as `false`.
    let periodOngoing: Bool
    /// Whether the Nutrition coach setup is finished (#221's `completedSetup`). `null` on the
    /// wire reads as `false`.
    let nutritionSetUp: Bool

    init(mode: EvaMode = .cycle, periodOngoing: Bool = false, nutritionSetUp: Bool = false) {
        self.mode = mode
        self.periodOngoing = periodOngoing
        self.nutritionSetUp = nutritionSetUp
    }

    /// The row's resting state: what it says when the payload says nothing.
    static let resting = EvaTodayShortcuts()

    // MARK: - Labels

    /// The first shortcut's label (PRD §Dashboard → Shortcuts 2).
    ///
    /// Postpartum wins over a running period: the PRD names the phase first, and the canvas
    /// labels `home_post` "Log feed" without asking about bleeding. Everything else that is
    /// not a running period is plain `Log`.
    var logLabel: String {
        if mode == .postpartum { return "Log feed" }
        if periodOngoing { return "Log period" }
        return "Log"
    }

    /// The second shortcut's label (PRD §Dashboard → Shortcuts 3): the feature when it is set
    /// up, and a prompt to set it up when it is not — never hidden.
    var mealsLabel: String {
        nutritionSetUp ? "Scan meal" : "Set up meals"
    }

    /// Whether the "Set up meal tracking" card is drawn below the row (`SPEC.home_setup`).
    var showsMealSetupCard: Bool { !nutritionSetUp }
}

extension EvaTodayShortcuts {

    /// Reads the three top-level keys of `GET /me/today` out of the response's container.
    ///
    /// `try?` on every read, deliberately: a wrong type is the same "the payload does not say"
    /// as a missing key, and must not throw the whole day's document away over a label.
    init<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        mode modeKey: Key,
        periodOngoing periodKey: Key,
        nutritionSetUp nutritionKey: Key
    ) {
        self.init(
            mode: EvaMode(wireValue: (try? container.decodeIfPresent(String.self, forKey: modeKey)) ?? nil),
            periodOngoing: ((try? container.decodeIfPresent(Bool.self, forKey: periodKey)) ?? nil) ?? false,
            nutritionSetUp: ((try? container.decodeIfPresent(Bool.self, forKey: nutritionKey)) ?? nil)
                ?? false
        )
    }
}

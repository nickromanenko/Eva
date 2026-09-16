import Foundation
import Testing
@testable import Eva

/// Issue #99: **the card is whatever D3 sent, read the way the canvas reads it.**
///
/// Two things are asserted here and neither is about pixels. First, the *decoding* — the
/// route does not exist, so every field below is a claim about a contract, and the tests
/// are what make the claims explicit enough to be wrong out loud when D3 lands. Second,
/// the two derivations the device is allowed to make from a card: which surface it draws
/// (`tone`) and where an action goes (`target`). Everything else on the screen is the
/// server's words, unaltered.
@Suite("Issue #99 · the Today card, as decoded and as routed")
struct TodayCardTests {

    private func decode(_ json: String) throws -> EvaTodayResponse {
        try JSONDecoder().decode(EvaTodayResponse.self, from: Data(json.utf8))
    }

    // MARK: - The contract

    @Test("The full body decodes: date, generatedAt, contentVersion and the card")
    func fullBodyDecodes() throws {
        let response = try decode("""
        {
          "date": "2026-08-18",
          "generatedAt": "2026-08-18T06:00:00.000Z",
          "contentVersion": "a1b2c3",
          "card": {
            "templateId": "phase_energy",
            "rung": "phase",
            "tone": "base",
            "kicker": "Cycle day 13 · likely approaching ovulation",
            "title": "Many women notice higher energy around now",
            "line2": "This is a tendency across cycles, not a prediction about your day.",
            "line3": "If that matches how you feel, a harder training session may be an option.",
            "actions": [{ "label": "View cycle details", "target": "cycleHistory" }]
          }
        }
        """)

        #expect(response.date == EvaDay(year: 2026, month: 8, day: 18))
        #expect(response.generatedAt == "2026-08-18T06:00:00.000Z")
        #expect(response.contentVersion == "a1b2c3")
        #expect(response.card?.templateId == "phase_energy")
        #expect(response.card?.rung == "phase")
        #expect(response.card?.actions.first?.target == .cycleHistory)
    }

    /// The state the app meets today: `content/` is unseeded (#97 refuses to seed copy
    /// nobody has signed off), so there is a day and no card. It has to decode as a state,
    /// not as a decoding failure.
    @Test("A day with no card decodes, whether the key is null or absent")
    func aMissingCardIsAState() throws {
        #expect(try decode(#"{"date":"2026-08-18","card":null}"#).card == nil)
        #expect(try decode(#"{"date":"2026-08-18"}"#).card == nil)
    }

    /// The device reads `timeZone`-resolved dates and has no business second-guessing one
    /// it cannot parse — but it must not treat an unreadable date as a *new* day either,
    /// which is what would replace a card on screen.
    @Test("A date that is not a date leaves the card readable and the date unknown")
    func anUnparseableDateIsNil() throws {
        let response = try decode(#"{"date":"2026-02-30","card":{"title":"Still a card"}}"#)
        #expect(response.date == nil)
        #expect(response.card?.title == "Still a card")
    }

    @Test("A card is only as much as its title: everything else is optional")
    func onlyTitleIsRequired() throws {
        let card = try #require(try decode(#"{"card":{"title":"Start with your first log"}}"#).card)
        #expect(card.title == "Start with your first log")
        #expect(card.kicker == nil)
        #expect(card.line2 == nil)
        #expect(card.line3 == nil)
        #expect(card.meta == nil)
        #expect(card.actions.isEmpty)
        #expect(card.tone == .base)
    }

    /// The canvas' `CARDS` holds actions as plain strings; #98 stores routing targets with
    /// them. Both readings are live until D3 ships, so both decode.
    @Test("Actions decode as plain strings and as { label, target }")
    func actionsDecodeBothShapes() throws {
        let strings = try #require(
            try decode(#"{"card":{"title":"t","actions":["Log now","Open Calendar"]}}"#).card
        )
        #expect(strings.actions.map(\.label) == ["Log now", "Open Calendar"])
        #expect(strings.actions.map(\.target) == [.logPicker, .calendar])

        let objects = try #require(
            try decode(#"""
            {"card":{"title":"t","actions":[{"label":"Somewhere new","target":"calendar"}]}}
            """#).card
        )
        // The server's target wins over anything the label would have implied.
        #expect(objects.actions.first?.target == .calendar)
    }

    // MARK: - Tone selection

    @Test("Each canvas tone decodes to its own surface")
    func tonesDecode() throws {
        for tone in EvaTodayCardTone.allCases {
            let card = try #require(
                try decode(#"{"card":{"title":"t","tone":"\#(tone.rawValue)"}}"#).card
            )
            #expect(card.tone == tone)
        }
    }

    /// The canvas omits `tone` on every `base` card and states it on three. An *unknown*
    /// value has to behave the same way: a tone is a surface, and refusing to draw a card
    /// because its surface has a name this build does not know would lose the words too.
    @Test("An absent or unrecognised tone is base, never a failure")
    func unknownToneFallsBackToBase() throws {
        #expect(try decode(#"{"card":{"title":"t"}}"#).card?.tone == .base)
        #expect(try decode(#"{"card":{"title":"t","tone":null}}"#).card?.tone == .base)
        #expect(try decode(#"{"card":{"title":"t","tone":"celebratory"}}"#).card?.tone == .base)
    }

    // MARK: - Routing

    /// The canvas' own routing table, transcribed — with the one widening its prototype
    /// left open: it sends a `Log…` label to the picker only at index 0, which strands
    /// `home_f`'s "Log test". #99 names all three, so the rule is the label.
    @Test(
        "A label routes where the canvas sends it",
        arguments: [
            ("Log now", EvaTodayCardTarget.logPicker),
            ("Log period", .logPicker),
            ("Log test", .logPicker),
            ("Open Calendar", .calendar),
            ("View cycle details", .cycleHistory),
            ("View cycle history", .cycleHistory),
            ("View window details", .cycleHistory),
            ("View pattern", .cycleHistory),
            ("View contact options", .contactOptions),
            ("View support resources", .supportResources),
            ("Review what I logged", .loggedDay),
            ("Review this morning’s log", .loggedDay),
            ("Read article", .article),
            ("View appointment", .unknown),
            ("Prepare questions", .unknown)
        ]
    )
    func labelsRoute(label: String, expected: EvaTodayCardTarget) {
        #expect(EvaTodayCardAction(label: label).target == expected)
    }

    /// #99, from the epic: everything that opens a screen the canvas has not drawn (review
    /// G7) is rendered and **disabled** until D11 builds it. Only two targets are live, and
    /// they are live by name rather than by exception — so a target added later starts off.
    @Test("Only the calendar and the log picker are reachable today")
    func onlyTheBuiltTargetsAreAvailable() {
        let available = EvaTodayCardTarget.allCases.filter(\.isAvailable)
        #expect(Set(available) == [.logPicker, .calendar])
    }

    /// Every action on every canvas card, checked against the two rules together: the ones
    /// #99 names as working work, and every `View …` / `Review …` / `Read article` does not.
    @Test("Across the fourteen canvas cards, exactly the logging and calendar actions work")
    func theCanvasCardsRouteAsSpecified() {
        let working = ["Log now", "Log period", "Log test", "Open Calendar"]
        for (state, card) in EvaTodayCardFixtures.all {
            for action in card.actions {
                #expect(
                    action.isAvailable == working.contains(action.label),
                    "\(state): \(action.label) is \(action.isAvailable ? "" : "not ")available"
                )
            }
        }
    }

    // MARK: - One readable block

    /// The canvas' `aria` string, character for character:
    /// `'Today. ' + (kicker ? kicker + '. ' : '') + title + '. ' + line2 + (line3 ? ' ' + line3 : '')`
    @Test("The accessibility label is the canvas' aria string")
    func accessibilityLabelIsTheAriaString() {
        #expect(EvaTodayCard.phaseFixture.accessibilityLabel == """
        Today. Cycle day 13 · likely approaching ovulation. Many women notice higher energy \
        around now. This is a tendency across cycles, not a prediction about your day. If \
        that matches how you feel, a harder training session may be an option.
        """)
    }

    @Test("A card with no kicker and no third line still reads as one sentence")
    func accessibilityLabelSkipsWhatIsNotThere() {
        #expect(EvaTodayCard.coldStartFixture.accessibilityLabel == """
        Today. Start with your first log. Log your period or today’s body signals so Eva \
        can begin recognizing patterns that are specific to you.
        """)
    }

    /// `home_loss` carries `kicker: ''` on the canvas — an empty string, not an absent one.
    /// Announcing "Today. . Pregnancy tracking has ended." would be the fragment reading
    /// the single-block rule exists to prevent.
    @Test("An empty kicker contributes nothing to the announcement")
    func anEmptyKickerIsNotAnnounced() throws {
        let loss = try #require(EvaTodayCardFixtures.all["home_loss"])
        #expect(loss.kicker == nil || loss.kicker?.isEmpty == true)
        #expect(!loss.accessibilityLabel.contains(". ."))
    }

    // MARK: - Tone and framing (PRD §Dashboard, quoted in #99)

    /// "With fewer than 3 logged cycles the card does not estimate a phase. It states what
    /// is needed instead" · "With irregular cycles the card says the phase cannot be
    /// estimated reliably" · "`home_a` and `home_g` never show a phase".
    ///
    /// The device adds no copy, so the check is that the cold-start cards carry no phase
    /// word — and it is a check of the fixtures because the fixtures are the canvas' copy.
    @Test("No cold-start card names a cycle phase", arguments: ["home_a", "home_b", "home_c", "home_g"])
    func coldStartCardsNameNoPhase(state: String) throws {
        let card = try #require(EvaTodayCardFixtures.all[state])
        let words = [card.kicker, card.title, card.line2, card.line3, card.meta]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        for phase in ["follicular", "luteal", "ovulation", "ovulating", "menstrual"] {
            #expect(!words.contains(phase), "\(state) names the \(phase) phase")
        }
    }

    /// "No comparison to other users, no scores for the person, no streaks." `home_b`'s
    /// "1 of 3 cycles" is a kicker and stays one — there is no percentage, no ring and no
    /// count of days in a row anywhere in the card model, because there is no field that
    /// could carry one.
    @Test("No canvas card carries a score, a percentage or a streak")
    func noCardScoresAnybody() {
        for (state, card) in EvaTodayCardFixtures.all {
            let words = [card.kicker, card.title, card.line2, card.line3, card.meta]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            for forbidden in ["streak", "score", "%", "in a row", "keep it up"] {
                #expect(!words.contains(forbidden), "\(state) contains \"\(forbidden)\"")
            }
        }
    }
}

import Foundation

// The Dashboard's daily card, as `GET /me/today` will hand it over.
//
// ## This is written against a contract, not against a running route
//
// D3 (#98) builds `GET /me/today?timeZone=` and answers
// `{ date, generatedAt, contentVersion, card }`. It does not exist yet, so everything
// below is the **client half of a contract that has one written half** — #98's own
// acceptance criteria ("the stored card holds only the filled text, template id, rung and
// routing targets") and #97's `Template`, whose field names are the canvas' `CARDS`
// entries verbatim: `kicker`, `title`, `line2`, `line3`, `meta`, `actions`, `tone`.
//
// Where the two written halves leave a choice, the decoding below takes **both** readings
// rather than betting on one:
//
//   * `card` may be absent or `null`. A day with no card is a real state (the `content/`
//     collection is unseeded until a clinician signs the copy off — #97 refuses to seed
//     without a reviewer), so it is decoded as a state and not as an error.
//   * `actions` may arrive as the canvas' plain strings, or as `{ label, target }` objects
//     once D3 stores routing targets. Both decode; a string-only action derives its target
//     from its label, using the canvas' own routing rules.
//   * `tone` may be absent. The canvas omits it on every `base` card and states it on
//     three, so absent means `base`, and an unrecognised value means `base` too — an
//     unknown tone must not blank the card.
//   * `templateId` and `rung` are optional here. #98 stores them; nothing on this screen
//     reads them, and requiring a field the device does not use would fail a decode over
//     something invisible.
//
// Nothing here is logged, ever. A filled card is a sentence about a user's cycle and
// symptoms — health data under GUARDRAILS 12, exactly like an event payload.

/// The body of `GET /me/today`.
struct EvaTodayResponse: Equatable, Sendable {
    /// The user's local date the card is for, as the server resolved it from the request's
    /// `timeZone`. `nil` when it could not be parsed — the device then keeps the date it
    /// already had rather than treating an unreadable field as a new day.
    let date: EvaDay?
    /// When the card was generated, verbatim from the server. Never parsed: the offline
    /// bar states when **this device** last synced, which is a different question, and
    /// `EvaEvent.loggedAt` sets the precedent of carrying a server instant as a string.
    let generatedAt: String?
    /// The `content/` version the card's words were filled from (#97).
    let contentVersion: String?
    /// The card, or `nil` when the server has none for that date.
    let card: EvaTodayCard?
    /// The day's "Worth reading" rail (D7, #102), in display order. Empty — never `nil` —
    /// when the server sent none, sent no key at all, or sent nothing openable; see
    /// `EvaTodayBanner` for what is dropped.
    let banners: [EvaTodayBanner]

    init(
        date: EvaDay?,
        generatedAt: String? = nil,
        contentVersion: String? = nil,
        card: EvaTodayCard?,
        banners: [EvaTodayBanner] = []
    ) {
        self.date = date
        self.generatedAt = generatedAt
        self.contentVersion = contentVersion
        self.card = card
        self.banners = banners
    }
}

extension EvaTodayResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case date, generatedAt, contentVersion, card, banners
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try container.decodeIfPresent(String.self, forKey: .date)
                .flatMap(EvaDay.init(isoDate:)),
            generatedAt: try container.decodeIfPresent(String.self, forKey: .generatedAt),
            contentVersion: try container.decodeIfPresent(String.self, forKey: .contentVersion),
            card: try container.decodeIfPresent(EvaTodayCard.self, forKey: .card),
            // Tolerant by construction: a missing key, a `null` or a malformed item never
            // fails the day's document — the card must still draw (#102).
            banners: EvaTodayBanner.rail(from: container, forKey: .banners)
        )
    }
}

/// One day's card: the words D3 filled, and where its actions go.
///
/// **The device adds no copy of its own.** Every string on the card comes from here, which
/// is the mechanism behind PRD §Dashboard's "the card must never generate a
/// personalised-sounding message from data the app does not have" — a state with no phase
/// has no phase line because the server sent none, not because a branch here suppressed it.
struct EvaTodayCard: Equatable, Sendable {
    /// Which `content/` template was filled. Recorded, not rendered.
    let templateId: String?
    /// Which rung of the priority ladder chose it. Recorded, not rendered.
    let rung: String?
    /// Which of the canvas' four card surfaces to draw.
    let tone: EvaTodayCardTone
    /// The overline above the title, when the card has one.
    let kicker: String?
    let title: String
    let line2: String?
    /// The suggestion line, which `base` and `flag` draw on a tinted surface of their own.
    let line3: String?
    /// The category-and-reading-time line the educational card carries.
    let meta: String?
    let actions: [EvaTodayCardAction]

    init(
        templateId: String? = nil,
        rung: String? = nil,
        tone: EvaTodayCardTone = .base,
        kicker: String? = nil,
        title: String,
        line2: String? = nil,
        line3: String? = nil,
        meta: String? = nil,
        actions: [EvaTodayCardAction] = []
    ) {
        self.templateId = templateId
        self.rung = rung
        self.tone = tone
        self.kicker = kicker
        self.title = title
        self.line2 = line2
        self.line3 = line3
        self.meta = meta
        self.actions = actions
    }

    /// What VoiceOver reads for the whole card — the canvas' own `aria` string:
    ///
    /// ```js
    /// 'Today. ' + (kicker ? kicker + '. ' : '') + title + '. ' + line2 + (line3 ? ' ' + line3 : '')
    /// ```
    ///
    /// PRD §Dashboard, Accessibility: "the card is a single readable block, not a set of
    /// decorative fragments". `meta` is deliberately **not** in it, because the canvas
    /// leaves it out — the educational card's "Nutrition · 4 min read" is a label on the
    /// surface rather than part of the sentence.
    var accessibilityLabel: String {
        var parts = ["Today."]
        if let kicker, !kicker.isEmpty { parts.append("\(kicker).") }
        parts.append("\(title).")
        if let line2, !line2.isEmpty { parts.append(line2) }
        if let line3, !line3.isEmpty { parts.append(line3) }
        return parts.joined(separator: " ")
    }

    /// The card as the screen draws it, with a flag card's guidance line replaced by the
    /// per-country emergency wording (#87) — or unchanged, when there is none to apply.
    ///
    /// **The one place the device may swap a word the server sent**, and the exception
    /// that proves the rule above: the replacement words are not written in the app, they
    /// come from the `refdata/` emergency-guidance table the server serves — the same
    /// kind of server-owned copy every chip label comes from. What the device contributes
    /// is *which country's row* resolves, from a setting that never leaves the device
    /// (LAUNCH §2.4). The card keeps its own line when the table has not arrived, when
    /// the resolved entry carries no wording, or when this is not a flag card — an
    /// escalation card without a table says the neutral sentence the template already
    /// carries, which is the fallback row's sentence byte for byte.
    func withFlagGuidance(_ wording: String?) -> EvaTodayCard {
        guard tone == .flag, let wording, !wording.isEmpty else { return self }
        return EvaTodayCard(
            templateId: templateId,
            rung: rung,
            tone: tone,
            kicker: kicker,
            title: title,
            line2: wording,
            line3: line3,
            meta: meta,
            actions: actions
        )
    }
}

extension EvaTodayCard: Decodable {
    private enum CodingKeys: String, CodingKey {
        case templateId, rung, tone, kicker, title, line2, line3, meta, actions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            templateId: try container.decodeIfPresent(String.self, forKey: .templateId),
            rung: try container.decodeIfPresent(String.self, forKey: .rung),
            tone: EvaTodayCardTone(
                wireValue: try container.decodeIfPresent(String.self, forKey: .tone)
            ),
            kicker: try container.decodeIfPresent(String.self, forKey: .kicker),
            title: try container.decode(String.self, forKey: .title),
            line2: try container.decodeIfPresent(String.self, forKey: .line2),
            line3: try container.decodeIfPresent(String.self, forKey: .line3),
            meta: try container.decodeIfPresent(String.self, forKey: .meta),
            actions: try container.decodeIfPresent([EvaTodayCardAction].self, forKey: .actions) ?? []
        )
    }
}

/// The four card surfaces the canvas draws (`CARDS` → `surf`).
///
/// `flag` and `quiet` belong to mode states D10 supplies the data for. They are built
/// here anyway, on #99's own instruction: a tone that only D10 can reach is a tone nothing
/// exercises until D10, and by then a regression in it is months old.
enum EvaTodayCardTone: String, Sendable, CaseIterable {
    /// The everyday card: the §4 glass surface, pink kicker.
    case base
    /// "Today's read" — pistachio, so an educational fallback is never mistaken for a
    /// personal insight (`SPEC.home_edu`).
    case edu
    /// A red-flag symptom. `SPEC.home_flag`: "Calm amber treatment, no decorative
    /// gradient, no diagnosis and no reassurance."
    case flag
    /// After a pregnancy ends. Flat, unsaturated, no gradient — `SPEC.home_loss` asks for
    /// "no celebratory or recovery assumptions", and that includes the surface.
    case quiet

    /// Absent, unknown or misspelled all mean `base`.
    ///
    /// A tone is a *surface*, not a claim: rendering an unrecognised one as the everyday
    /// card shows the words, where refusing to decode would show nothing at all.
    init(wireValue: String?) {
        self = wireValue.flatMap(EvaTodayCardTone.init(rawValue:)) ?? .base
    }
}

/// One action under the card: what it says, and where it goes.
struct EvaTodayCardAction: Equatable, Sendable {
    let label: String
    let target: EvaTodayCardTarget

    init(label: String, target: EvaTodayCardTarget? = nil) {
        self.label = label
        self.target = target ?? EvaTodayCardTarget(derivedFrom: label)
    }

    /// Whether this action reaches a screen that exists today.
    ///
    /// #99, from the epic: every `View …` / `Review …` / `Read article` action opens a
    /// screen the canvas has not drawn (review G7), so it is **rendered and disabled**
    /// until D11 builds it. Drawing it is the point — a card whose only action is hidden
    /// reads as a card with nothing to do.
    var isAvailable: Bool { target.isAvailable }
}

extension EvaTodayCardAction: Decodable {
    private enum CodingKeys: String, CodingKey { case label, target }

    /// Decodes either the canvas' plain string or D3's `{ label, target }`.
    init(from decoder: any Decoder) throws {
        if let label = try? decoder.singleValueContainer().decode(String.self) {
            self.init(label: label)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decode(String.self, forKey: .label),
            target: try container.decodeIfPresent(String.self, forKey: .target)
                .flatMap(EvaTodayCardTarget.init(rawValue:))
        )
    }
}

/// Where a card action leads.
///
/// Two of these reach a screen that exists; the rest name a screen D11 builds, and are
/// here so that a disabled button can say *which* screen it is waiting for rather than
/// being an anonymous dead control.
enum EvaTodayCardTarget: String, Sendable, CaseIterable {
    /// The calendar's log picker, on the selected day.
    case logPicker
    /// The Calendar tab.
    case calendar
    /// Cycle history / cycle details / fertile-window details — one screen on the canvas
    /// (`cycleHistory`), three labels pointing at it. D11.
    case cycleHistory
    /// Contact options for a red flag. D11.
    case contactOptions
    /// Support resources after a pregnancy ends. D11.
    case supportResources
    /// What was logged, on the day it was logged. D11 — the calendar's day detail is
    /// close, but "review this morning's log" is a screen the canvas draws separately.
    case loggedDay
    /// An article in Learn. D7/D11.
    case article
    /// A label this build does not recognise. Rendered, disabled, and never guessed at.
    case unknown

    /// True only where the destination is built.
    ///
    /// `logPicker` and `calendar` are the two #99 names as working. Everything else is
    /// false **by construction** rather than by a list of exceptions, so a target added
    /// later starts disabled and has to be turned on deliberately.
    var isAvailable: Bool {
        switch self {
        case .logPicker, .calendar: true
        case .cycleHistory, .contactOptions, .supportResources, .loggedDay, .article, .unknown:
            false
        }
    }

    /// What a disabled action says after its label, so the reason is spoken and not only
    /// implied by the dimming.
    static let unavailableSuffix = "Not available yet."

    /// The canvas' own routing, from a label alone.
    ///
    /// Read off `card.actions[].onClick` in "Eva App.dc.html", with **one widening**: the
    /// canvas routes a `Log…` label to the picker only at index 0, which leaves
    /// `home_f`'s second action ("Log test") falling through to its catch-all toast. #99
    /// names all three — `Log now` / `Log period` / `Log test` — as opening the picker, so
    /// the rule here is the label, not the position.
    ///
    /// This is the fallback for a card that arrives with plain-string actions. Once D3
    /// stores routing targets, the server's target wins and nothing below runs.
    init(derivedFrom label: String) {
        let text = label.lowercased()
        if text == "log" || text.hasPrefix("log ") {
            self = .logPicker
        } else if text.contains("calendar") {
            self = .calendar
        } else if text.contains("cycle") || text.contains("window") || text.contains("pattern") {
            self = .cycleHistory
        } else if text.contains("contact") {
            self = .contactOptions
        } else if text.contains("support") {
            self = .supportResources
        } else if text.contains("logged") || text.hasSuffix("log") {
            self = .loggedDay
        } else if text.contains("article") {
            self = .article
        } else {
            self = .unknown
        }
    }
}

import SwiftUI

/// The Today card — the one thing the Dashboard is for.
///
/// ## One subject, three lines, and nothing this file decides
///
/// PRD §Dashboard → Composition: three lines maximum, one subject. Every string drawn
/// here comes from the card; there is no branch that adds a sentence, softens one or
/// supplies a fallback. That is what makes "the card must never generate a
/// personalised-sounding message from data the app does not have" a property of the screen
/// rather than a promise about it — `home_a` shows no phase line because the server sent
/// none.
///
/// ## Accessibility: one block, and buttons that are still buttons
///
/// The canvas draws `role="group" aria-label="{{ card.aria }}"` around the whole card.
/// The text is collapsed into **one** element carrying that string, and the actions are
/// left as siblings: a group label plus reachable children is what the canvas means, and a
/// single leaf element spanning the buttons would make them unreachable. PRD §Dashboard,
/// Accessibility: "the card is a single readable block, not a set of decorative fragments".
///
/// ## The actions are §5's buttons, not the artboard's pills
///
/// The artboard draws them at `min-height:46px;border-radius:15px;font:600 13.5px`, which
/// matches no §5 variant. #160 hit the same thing with the day-detail Edit and Delete
/// buttons and took §5's standard 52/17; so does this. A §5 button is full width, so the
/// row the artboard draws becomes a column — which is also the only arrangement in which
/// "View contact options" and "Review what I logged" both fit without truncating.
///
/// The first action takes the primary style and the rest the secondary, which is the
/// artboard's own `i === 0` rule — **but only when the first action works.** Enablement
/// comes from the action's target: everything that opens a screen D11 has not built is
/// disabled (#99), and a disabled §5 primary is a full-width 28%-pink slab that becomes
/// the loudest thing on the card. On `home_d`, whose one action is `View cycle details`,
/// that paints a dead control as the screen's call to action; on `home_flag` it paints a
/// pink one onto an amber card. So an unavailable action takes the secondary style
/// wherever it sits. Nine of the fourteen canvas cards have no working action at all, so
/// this is the common case rather than a corner of it.
struct TodayCardView: View {

    let card: EvaTodayCard
    /// The red-flag card's guidance line, resolved on the device from the per-country
    /// emergency table (#87) — the `refdata/` wording for the country this device shows.
    /// `nil` keeps the card's own line; see `EvaTodayCard.withFlagGuidance` for the one
    /// rule this parameter rides on.
    var flagGuidance: String? = nil
    /// Called for an action that has somewhere to go. Never called for a disabled one.
    let perform: (EvaTodayCardTarget) -> Void

    var body: some View {
        // The one substitution the device may make (#87), applied once so the drawn card
        // and the string VoiceOver reads cannot disagree about the guidance line.
        let shown = card.withFlagGuidance(flagGuidance)
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            block(shown)
            if !shown.actions.isEmpty { actions(shown) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.lg)
        .modifier(EvaTodayCardSurface(tone: shown.tone))
    }

    // MARK: - The words

    /// Kicker, title, line 2, the suggestion and the meta line — one accessibility element
    /// labelled with the canvas' `aria` string.
    private func block(_ card: EvaTodayCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kicker = card.kicker, !kicker.isEmpty {
                kickerPill(kicker)
                    .padding(.bottom, EvaSpacing.sm)
            }

            Text(card.title)
                // `font:600 19.5px/1.32` — 25.7pt of line box, which is H2's 26 almost
                // exactly. §3 has no 19.5 row; H2 (21/600) is 1.5pt away and H3 (17/600)
                // is 2.5, and this is the hero line of the screen rather than a heading
                // inside a list. Same trade the calendar's month header took (§9a).
                .evaTextStyle(.h2)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let line2 = card.line2, !line2.isEmpty {
                Text(line2)
                    // `font:400 14px/1.6`. Body (15/24) is the nearest row.
                    .evaTextStyle(.body)
                    // `#4F464B`, which is not a token. It sits between Primary Text
                    // (`#282126`) and Secondary (`#6F656B`); Secondary is the nearer of
                    // the two and is what the rest of the app puts under a heading.
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }

            if let line3 = card.line3, !line3.isEmpty {
                suggestion(line3)
                    .padding(.top, EvaSpacing.sm)
            }

            if let meta = card.meta, !meta.isEmpty {
                Text(meta)
                    // `font:500 11.5px` — the same value the calendar legend maps onto
                    // Caption (12.5/19).
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .padding(.top, EvaSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityIdentifier("home.card")
    }

    /// The overline above the title, on a tinted pill.
    ///
    /// Uppercase at the call site, as `EvaTextStyle.overline` documents: casing is a string
    /// decision. The artboard's `.1em` tracking takes the scale's `.14em` with it.
    private func kickerPill(_ kicker: String) -> some View {
        Text(kicker.uppercased())
            .evaTextStyle(.overline)
            .foregroundStyle(card.tone.kickerInk)
            .padding(EvaHomeMetrics.kickerPadding)
            .background {
                if let fill = card.tone.kickerFill {
                    RoundedRectangle(
                        cornerRadius: EvaHomeMetrics.kickerRadius, style: .continuous
                    )
                    .fill(fill)
                }
            }
    }

    /// Line 3 — the optional suggestion.
    ///
    /// `base` and `flag` put it on a tinted surface of its own; `edu` and `quiet` run it on
    /// as another paragraph. The artboard draws it half a point smaller than line 2 (13.5
    /// against 14), which is below what the §3 scale can express and below what the eye
    /// reads as a step — the *surface* is what separates them, so both take Body.
    private func suggestion(_ line3: String) -> some View {
        Text(line3)
            .evaTextStyle(.body)
            .foregroundStyle(Color.evaSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(card.tone.suggestionFill == nil ? EdgeInsets() : EvaHomeMetrics.suggestionPadding)
            .background {
                if let fill = card.tone.suggestionFill {
                    let shape = RoundedRectangle(
                        cornerRadius: EvaHomeMetrics.suggestionRadius, style: .continuous
                    )
                    shape.fill(fill)
                        .overlay {
                            if let border = card.tone.suggestionBorder {
                                shape.strokeBorder(border, lineWidth: 1)
                            }
                        }
                }
            }
    }

    // MARK: - The actions

    private func actions(_ card: EvaTodayCard) -> some View {
        VStack(spacing: EvaSpacing.xs) {
            ForEach(Array(card.actions.enumerated()), id: \.offset) { index, action in
                button(action, isPrimary: index == 0)
            }
        }
    }

    @ViewBuilder
    private func button(_ action: EvaTodayCardAction, isPrimary: Bool) -> some View {
        let tap = { perform(action.target) }
        Group {
            // The artboard's `i === 0`, narrowed to an action that can be taken — see the
            // type comment.
            if isPrimary && action.isAvailable {
                PrimaryButton(title: action.label, action: tap)
            } else {
                SecondaryButton(title: action.label, action: tap)
            }
        }
        .disabled(!action.isAvailable)
        // The reason is spoken, not only dimmed. A disabled control announces itself as
        // dimmed and says nothing about *why*; #99 asks the label to carry it, which is
        // the same trade the log picker's unavailable rows took.
        .accessibilityLabel(
            action.isAvailable
                ? Text(action.label)
                : Text("\(action.label). \(EvaTodayCardTarget.unavailableSuffix)")
        )
    }
}

// MARK: - The four surfaces

/// The card's surface, per tone.
///
/// ## Each tone is the §4 card plus a §2 semantic treatment
///
/// The artboard gives all four tones their own fill, border and shadow (`CARDS` → `surf`).
/// Read straight, that is four bespoke surfaces; read against the token set, it is one
/// surface — §4's standard card — wearing three of §2's semantic tints:
///
/// | Tone | Artboard | Here |
/// |---|---|---|
/// | `base` | `linear-gradient(155deg,#fff .9,#fff .74)`, `#fff .95` border | §4's card, untinted |
/// | `edu` | `rgba(237,246,218,.94)`, `rgba(142,173,86,.32)` border | Light Pistachio tint, `evaSuccessBorder` (exact) |
/// | `flag` | `rgba(255,247,235,.97)`, `rgba(201,145,63,.55)` border 1.5px | `evaWarningTint`, `evaWarningBorder` at 1.5pt |
/// | `quiet` | `rgba(255,255,255,.86)`, `rgba(40,33,38,.08)` border | untinted, `evaControlBorder` |
///
/// Taking §4's card as the base costs the artboard's 155° / .9→.74 gradient and its .95
/// hairline — §4 draws 150° / .66→.36 and .72 — and it is worth it: the alternative is a
/// fifth card surface in a codebase that has one, differing from it in three properties
/// none of which is what makes a card an educational card or a red flag. The rule is
/// `ProfileView`'s and the calendar's: the nearest named value, and the difference reported.
///
/// The shadow stays **neutral** in every tone, where the artboard draws all four pink or
/// amber. That is #12 and DESIGN.md §9a, and it applies here for the reason it applies
/// everywhere: a saturated shadow under a translucent card is sampled *through* the card
/// by `Material`, so it tints the surface as well as ringing it.
private struct EvaTodayCardSurface: ViewModifier {

    let tone: EvaTodayCardTone

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
        return content
            // Behind the content and, because `evaCardSurface` attaches further back
            // still, in front of the card's own white gradient. A tone is a wash over the
            // surface, not a replacement for it.
            .background { shape.fill(tone.surfaceTint) }
            .evaCardSurface(in: shape)
            .overlay {
                if let border = tone.surfaceBorder {
                    shape.strokeBorder(border, lineWidth: tone.surfaceBorderWidth)
                }
            }
    }
}

extension EvaTodayCardTone {

    /// The wash over §4's card. Clear where the artboard draws no colour of its own.
    var surfaceTint: AnyShapeStyle {
        switch self {
        // `linear-gradient(155deg, rgba(255,255,255,.9), rgba(255,255,255,.74))`. The
        // artboard's own stops, on §4's 150°. **Not `.clear`** — §4's card is 66% → 36%
        // white over a `Material`, and at that opacity the material's own grey shows
        // through and the hero card of the app reads *darker* than the ground it sits on,
        // where the canvas draws it brighter. That is #60 seen at its worst, and this is
        // not a fix for it: it is the artboard's fill, which happens to be opaque enough
        // that the material stops deciding the colour.
        case .base:
            AnyShapeStyle(LinearGradient(
                colors: [Color.white.opacity(0.9), Color.white.opacity(0.74)],
                startPoint: UnitPoint(x: 0.159, y: -0.092),
                endPoint: UnitPoint(x: 0.841, y: 1.092)
            ))
        // `linear-gradient(155deg, rgba(237,246,218,.94), rgba(255,255,255,.8))` — the
        // artboard's own two stops, on §4's 150° rather than its 155°, so the tone sits on
        // the same diagonal as every other card in the app. Light Pistachio is the exact
        // hue; both alphas are the artboard's.
        case .edu:
            AnyShapeStyle(LinearGradient(
                colors: [Color.evaLightPistachio.opacity(0.94), Color.white.opacity(0.8)],
                // The same unit points `EvaCardSurfaceModifier` derives for 150°.
                startPoint: UnitPoint(x: 0.159, y: -0.092),
                endPoint: UnitPoint(x: 0.841, y: 1.092)
            ))
        // `rgba(255,247,235,.97)` → `rgba(255,250,244,.92)` — two warm near-whites with no
        // token between them. §2's Warning tint is the named surface for this state and
        // lands in the same family; the artboard's barely-there gradient across it does not
        // survive a translation that has to pick one of them anyway.
        case .flag:
            AnyShapeStyle(Color.evaWarningTint)
        // `rgba(255,255,255,.86)` — flat and unsaturated, where `base` is a gradient. The
        // tone's job is what it does *not* add; its border is what says so.
        case .quiet:
            AnyShapeStyle(Color.white.opacity(0.86))
        }
    }

    /// A border over §4's own .72 white hairline, where the tone has one of its own.
    var surfaceBorder: Color? {
        switch self {
        case .base: nil
        case .edu: .evaSuccessBorder
        case .flag: .evaWarningBorder
        case .quiet: .evaControlBorder
        }
    }

    /// 1.5pt on `flag`, the artboard's own weight — the one thing that separates a
    /// red-flag card from an ordinary one before a word is read.
    var surfaceBorderWidth: CGFloat {
        self == .flag ? EvaHomeMetrics.flagBorderWidth : 1
    }

    /// The kicker's ink.
    var kickerInk: Color {
        switch self {
        // `#A9436E`; `evaActionPinkSolid` is `#A94A6C`, one channel away, and is already
        // what the calendar's mode chip took for the same artboard value.
        case .base: .evaActionPinkSolid
        // `#5C7434`; §2's Success ink is `#4F6630`.
        case .edu: .evaSuccessInk
        // `#8A6425` — §2's Warning ink, exactly.
        case .flag: .evaWarningInk
        // `#6F656B` — Secondary Text, exactly. And no pill: the quiet tone's kicker is
        // plain text on the card.
        case .quiet: .evaSecondaryText
        }
    }

    /// The pill behind the kicker, or `nil` where the artboard draws none.
    var kickerFill: Color? {
        switch self {
        case .base: Color.evaPrimaryPink.opacity(0.14)
        case .edu: Color.evaDeepPistachio.opacity(0.18)
        case .flag: Color.evaWarning.opacity(0.16)
        case .quiet: nil
        }
    }

    /// The surface behind line 3, or `nil` where it is just another paragraph.
    var suggestionFill: Color? {
        switch self {
        // `rgba(205,231,157,.28)`; §2's Success tint is the same pistachio at .26.
        case .base: .evaSuccessTint
        case .edu: nil
        // `rgba(201,145,63,.1)` — §2's Warning tint, exactly.
        case .flag: .evaWarningTint
        case .quiet: nil
        }
    }

    /// `rgba(142,173,86,.28)` on `base` only; §2's Success border is .32.
    var suggestionBorder: Color? {
        self == .base ? .evaSuccessBorder : nil
    }
}

// MARK: - Preview

#Preview("Today card · four tones") {
    // The canvas' own `CARDS` copy, inline rather than borrowed from
    // `EvaTodayCardFixtures` — that type is DEBUG-only and this file is not.
    let cards: [EvaTodayCard] = [
        EvaTodayCard(
            tone: .base,
            kicker: "Cycle day 13 · likely approaching ovulation",
            title: "Many women notice higher energy around now",
            line2: "This is a tendency across cycles, not a prediction about your day.",
            line3: "If that matches how you feel, a harder training session may be an option.",
            actions: [EvaTodayCardAction(label: "View cycle details")]
        ),
        EvaTodayCard(
            tone: .edu,
            kicker: "Today’s read",
            title: "Why sleep can affect appetite more than willpower",
            line2: "Educational content, not personalized insight — nothing new in your logs today.",
            meta: "Nutrition · 4 min read",
            actions: [EvaTodayCardAction(label: "Read article")]
        ),
        EvaTodayCard(
            tone: .flag,
            kicker: "Logged 14:20 today",
            title: "You logged reduced fetal movement today",
            line2: "Contact your maternity provider or local urgent care service for guidance. "
                + "Eva cannot assess this.",
            actions: [
                EvaTodayCardAction(label: "View contact options"),
                EvaTodayCardAction(label: "Review what I logged")
            ]
        ),
        EvaTodayCard(
            tone: .quiet,
            title: "Pregnancy tracking has ended",
            line2: "Your previous data remains private and can be reviewed or deleted from Settings.",
            actions: [EvaTodayCardAction(label: "View support resources")]
        )
    ]

    return ScrollView {
        VStack(spacing: EvaSpacing.lg) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                TodayCardView(card: card) { _ in }
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background { EvaScreenBackground().ignoresSafeArea() }
}

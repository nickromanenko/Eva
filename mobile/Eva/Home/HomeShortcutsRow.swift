import SwiftUI

/// The Dashboard's shortcuts row (D5, #100): four buttons under the Today card, and the
/// "Set up meal tracking" prompt under them while meals are not set up.
///
/// Drawn from the `home` screen in "Eva App.dc.html" — `sc-for list="{{ shortcuts }}"` and
/// `sc-if value="{{ setupCard }}"` — in the canvas' order: the log shortcut, meals,
/// Calendar, Eva Chat. Compared against `home_d` (meals set up) and `home_setup` (not).
///
/// ## Labels come from the payload
///
/// `EvaTodayShortcuts` holds the rules: `Log feed` in postpartum, `Log period` while her
/// logged period is running, `Log` otherwise; `Scan meal` once meals are set up, `Set up
/// meals` and the setup card until then. Every input is a fact the server stated — nothing
/// here reads an event (#100, Risks).
///
/// ## Never hidden; disabled where the destination does not exist
///
/// PRD §Dashboard → Shortcuts 3: a feature that is not set up turns its shortcut into a setup
/// prompt rather than removing it. The meal shortcut and the setup card both lead into the
/// Nutrition coach (#25 S3 setup, S9 scan), which is not built — so both are **drawn and
/// disabled** and say so to VoiceOver, the posture D4's card actions and the rail's Learn
/// link take (review G7). Eva Chat is the same: the canvas draws a Chat tab, this build has
/// three tabs and no Chat (DESIGN.md §9a, #159), so there is nothing to select yet.
///
/// ## Where it differs from the artboard, and why
///
/// | Artboard | Here | Why |
/// |---|---|---|
/// | tile `linear-gradient(160deg, #fff .9, #fff .62)`, `.9` border, pink shadow | the artboard's two stops over §4's card at 150°, §4's hairline, neutral shadow | The Today card's `base` tone made the same trade for the same reason (#12, §9a) |
/// | label `600 10.5px/1.25` | `Font.evaOverline` (11/600), no tracking or case | The tab bar's rounding of the same 10.5px label |
/// | mark: a tinted 34pt tile with nothing in it | the same tinted tile, nothing in it | The canvas draws no glyph; inventing four would be a design decision. The tints differ per shortcut and the words carry the meaning |
/// | setup title `600 13.5px`, benefit `400 12px #6F656B` | Control (13/600), Input helper (12/18) in Secondary Text | The nearest rows; the rail's title took Control for the same 13.5 |
/// | setup chevron `›` `17px #C8BFC3` | `chevron.right` in `evaDisabledText`, dropped while disabled | The settings row's chevron; an unavailable row loses it, as the log picker's does |
struct HomeShortcutsRow: View {

    let shortcuts: EvaTodayShortcuts
    /// Whether the setup card is drawn. The caller passes `false` until a document has been
    /// read, so a cold start does not flash a setup prompt at someone who has set meals up.
    let showsSetupCard: Bool
    /// The log shortcut: the calendar's type picker, on today.
    let log: () -> Void
    /// The meal shortcut: the Nutrition coach's setup (S3, #223) once it is built, the scan
    /// (S9) later. `nil` until then, and the shortcut is drawn disabled.
    var meals: (() -> Void)? = nil
    /// The Calendar shortcut: the Calendar tab.
    let openCalendar: () -> Void

    var body: some View {
        VStack(spacing: EvaSpacing.xs) {
            HStack(spacing: EvaSpacing.xs) {
                ForEach(items) { item in
                    tile(item)
                }
            }
            // With each tile asking for all the height it can get, this makes all four as
            // tall as the tallest — a grid row, as the artboard's `grid` stretches them.
            .fixedSize(horizontal: false, vertical: true)

            if showsSetupCard {
                setupCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.shortcuts")
    }

    // MARK: - The four shortcuts

    /// One shortcut: a stable identifier, the words, the mark's tint, and where it goes —
    /// `nil` where the destination is not built.
    private struct Item: Identifiable {
        let id: String
        let label: String
        let tint: Color
        let action: (() -> Void)?
    }

    /// In the canvas' order. The identifiers name the *slot*, not the label, so a test or a
    /// screenshot run finds the first shortcut whether it reads `Log`, `Log period` or `Log
    /// feed` — and the label is asserted separately, which is the point.
    private var items: [Item] {
        [
            // `rgba(233,130,165,.22)`.
            Item(id: "log", label: shortcuts.logLabel, tint: .evaPrimaryPink.opacity(0.22), action: log),
            // `rgba(205,231,157,.45)`. #25's setup is built (S3, #223); the scanner is not.
            Item(id: "meals", label: shortcuts.mealsLabel, tint: .evaPistachio.opacity(0.45), action: meals),
            // `rgba(249,220,230,.75)`.
            Item(id: "calendar", label: "Calendar", tint: .evaSoftBlush.opacity(0.75), action: openCalendar),
            // `rgba(90,123,160,.16)`. No Chat tab in this build.
            Item(id: "chat", label: "Eva Chat", tint: .evaInformation.opacity(0.16), action: nil)
        ]
    }

    private func tile(_ item: Item) -> some View {
        let shape = RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
        let isAvailable = item.action != nil
        return Button {
            item.action?()
        } label: {
            VStack(spacing: EvaSpacing.xs) {
                mark(tint: item.tint, size: EvaHomeMetrics.shortcutMarkSize, border: 0.85)

                Text(item.label)
                    .font(.evaOverline)
                    .foregroundStyle(Color.evaPrimaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EvaHomeMetrics.shortcutPadding)
            .frame(maxWidth: .infinity, minHeight: EvaHomeMetrics.shortcutHeight)
            .frame(maxHeight: .infinity)
            // `linear-gradient(160deg, rgba(255,255,255,.9), rgba(255,255,255,.62))` as a
            // wash over §4's card, on §4's 150° — the Today card's `base` tone, and the same
            // unit points `EvaCardSurfaceModifier` derives for that angle.
            .background {
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(0.9), Color.white.opacity(0.62)],
                    startPoint: UnitPoint(x: 0.159, y: -0.092),
                    endPoint: UnitPoint(x: 0.841, y: 1.092)
                ))
            }
            .evaCardSurface(in: shape)
            .opacity(isAvailable ? 1 : LogPickerMetrics.unavailableOpacity)
            .contentShape(shape)
        }
        .buttonStyle(.evaUndimmed)
        .disabled(!isAvailable)
        .accessibilityLabel(Text(
            isAvailable ? item.label : "\(item.label). \(EvaTodayCardTarget.unavailableSuffix)"
        ))
        .accessibilityIdentifier("home.shortcut.\(item.id)")
    }

    /// The tinted slot the canvas draws where a mark will go. Decorative.
    private func mark(tint: Color, size: CGFloat, border: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: EvaHomeMetrics.markRadius, style: .continuous)
        return shape
            .fill(tint)
            .overlay { shape.strokeBorder(Color.white.opacity(border), lineWidth: 1) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    // MARK: - The setup prompt

    /// "Set up meal tracking — See calories and protein at a glance." (`SPEC.home_setup`:
    /// the prompt states the benefit, never a completion percentage or "x of y steps").
    ///
    /// §7's empty-state surface — `rgba(255,255,255,.6)` with a dashed border, the calendar's
    /// empty-day row — in the artboard's pink `rgba(201,95,134,.4)`. Disabled until #25's
    /// setup exists, and it says so.
    private var setupCard: some View {
        let shape = RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
        return Button {} label: {
            HStack(spacing: EvaSpacing.sm) {
                // `rgba(233,130,165,.18)`, `.8` white border.
                mark(tint: .evaPrimaryPink.opacity(0.18), size: EvaHomeMetrics.setupMarkSize, border: 0.8)

                // `margin-top:2px` on the benefit line — below the 4pt step, and the two lines
                // are one sentence's title and body.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up meal tracking")
                        .evaTextStyle(.control)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text("See calories and protein at a glance.")
                        .evaTextStyle(.inputHelper)
                        .foregroundStyle(Color.evaSecondaryText)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, EvaSpacing.md)
            .padding(.horizontal, EvaSpacing.md)
            .frame(minHeight: EvaMetrics.minimumTouchTarget)
            .background {
                shape
                    .fill(Color.white.opacity(0.6))
                    .overlay {
                        shape.strokeBorder(
                            Color.evaDeepPink.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: EvaHomeMetrics.setupCardDash)
                        )
                    }
            }
            .opacity(LogPickerMetrics.unavailableOpacity)
            .contentShape(shape)
        }
        .buttonStyle(.evaUndimmed)
        .disabled(true)
        .accessibilityLabel(Text(
            "Set up meal tracking. See calories and protein at a glance. "
                + EvaTodayCardTarget.unavailableSuffix
        ))
        .accessibilityIdentifier("home.setupMeals")
    }
}

#Preview("Meals not set up · home_setup") {
    ZStack(alignment: .top) {
        EvaScreenBackground().ignoresSafeArea()
        HomeShortcutsRow(shortcuts: .resting, showsSetupCard: true, log: {}, openCalendar: {})
            .padding(EvaSpacing.lg)
    }
}

#Preview("Postpartum, set up · home_post") {
    ZStack(alignment: .top) {
        EvaScreenBackground().ignoresSafeArea()
        HomeShortcutsRow(
            shortcuts: EvaTodayShortcuts(mode: .postpartum, nutritionSetUp: true),
            showsSetupCard: false,
            log: {},
            openCalendar: {}
        )
        .padding(EvaSpacing.lg)
    }
}

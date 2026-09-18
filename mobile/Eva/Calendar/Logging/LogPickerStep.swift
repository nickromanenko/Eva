import SwiftUI

/// The canvas' `picker` sheet: which day this is going on, and what to log on it.
///
/// `SPEC.picker` asks for three things and all three are load-bearing rather than
/// decorative:
///
/// * **The header states the target date and offers an obvious change control.** A log
///   sheet opened from a floating button has no other way of saying which day it is about,
///   and a health entry on the wrong day is worse than no entry.
/// * **Options adapt to the active mode**, which in C2 means they adapt to the *day*: a
///   future day takes an appointment and nothing else, and the rows that cannot be used say
///   why before they are tapped. #160's criterion is that they are visibly unavailable, not
///   silently refused.
/// * **Sensitive types stay visually neutral.** Sex is a word and a grey dot — no imagery,
///   no colour of its own, nothing that reads across a room.
///
/// It carries no close button, which is the artboard's own arrangement: the form sheets
/// draw a × and this one does not. Two reasons to keep it that way rather than add one for
/// symmetry — the sheet's grabber and swipe-down are the platform's dismissal and are
/// always there, and a × beside "Change date" squeezed the date onto two lines, which is
/// the one thing on this sheet that must be read at a glance.
struct LogPickerStep: View {

    @Binding var day: EvaDay
    let today: EvaDay
    /// The day's existing entry of a one-per-day type, if there is one. What turns "Log"
    /// into "Edit" on the row.
    let existingEntry: (EvaEventType) -> EvaEvent?
    let choose: (EvaEventType) -> Void

    @State private var isChangingDate = false

    /// The order the artboard lists them in, minus the two it draws that this build does not
    /// offer. Sex is here but unavailable — the route reserves the type until C10 ships it
    /// with its privacy switch. It is drawn rather than dropped because the canvas is
    /// specific about how it must look, and because a type that exists on the calendar and
    /// not in the picker reads as a bug rather than as a plan.
    ///
    /// **Positive test is dropped, and the reason has changed (#80).** C2 dropped it as a
    /// pregnancy-mode entry, which the PRD's own table contradicts — it reads *yes* in Cycle
    /// and in Planning. #80 ships the type, the grid's top-left mark and the legend row; what
    /// it does not ship is a row here and the sheet behind it, so there is still nothing for
    /// this list to open. Adding the row is the next slice, and it belongs after `.cycle`,
    /// where the artboard puts it.
    private static let types: [EvaEventType] = [.cycle, .sex, .bodySignals, .sport, .appointment]

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            header
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                LogSectionHeading("What would you like to log?")
                ForEach(Self.types, id: \.self) { type in
                    row(type)
                }
            }
            footnote
        }
    }

    // MARK: - Header

    /// The artboard's pistachio "Logging to" card, with the date and a change control.
    private var header: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.sm) {
                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text("Logging to")
                        .evaTextStyle(.overline)
                        .foregroundStyle(Color.evaSuccessInk)
                    Text(day.longLabel)
                        .evaTextStyle(.button)
                        .foregroundStyle(Color.evaPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("log.targetDay")
                }
                Spacer(minLength: EvaSpacing.xs)
                Button {
                    isChangingDate.toggle()
                } label: {
                    Text(isChangingDate ? "Done" : "Change date")
                        .evaTextStyle(.control)
                        .foregroundStyle(Color.evaSuccessInk)
                        .padding(.horizontal, EvaSpacing.sm)
                        .frame(minHeight: EvaMetrics.minimumTouchTarget)
                        .background(
                            Color.white.opacity(0.7),
                            in: .rect(cornerRadius: EvaRadius.chip, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                                .strokeBorder(Color.evaSuccessBorder, lineWidth: 1)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.evaUndimmed)
                .accessibilityIdentifier("log.changeDate")
            }

            if isChangingDate {
                // **The canvas draws a control it does not specify** — its own handler is
                // `noop` — and the design system has no date picker. Inventing one is a
                // design decision, so the platform's own is used instead, tinted and
                // bounded to exactly what the route will accept: no earlier than twelve
                // months back, and forward without limit because appointments are made
                // ahead. Reported on #160 rather than taken quietly.
                DatePicker(
                    "Logging to",
                    selection: EvaDay.binding($day),
                    in: EvaEventType.backdateFloor(from: today).deviceNoon...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(Color.evaActionPinkSolid)
                .labelsHidden()
                .accessibilityIdentifier("log.datePicker")
            }
        }
        .padding(EvaSpacing.sm)
        .background(
            Color.evaPistachio.opacity(0.42),
            in: .rect(cornerRadius: EvaRadius.banner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                .strokeBorder(Color.evaDeepPistachio.opacity(0.4), lineWidth: 1)
        }
    }

    // MARK: - Rows

    private func row(_ type: EvaEventType) -> some View {
        let availability = type.availability(on: day, today: today)
        let existing = existingEntry(type)
        return Button {
            choose(type)
        } label: {
            HStack(spacing: EvaSpacing.sm) {
                LogTypeMark(type: type)

                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text(CalendarEntryPresentation.typeName(for: type))
                        .evaTextStyle(.button)
                        // Secondary rather than the disabled ink, and the row's own
                        // dimming is light: a row that says why it cannot be used has to
                        // be readable to say it. The same §9a argument the filled
                        // controls' disabled labels won — except that here the sentence
                        // *is* the affordance, so it matters more, not less.
                        .foregroundStyle(
                            availability.isAvailable ? Color.evaPrimaryText : .evaSecondaryText
                        )
                    Text(hint(type, availability: availability, existing: existing))
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if availability.isAvailable {
                    Image(systemName: "chevron.right")
                        .font(.evaControlText)
                        .foregroundStyle(Color.evaDisabledText)
                }
            }
            .padding(.horizontal, EvaSpacing.md)
            .padding(.vertical, EvaSpacing.sm)
            .frame(minHeight: LogPickerMetrics.rowHeight)
            .evaGlass(.card, cornerRadius: EvaRadius.card)
            .overlay {
                RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
                    .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
            }
            .opacity(availability.isAvailable ? 1 : LogPickerMetrics.unavailableOpacity)
            .contentShape(.rect(cornerRadius: EvaRadius.card, style: .continuous))
        }
        .buttonStyle(.evaUndimmed)
        .disabled(!availability.isAvailable)
        .accessibilityIdentifier("log.type.\(type.rawValue)")
    }

    /// The second line of a row: why it cannot be used, what re-opening it would do, or
    /// what it is — in that order, because the first two are news and the third is not.
    private func hint(
        _ type: EvaEventType,
        availability: EvaLogAvailability,
        existing: EvaEvent?
    ) -> String {
        if let reason = availability.reason { return reason }
        if existing != nil { return "Already logged — opens what you saved" }
        return Self.description(type)
    }

    /// The artboard's own hints.
    private static func description(_ type: EvaEventType) -> String {
        switch type {
        case .cycle: "Spotting marker, or light to heavy flow"
        case .sex: "Private · neutral indicator"
        case .bodySignals: "Energy, mood, sleep, symptoms"
        case .sport: "Activity, duration, intensity"
        case .appointment: "Type, notes, reminder"
        // Unreachable while `types` omits the row — kept as an arm rather than a `default`
        // so the compiler still names this file the day a type is added.
        case .positiveTest: "Marks the day · does not change your mode"
        }
    }

    /// The footnote the artboard draws under the list, with the half about modes removed —
    /// there is one mode in C2 and the mode chip above the grid is read-only.
    private var footnote: some View {
        Text(
            "Past days and today can be logged; future days accept appointments only. "
            + "Saving needs a connection — nothing is queued yet."
        )
        .evaTextStyle(.caption)
        .foregroundStyle(Color.evaMutedText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("log.footnote")
    }
}

/// The 42pt tile beside a picker row.
///
/// The artboard fills each with a different pale wash and draws nothing inside. Eva's own
/// calendar already has a shape language for these four types — bottom-left dot,
/// bottom-centre square, bottom-right diamond, top-right badge — so the tile carries the
/// **same mark the grid draws**, which makes the picker the one place the legend is learned
/// by using it. Cycle has no corner mark on the grid (it is the cell's wash), so it takes a
/// disc of that wash, exactly as the day list does.
///
/// Sex keeps the artboard's `rgba(40,33,38,.07)` neutral tile and the grey dot the calendar
/// draws: DESIGN.md §8 asks sensitive events to stay neutral in their indicators as well as
/// in their language, and the canvas' note on `sex` is explicit — a neutral label and dot,
/// no imagery.
struct LogTypeMark: View {
    let type: EvaEventType

    var body: some View {
        ZStack {
            if let glyph = type.glyph {
                EvaEventGlyphMark(glyph: glyph)
            } else {
                Circle()
                    .fill(EvaCycleMark.flow(.medium).cellFill ?? .clear)
                    .overlay { Circle().strokeBorder(Color.evaDeepPink, lineWidth: 1) }
                    .frame(
                        width: EvaCalendarMetrics.badgeSize,
                        height: EvaCalendarMetrics.badgeSize
                    )
            }
        }
        .frame(width: LogPickerMetrics.markSize, height: LogPickerMetrics.markSize)
        .background(wash, in: .rect(cornerRadius: EvaRadius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    /// The artboard's per-row wash, in tokens.
    private var wash: Color {
        switch type {
        case .cycle: .evaPrimaryPink.opacity(0.22)
        case .sex: .evaPrimaryText.opacity(0.07)
        case .bodySignals: .evaDeepPink.opacity(0.16)
        case .sport: .evaPistachio.opacity(0.40)
        case .appointment: .evaInformation.opacity(0.16)
        // As above: no row draws this yet. The tile's own mark is the grid's outlined
        // square, so the wash behind it is the cycle row's pink.
        case .positiveTest: .evaPrimaryPink.opacity(0.22)
        }
    }
}

enum LogPickerMetrics {
    /// `min-height:66px` on a picker row.
    static let rowHeight: CGFloat = 66
    /// `width:42px;height:42px` on the tile beside it.
    static let markSize: CGFloat = 42
    /// An unavailable row is dimmed **and** loses its chevron **and** says why — §1's
    /// "never colour alone", applied to the absence of colour. The dimming is deliberately
    /// light: at 0.55 it stacked on the disabled ink and the sentence explaining the
    /// refusal was the least readable thing on the sheet, which defeats the point of
    /// drawing the row at all.
    static let unavailableOpacity: Double = 0.75
}

#Preview("Log picker") {
    @Previewable @State var day = EvaDay(year: 2026, month: 8, day: 12)
    @Previewable @State var future = EvaDay(year: 2026, month: 9, day: 20)

    return ScrollView {
        VStack(spacing: EvaSpacing.xl) {
            LogPickerStep(
                day: $day,
                today: EvaDay(year: 2026, month: 8, day: 18),
                existingEntry: { _ in nil },
                choose: { _ in }
            )
            LogPickerStep(
                day: $future,
                today: EvaDay(year: 2026, month: 8, day: 18),
                existingEntry: { _ in nil },
                choose: { _ in }
            )
        }
        .padding(EvaSpacing.lg)
    }
    .background { EvaScreenBackground().ignoresSafeArea() }
}

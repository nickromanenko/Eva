import SwiftUI

/// The selected day's entries, listed under the grid.
///
/// ## Why this is not the canvas' bottom sheet
///
/// "Eva App.dc.html" opens a large sheet on a day tap (`SPEC.day`), and that sheet is
/// mostly its own actions: Edit, Delete, Mark period end and Add entry — every one of them
/// C2 or C5. A sheet holding a read-only list and no action is a surface you open to find
/// nothing to do, and it covers the grid, so the selection outline that #159's criterion
/// pairs with the listing ("a tapped day is outlined **and** lists that day's entries")
/// would be hidden behind it.
///
/// So C1 lists the day in place, under the grid, where the outline stays visible. The
/// sheet arrives with the actions that justify it. Reported on #159 as a deviation rather
/// than taken quietly.
struct CalendarDayDetail: View {

    let day: EvaDay
    let entries: [EvaEvent]
    let refData: EvaRefData?

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            header

            if entries.isEmpty {
                emptyDay
            } else {
                ForEach(entries) { entry in
                    CalendarEntryRow(
                        presentation: CalendarEntryPresentation(event: entry, refData: refData)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text(day.formattingDate.formatted(
                EvaDay.formatStyle.weekday(.wide).day().month(.wide)
            ))
            // The artboard's day title is 24/400, which the §3 scale has no row for. This
            // is a section heading on the calendar rather than a sheet's own title, and
            // H2 is the scale's row for one.
            .evaTextStyle(.h2)
            .foregroundStyle(Color.evaPrimaryText)
            .accessibilityIdentifier("calendar.day.title")

            Text(entries.count == 1 ? "1 entry" : "\(entries.count) entries")
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)
                .accessibilityIdentifier("calendar.day.count")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The artboard's dashed empty row, minus its second line.
    ///
    /// That line reads "Add flow, body signals, sport or an appointment" — an instruction
    /// for a control C1 does not have. Telling someone to do something the build cannot do
    /// is the same defect as an inert button, one sentence smaller.
    private var emptyDay: some View {
        Text("Nothing logged on this day")
            .evaTextStyle(.h3)
            .foregroundStyle(Color.evaPrimaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, EvaSpacing.lg)
            .padding(.horizontal, EvaSpacing.md)
            .background {
                let shape = RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                shape
                    // `background:rgba(255,255,255,.6)`.
                    .fill(Color.white.opacity(0.6))
                    .overlay {
                        // DESIGN.md §7: the empty state carries a dashed border.
                        shape.strokeBorder(
                            Color.evaPrimaryText.opacity(0.14),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                    }
            }
            .accessibilityIdentifier("calendar.day.empty")
    }
}

/// One entry: its mark, the time it was logged, what it is, and what it said.
struct CalendarEntryRow: View {

    let presentation: CalendarEntryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            HStack(spacing: EvaSpacing.xs) {
                mark
                if let time = presentation.time {
                    Text(time)
                        .evaTextStyle(.bodyMedium)
                        .foregroundStyle(Color.evaPrimaryText)
                }
                Text(presentation.typeName)
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(Color.evaSecondaryText)
            }

            if !presentation.summary.isEmpty {
                Text(presentation.summary)
                    .evaTextStyle(.body)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = presentation.note {
                Text(note)
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(.card, cornerRadius: EvaRadius.banner)
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.entry.\(presentation.typeName)")
    }

    /// The same shape the grid draws for this type, so a mark learned in one place reads
    /// in the other. `cycle` has no corner mark — the grid washes the whole cell — so it
    /// gets a disc of the same wash here, which is what the artboard's day sheet draws.
    @ViewBuilder
    private var mark: some View {
        if let glyph = presentation.glyph {
            EvaEventGlyphMark(glyph: glyph)
                .frame(
                    width: EvaCalendarMetrics.badgeSize,
                    height: EvaCalendarMetrics.badgeSize
                )
        } else if let cycleMark = presentation.cycleMark {
            Circle()
                .fill(cycleMark.cellFill ?? Color.clear)
                .overlay { Circle().strokeBorder(Color.evaDeepPink, lineWidth: 1) }
                .frame(width: EvaCalendarMetrics.markSize + 2, height: EvaCalendarMetrics.markSize + 2)
                .frame(width: EvaCalendarMetrics.badgeSize, height: EvaCalendarMetrics.badgeSize)
        }
    }
}

#Preview("Day detail") {
    let day = EvaDay(year: 2026, month: 8, day: 12)
    let entries = [
        EvaEvent(
            id: "1",
            detail: .cycle(.flow(.light)),
            localDate: day,
            loggedAt: "2026-08-12T07:10:00"
        ),
        EvaEvent(
            id: "2",
            detail: .bodySignals(EvaBodySignalsPayload(
                energy: 2,
                sleep: 5,
                symptoms: [
                    EvaSymptom(code: "cramps", severity: .severe),
                    EvaSymptom(code: "headache")
                ]
            )),
            localDate: day,
            loggedAt: "2026-08-12T08:30:00",
            note: "Worse after lunch."
        ),
        EvaEvent(
            id: "3",
            detail: .sex,
            localDate: day,
            loggedAt: "2026-08-12T22:00:00"
        )
    ]

    return ZStack {
        EvaScreenBackground().ignoresSafeArea()
        ScrollView {
            CalendarDayDetail(day: day, entries: entries, refData: nil)
                .padding(EvaSpacing.lg)
        }
    }
}

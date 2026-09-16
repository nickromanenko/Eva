import SwiftUI

/// The month grid: a Monday-first weekday row over six rows of seven day cells.
///
/// Six rows always — see `EvaMonthGrid`. The grid keeps a fixed height so that paging a
/// month does not move the day detail and the legend underneath it.
struct CalendarMonthGrid: View {

    let grid: EvaMonthGrid
    let today: EvaDay
    let selectedDay: EvaDay
    /// Everything a cell needs to draw itself, asked for per day rather than passed in as
    /// a dictionary so the grid never has to know how the model stores it.
    let cycleMark: (EvaDay) -> EvaCycleMark?
    let glyphs: (EvaDay) -> [EvaEventGlyph]
    let select: (EvaDay) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: EvaCalendarMetrics.cellSpacing),
        count: EvaMonthGrid.columnCount
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: EvaCalendarMetrics.cellSpacing) {
            ForEach(Self.weekdayHeadings, id: \.full) { heading in
                Text(heading.initial)
                    // 11/600 with no tracking, which is the Overline row's face at the
                    // Overline row's size. `.evaTextStyle(.overline)` would add the .14em
                    // the artboard does not draw on this row.
                    .font(.evaOverline)
                    .foregroundStyle(Color.evaMutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, EvaSpacing.xxs)
                    // A single letter is announced as a letter. Four of the seven are
                    // ambiguous besides — two Ts and two Ss.
                    .accessibilityLabel(heading.full)
            }

            ForEach(grid.cells) { cell in
                CalendarDayCell(
                    cell: cell,
                    isToday: cell.date == today,
                    isSelected: cell.date == selectedDay,
                    cycleMark: cycleMark(cell.date),
                    glyphs: glyphs(cell.date),
                    select: { select(cell.date) }
                )
            }
        }
    }

    /// The weekday row, Monday first, in the user's locale.
    ///
    /// Monday-first is the artboard's (`dowLabels: ['M','T','W','T','F','S','S']`) and is
    /// **not** the locale's own first weekday, which is Sunday in the US. Reported on #159
    /// rather than decided here: the canvas draws one calendar and it starts on Monday.
    static var weekdayHeadings: [(initial: String, full: String)] {
        // The user's own calendar, for its locale's weekday names. Only the *order*
        // is fixed here, and it is fixed to the artboard rather than to the locale.
        let calendar = Calendar.autoupdatingCurrent
        // Foundation's arrays are Sunday-first.
        return (0..<EvaMonthGrid.columnCount).map { index in
            let sundayFirst = (index + 1) % 7
            return (
                initial: calendar.veryShortWeekdaySymbols[sundayFirst],
                full: calendar.weekdaySymbols[sundayFirst]
            )
        }
    }
}

/// One day. A 50pt rounded cell carrying the date, the flow wash if there is one, and up
/// to four corner marks.
struct CalendarDayCell: View {

    let cell: EvaMonthGrid.Cell
    let isToday: Bool
    let isSelected: Bool
    let cycleMark: EvaCycleMark?
    let glyphs: [EvaEventGlyph]
    let select: () -> Void

    var body: some View {
        // Days from the months either side are drawn and not tappable, which is what the
        // artboard does (`onClick:()=>{}` on both). They are context for the week, not
        // days of this month; tapping one would have to page the grid as a side effect of
        // selecting, and the header and the two steppers are how the month changes.
        if cell.placement.isInMonth {
            Button(action: select) { face }
                .buttonStyle(.evaUndimmed)
                .accessibilityIdentifier("calendar.day.\(cell.date.isoDate)")
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            face
                .accessibilityHidden(true)
        }
    }

    private var face: some View {
        ZStack {
            background
            number
        }
        .frame(height: EvaCalendarMetrics.cellHeight)
        .frame(maxWidth: .infinity)
        .overlay { marks }
        .overlay { selectionRing }
        .contentShape(RoundedRectangle(cornerRadius: EvaCalendarMetrics.cellRadius, style: .continuous))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaCalendarMetrics.cellRadius, style: .continuous)
    }

    @ViewBuilder
    private var background: some View {
        if !cell.placement.isInMonth {
            // `height:50px;border-radius:15px` with no fill and no border — the artboard
            // draws adjacent days as a number on the screen's own ground.
            Color.clear
        } else if let fill = cycleMark?.cellFill {
            shape.fill(fill)
        } else {
            // L1 glass: 40% white against the artboard's 34%, and the nearest level the
            // design system names. No `Material` at L1, which matters at 42 cells.
            shape
                .fill(EvaGlassLevel.background.tint)
                .overlay { shape.strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1) }
        }
    }

    @ViewBuilder
    private var number: some View {
        let label = Text(verbatim: String(cell.date.day))
            // 15/500. The artboard sets today at 700, which the §3 scale has no row for —
            // the filled disc and the white ink already say "today" without it.
            .font(.evaBodyMedium)

        if isToday {
            label
                .foregroundStyle(Color.evaTextOnDark)
                .frame(
                    width: EvaCalendarMetrics.todayMarkerSize,
                    height: EvaCalendarMetrics.todayMarkerSize
                )
                // `#C95F86` on the artboard; the action ramp's solid stop (#12), which is
                // the token whose whole purpose is pink that carries a white label.
                .background(Circle().fill(Color.evaActionPinkSolid))
        } else {
            label.foregroundStyle(numberColor)
        }
    }

    private var numberColor: Color {
        cell.placement.isInMonth ? .evaPrimaryText : .evaDisabledText
    }

    private var marks: some View {
        CalendarDayMarks(glyphs: glyphs)
    }

    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            // `outline:2px solid #282126;outline-offset:1px` — outside the cell, so a
            // selected flow day still shows its wash right to the edge.
            RoundedRectangle(
                cornerRadius: EvaCalendarMetrics.cellRadius + EvaCalendarMetrics.selectionOffset,
                style: .continuous
            )
            .strokeBorder(Color.evaPrimaryText, lineWidth: EvaCalendarMetrics.selectionWidth)
            .padding(-EvaCalendarMetrics.selectionOffset)
            .allowsHitTesting(false)
        }
    }

    /// One sentence per cell, the artboard's `aria-label` shape: the date, then what is on
    /// it, then "No entries" when there is nothing.
    ///
    /// Everything the cell draws is in here, because everything the cell draws is a small
    /// coloured shape in a corner — the grid is unreadable to VoiceOver and to anyone who
    /// cannot separate a 6pt pink square from a 6pt green diamond unless the cell says so.
    private var accessibilityLabel: String {
        var parts = [cell.date.formattingDate.formatted(
            EvaDay.formatStyle.weekday(.wide).day().month(.wide).year()
        )]
        if isToday { parts.append("Today") }
        if let cycleMark { parts.append(cycleMark.accessibilityLabel) }
        parts.append(contentsOf: glyphs.map(\.accessibilityLabel))
        if cycleMark == nil && glyphs.isEmpty { parts.append("No entries") }
        return parts.joined(separator: ". ")
    }
}

#Preview("Month grid") {
    let month = EvaMonth(year: 2026, month: 8)
    let marks: [EvaDay: EvaCycleMark] = [
        EvaDay(year: 2026, month: 8, day: 4): .flow(.medium),
        EvaDay(year: 2026, month: 8, day: 5): .flow(.heavy),
        EvaDay(year: 2026, month: 8, day: 6): .flow(.heavy),
        EvaDay(year: 2026, month: 8, day: 7): .flow(.medium),
        EvaDay(year: 2026, month: 8, day: 8): .flow(.light),
        EvaDay(year: 2026, month: 8, day: 9): .spotting
    ]
    let glyphs: [EvaDay: [EvaEventGlyph]] = [
        EvaDay(year: 2026, month: 8, day: 10): [.sex],
        EvaDay(year: 2026, month: 8, day: 12): [.bodySignals, .appointment],
        EvaDay(year: 2026, month: 8, day: 13): [.sport],
        EvaDay(year: 2026, month: 8, day: 18): [.bodySignals]
    ]

    return ZStack {
        EvaScreenBackground().ignoresSafeArea()
        CalendarMonthGrid(
            grid: EvaMonthGrid(month: month),
            today: EvaDay(year: 2026, month: 8, day: 18),
            selectedDay: EvaDay(year: 2026, month: 8, day: 12),
            cycleMark: { marks[$0] },
            glyphs: { glyphs[$0] ?? [] },
            select: { _ in }
        )
        .padding(EvaSpacing.lg)
    }
}

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
/// So C1 lists the day in place, under the grid, where the outline stays visible.
///
/// ## C2 puts the actions on the rows, not in a sheet
///
/// C1's note here promised the sheet would arrive with Edit and Delete. #160 builds those
/// and keeps them in place instead, for two reasons that only became clear once the log
/// flow existed. The picker is already a bottom sheet, so a day sheet that opens a log
/// sheet is two sheets deep before anything is logged. And the actions attach to *an
/// entry*, which is drawn here — moving them into a sheet would move the rows with them
/// and take the day's contents off a screen where they sit under the day that is outlined.
///
/// What the day sheet would have added over this is "Add entry", and the calendar already
/// has one: the Log button targets the selected day, which is the day this is describing.
/// Recorded in DESIGN.md §9a; the canvas has not drawn this arrangement.
struct CalendarDayDetail: View {

    let day: EvaDay
    let entries: [EvaEvent]
    let refData: EvaRefData?
    /// Opens the log sheet on an existing entry. `nil` while the calendar is read-only.
    var edit: ((EvaEvent) -> Void)?
    var delete: ((EvaEvent) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            header

            if entries.isEmpty {
                emptyDay
            } else {
                ForEach(entries) { entry in
                    CalendarEntryRow(
                        presentation: CalendarEntryPresentation(event: entry, refData: refData),
                        edit: edit.map { edit in { edit(entry) } },
                        delete: delete.map { delete in { delete(entry) } }
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

    /// The artboard's dashed empty row.
    ///
    /// Its second line came back in C2. C1 dropped it because it reads "Add flow, body
    /// signals, sport or an appointment" and there was nothing to add it with — an
    /// instruction for a control the build did not have. There is one now, so the line is
    /// restored, pointing at it by name rather than describing a gesture.
    private var emptyDay: some View {
        VStack(spacing: EvaSpacing.xxs) {
            Text("Nothing logged on this day")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
            if edit != nil {
                Text("Use the Log button to add flow, body signals, sport or an appointment.")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// One entry: its mark, the time it was logged, what it is, what it said, and what can be
/// done to it.
struct CalendarEntryRow: View {

    let presentation: CalendarEntryPresentation
    var edit: (() -> Void)?
    var delete: (() -> Void)?

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

            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(.card, cornerRadius: EvaRadius.banner)
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
        }
        // `.contain`, not `.combine`: the row now holds two buttons, and combining would
        // fold their labels into one unreachable sentence. The label is assembled instead,
        // so the row still announces as one sentence.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.entry.\(presentation.id)")
        .accessibilityLabel(presentation.announcement)
    }

    /// Edit and Delete, side by side.
    ///
    /// The artboard draws both at `min-height:36px; border-radius:11px; font:600 12.5px`,
    /// which is under §1's 44pt floor for something you tap and matches no §5 variant. Both
    /// take §5's standard 52 instead — the secondary glass and the outlined destructive —
    /// which is the nearest named pair and keeps them the same height as each other.
    /// Recorded in DESIGN.md §9a.
    ///
    /// **Delete asks nothing first.** It is soft, it is reversible for thirty days, and the
    /// toast offers Undo the moment it happens; a confirmation dialog in front of a
    /// reversible action is what teaches people to dismiss dialogs without reading them.
    @ViewBuilder
    private var actions: some View {
        if edit != nil || delete != nil {
            HStack(spacing: EvaSpacing.xs) {
                // Keyed on the **entry's id**, for the reason C1 keyed the row on it: two
                // sport entries on one day are legal, and a day would otherwise carry two
                // elements answering to `calendar.delete.Sport`. That is also why the §5
                // styles are used directly rather than `SecondaryButton` /
                // `DestructiveButton`, which set `secondary.Edit` and `destructive.Delete`
                // on themselves — the identifier has to name the row, so it has to be the
                // only one applied.
                if let edit {
                    Button("Edit", action: edit)
                        .buttonStyle(EvaSecondaryButtonStyle())
                        .accessibilityIdentifier("calendar.edit.\(presentation.id)")
                }
                if let delete {
                    Button("Delete", action: delete)
                        .buttonStyle(EvaDestructiveButtonStyle(kind: .outlined))
                        .accessibilityIdentifier("calendar.delete.\(presentation.id)")
                }
            }
            .padding(.top, EvaSpacing.xs)
        }
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

import SwiftUI

/// The log flow: the canvas' `picker` sheet and the four forms it leads to.
///
/// ## One sheet, several steps
///
/// The artboard draws five bottom sheets that replace one another in place — each form
/// carries "‹ Back" to the picker and "×" to the calendar — so this is one
/// `.sheet` switching on `step` rather than a navigation stack. A stack would put a
/// system navigation bar above a sheet the canvas draws without one, and would animate
/// sideways where the canvas swaps.
///
/// ## What it does not do
///
/// **Online only, and it says so.** There is no queue behind these calls (#78): a save
/// with no signal fails, says so on the sheet, and keeps everything the user typed so the
/// same tap can be repeated. The alternative — accepting the tap and showing the entry —
/// would draw a calendar containing something that was never stored.
struct LogSheet: View {

    /// What opened the sheet.
    enum Start: Identifiable, Hashable {
        /// The Log button, or the day's "Add entry": choose a type for this day.
        case picker(EvaDay)
        /// A row's Edit: straight into the form, on the entry it belongs to.
        case edit(EvaEvent)

        var id: String {
            switch self {
            case .picker(let day): "picker-\(day.isoDate)"
            case .edit(let event): "edit-\(event.id)"
            }
        }

        var day: EvaDay {
            switch self {
            case .picker(let day): day
            case .edit(let event): event.localDate
            }
        }
    }

    /// Which form is on screen. `editing` is the id being replaced, or `nil` for a new
    /// entry — the one piece of state that decides `PATCH` against `POST`.
    enum Step: Hashable {
        case picker
        case cycle(editing: String?)
        case bodySignals(editing: String?)
        case sport(editing: String?)
        case appointment(editing: String?)
    }

    let model: CalendarModel
    let start: Start

    @Environment(\.dismiss) private var dismiss

    @State private var day: EvaDay
    @State private var step: Step
    @State private var cycle = LogCycleDraft()
    @State private var bodySignals = LogBodySignalsDraft()
    @State private var sport = LogSportDraft()
    @State private var appointment = LogAppointmentDraft()
    @State private var isSaving = false
    @State private var failure: String?
    /// One key for the life of this sheet, so a save retried after a timeout returns the
    /// entry the first attempt created rather than logging the same thing twice.
    @State private var idempotencyKey = UUID().uuidString

    init(model: CalendarModel, start: Start) {
        self.model = model
        self.start = start
        _day = State(initialValue: start.day)
        switch start {
        case .picker:
            _step = State(initialValue: .picker)
        case .edit(let event):
            _step = State(initialValue: Self.step(editing: event))
            _cycle = State(initialValue: LogCycleDraft(editing: event))
            _bodySignals = State(initialValue: LogBodySignalsDraft(
                editing: event, refData: model.refData
            ))
            _sport = State(initialValue: LogSportDraft(editing: event, refData: model.refData))
            _appointment = State(initialValue: LogAppointmentDraft(editing: event))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EvaSpacing.md) {
                content
                if let failure {
                    LogSheetFailure(message: failure)
                }
            }
            .padding(.horizontal, EvaSpacing.lg)
            .padding(.top, EvaSpacing.xs)
            // §4's sheet: 26pt of safe-area bottom padding under the last control.
            .padding(.bottom, EvaSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { EvaScreenBackground().ignoresSafeArea() }
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .presentationCornerRadius(EvaRadius.sheet)
        .accessibilityIdentifier("log.sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .picker:
            LogPickerStep(
                day: $day,
                today: model.today,
                existingEntry: { model.onePerDayEntry($0, on: day) },
                choose: open(_:)
            )
        case .cycle(let editing):
            LogCycleStep(
                draft: $cycle,
                day: day,
                isEditing: editing != nil,
                isSaving: isSaving,
                back: back,
                close: { dismiss() },
                save: { save(cycle.payload, note: cycle.note, editing: editing) }
            )
        case .bodySignals(let editing):
            LogBodySignalsStep(
                draft: $bodySignals,
                day: day,
                catalogue: model.refData.offered(.symptoms),
                isEditing: editing != nil,
                isSaving: isSaving,
                back: back,
                close: { dismiss() },
                save: {
                    save(
                        bodySignals.payload(in: model.refData.offered(.symptoms)),
                        note: bodySignals.note,
                        editing: editing
                    )
                }
            )
        case .sport(let editing):
            LogSportStep(
                draft: $sport,
                day: day,
                catalogue: model.refData.offered(.sportActivities),
                isEditing: editing != nil,
                isSaving: isSaving,
                back: back,
                close: { dismiss() },
                save: {
                    save(
                        sport.payload(in: model.refData.offered(.sportActivities)),
                        note: sport.note,
                        editing: editing
                    )
                }
            )
        case .appointment(let editing):
            LogAppointmentStep(
                draft: $appointment,
                day: day,
                catalogue: model.refData.offered(.appointmentTypes),
                isEditing: editing != nil,
                isSaving: isSaving,
                back: back,
                close: { dismiss() },
                save: {
                    save(
                        appointment.payload(on: day),
                        note: appointment.note,
                        editing: editing
                    )
                }
            )
        }
    }

    // MARK: - Navigation

    /// Opens the form for a type, on the entry that day already has if there is one.
    ///
    /// This is the whole of "re-opening a logged day loads the existing entry for editing
    /// rather than creating a second". It has to happen here rather than in the picker,
    /// because only the model knows what is on the day — and for `cycle` and `bodySignals`
    /// the consequence of getting it wrong is not a duplicate but a **silent replacement**:
    /// the server stores those at a day-derived id, so a second save overwrites the first
    /// and the user never sees what she lost.
    private func open(_ type: EvaEventType) {
        failure = nil
        let existing = model.onePerDayEntry(type, on: day)
        if let existing {
            switch existing.detail {
            case .cycle: cycle = LogCycleDraft(editing: existing)
            case .bodySignals:
                bodySignals = LogBodySignalsDraft(editing: existing, refData: model.refData)
            default: break
            }
        }
        switch type {
        case .cycle: step = .cycle(editing: existing?.id)
        case .bodySignals: step = .bodySignals(editing: existing?.id)
        case .sport: step = .sport(editing: nil)
        case .appointment: step = .appointment(editing: nil)
        case .sex: break
        }
    }

    /// "‹ Back" — to the picker when that is where the sheet started, and out of the sheet
    /// when it did not. An edit opened from a row has no picker behind it, so offering one
    /// would invent a step the user never came through.
    private var back: (() -> Void)? {
        guard case .picker = start else { return nil }
        return { failure = nil; step = .picker }
    }

    private static func step(editing event: EvaEvent) -> Step {
        switch event.type {
        case .cycle: .cycle(editing: event.id)
        case .bodySignals: .bodySignals(editing: event.id)
        case .sport: .sport(editing: event.id)
        case .appointment: .appointment(editing: event.id)
        // Not reachable: a sex entry cannot be written, so nothing offers to edit one.
        case .sex: .picker
        }
    }

    // MARK: - Saving

    private func save(_ payload: EvaEventPayload?, note: String, editing id: String?) {
        // A CTA that is disabled until the form is complete is the primary guard; this is
        // the floor under it, so a payload that cannot be built is never sent as an empty
        // object for the route to reject.
        guard let payload, !isSaving else { return }
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.save(
                    EvaEventWrite(
                        payload: payload,
                        localDate: day,
                        note: note.evaTrimmedNote,
                        idempotencyKey: idempotencyKey
                    ),
                    editing: id
                )
                dismiss()
            } catch let error as APIError {
                // A dead session is already being handled by `AppSession`: the root view
                // has switched away, and an error on a sheet being torn down would be the
                // last thing a user sees on her way to the log-in screen.
                if case .sessionExpired = error { return }
                failure = error.localizedDescription
            } catch {
                failure = APIError.decoding.localizedDescription
            }
        }
    }
}

// MARK: - Chrome

/// The header every form step carries: back, title, close, and the day it is writing to.
struct LogStepHeader: View {

    let title: String
    /// The day, plus whatever the canvas says about the form under it.
    let subtitle: String
    let back: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(spacing: EvaSpacing.xxs) {
            HStack {
                if let back {
                    TextButton(title: "‹ Back", action: back)
                } else {
                    // Keeps the title centred when there is nothing to go back to.
                    Color.clear.frame(width: EvaMetrics.minimumTouchTarget, height: 1)
                }
                Spacer(minLength: EvaSpacing.xs)
                Text(title)
                    .evaTextStyle(.button)
                    .foregroundStyle(Color.evaPrimaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: EvaSpacing.xs)
                LogSheetCloseButton(action: close)
            }

            Text(subtitle)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The sheet's × — a 44pt circle on a 6% ink fill.
///
/// 44 rather than the artboard's 40: §1's minimum touch target, the same trade the month
/// picker's chips took (DESIGN.md §9a).
struct LogSheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.evaControlText)
                .foregroundStyle(Color.evaSecondaryText)
                .frame(
                    width: EvaMetrics.minimumTouchTarget,
                    height: EvaMetrics.minimumTouchTarget
                )
                .background(Color.evaPrimaryText.opacity(0.06), in: .circle)
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("log.close")
    }
}

/// An uppercase section heading — the artboard's `font:600 11px;letter-spacing:.12em`.
///
/// §3's Overline row is 11/600 at .14em; the difference is 0.2pt of tracking on an 11pt
/// label, and the token wins (DESIGN.md §9a's rule for the calendar's surfaces).
struct LogSectionHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .evaTextStyle(.overline)
            .foregroundStyle(Color.evaMutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a failed save says, on the sheet, over the form that still holds everything.
///
/// Information-toned rather than error-toned, the same call `CalendarView`'s load banner
/// makes: nothing the user entered was wrong and nothing was stored — a request failed.
/// The retry is the Save button itself, which is still there and still armed.
struct LogSheetFailure: View {
    let message: String

    var body: some View {
        EvaInfoBanner(title: "That didn't save", message: message) {
            EmptyView()
        }
        .accessibilityIdentifier("log.error")
    }
}

/// The sheets' shared note field — the artboard's collapsed "Add note (optional)" row.
struct LogNoteField: View {

    @Binding var note: String
    var placeholder: String = "Anything worth remembering about today."
    /// `NOTE_LIMIT` in `api/src/index.ts`; an appointment's is far larger.
    var limit: Int = 280
    let identifier: String

    @State private var isOpen = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            if isOpen {
                EvaInputField(
                    label: "Note (optional)",
                    placeholder: placeholder,
                    isFocused: isFocused,
                    errorMessage: note.count > limit
                        ? "Notes are up to \(limit) characters. This one is \(note.count)."
                        : nil,
                    errorIdentifier: "\(identifier).error"
                ) { prompt in
                    TextField("", text: $note, prompt: prompt, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($isFocused)
                        .accessibilityIdentifier(identifier)
                }
            } else {
                Button {
                    isOpen = true
                    isFocused = true
                } label: {
                    HStack {
                        Text(note.isEmpty ? "Add note (optional)" : note)
                            .evaTextStyle(.control)
                            .foregroundStyle(Color.evaSecondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: EvaSpacing.xs)
                        Image(systemName: "chevron.down")
                            .font(.evaLabel)
                            .foregroundStyle(Color.evaDisabledText)
                    }
                    .padding(.horizontal, EvaSpacing.md)
                    .frame(minHeight: EvaControl.height)
                    .background(
                        Color.white.opacity(0.6),
                        in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.evaUndimmed)
                .accessibilityIdentifier("\(identifier).disclose")
            }
        }
        .onAppear {
            // An entry being edited opens with its note already showing: a note hidden
            // behind a row labelled "Add note" is a note the user would have to guess is
            // there, and saving would keep it whether or not she meant to.
            if !note.isEmpty { isOpen = true }
        }
    }
}

// MARK: - The day, as a date picker binds one

extension EvaDay {
    /// A two-way bridge to the `Date` a `DatePicker` works in.
    ///
    /// Midday in the **device's** zone on both sides, not UTC: the picker renders in the
    /// user's zone, so the components that go in are the components that come back. This
    /// is the one place in the calendar where a day becomes an instant, and it is
    /// immediately turned back again.
    static func binding(_ day: Binding<EvaDay>) -> Binding<Date> {
        Binding(
            get: { day.wrappedValue.deviceNoon },
            set: { date in
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day
                else { return }
                day.wrappedValue = EvaDay(year: year, month: month, day: dayOfMonth)
            }
        )
    }

    /// Midday in the **device's** zone. The only instant this day ever becomes, and only
    /// so that a `DatePicker` has something to bind to — `formattingDate` is midday UTC and
    /// is for formatters, which is a different question with a different answer.
    var deviceNoon: Date {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        ) ?? Date()
    }

    /// "Wed 12 August 2026" — the picker header's own format.
    var longLabel: String {
        formattingDate.formatted(
            EvaDay.formatStyle.weekday(.abbreviated).day().month(.wide).year()
        )
    }

    /// "Wed 12 August" — the form headers'.
    var shortLabel: String {
        formattingDate.formatted(EvaDay.formatStyle.weekday(.abbreviated).day().month(.wide))
    }
}

#Preview("Log sheet") {
    CalendarView(session: AppSession(), today: EvaDay(year: 2026, month: 8, day: 18))
}

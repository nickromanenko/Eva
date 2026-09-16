import SwiftUI

/// The canvas' `doctor` sheet: a time, a type, questions to bring, a reminder and notes.
///
/// The one sheet that can be saved onto a **future** day, which is the whole of the date
/// policy's exception: an appointment is a plan, and the other three types are
/// observations of something that has already happened.
///
/// Two departures from the artboard, both reported on #160:
///
/// * The reminder is a **chip**, not the artboard's 52×32 pistachio switch. DESIGN.md §6
///   specifies that toggle and the design system has never built one; building it here
///   would make a feature PR into a design-system PR, and a chip already carries a binary
///   with fill, label colour and elevation moving together (§10).
/// * The questions list starts empty. The artboard seeds it with two written questions,
///   which are neither reference data nor the user's — putting words in her mouth about
///   her own appointment.
struct LogAppointmentStep: View {

    @Binding var draft: LogAppointmentDraft
    let day: EvaDay
    /// `/refdata`'s active appointment types, already in catalogue order.
    let catalogue: [EvaRefData.Item]
    let isEditing: Bool
    let isSaving: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let save: () -> Void

    @FocusState private var isWritingQuestion: Bool

    private let chipColumns = [
        GridItem(.adaptive(minimum: LogBodySignalsMetrics.chipMinimumWidth), spacing: EvaSpacing.xs)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            LogStepHeader(
                title: CalendarEntryPresentation.typeName(for: .appointment),
                subtitle: day.shortLabel,
                back: back,
                close: close
            )

            time
            types
            reminder
            questions

            LogNoteField(
                note: $draft.note,
                placeholder: "What you want to raise, and anything to bring.",
                // `APPOINTMENT_NOTE_LIMIT` — the route says 10 000 here against 280
                // everywhere else, and the artboard says "no length limit".
                limit: 10_000,
                identifier: "log.appointment.note"
            )

            PrimaryButton(
                title: isEditing ? "Save changes" : "Save appointment",
                isLoading: isSaving,
                action: save
            )
        }
    }

    // MARK: - When

    private var time: some View {
        HStack(alignment: .bottom, spacing: EvaSpacing.xs) {
            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("Date")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                // Read-only, as the artboard draws it: the day comes from the picker's own
                // "Change date", and a second control for it here would be two sources of
                // truth for the one field that must not be wrong.
                Text(day.shortLabel)
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(Color.evaPrimaryText)
                    .frame(maxWidth: .infinity, minHeight: EvaControl.height, alignment: .leading)
                    .padding(.horizontal, EvaSpacing.md)
                    .background(
                        Color.evaInputFill,
                        in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                            .strokeBorder(Color.evaControlBorder, lineWidth: 1)
                    }
                    .accessibilityIdentifier("log.appointment.date")
            }

            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("Time")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                // The same call the picker's date control makes: the canvas draws a field
                // and specifies no control, the design system has no time picker, and
                // inventing one is a design decision. The platform's compact picker, tinted.
                DatePicker(
                    "Time",
                    selection: timeBinding,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(Color.evaActionPinkSolid)
                .frame(minHeight: EvaControl.height)
                .accessibilityIdentifier("log.appointment.time")
            }
        }
    }

    /// The draft's wall clock as a `Date`, anchored on the appointment's own day.
    ///
    /// Anchored rather than free-floating so the picker shows the right day's time; only
    /// the hour and minute are read back, and the day never travels through this.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(
                    year: day.year, month: day.month, day: day.day,
                    hour: draft.hour, minute: draft.minute
                )) ?? day.deviceNoon
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? draft.hour
                draft.minute = parts.minute ?? draft.minute
            }
        )
    }

    // MARK: - Type

    @ViewBuilder
    private var types: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            LogSectionHeading("Appointment type")

            if catalogue.isEmpty {
                Text("Eva couldn't load the type list. The appointment still saves without one.")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("log.appointmentTypes.unavailable")
            } else {
                LazyVGrid(columns: chipColumns, spacing: EvaSpacing.xs) {
                    ForEach(catalogue) { item in
                        ChipToggleButton(
                            label: item.label,
                            isSelected: draft.typeCode == item.code,
                            isCentered: true
                        ) {
                            draft.typeCode = draft.typeCode == item.code ? nil : item.code
                        }
                    }
                }
                // The field is addressable as a whole, because its chips are not: their
                // labels are reference data, so a test cannot name one, and `chip.<label>`
                // is set by the component. Without this, "the first chip on the sheet" is
                // whichever one the accessibility tree happens to order first — which on
                // this sheet is sometimes the reminder, and toggling that instead of
                // choosing a type is exactly the mistake the first run of the UI test made.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("log.appointmentTypes")
            }
        }
    }

    // MARK: - Reminder

    private var reminder: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            LogSectionHeading("Reminder")
            ChipToggleButton(
                label: "Remind me · 24 hours before",
                isSelected: draft.remind
            ) {
                draft.remind.toggle()
            }
            // Says what is stored and what is not. Nothing schedules a notification yet —
            // the route stores intent and says so in its own type — and a chip that
            // implied otherwise would be a promise the app cannot keep (§8).
            Text("Saved with the appointment. Eva does not send notifications yet.")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Questions

    private var questions: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            LogSectionHeading("Questions for the doctor")

            ForEach(Array(draft.questions.enumerated()), id: \.offset) { index, question in
                HStack(alignment: .top, spacing: EvaSpacing.sm) {
                    Text(question)
                        .evaTextStyle(.bodyMedium)
                        .foregroundStyle(Color.evaPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        draft.questions.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.evaLabel)
                            .foregroundStyle(Color.evaSecondaryText)
                            .frame(
                                width: EvaMetrics.minimumTouchTarget,
                                height: EvaMetrics.minimumTouchTarget
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.evaUndimmed)
                    .accessibilityLabel("Remove question: \(question)")
                    .accessibilityIdentifier("log.question.remove.\(index)")
                }
                .padding(.leading, EvaSpacing.md)
                .padding(.vertical, EvaSpacing.xxs)
                .background(
                    Color.white.opacity(0.65),
                    in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                }
            }

            if draft.questions.count < LogAppointmentDraft.questionLimit {
                HStack(spacing: EvaSpacing.xs) {
                    EvaInputField(
                        label: "Add a question",
                        placeholder: "Is the iron supplement still needed?",
                        isFocused: isWritingQuestion
                    ) { prompt in
                        // Single-line, unlike the notes field below it. Two reasons, and
                        // the first is not cosmetic: a `TextField(axis: .vertical)` takes
                        // Return as a newline and never fires `onSubmit`, so the obvious
                        // way to add a question would have done nothing. And a question is
                        // one line by construction — the long-form field is Notes.
                        TextField("", text: $draft.draftQuestion, prompt: prompt)
                            .focused($isWritingQuestion)
                            .submitLabel(.done)
                            .onSubmit(addQuestion)
                            .accessibilityIdentifier("log.question.text")
                    }
                    SecondaryButton(title: "Add", action: addQuestion)
                        .disabled(draft.draftQuestion.evaTrimmedNote == nil)
                        // Bottom-aligned with the field, which carries a label above it.
                        .padding(.top, LogAppointmentMetrics.addButtonTopInset)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
    }
}

extension LogAppointmentStep {

    /// Adds what the field is holding, and gives up the keyboard.
    ///
    /// Dropping focus is the load-bearing half. The question list and the Save button are
    /// both **below** this field, so a keyboard that stays up after the question has been
    /// added covers the thing the user came here to press — which is how the UI test found
    /// it: `primary.Save appointment` existed, was under the keyboard, and no amount of
    /// scrolling the sheet reached it.
    fileprivate func addQuestion() {
        draft.addDraftQuestion()
        isWritingQuestion = false
    }
}

enum LogAppointmentMetrics {
    /// The height of `EvaInputField`'s own label row plus its gap, so the Add button lines
    /// up with the field rather than with the label above it.
    static let addButtonTopInset: CGFloat = 24
}

#Preview("Log appointment") {
    @Previewable @State var draft = LogAppointmentDraft()

    return ScrollView {
        LogAppointmentStep(
            draft: $draft,
            day: EvaDay(year: 2026, month: 9, day: 20),
            catalogue: [
                EvaRefData.Item(code: "scan", label: "Scan"),
                EvaRefData.Item(code: "gp", label: "GP"),
                EvaRefData.Item(code: "blood-test", label: "Blood test"),
                EvaRefData.Item(code: "other", label: "Other", freeText: true)
            ],
            isEditing: false,
            isSaving: false,
            back: {},
            close: {},
            save: {}
        )
        .padding(EvaSpacing.lg)
    }
    .background { EvaScreenBackground().ignoresSafeArea() }
}

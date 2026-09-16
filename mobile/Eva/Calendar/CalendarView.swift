import SwiftUI

/// The calendar — the app's landing surface, and the screen every later calendar slice
/// builds on.
///
/// Read and navigate only. Logging is C2 (#160); predictions, phases and the fertile
/// window are C3, which is why nothing here is dashed or patterned — the artboard reserves
/// those two treatments for predicted data, and drawing one now would mean drawing a
/// prediction Eva has not made.
struct CalendarView: View {

    let session: AppSession

    @State private var model: CalendarModel
    @State private var isPickerOpen = false
    @State private var pickerYear: Int
    @Environment(\.scenePhase) private var scenePhase

    init(session: AppSession, today: EvaDay = .today()) {
        self.session = session
        _model = State(initialValue: CalendarModel(source: session, today: today))
        _pickerYear = State(initialValue: today.year)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            EvaScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.md) {
                    CalendarHeader(
                        month: model.visibleMonth,
                        isPickerOpen: isPickerOpen,
                        togglePicker: togglePicker,
                        showPrevious: { page(to: model.visibleMonth.previous) },
                        showNext: { page(to: model.visibleMonth.next) }
                    )

                    CalendarModeChip()

                    if isPickerOpen {
                        CalendarMonthPicker(
                            year: pickerYear,
                            selected: model.visibleMonth,
                            showPreviousYear: { pickerYear -= 1 },
                            showNextYear: { pickerYear += 1 },
                            select: { month in
                                isPickerOpen = false
                                page(to: month)
                            }
                        )
                    }

                    if model.showsEmptyState {
                        emptyStateCard
                    }

                    if case .failed(let message) = model.loadState {
                        loadFailureBanner(message)
                    }

                    grid

                    CalendarDayDetail(
                        day: model.selectedDay,
                        entries: model.events(on: model.selectedDay),
                        refData: model.refData
                    )

                    CalendarLegend()
                }
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.xs)
                // Room for the log button to float over without covering the legend.
                .padding(.bottom, EvaCalendarMetrics.fabSize + EvaSpacing.xl)
            }

            logButton
        }
        .task { await model.start() }
        // `today` is read once when the model is built and this view is kept alive across
        // tab switches, so nothing else would move it: past midnight the grid would ring
        // yesterday and announce it as "Today". `significantTimeChangeNotification` is the
        // system's own midnight-and-time-zone signal; the scene phase covers a device that
        // was asleep through it and is woken straight back onto this screen.
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification
            )
        ) { _ in model.refreshToday() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshToday() }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        CalendarMonthGrid(
            grid: model.grid,
            today: model.today,
            selectedDay: model.selectedDay,
            cycleMark: model.cycleMark(on:),
            glyphs: model.glyphs(on:),
            select: model.select
        )
        // `simultaneousGesture`, not `gesture`: the screen scrolls vertically and the
        // grid pages horizontally, and a plain gesture on the grid would win the vertical
        // drag as well and stop the page scrolling at all. The predominant-axis check in
        // `page(for:)` is what keeps a slightly-diagonal scroll from also changing month.
        .simultaneousGesture(
            DragGesture(minimumDistance: Self.swipeMinimumDistance)
                .onEnded { page(for: $0.translation) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(CalendarHeader.title(for: model.visibleMonth)) calendar")
        .accessibilityIdentifier("calendar.grid")
    }

    /// How far a drag has to travel sideways before it is a page rather than a scroll that
    /// wandered. Not a canvas value — the canvas specifies no motion at all (DESIGN.md
    /// §9c) — so this is the platform's own convention rather than a design decision.
    private static let swipeMinimumDistance: CGFloat = 24
    private static let swipeAxisRatio: CGFloat = 1.5

    private func page(for translation: CGSize) {
        guard abs(translation.width) > abs(translation.height) * Self.swipeAxisRatio,
              abs(translation.width) > Self.swipeMinimumDistance * 2
        else { return }
        page(to: translation.width < 0 ? model.visibleMonth.next : model.visibleMonth.previous)
    }

    private func page(to month: EvaMonth) {
        pickerYear = month.year
        Task { await model.show(month) }
    }

    private func togglePicker() {
        if !isPickerOpen { pickerYear = model.visibleMonth.year }
        isPickerOpen.toggle()
    }

    // MARK: - Empty state

    /// The zero-data card. **Not a modal** — the calendar stays fully explorable, which is
    /// the whole of `SPEC.calEmpty`: someone who has logged nothing can still page through
    /// months, select days and read the legend.
    ///
    /// The first line is the canvas' copy, exactly. The second is the canvas' too, and it
    /// is the sentence that makes the first one a statement rather than an instruction —
    /// it says what Eva needs and what it will not pretend to know without it.
    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text("Log your first period to start predictions.")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can explore the calendar first — nothing is locked. "
                 + "Eva needs one cycle before it estimates anything.")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaGlass(.card, cornerRadius: EvaRadius.card)
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
                .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.empty")
    }

    /// A load that did not land.
    ///
    /// Information-toned, not error-toned, for the reason `AuthRateLimitedBanner` is
    /// (DESIGN.md §9a): nothing the user did was wrong and nothing about their data
    /// changed — a request failed. The grid stays on screen and stays explorable behind it.
    private func loadFailureBanner(_ message: String) -> some View {
        EvaInfoBanner(title: "Your entries didn't load", message: message) {
            TextButton(title: "Try again") {
                Task { await model.retry() }
            }
        }
        .accessibilityIdentifier("calendar.loadError")
    }

    // MARK: - Log button

    /// C2 (#160) turns this on. One line, and it is the only thing standing between the
    /// button below and the log picker.
    private var isLogEnabled: Bool { false }

    /// The artboard's 60pt FAB, and the empty state's pointer at it.
    ///
    /// **Disabled in C1, deliberately.** What it opens is the log picker (`SPEC.picker`),
    /// which is C2 (#160) — so the button is drawn, because the screen is incomplete
    /// without it and the empty state's pointer has to point at something, and it is
    /// `.disabled` rather than silently inert, because a button that takes a tap and does
    /// nothing reads as a broken app while a dimmed one reads as not yet. One line in C2
    /// turns it on. Flagged on #159 rather than decided here.
    private var logButton: some View {
        VStack(alignment: .trailing, spacing: EvaSpacing.xs) {
            if model.showsEmptyState {
                Text("Start here")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaTextOnDark)
                    .padding(.horizontal, EvaSpacing.sm)
                    .padding(.vertical, EvaSpacing.xs)
                    .background(
                        // `background:rgba(40,33,38,.88)` with a white label.
                        Color.evaPrimaryText.opacity(0.88),
                        in: .rect(cornerRadius: EvaRadius.chip, style: .continuous)
                    )
                    .accessibilityIdentifier("calendar.logPointer")
            }

            Button {
                // C2 (#160) opens the log picker here.
            } label: {
                Image(systemName: "plus")
                    .font(.evaH2)
                    // §5's disabled primary, with §9a's label colour: the artboard keeps
                    // the label white on the 28% fill, which measures 1.45:1. Drawn here
                    // rather than left to `.disabled(_:)`, whose dimming does not reach a
                    // fill the label paints itself — the button came out at full strength
                    // and read as working while taking no taps.
                    .foregroundStyle(isLogEnabled ? Color.evaTextOnDark : Color.evaPrimaryText)
                    .frame(width: EvaCalendarMetrics.fabSize, height: EvaCalendarMetrics.fabSize)
                    .background(
                        isLogEnabled ? Color.evaActionPinkSolid : Color.evaPrimaryButtonDisabled,
                        in: .rect(cornerRadius: EvaCalendarMetrics.fabRadius, style: .continuous)
                    )
            }
            .buttonStyle(.evaUndimmed)
            .disabled(!isLogEnabled)
            .accessibilityLabel("Log an event")
            .accessibilityIdentifier("calendar.log")
        }
        .padding(.trailing, EvaSpacing.lg)
        .padding(.bottom, EvaCalendarMetrics.fabBottomInset)
    }
}

#Preview {
    CalendarView(session: AppSession(), today: EvaDay(year: 2026, month: 8, day: 18))
}

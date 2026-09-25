import Foundation

/// Which tab is showing, and the one thing a tab can ask of another.
///
/// The Today card's working actions both leave the Home tab: `Open Calendar` selects the
/// Calendar tab, and `Log now` / `Log period` / `Log test` select it **and** open its log
/// picker. Neither is expressible as a binding on `EvaTabView` alone — the calendar is
/// kept alive across tab switches (see `EvaTabView`), so it is never re-initialised and a
/// constructor parameter would fire once and never again.
///
/// Deliberately small. It is a tab selection and a counter, not a navigation stack: the
/// screens inside a tab push with `NavigationStack`, and the canvas draws no cross-tab
/// destination beyond these two.
@MainActor
@Observable
final class EvaTabRouter {

    /// The tab on screen.
    var selection: EvaTab

    /// Bumped when another tab asks the calendar to open its log picker.
    ///
    /// A counter rather than a flag, so that asking twice is two requests: a user who taps
    /// "Log now", cancels the sheet and taps it again has to get the sheet back, and a
    /// boolean that was already `true` would silently do nothing the second time.
    private(set) var calendarLogRequests = 0

    /// Which day the latest log request asked for. Read by the calendar when
    /// `calendarLogRequests` moves.
    private(set) var calendarLogDay: EvaCalendarLogDay = .selected

    init(selection: EvaTab = .home) {
        self.selection = selection
    }

    func show(_ tab: EvaTab) {
        selection = tab
    }

    /// Go to the calendar and open the log picker.
    ///
    /// The day is still the calendar's to resolve, not this type's: a request says *which
    /// of the calendar's days* — the one it has selected, or its today — and never names a
    /// date. The Today card's actions ask for the selected day (#160, the FAB's day); the
    /// Dashboard's `Log` shortcut asks for today (#100: "Log → calendar type picker on
    /// today"), because a shortcut on the day's briefing is about the day.
    func openCalendarLogPicker(on day: EvaCalendarLogDay = .selected) {
        selection = .calendar
        calendarLogDay = day
        calendarLogRequests += 1
    }
}

/// Which of the calendar's days a log request opens the picker on.
enum EvaCalendarLogDay: Sendable, Equatable {
    /// The day the calendar has selected — the FAB's day.
    case selected
    /// The calendar's today, paged to and selected first.
    case today
}

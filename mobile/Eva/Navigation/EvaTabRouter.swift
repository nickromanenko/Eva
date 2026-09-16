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

    init(selection: EvaTab = .home) {
        self.selection = selection
    }

    func show(_ tab: EvaTab) {
        selection = tab
    }

    /// Go to the calendar and open the log picker on whatever day it has selected.
    ///
    /// The day is the calendar's to decide, not this type's: the picker opens on the
    /// **selected** day (#160), the calendar's selection follows its own page, and a
    /// router that named a day would be overruling it from another screen.
    func openCalendarLogPicker() {
        selection = .calendar
        calendarLogRequests += 1
    }
}

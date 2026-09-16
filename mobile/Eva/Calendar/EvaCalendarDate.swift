import Foundation

// The calendar's own arithmetic, kept away from `Date` on purpose.
//
// The API stores a day as the user's wall clock — `localDate` is "the day the device
// said it was", never derived from an instant, so that a flight across a date line
// cannot move an entry to another day (`api/src/events.ts`, PRD edge case 5). The grid
// has to speak the same language, and the cheapest way to guarantee it is to make an
// instant unrepresentable here: a day is three integers, and nothing in this file adds a
// duration to anything.
//
// That is what makes the grid DST-proof rather than DST-tested. "The day after
// 2026-10-25" is 24 hours later in most of the world and 25 in Europe that night, so a
// grid built by adding 86_400 seconds repeats a cell in the autumn and skips one in the
// spring — in one time zone, twice a year, for one user in a region nobody develops in.
// There is no arithmetic of that shape below to get wrong.

/// The Gregorian calendar with **no time zone in it**.
///
/// Day-of-week and days-in-month are properties of the calendar, not of where the user
/// is standing: 1 August 2026 is a Saturday everywhere. Asking a UTC calendar removes
/// DST from every question this file asks — a `DateComponents` at midnight is a real
/// instant in UTC on every day that has ever existed, which is not true of a zone that
/// springs forward at midnight (Brazil did, until 2019).
///
/// `TimeZone.current` appears exactly once, in `EvaDay.today(in:now:)`, which is the one
/// question that genuinely has a location in it.
private let evaGregorianUTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// A calendar day in the user's wall clock — the `YYYY-MM-DD` the API calls `localDate`.
struct EvaDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses the API's `YYYY-MM-DD`, rejecting anything that is not a day that exists.
    ///
    /// The shape check alone is not enough: `2026-02-30` matches the pattern and is not a
    /// date. The API applies the same two-part rule at its edge (`isCalendarDate`), so a
    /// value this refuses is one the server would have refused to store.
    init?(isoDate: String) {
        let parts = isoDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        guard (1...12).contains(month), day >= 1, day <= EvaMonth(year: year, month: month).dayCount
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The wire form, zero-padded. What goes in `?from=` and `?to=`.
    var isoDate: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { isoDate }

    /// What day it is where the user is.
    ///
    /// The one place a time zone belongs. Injectable so a test can ask the question from
    /// somewhere other than the machine running it — including from a zone that is on
    /// the other side of the date line from UTC, which is the case that catches a
    /// "today" derived from a UTC instant.
    static func today(in timeZone: TimeZone = .current, now: Date = Date()) -> EvaDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return EvaDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// The month this day falls in.
    var evaMonth: EvaMonth { EvaMonth(year: year, month: month) }

    /// Day of the week, **Monday = 0** through Sunday = 6.
    ///
    /// Monday-first because that is what the artboard draws: "Eva App.dc.html" lists
    /// `dowLabels: ['M','T','W','T','F','S','S']`, and its own August 2026 grid sets
    /// `firstDow = 5` — 1 August 2026 is a Saturday, which is index 5 only when Monday
    /// is 0. Not the locale's first weekday, which would put Sunday first in the US.
    var weekdayIndex: Int {
        // Foundation's `.weekday` is 1 = Sunday … 7 = Saturday.
        let foundationWeekday = evaGregorianUTC.component(.weekday, from: utcNoon)
        return (foundationWeekday + 5) % 7
    }

    /// This day, shifted by whole days.
    ///
    /// Real calendar arithmetic in UTC, where a day is always 86_400 seconds, so the
    /// result is a pure Gregorian answer with no zone in it.
    func adding(days: Int) -> EvaDay {
        guard days != 0 else { return self }
        let shifted = evaGregorianUTC.date(byAdding: .day, value: days, to: utcNoon)!
        let parts = evaGregorianUTC.dateComponents([.year, .month, .day], from: shifted)
        return EvaDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Whole days from `other` to `self`, negative if this day is earlier.
    func days(since other: EvaDay) -> Int {
        evaGregorianUTC.dateComponents([.day], from: other.utcNoon, to: utcNoon).day!
    }

    /// Midday UTC, the only `Date` this type ever makes.
    ///
    /// Midday rather than midnight so the value sits far from any boundary a formatter or
    /// a calendar might round across; the components are read back in the same UTC
    /// calendar that produced it, so the hour is never observable.
    private var utcNoon: Date {
        evaGregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// A `Date` in UTC for the formatters that need one — month and weekday names.
    ///
    /// **Only ever format this with `EvaDay.formatStyle`.** See its note.
    var formattingDate: Date { utcNoon }

    /// The format style every calendar string is built from.
    ///
    /// Anchored in UTC, because `formattingDate` is. `Date.formatted(.dateTime…)` renders
    /// in the *device's* zone by default, and midday UTC is the small hours of the next
    /// day anywhere east of UTC+11 — so the cell for the 12th would announce itself as the
    /// 13th in Auckland, Suva and Apia, and the month header would name the wrong month for
    /// two days in every thirty. The locale is still the user's; only the anchor is fixed.
    static var formatStyle: Date.FormatStyle {
        Date.FormatStyle(locale: .autoupdatingCurrent, timeZone: .gmt)
    }

    static func < (lhs: EvaDay, rhs: EvaDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// A year and a month. The unit the event cache is keyed by, and the unit the grid pages.
struct EvaMonth: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    /// 1 = January.
    let month: Int

    init(year: Int, month: Int) {
        // Normalised so `EvaMonth(year: 2026, month: 13)` can never exist as a key that
        // means the same month as `EvaMonth(year: 2027, month: 1)` but does not equal it.
        let zeroBased = month - 1
        let yearShift = Int((Double(zeroBased) / 12).rounded(.down))
        self.year = year + yearShift
        self.month = zeroBased - yearShift * 12 + 1
    }

    static func containing(_ day: EvaDay) -> EvaMonth { day.evaMonth }

    var firstDay: EvaDay { EvaDay(year: year, month: month, day: 1) }
    var lastDay: EvaDay { EvaDay(year: year, month: month, day: dayCount) }

    /// How many days this month has. February answers 29 in a leap year because the
    /// calendar says so, not because this file counts.
    var dayCount: Int {
        let start = evaGregorianUTC.date(from: DateComponents(year: year, month: month, day: 1))!
        return evaGregorianUTC.range(of: .day, in: .month, for: start)!.count
    }

    func adding(months: Int) -> EvaMonth {
        EvaMonth(year: year, month: month + months)
    }

    var next: EvaMonth { adding(months: 1) }
    var previous: EvaMonth { adding(months: -1) }

    /// Whole months from `other` to `self`. Used to decide whether two months are
    /// adjacent enough to fetch in one range.
    func months(since other: EvaMonth) -> Int {
        (year - other.year) * 12 + (month - other.month)
    }

    /// Whether every day of this month falls inside `from…to` inclusive. A month only
    /// enters the cache as *loaded* when this is true — a range that clipped it would
    /// otherwise cache a half-answer as a whole one.
    func isFullyCovered(from: EvaDay, to: EvaDay) -> Bool {
        from <= firstDay && lastDay <= to
    }

    var description: String { String(format: "%04d-%02d", year, month) }

    static func < (lhs: EvaMonth, rhs: EvaMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

/// One month laid out as the artboard draws it: **always six rows of seven**, Monday
/// first, with the surrounding month's days filling the corners.
///
/// Six rows always, not "as many as the month needs". The artboard's own loop is
/// `for(let row=0;row<6;row++)`, and the reason is behavioural rather than decorative: a
/// grid that grew and shrank between months would move the day detail and the legend up
/// and down under the user's thumb as they page.
struct EvaMonthGrid: Sendable, Equatable {
    static let columnCount = 7
    static let rowCount = 6
    static let cellCount = columnCount * rowCount

    /// Where a cell sits relative to the month being shown.
    enum Placement: Sendable, Hashable {
        /// The tail of the previous month, filling the first row.
        case leadingAdjacent
        /// A day of this month.
        case inMonth
        /// The head of the next month, filling the last rows.
        case trailingAdjacent

        var isInMonth: Bool { self == .inMonth }
    }

    struct Cell: Hashable, Identifiable, Sendable {
        let date: EvaDay
        let placement: Placement
        var id: EvaDay { date }
    }

    let month: EvaMonth
    let cells: [Cell]

    init(month: EvaMonth) {
        self.month = month
        let leading = month.firstDay.weekdayIndex
        let start = month.firstDay.adding(days: -leading)
        // One `adding(days:)` per cell from a single anchor, rather than each cell from
        // the one before it: an error in a single step would otherwise propagate through
        // every cell after it, and the cells that matter most — the month boundaries —
        // are the furthest from the anchor.
        self.cells = (0..<Self.cellCount).map { offset in
            let date = start.adding(days: offset)
            let placement: Placement =
                date.evaMonth == month ? .inMonth
                : (date < month.firstDay ? .leadingAdjacent : .trailingAdjacent)
            return Cell(date: date, placement: placement)
        }
    }

    /// The first and last day the grid actually draws — the range a fetch has to cover
    /// for this page to be complete.
    var visibleRange: ClosedRange<EvaDay> {
        cells.first!.date...cells.last!.date
    }

    /// The months the grid touches, in order. At most three: a 42-cell grid can reach one
    /// month back and one forward, never two.
    var visibleMonths: [EvaMonth] {
        var seen: [EvaMonth] = []
        for cell in cells where !seen.contains(cell.date.evaMonth) {
            seen.append(cell.date.evaMonth)
        }
        return seen
    }
}

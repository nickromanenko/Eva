import Foundation
import Testing
@testable import Eva

/// Issue #159: **the month grid's date maths.**
///
/// The grid is the surface every later calendar slice draws on, so the arithmetic under it
/// is worth more coverage than the pixels over it. Two classes of bug are what this suite
/// is for, and both are silent:
///
/// * **Month boundaries.** A grid that is off by one at the start of a month puts every
///   entry on the wrong weekday for that month and nowhere else, which is the kind of
///   thing that ships.
/// * **DST.** `EvaDay` is three integers and `adding(days:)` asks a UTC calendar, so a
///   clock change cannot repeat or skip a cell. That is a design claim, and these are the
///   tests that hold it to it — including the day the clocks actually change, in the zones
///   where they change at a time that would break a naive implementation.
@Suite("Issue #159 · month grid date maths")
struct CalendarGridTests {

    // MARK: - Shape

    @Test("A grid is always six rows of seven")
    func gridIsAlwaysFortyTwoCells() {
        // Every shape a month can have: 28 days starting on a Monday is the least a grid
        // has to hold, 31 days starting on a Sunday the most (37 cells).
        for year in 2024...2027 {
            for month in 1...12 {
                let grid = EvaMonthGrid(month: EvaMonth(year: year, month: month))
                #expect(grid.cells.count == EvaMonthGrid.cellCount)
                #expect(grid.cells.count == 42)
            }
        }
    }

    @Test("Every cell is the day after the one before it")
    func cellsAreConsecutive() {
        let grid = EvaMonthGrid(month: EvaMonth(year: 2026, month: 8))
        for (earlier, later) in zip(grid.cells, grid.cells.dropFirst()) {
            #expect(later.date == earlier.date.adding(days: 1),
                    "\(earlier.date) is not followed by \(later.date)")
        }
        #expect(Set(grid.cells.map(\.date)).count == 42, "The grid repeated a day")
    }

    /// The artboard's own August 2026 grid sets `firstDow = 5`, and 1 August 2026 is a
    /// Saturday — which is index 5 only when Monday is 0. This is the test that pins the
    /// week to Monday, which is the canvas' choice and not the US locale's.
    @Test("The week starts on Monday, as the artboard draws it")
    func weeksStartOnMonday() {
        #expect(EvaDay(year: 2026, month: 8, day: 1).weekdayIndex == 5)
        #expect(EvaDay(year: 2026, month: 8, day: 3).weekdayIndex == 0, "3 Aug 2026 is a Monday")
        #expect(EvaDay(year: 2026, month: 8, day: 9).weekdayIndex == 6, "9 Aug 2026 is a Sunday")

        let grid = EvaMonthGrid(month: EvaMonth(year: 2026, month: 8))
        #expect(grid.cells.first?.date == EvaDay(year: 2026, month: 7, day: 27))
        #expect(grid.cells.first?.placement == .leadingAdjacent)
        #expect(grid.cells.prefix(5).allSatisfy { $0.placement == .leadingAdjacent })
        #expect(grid.cells[5].date == EvaDay(year: 2026, month: 8, day: 1))
        #expect(grid.cells[5].placement == .inMonth)
    }

    @Test("A month that starts on a Monday has no leading days")
    func monthStartingOnMondayHasNoLeadingCells() {
        // 1 June 2026 is a Monday.
        let grid = EvaMonthGrid(month: EvaMonth(year: 2026, month: 6))
        #expect(grid.cells.first?.date == EvaDay(year: 2026, month: 6, day: 1))
        #expect(grid.cells.first?.placement == .inMonth)
        #expect(grid.cells.filter { $0.placement == .inMonth }.count == 30)
    }

    @Test("A grid touches at most three months, and always names them in order")
    func gridNeverSpansMoreThanThreeMonths() {
        for year in 2024...2027 {
            for month in 1...12 {
                let grid = EvaMonthGrid(month: EvaMonth(year: year, month: month))
                let months = grid.visibleMonths
                #expect(months.count <= 3, "\(grid.month) spans \(months)")
                #expect(months.contains(grid.month))
                #expect(months == months.sorted())
            }
        }
    }

    // MARK: - Month boundaries

    @Test("February knows about leap years")
    func februaryLength() {
        #expect(EvaMonth(year: 2024, month: 2).dayCount == 29)
        #expect(EvaMonth(year: 2025, month: 2).dayCount == 28)
        #expect(EvaMonth(year: 2100, month: 2).dayCount == 28, "2100 is not a leap year")
        #expect(EvaMonth(year: 2000, month: 2).dayCount == 29, "2000 is a leap year")
    }

    @Test("A grid for a short February still ends in the next month")
    func shortFebruaryFillsTheTail() {
        // 1 Feb 2026 is a Sunday: six leading cells, 28 in month, eight trailing.
        let grid = EvaMonthGrid(month: EvaMonth(year: 2026, month: 2))
        #expect(grid.cells.filter { $0.placement == .leadingAdjacent }.count == 6)
        #expect(grid.cells.filter { $0.placement == .inMonth }.count == 28)
        #expect(grid.cells.filter { $0.placement == .trailingAdjacent }.count == 8)
        #expect(grid.cells.last?.date == EvaDay(year: 2026, month: 3, day: 8))
    }

    @Test("Paging crosses the year boundary in both directions")
    func yearBoundary() {
        #expect(EvaMonth(year: 2026, month: 12).next == EvaMonth(year: 2027, month: 1))
        #expect(EvaMonth(year: 2026, month: 1).previous == EvaMonth(year: 2025, month: 12))
        #expect(EvaDay(year: 2026, month: 12, day: 31).adding(days: 1)
                == EvaDay(year: 2027, month: 1, day: 1))
        #expect(EvaDay(year: 2027, month: 1, day: 1).adding(days: -1)
                == EvaDay(year: 2026, month: 12, day: 31))
        // 2024 is a leap year, so the day after 28 February is the 29th.
        #expect(EvaDay(year: 2024, month: 2, day: 28).adding(days: 1)
                == EvaDay(year: 2024, month: 2, day: 29))
        #expect(EvaDay(year: 2025, month: 2, day: 28).adding(days: 1)
                == EvaDay(year: 2025, month: 3, day: 1))
    }

    @Test("A month out of range normalises rather than existing twice")
    func monthsNormalise() {
        // Two keys that mean the same month would split the event cache in half.
        #expect(EvaMonth(year: 2026, month: 13) == EvaMonth(year: 2027, month: 1))
        #expect(EvaMonth(year: 2026, month: 0) == EvaMonth(year: 2025, month: 12))
        #expect(EvaMonth(year: 2026, month: -11) == EvaMonth(year: 2025, month: 1))
        #expect(EvaMonth(year: 2026, month: 25) == EvaMonth(year: 2028, month: 1))
        #expect(EvaMonth(year: 2026, month: 6).adding(months: -18) == EvaMonth(year: 2024, month: 12))
    }

    // MARK: - Daylight saving

    /// The grids for the months in which the clocks actually change, in the zones where
    /// they change at a time that breaks the naive implementation.
    ///
    /// A grid built by adding 86_400 seconds to a local midnight repeats a day in the
    /// autumn and skips one in the spring; Brazil used to move its clocks *at* midnight,
    /// which is why "midnight on the 15th" is a date that has not always existed. Nothing
    /// here can produce either, because nothing here adds a duration to a local time —
    /// the assertion is that all 42 days are distinct and consecutive regardless.
    @Test(
        "A clock change neither repeats nor skips a cell",
        arguments: [
            // US spring forward, 8 March 2026, 02:00 local.
            EvaMonth(year: 2026, month: 3),
            // US fall back, 1 November 2026.
            EvaMonth(year: 2026, month: 11),
            // EU last Sunday in March / October 2026.
            EvaMonth(year: 2026, month: 10),
            // Southern hemisphere, and the month Brazil used to change at midnight.
            EvaMonth(year: 2018, month: 11),
            EvaMonth(year: 2018, month: 2)
        ]
    )
    func daylightSavingDoesNotDisturbTheGrid(month: EvaMonth) {
        let grid = EvaMonthGrid(month: month)
        #expect(Set(grid.cells.map(\.date)).count == 42)
        for (earlier, later) in zip(grid.cells, grid.cells.dropFirst()) {
            #expect(later.date == earlier.date.adding(days: 1))
        }
        #expect(grid.cells.filter { $0.placement == .inMonth }.count == month.dayCount)
    }

    /// The other half of the same claim: a run of single-day steps across a clock change
    /// lands where a single multi-day step lands.
    @Test("Stepping a day at a time agrees with stepping many at once")
    func singleAndMultiDayStepsAgree() {
        var walked = EvaDay(year: 2026, month: 10, day: 20)
        for _ in 0..<40 { walked = walked.adding(days: 1) }
        #expect(walked == EvaDay(year: 2026, month: 10, day: 20).adding(days: 40))
        #expect(walked == EvaDay(year: 2026, month: 11, day: 29))
        #expect(walked.days(since: EvaDay(year: 2026, month: 10, day: 20)) == 40)
    }

    // MARK: - Today, and the wall clock

    /// "Today" is the one question with a location in it, and the date line is where a
    /// UTC-derived answer would be visibly wrong: at the same instant, two real zones are
    /// on two different days.
    @Test("Today is the user's day, not UTC's")
    func todayFollowsTheUsersZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        // One instant on which three real places are on three different dates.
        let instant = utc.date(
            from: DateComponents(year: 2026, month: 8, day: 12, hour: 10, minute: 30)
        )!

        // Kiritimati is UTC+14 all year; Niue is UTC-11 all year.
        #expect(EvaDay.today(in: TimeZone(identifier: "Pacific/Kiritimati")!, now: instant)
                == EvaDay(year: 2026, month: 8, day: 13))
        #expect(EvaDay.today(in: .gmt, now: instant)
                == EvaDay(year: 2026, month: 8, day: 12))
        #expect(EvaDay.today(in: TimeZone(identifier: "Pacific/Niue")!, now: instant)
                == EvaDay(year: 2026, month: 8, day: 11))
    }

    /// Beirut moves its clocks **at midnight**, so 00:30 on the last Sunday in March is a
    /// local time that does not exist there. Asking what day it is has to survive that.
    @Test("A zone whose clocks change at midnight still has a today")
    func todaySurvivesAMidnightClockChange() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let beirut = TimeZone(identifier: "Asia/Beirut")!
        // Well after the jump, whatever offset the shipped tzdata gives Lebanon.
        let afterTheJump = utc.date(
            from: DateComponents(year: 2026, month: 3, day: 29, hour: 0, minute: 30)
        )!
        #expect(EvaDay.today(in: beirut, now: afterTheJump)
                == EvaDay(year: 2026, month: 3, day: 29))
        // And an hour either side of the transition itself: 2026-03-28T23:00:00Z is
        // 01:00 or 02:00 on the 29th in Beirut depending on the rule, and the day is the
        // 29th either way — which is what this is asserting.
        let atTheJump = utc.date(
            from: DateComponents(year: 2026, month: 3, day: 28, hour: 23, minute: 0)
        )!
        #expect(EvaDay.today(in: beirut, now: atTheJump)
                == EvaDay(year: 2026, month: 3, day: 29))
    }

    /// Every string the calendar draws is built from `formattingDate`, which is midday
    /// UTC. `Date.formatted(.dateTime…)` renders in the *device's* zone, so an unanchored
    /// style turns midday UTC into the small hours of the next day anywhere east of
    /// UTC+11 — the cell for the 12th would announce itself as the 13th in Auckland, and
    /// the month header would name the wrong month for two days in every thirty.
    @Test("A day formats as the day it is, not as the device's reading of an instant")
    func formattingIsAnchoredToTheDay() {
        #expect(EvaDay.formatStyle.timeZone == TimeZone.gmt,
                "The calendar's format style is anchored to the device, not to the day")

        let day = EvaDay(year: 2026, month: 8, day: 12)
        let american = EvaDay.formatStyle.locale(Locale(identifier: "en_US"))
        #expect(day.formattingDate.formatted(american.month(.wide).day().year())
                == "August 12, 2026")

        // The failure this guards, shown rather than described: the same instant, read in
        // a real zone the app has to work in, is a different date.
        let kiritimati = Date.FormatStyle(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Pacific/Kiritimati")!
        )
        #expect(day.formattingDate.formatted(kiritimati.month(.wide).day().year())
                == "August 13, 2026")
    }

    @Test("A day round-trips through its wire form")
    func isoRoundTrip() {
        let day = EvaDay(year: 2026, month: 8, day: 3)
        #expect(day.isoDate == "2026-08-03", "The wire form must be zero-padded")
        #expect(EvaDay(isoDate: "2026-08-03") == day)
        #expect(EvaDay(isoDate: "2026-12-31") == EvaDay(year: 2026, month: 12, day: 31))
    }

    @Test("A day that does not exist is not a day")
    func rejectsImpossibleDates() {
        // The same two-part rule the API applies at its edge: the shape *and* the day.
        #expect(EvaDay(isoDate: "2026-02-30") == nil)
        #expect(EvaDay(isoDate: "2025-02-29") == nil)
        #expect(EvaDay(isoDate: "2024-02-29") != nil, "2024 is a leap year")
        #expect(EvaDay(isoDate: "2026-13-01") == nil)
        #expect(EvaDay(isoDate: "2026-00-10") == nil)
        #expect(EvaDay(isoDate: "2026-08-00") == nil)
        #expect(EvaDay(isoDate: "2026-8-03") == nil, "Not zero-padded")
        #expect(EvaDay(isoDate: "2026-08-03T00:00:00") == nil)
        #expect(EvaDay(isoDate: "") == nil)
        #expect(EvaDay(isoDate: "not-a-date") == nil)
    }

    // MARK: - Coverage

    @Test("A month only counts as cached when the range held all of it")
    func coverageIsAllOrNothing() {
        let august = EvaMonth(year: 2026, month: 8)
        #expect(august.isFullyCovered(
            from: EvaDay(year: 2026, month: 8, day: 1),
            to: EvaDay(year: 2026, month: 8, day: 31)
        ))
        #expect(august.isFullyCovered(
            from: EvaDay(year: 2026, month: 7, day: 15),
            to: EvaDay(year: 2026, month: 9, day: 2)
        ))
        // The first load's window starts mid-month. Caching that month whole would leave
        // the days before the cut permanently blank.
        #expect(!august.isFullyCovered(
            from: EvaDay(year: 2026, month: 8, day: 2),
            to: EvaDay(year: 2026, month: 9, day: 30)
        ))
        #expect(!august.isFullyCovered(
            from: EvaDay(year: 2026, month: 8, day: 1),
            to: EvaDay(year: 2026, month: 8, day: 30)
        ))
    }
}

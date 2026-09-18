import Foundation
import Testing
@testable import Eva

/// Issue #206: **the calendar draws what the API predicted, and derives nothing.**
///
/// Three claims, and each one is a way the overlay could be wrong without looking wrong:
///
/// * the days on the grid are the days the response named, clipped and cached by the same
///   rules the entries are — not a second fetch model bolted onto one screen;
/// * a **withheld** prediction and a prediction that simply *falls outside the range* are
///   different states with different words, and neither is inferred from an empty list;
/// * nothing on this path computes a date. That last one is asserted by reading the source,
///   below, because it is the one a green suite would otherwise happily keep quiet about:
///   a helper that extends the predicted period by four days draws four extra cells and
///   breaks no expectation anywhere in this repo.
///
/// The pixels are `CalendarPredictionRenderTests`; the words on the cells are
/// `CalendarPredictionUITests`.
@Suite("Issue #206 · the prediction overlay")
@MainActor
struct CalendarPredictionTests {

    typealias RecordingSource = RecordingCalendarSource

    static let today = EvaDay(year: 2026, month: 8, day: 18)
    static func day(_ day: Int, month: Int = 8) -> EvaDay {
        EvaDay(year: 2026, month: month, day: day)
    }

    /// The artboard's own August: a fertile window over 17–21, one predicted period day on
    /// the 31st.
    static func answer(
        confidence: EvaPredictionConfidence? = .narrow,
        withheld: EvaPredictionWithheld? = nil
    ) -> EvaCyclePredictions {
        EvaCyclePredictions(
            from: day(1, month: 1), to: EvaDay(year: 2027, month: 12, day: 31),
            predictedPeriod: withheld == nil ? [day(31)] : [],
            fertileWindow: withheld == nil ? Set((17...21).map { day($0) }) : [],
            confidence: withheld == nil ? confidence : nil,
            withheld: withheld
        )
    }

    // MARK: - The wire

    @Test("The route's body decodes into the days the grid draws")
    func theBodyDecodes() throws {
        let json = """
        {"from":"2026-08-01","to":"2026-08-31",
         "predictedPeriod":["2026-08-31"],
         "fertileWindow":["2026-08-17","2026-08-18"],
         "peak":["2026-08-17"],
         "confidence":"wide","withheld":null}
        """
        let answer = try JSONDecoder().decode(
            EvaCyclePredictions.self, from: Data(json.utf8)
        )

        #expect(answer.from == Self.day(1))
        #expect(answer.to == Self.day(31))
        #expect(answer.predictedPeriod == [Self.day(31)])
        #expect(answer.fertileWindow == [Self.day(17), Self.day(18)])
        #expect(answer.confidence == .wide)
        #expect(answer.withheld == nil)
    }

    @Test(
        "Every withheld reason the API can send decodes to its own case",
        arguments: [
            ("no-flow-logged", EvaPredictionWithheld.noFlowLogged),
            ("too-few-counted-cycles", .tooFewCountedCycles),
            ("irregular-cycles", .irregularCycles)
        ]
    )
    func everyWithheldReasonDecodes(wire: String, expected: EvaPredictionWithheld) throws {
        let json = """
        {"from":"2026-08-01","to":"2026-08-31","predictedPeriod":[],"fertileWindow":[],
         "peak":[],"confidence":null,"withheld":"\(wire)"}
        """
        let answer = try JSONDecoder().decode(
            EvaCyclePredictions.self, from: Data(json.utf8)
        )
        #expect(answer.withheld == expected)
        #expect(answer.confidence == nil)
    }

    /// A date this cannot parse is refused, not skipped. A dropped day is a fertile window
    /// with a hole in it, which is worse than no window at all.
    @Test("A day that is not a date fails the decode instead of vanishing")
    func aBadDayIsRefused() {
        let json = """
        {"from":"2026-08-01","to":"2026-08-31","predictedPeriod":["2026-02-30"],
         "fertileWindow":[],"peak":[],"confidence":"narrow","withheld":null}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EvaCyclePredictions.self, from: Data(json.utf8))
        }
    }

    // MARK: - The request shape

    @Test("The overlay is asked for over the same range as the entries, once")
    func oneRequestPerRange() async throws {
        let source = RecordingSource()
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(source.predictionRanges.count == 1,
                "The first load made \(source.predictionRanges.count) prediction requests")
        let events = try #require(source.ranges.first)
        let overlay = try #require(source.predictionRanges.first)
        // One range, ending where the entries' range ends — so the overlay reaches every
        // cell the grid can draw without a second fetch model on the screen.
        #expect(overlay.upperBound == events.upperBound)
        // It starts at a month boundary rather than at the events range's own start. The
        // 400-day window opens mid-month, and a month the response only partly covers
        // cannot be cached as answered by either half.
        #expect(overlay.lowerBound == overlay.lowerBound.evaMonth.firstDay)
        #expect(overlay.lowerBound >= events.lowerBound)
        #expect(overlay.lowerBound.evaMonth <= events.lowerBound.evaMonth.next)
        // Every cell of the month on screen is inside it, which is the point of asking.
        let grid = EvaMonthGrid(month: model.visibleMonth)
        #expect(overlay.contains(grid.visibleRange.lowerBound))
        #expect(overlay.contains(grid.visibleRange.upperBound))
    }

    @Test("Paging inside what is already cached asks for no overlay")
    func pagingWithinTheCacheIsFree() async {
        let source = RecordingSource()
        source.prediction = Self.answer()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        let afterFirstLoad = source.predictionRanges.count

        // Backwards and back again: the first load warmed thirteen months of history, so
        // July's three-month neighbourhood is entirely inside it. (Forwards is not — the
        // window ends at the end of *next* month, so paging there reaches into October,
        // which is `pagingOutOfTheCacheAsksAgain`'s case.)
        await model.showPreviousMonth()
        await model.showNextMonth()

        #expect(source.predictionRanges.count == afterFirstLoad,
                "Paging inside the cache asked for the overlay again")
    }

    @Test("Paging past the cache asks once, and keeps what it already had")
    func pagingOutOfTheCacheAsksAgain() async {
        let source = RecordingSource()
        source.prediction = Self.answer()
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        let afterFirstLoad = source.predictionRanges.count

        // Far enough out that neither cache holds it.
        await model.show(EvaMonth(year: 2027, month: 6))

        #expect(source.predictionRanges.count == afterFirstLoad + 1)
        // …and August's window is still drawn. A response names only the days inside its
        // own range, so replacing rather than merging would have un-drawn it.
        #expect(model.predictions(on: Self.day(18)) == [.fertileWindow])
    }

    // MARK: - What lands on the cells

    @Test("The predicted days are the response's days, and no others")
    func theDaysAreTheServersDays() async {
        let source = RecordingSource()
        source.prediction = Self.answer()
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        for day in 17...21 {
            #expect(model.predictions(on: Self.day(day)) == [.fertileWindow],
                    "August \(day) should be in the fertile window")
        }
        #expect(model.predictions(on: Self.day(31)) == [.period])
        // The days either side of the window, and the days either side of the predicted
        // period. **The period is one day**: `cycle.ts` gives a start and no length, so
        // anything that "rounded it up to a period" would light these.
        for day in [16, 22, 30] {
            #expect(model.predictions(on: Self.day(day)).isEmpty,
                    "August \(day) is not predicted and should draw nothing")
        }
        #expect(model.predictions(on: Self.day(1, month: 9)).isEmpty)
    }

    @Test("A day that is both announces and draws the fertile window first")
    func bothMarksAreOrderedTheArtboardsWay() async {
        let source = RecordingSource()
        source.prediction = EvaCyclePredictions(
            from: Self.day(1), to: Self.day(31),
            predictedPeriod: [Self.day(21)],
            fertileWindow: [Self.day(21)],
            confidence: .narrow
        )
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.predictions(on: Self.day(21)) == [.fertileWindow, .period],
                "mkCell tries the fertile window before the predicted period")
    }

    @Test("A withheld prediction draws nothing at all")
    func withheldDrawsNothing() async {
        for reason in [
            EvaPredictionWithheld.noFlowLogged, .tooFewCountedCycles, .irregularCycles
        ] {
            let source = RecordingSource()
            source.prediction = Self.answer(withheld: reason)
            let model = CalendarModel(source: source, today: Self.today)

            await model.start()

            let grid = EvaMonthGrid(month: model.visibleMonth)
            for cell in grid.cells {
                #expect(model.predictions(on: cell.date).isEmpty,
                        "\(cell.date) is drawn as predicted with \(reason.rawValue) withheld")
            }
        }
    }

    // MARK: - The card

    @Test("Each withheld reason gets its own sentence, and says what would change it")
    func theThreeReasonsAreThreeSentences() async throws {
        var titles: Set<String> = []
        var bodies: Set<String> = []

        for reason in [
            EvaPredictionWithheld.noFlowLogged, .tooFewCountedCycles, .irregularCycles
        ] {
            let source = RecordingSource()
            source.prediction = Self.answer(withheld: reason)
            source.events = [CalendarModelTests.event("e1", on: Self.day(2))]
            let model = CalendarModel(source: source, today: Self.today)

            await model.start()

            let summary = try #require(model.summary, "\(reason.rawValue) showed no card")
            titles.insert(summary.title)
            bodies.insert(summary.body)
            // Never a date and never a band: there is no prediction to qualify.
            #expect(!summary.body.contains("estimated around"))
        }

        #expect(titles.count == 3, "Two withheld reasons share a heading: \(titles)")
        #expect(bodies.count == 3, "Two withheld reasons share a body: \(bodies)")
    }

    /// A27, and the reason the field exists at all: a wide band is a prediction from a few
    /// cycles and a narrow one is a prediction from more, and the card has to read
    /// differently for them.
    @Test("A wide band does not read like a narrow one")
    func aWideBandIsNotACertainty() async throws {
        func card(_ confidence: EvaPredictionConfidence) async throws -> CalendarSummary {
            let source = RecordingSource()
            source.prediction = Self.answer(confidence: confidence)
            source.events = [CalendarModelTests.event("e1", on: Self.day(2))]
            let model = CalendarModel(source: source, today: Self.today)
            await model.start()
            return try #require(model.summary)
        }

        let wide = try await card(.wide)
        let narrow = try await card(.narrow)

        #expect(wide.body != narrow.body, "Both bands render the same sentence")
        #expect(wide.body.localizedCaseInsensitiveContains("wide"))
        // Both hedge — v1 has no confirmed-ovulation path, so neither band may promise.
        #expect(wide.body.localizedCaseInsensitiveContains("estimate"))
        #expect(narrow.body.localizedCaseInsensitiveContains("estimate"))
        // Neither restates a threshold `config.ts` owns: A27's bands are 3–5 and 6+, and a
        // number here is a second copy of `narrowBandMinCycles`.
        for sentence in [wide.body, narrow.body] {
            #expect(sentence.rangeOfCharacter(from: .decimalDigits) == nil,
                    "The confidence sentence names a number the server owns: \(sentence)")
        }
        // And the date is still stated, from the day the server named and no other.
        #expect(wide.title.contains(Self.rendered(Self.day(31))))
        #expect(!wide.title.contains(Self.rendered(Self.day(30))))
    }

    /// A day as the card writes it. Built through the app's own format style rather than
    /// spelled out, because the *order* is the locale's — "31 Aug" here, "Aug 31" on a US
    /// simulator — and what this suite is asserting is **which day is named**, not how the
    /// user's region writes it down.
    static func rendered(_ day: EvaDay) -> String {
        day.formattingDate.formatted(EvaDay.formatStyle.day().month(.abbreviated))
    }

    /// The distinction C12a put a field on the wire for. Empty lists with no reason is
    /// "not in this range"; empty lists with a reason is "a gate closed".
    @Test("Out of range is not the same card as withheld")
    func outOfRangeIsNotWithheld() async throws {
        let source = RecordingSource()
        source.prediction = EvaCyclePredictions(
            from: Self.day(1), to: Self.day(31),
            predictedPeriod: [EvaDay(year: 2027, month: 5, day: 4)],
            fertileWindow: [],
            confidence: .narrow
        )
        source.events = [CalendarModelTests.event("e1", on: Self.day(2))]
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        let summary = try #require(model.summary)
        for reason in [
            EvaPredictionWithheld.noFlowLogged, .tooFewCountedCycles, .irregularCycles
        ] {
            #expect(summary.title != reason.title,
                    "An out-of-range prediction is being explained as \(reason.rawValue)")
        }
        // It still says which band it is, because there *is* a prediction.
        #expect(summary.body.localizedCaseInsensitiveContains("estimate"))
    }

    @Test("No card until an answer has landed, and none over the empty state")
    func theCardWaitsForAnAnswer() async {
        let source = RecordingSource()
        source.predictionFailure = APIError.server(
            code: "SERVICE_UNAVAILABLE", message: "not available", status: 503
        )
        source.events = [CalendarModelTests.event("e1", on: Self.day(2))]
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.summary == nil,
                "A 503 from the route invented a card; there is nothing to say")

        // …and on an account with no history the empty state is the whole message.
        let empty = RecordingSource()
        empty.prediction = Self.answer(withheld: .noFlowLogged)
        let emptyModel = CalendarModel(source: empty, today: Self.today)
        await emptyModel.start()
        #expect(emptyModel.showsEmptyState)
        #expect(emptyModel.summary == nil, "The summary card doubled up with the empty state")
    }

    // MARK: - The overlay never takes the screen down with it

    /// The route answers `503` in every environment that has not configured `CYCLE_*`,
    /// which is all of them (#176, #191). A calendar that showed a failure card for that
    /// would be reporting a feature that is not switched on as a broken load.
    @Test("A prediction that will not load leaves the entries and the screen alone")
    func aFailedOverlayIsNotAFailedScreen() async {
        let source = RecordingSource()
        source.predictionFailure = APIError.server(
            code: "SERVICE_UNAVAILABLE", message: "not available", status: 503
        )
        source.events = [CalendarModelTests.event("e1", on: Self.day(12))]
        let model = CalendarModel(source: source, today: Self.today)

        await model.start()

        #expect(model.loadState == .idle, "A 503 on the overlay failed the whole screen")
        #expect(model.events(on: Self.day(12)).count == 1, "The entries went missing with it")
        #expect(model.predictions(on: Self.day(12)).isEmpty)
    }

    // MARK: - The overlay follows the data it is derived from

    /// A25 item 5, as the user meets it: the estimate is derived from her logged periods on
    /// every read, so logging one has to move it. Without this the first period a new user
    /// logs clears the empty state and leaves "Log a period and Eva can start estimating"
    /// on screen underneath.
    @Test("Logging a period re-asks for the estimate; logging a run does not")
    func aCycleWriteRefreshesTheOverlay() async throws {
        let source = RecordingSource()
        source.prediction = Self.answer(withheld: .noFlowLogged)
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        let afterLoad = source.predictionRanges.count

        source.prediction = Self.answer(confidence: .wide)
        try await model.save(EvaEventWrite(
            payload: .cycle(.flow(.medium)),
            localDate: Self.today,
            idempotencyKey: "k1"
        ))

        #expect(source.predictionRanges.count == afterLoad + 1,
                "A logged period left the old estimate on screen")
        #expect(model.predictions(on: Self.day(18)) == [.fertileWindow])
        let refreshed = try #require(model.summary)
        #expect(refreshed.title.contains(Self.rendered(Self.day(31))))

        // A sport entry changes nothing the maths reads, and must not spend a request.
        let before = source.predictionRanges.count
        try await model.save(EvaEventWrite(
            payload: .sport(EvaSportPayload(activity: "run", durationMin: 30, intensity: .light)),
            localDate: Self.today,
            idempotencyKey: "k2"
        ))
        #expect(source.predictionRanges.count == before,
                "A sport entry re-asked for a prediction it cannot have changed")
    }

    @Test("Deleting the period the estimate was anchored on re-asks for it")
    func deletingACycleEntryRefreshesTheOverlay() async {
        let source = RecordingSource()
        source.prediction = Self.answer(confidence: .narrow)
        let logged = CalendarModelTests.event("cycle_2026-08-02", on: Self.day(2))
        source.events = [logged]
        let model = CalendarModel(source: source, today: Self.today)
        await model.start()
        let afterLoad = source.predictionRanges.count

        source.prediction = Self.answer(withheld: .noFlowLogged)
        await model.delete(logged)

        #expect(source.predictionRanges.count == afterLoad + 1)
        #expect(model.predictions(on: Self.day(18)).isEmpty,
                "The window stayed on the grid after its anchor was deleted")
        #expect(model.summary?.title == EvaPredictionWithheld.noFlowLogged.title)
    }

    // MARK: - The device derives nothing

    /// #206's hard constraint, asserted rather than reviewed.
    ///
    /// **The failure this catches is a helper, not a typo.** "The predicted period is one
    /// day, so let us paint the four after it too" is four lines of plausible Swift, it
    /// makes the grid look more finished, and every other test in this repo passes with it
    /// in place — because every other test checks the days the *source* was told to return.
    /// So the check is on the source text: the three files that make up the prediction path
    /// may not contain a call that can produce a date.
    ///
    /// The same shape as `api/test/cycle.test.ts`'s scan of `cycle.ts` for Firestore and
    /// clocks, and it is deliberately dumb: it does not parse Swift, it looks for the names
    /// of the tools. `EvaMonth.next` and `firstDay` are not on the list and are used —
    /// walking the months of a range to work out what is cached is bookkeeping about the
    /// request, not a date anybody is shown.
    @Test("No date arithmetic anywhere on the prediction path")
    func thePredictionPathDoesNoDateArithmetic() throws {
        let forbidden = [
            "adding(days:", ".adding(days", "days(since:",
            "DateComponents", "Calendar(", "evaGregorianUTC",
            "addingTimeInterval", "timeIntervalSince", "Date()"
        ]

        for file in Self.predictionPathFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Comments say what is *not* done here, so they would trip every match.
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            for call in forbidden {
                #expect(
                    !code.contains(call),
                    """
                    \(file.lastPathComponent) calls `\(call)`. The prediction path maps the \
                    days the API returned onto cells and computes none of its own (#206).
                    """
                )
            }
        }
    }

    /// The files the assertion above covers, located from this test file rather than from
    /// the bundle — the sources are not in it.
    ///
    /// `CalendarModel` is not one of them, and it does do date arithmetic: the 400-day
    /// history window, the visible three months. What it does on *this* path is four calls
    /// that pass days straight through — `loadPrediction`, `cycleDataChanged`,
    /// `predictions(on:)`, `summary` — and the days they pass come from `EvaMonth`, which
    /// is where the grid's own geometry has always come from.
    static let predictionPathFiles: [URL] = {
        let calendar = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // EvaTests
            .deletingLastPathComponent()      // mobile
            .appendingPathComponent("Eva/Calendar")
        return ["EvaCyclePrediction.swift", "EvaPredictionMark.swift", "CalendarSummaryCard.swift"]
            .map(calendar.appendingPathComponent)
    }()

    @Test("The scan is looking at files that exist")
    func theScannedFilesExist() {
        for file in Self.predictionPathFiles {
            #expect(FileManager.default.fileExists(atPath: file.path),
                    "\(file.path) is gone — the arithmetic scan is asserting nothing")
        }
    }
}

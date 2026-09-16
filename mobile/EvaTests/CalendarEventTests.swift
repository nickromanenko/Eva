import Foundation
import Testing
@testable import Eva

/// Issue #159: **the event → glyph mapping, and the wire shapes it reads.**
///
/// The mapping is an accessibility property rather than a styling one (DESIGN.md §1 —
/// never colour alone), so the properties worth pinning are *structural*: every drawn type
/// has a mark, no two marks share a corner, and no two share an outline. A regression that
/// gave two types the same corner would look almost right and be unreadable.
@Suite("Issue #159 · event glyphs and wire decoding")
struct CalendarEventTests {

    // MARK: - The mapping

    @Test("Every type that draws a mark has its own corner and its own shape")
    func glyphsAreDistinctInPositionAndShape() {
        let positions = EvaEventGlyph.allCases.map(\.position)
        #expect(Set(positions).count == EvaEventGlyph.allCases.count,
                "Two marks share a corner: \(positions)")
        let shapes = EvaEventGlyph.allCases.map(\.shape)
        #expect(Set(shapes).count == EvaEventGlyph.allCases.count,
                "Two marks share an outline: \(shapes)")
    }

    /// The artboard, cell by cell: sex bottom-left dot, body signals bottom-centre square,
    /// sport bottom-right diamond, appointment top-right badge.
    @Test(
        "Each type draws the mark the artboard gives it",
        arguments: [
            (EvaEventType.sex, EvaEventGlyph.sex, EvaEventGlyph.Position.bottomLeading, EvaEventGlyph.Shape.dot),
            (.bodySignals, .bodySignals, .bottomCenter, .square),
            (.sport, .sport, .bottomTrailing, .diamond),
            (.appointment, .appointment, .topTrailing, .badge)
        ]
    )
    func typeMapsToItsMark(
        type: EvaEventType,
        glyph: EvaEventGlyph,
        position: EvaEventGlyph.Position,
        shape: EvaEventGlyph.Shape
    ) {
        #expect(type.glyph == glyph)
        #expect(glyph.position == position)
        #expect(glyph.shape == shape)
    }

    /// `cycle` is drawn as the cell's wash, so it must not also claim a corner — two marks
    /// for one type would double-count the day.
    @Test("A cycle entry draws no corner mark")
    func cycleHasNoGlyph() {
        #expect(EvaEventType.cycle.glyph == nil)
        #expect(EvaEventGlyph.allCases.count == 4)
    }

    @Test("Every mark names its shape and its corner in the legend and to VoiceOver")
    func glyphsDescribeThemselvesInWords() {
        for glyph in EvaEventGlyph.allCases {
            #expect(!glyph.legendLabel.isEmpty)
            #expect(!glyph.accessibilityLabel.isEmpty)
            // The legend has to work in greyscale, so each row names its own geometry.
            let names = ["dot", "square", "diamond", "badge"]
            #expect(names.contains { glyph.legendLabel.localizedCaseInsensitiveContains($0) },
                    "\(glyph.legendLabel) does not say what shape it is")
        }
    }

    @Test("Flow strength is three distinct washes, and spotting is not one of them")
    func flowFills() {
        let fills = EvaFlowLevel.allCases.map { EvaCycleMark.flow($0).cellFill }
        #expect(fills.allSatisfy { $0 != nil })
        // Spotting does not start a period, so it must not be drawn as the lightest flow.
        // The artboard draws it as an ordinary cell; the day still announces it.
        #expect(EvaCycleMark.spotting.cellFill == nil)
        #expect(EvaCycleMark.spotting.accessibilityLabel == "Spotting logged")
        #expect(EvaCycleMark.flow(.heavy).accessibilityLabel == "Heavy flow logged")
    }

    // MARK: - Decoding

    static func decode(_ json: String) throws -> EvaEvent {
        try JSONDecoder().decode(EvaEvent.self, from: Data(json.utf8))
    }

    @Test("A flow day decodes to one mark, not two optionals")
    func decodesFlow() throws {
        let event = try Self.decode(#"""
        {"id":"e1","type":"cycle","localDate":"2026-08-05","loggedAt":"2026-08-05T07:10:00",
         "note":null,"source":"user","idempotencyKey":null,"payload":{"flow":"heavy"}}
        """#)
        #expect(event.detail == .cycle(.flow(.heavy)))
        #expect(event.localDate == EvaDay(year: 2026, month: 8, day: 5))
        #expect(event.note == nil)
        #expect(event.source == .user)
    }

    @Test("A spotting day decodes to spotting, not to a flow level")
    func decodesSpotting() throws {
        let event = try Self.decode(#"""
        {"id":"e2","type":"cycle","localDate":"2026-08-02","loggedAt":"2026-08-02T09:00:00",
         "note":null,"source":"user","idempotencyKey":null,"payload":{"spotting":true}}
        """#)
        #expect(event.detail == .cycle(.spotting))
    }

    /// The API's `never` arms make this unrepresentable on the wire. If one ever arrives,
    /// failing is right: silently choosing one of the two would put a period day on the
    /// calendar that the user never logged.
    @Test("A cycle payload that says neither is refused")
    func refusesEmptyCyclePayload() {
        #expect(throws: (any Error).self) {
            try Self.decode(#"""
            {"id":"e3","type":"cycle","localDate":"2026-08-02","loggedAt":"2026-08-02T09:00:00",
             "note":null,"source":"user","idempotencyKey":null,"payload":{}}
            """#)
        }
    }

    @Test("Body signals keep an unanswered rating unanswered")
    func decodesBodySignals() throws {
        let event = try Self.decode(#"""
        {"id":"e4","type":"bodySignals","localDate":"2026-08-12","loggedAt":"2026-08-12T08:30:00",
         "note":"Worse after lunch.","source":"user","idempotencyKey":null,
         "payload":{"energy":2,"symptoms":[{"code":"cramps","severity":"severe"},
                                           {"code":"discharge","severity":"normal","value":"creamy"}]}}
        """#)
        guard case .bodySignals(let payload) = event.detail else {
            Issue.record("Decoded as \(event.detail)")
            return
        }
        #expect(payload.energy == 2)
        // Absent is not a 3. An unanswered scale has to stay unanswered all the way through.
        #expect(payload.mood == nil)
        #expect(payload.sleep == nil)
        #expect(payload.symptoms.count == 2)
        #expect(payload.symptoms.first?.severity == .severe)
        #expect(payload.symptoms.last?.value == "creamy")
        #expect(event.note == "Worse after lunch.")
    }

    @Test("Sport and appointment decode their own payloads")
    func decodesSportAndAppointment() throws {
        let sport = try Self.decode(#"""
        {"id":"e5","type":"sport","localDate":"2026-08-13","loggedAt":"2026-08-13T18:15:00",
         "note":null,"source":"user","idempotencyKey":"k1",
         "payload":{"activity":"strength","durationMin":45,"intensity":"medium"}}
        """#)
        #expect(sport.detail == .sport(EvaSportPayload(
            activity: "strength", durationMin: 45, intensity: .medium
        )))
        #expect(sport.idempotencyKey == "k1")

        let appointment = try Self.decode(#"""
        {"id":"e6","type":"appointment","localDate":"2026-08-20","loggedAt":"2026-08-12T20:00:00",
         "note":null,"source":"user","idempotencyKey":null,
         "payload":{"startAt":"2026-08-20T09:30:00","type":"gynecologist",
                    "questions":["Iron levels?"],"reminderMinutesBefore":1440}}
        """#)
        guard case .appointment(let payload) = appointment.detail else {
            Issue.record("Decoded as \(appointment.detail)")
            return
        }
        #expect(payload.type == "gynecologist")
        #expect(payload.questions == ["Iron levels?"])
        #expect(payload.reminderMinutesBefore == 1440)
    }

    /// `sex` is reserved on the API and has no payload. The app decodes it anyway so the
    /// calendar can draw one the day the server can store one (C10).
    @Test("A sex entry decodes with no payload")
    func decodesSex() throws {
        let event = try Self.decode(#"""
        {"id":"e7","type":"sex","localDate":"2026-08-10","loggedAt":"2026-08-10T22:00:00",
         "note":null,"source":"user","idempotencyKey":null}
        """#)
        #expect(event.detail == .sex)
        #expect(event.type.glyph == .sex)
    }

    @Test("A localDate that is not a real day is refused")
    func refusesAnImpossibleLocalDate() {
        #expect(throws: (any Error).self) {
            try Self.decode(#"""
            {"id":"e8","type":"cycle","localDate":"2026-02-30","loggedAt":"2026-02-30T09:00:00",
             "note":null,"source":"user","idempotencyKey":null,"payload":{"flow":"light"}}
            """#)
        }
    }

    @Test("The response wrapper unpacks the array the route sends")
    func decodesResponse() throws {
        let response = try JSONDecoder().decode(EvaEventsResponse.self, from: Data(#"""
        {"events":[{"id":"e9","type":"cycle","localDate":"2026-08-05",
         "loggedAt":"2026-08-05T07:10:00","note":null,"source":"user",
         "idempotencyKey":null,"payload":{"flow":"light"}}]}
        """#.utf8))
        #expect(response.events.count == 1)
    }

    /// **One row this build cannot read must not take the calendar with it.**
    ///
    /// Not reachable against today's API, which refuses every one of these at write time.
    /// It becomes reachable the first time the API grows a type or a value this build
    /// predates — C10's `sex` is the next one — and the failure would land on the app's
    /// landing screen: every entry gone because of one.
    @Test(
        "A row that cannot be read is dropped, and the rest of the month survives",
        arguments: [
            // A type this build has never heard of.
            #"{"id":"x","type":"somethingNew","localDate":"2026-08-06","loggedAt":"2026-08-06T09:00:00","payload":{}}"#,
            // A flow level this build has never heard of.
            #"{"id":"x","type":"cycle","localDate":"2026-08-06","loggedAt":"2026-08-06T09:00:00","payload":{"flow":"torrential"}}"#,
            // A day that is not a day.
            #"{"id":"x","type":"cycle","localDate":"2026-02-30","loggedAt":"2026-02-30T09:00:00","payload":{"flow":"light"}}"#,
            // A cycle entry that is both spotting and a flow — see below.
            #"{"id":"x","type":"cycle","localDate":"2026-08-06","loggedAt":"2026-08-06T09:00:00","payload":{"spotting":true,"flow":"heavy"}}"#,
            // Not an object at all.
            "42"
        ]
    )
    func anUnreadableRowIsSkippedNotFatal(unreadable: String) throws {
        let first = Self.cycleRow(id: "good")
        let second = Self.cycleRow(id: "good2")
        let response = try JSONDecoder().decode(
            EvaEventsResponse.self,
            from: Data(#"{"events":[\#(first),\#(unreadable),\#(second)]}"#.utf8)
        )

        #expect(
            response.events.map(\.id) == ["good", "good2"],
            "A row that could not be read took the others with it"
        )
    }

    static func cycleRow(id: String) -> String {
        #"""
        {"id":"\#(id)","type":"cycle","localDate":"2026-08-05","loggedAt":"2026-08-05T07:10:00",
         "note":null,"source":"user","idempotencyKey":null,"payload":{"flow":"light"}}
        """#
    }

    /// `{"spotting":true,"flow":"heavy"}` is unrepresentable on the wire — the API's `never`
    /// arms see to that — and if one ever arrives, refusing it is the only honest answer.
    ///
    /// The version before this preferred `flow` whenever it was present, so the spotting
    /// marker vanished without trace and the day was drawn as a heavy period. Guessing
    /// which half of a contradiction to believe is how a calendar comes to show a period
    /// the user never logged.
    @Test(
        "A cycle payload the API cannot produce is refused, never half-believed",
        arguments: [
            #"{"spotting":true,"flow":"heavy"}"#,
            #"{"spotting":true,"flow":"light"}"#,
            #"{"spotting":false}"#,
            "{}"
        ]
    )
    func contradictoryCyclePayloadsAreRefused(payload: String) {
        #expect(throws: (any Error).self) {
            try Self.decode(#"""
            {"id":"e","type":"cycle","localDate":"2026-08-02","loggedAt":"2026-08-02T09:00:00",
             "note":null,"source":"user","idempotencyKey":null,"payload":\#(payload)}
            """#)
        }
    }

    /// The shapes the API *can* produce still decode, including `spotting: false` beside a
    /// flow, which is how a TypeScript `never` arm serialises if anything ever emits one.
    @Test("A flow day with an explicit spotting:false is still a flow day")
    func explicitFalseSpottingIsStillAFlowDay() throws {
        let event = try Self.decode(#"""
        {"id":"e","type":"cycle","localDate":"2026-08-02","loggedAt":"2026-08-02T09:00:00",
         "note":null,"source":"user","idempotencyKey":null,
         "payload":{"spotting":false,"flow":"medium"}}
        """#)
        #expect(event.detail == .cycle(.flow(.medium)))
    }

    // MARK: - The words a day detail shows

    @Test("A cycle entry says what was logged, and never scores it")
    func cyclePresentation() {
        let event = EvaEvent(
            id: "1",
            detail: .cycle(.flow(.light)),
            localDate: EvaDay(year: 2026, month: 8, day: 5),
            loggedAt: "2026-08-05T07:10:00"
        )
        let presentation = CalendarEntryPresentation(event: event, refData: nil)
        #expect(presentation.typeName == "Menstrual cycle")
        #expect(presentation.summary == "Light flow")
        #expect(presentation.cycleMark == .flow(.light))
        #expect(presentation.glyph == nil)
    }

    /// Labels come from `/refdata` and codes are never shown when a label exists — and
    /// when the catalogue has not arrived, the code is shown rather than a placeholder
    /// word, because "Unknown" would tell the user her entry is not there.
    @Test("Symptom codes resolve through refdata, and fall back to the code itself")
    func bodySignalsPresentation() throws {
        let refData = try JSONDecoder().decode(EvaRefData.self, from: Data(#"""
        {"version":"v1","catalogues":{"symptoms":[{"code":"cramps","label":"Cramps"}],
         "sportActivities":[],"appointmentTypes":[]}}
        """#.utf8))
        let event = EvaEvent(
            id: "2",
            detail: .bodySignals(EvaBodySignalsPayload(
                energy: 2,
                sleep: 5,
                symptoms: [
                    EvaSymptom(code: "cramps", severity: .severe),
                    EvaSymptom(code: "hot_flashes")
                ]
            )),
            localDate: EvaDay(year: 2026, month: 8, day: 12),
            loggedAt: "2026-08-12T08:30:00"
        )

        let resolved = CalendarEntryPresentation(event: event, refData: refData)
        // The canvas' own words for each point of the scale — never a bare number, which
        // would read as a score (DESIGN.md §8).
        #expect(resolved.summary == "Energy Low, Sleep Deep, Cramps (severe), hot_flashes")

        let unresolved = CalendarEntryPresentation(event: event, refData: nil)
        #expect(unresolved.summary.contains("cramps (severe)"),
                "Without a catalogue the code stands in: \(unresolved.summary)")
    }

    /// A sensitive event stays neutral in language as well as in its indicator — the
    /// canvas is explicit that the calendar shows "a neutral dot with no label".
    @Test("A sex entry carries a neutral label and no detail")
    func sexPresentationIsNeutral() {
        let presentation = CalendarEntryPresentation(
            event: EvaEvent(
                id: "3",
                detail: .sex,
                localDate: EvaDay(year: 2026, month: 8, day: 10),
                loggedAt: "2026-08-10T22:00:00"
            ),
            refData: nil
        )
        #expect(presentation.typeName == "Sex")
        #expect(presentation.summary.isEmpty)
    }

    /// `loggedAt` is a wall clock with no zone. Reading it as an instant would attach the
    /// device's current offset to a string that never had one and move last winter's
    /// entries by an hour.
    @Test("A wall-clock time is read as written, never as an instant")
    func wallClockTimes() {
        #expect(EvaWallClock.time(from: "2026-08-12T08:30:00") != nil)
        #expect(EvaWallClock.time(from: "2026-01-12T08:30:00")
                == EvaWallClock.time(from: "2026-08-12T08:30:00"),
                "The same wall clock read differently either side of a DST boundary")
        #expect(EvaWallClock.time(from: "2026-08-12T08:30") != nil, "Seconds are optional")
        #expect(EvaWallClock.time(from: "2026-08-12") == nil)
        #expect(EvaWallClock.time(from: "2026-08-12T99:30:00") == nil)
        #expect(EvaWallClock.time(from: "") == nil)
    }
}

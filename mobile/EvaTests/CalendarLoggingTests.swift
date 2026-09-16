import Foundation
import Testing
@testable import Eva

/// Issue #160: **what the log sheets build, and what the day will accept.**
///
/// Three things are asserted here and none of them is visible on screen: the exact JSON a
/// draft turns into, the date policy the picker draws its unavailable rows from, and the
/// rule that stops Undo being offered for an entry that no longer exists (#50). All three
/// fail silently if they are wrong — a payload the route rejects looks like "it didn't
/// save", a wrong date policy looks like a row that is greyed for no reason, and a stale
/// Undo looks like a button that does nothing.
///
/// Nothing here arms `EvaStubURLProtocol`. That stub is global, shared with every other
/// suite in the target, and `RateLimitedResponseTests` is not `.serialized` — so a suite
/// that reached for it could interleave with that one and corrupt both. The narrow
/// `CalendarEventSource` seam is used instead (`RecordingCalendarSource`).
@Suite("Issue #160 · the log picker builds what the API takes")
struct CalendarLoggingTests {

    static let day = EvaDay(year: 2026, month: 8, day: 12)

    /// The JSON one write turns into, with keys sorted so a comparison is stable.
    static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded to something that is not an object"
        )
    }

    static func payloadJSON(_ value: some Encodable) throws -> [String: Any] {
        try #require(
            try json(value)["payload"] as? [String: Any],
            "the write carried no payload object"
        )
    }

    // MARK: - The envelope

    @Test("Every write names its type, its day and the zone that decides 'today'")
    func envelopeCarriesWhatTheRouteValidates() throws {
        let write = EvaEventWrite(
            payload: .cycle(.flow(.medium)),
            localDate: Self.day,
            note: "  Cramping in the evening.  ".evaTrimmedNote,
            idempotencyKey: "abc",
            timeZone: "Europe/Lisbon"
        )
        let body = try Self.json(write)

        #expect(body["type"] as? String == "cycle")
        #expect(body["localDate"] as? String == "2026-08-12")
        // Without this the route grants a day of slack either side of UTC and its idea of
        // the future stops matching the grid's — so the picker would offer a day the
        // server refuses, or refuse one it would have taken.
        #expect(body["timeZone"] as? String == "Europe/Lisbon")
        #expect(body["idempotencyKey"] as? String == "abc")
        #expect(body["note"] as? String == "Cramping in the evening.")
        // `loggedAt` is deliberately absent: the route computes a time on the right day
        // from the zone above, and on a PATCH its absence is what preserves the original.
        #expect(body["loggedAt"] == nil)
    }

    @Test("A note that is only whitespace is not a note")
    func blankNotesAreOmitted() throws {
        let write = EvaEventWrite(
            payload: .cycle(.spotting),
            localDate: Self.day,
            note: "   \n ".evaTrimmedNote,
            idempotencyKey: "abc"
        )
        #expect(try Self.json(write)["note"] == nil)
    }

    // MARK: - Cycle

    @Test("Spotting and a flow are different keys, never both")
    func cyclePayloadIsOneKeyOrTheOther() throws {
        let spotting = try Self.payloadJSON(EvaEventWrite(
            payload: .cycle(.spotting), localDate: Self.day, idempotencyKey: "a"
        ))
        #expect(spotting["spotting"] as? Bool == true)
        // `parseCyclePayload` rejects a body carrying both — "A cycle entry is either
        // spotting or a flow level, not both".
        #expect(spotting["flow"] == nil)

        let heavy = try Self.payloadJSON(EvaEventWrite(
            payload: .cycle(.flow(.heavy)), localDate: Self.day, idempotencyKey: "a"
        ))
        #expect(heavy["flow"] as? String == "heavy")
        #expect(heavy["spotting"] == nil)
    }

    /// C1 tightened `CycleWire` so that `{spotting: true, flow: "heavy"}` is refused
    /// outright rather than silently read as a heavy period day. That is the decode this
    /// slice's writes land in, so the loop is closed here: what the encoder produces has to
    /// come back as the mark that produced it.
    @Test("What the cycle encoder writes decodes back as the same marker", arguments: [
        EvaCycleMark.spotting, .flow(.light), .flow(.medium), .flow(.heavy)
    ])
    func cyclePayloadsRoundTripThroughTheDecoder(mark: EvaCycleMark) throws {
        let payload = try Self.payloadJSON(EvaEventWrite(
            payload: .cycle(mark), localDate: Self.day, idempotencyKey: "a"
        ))
        let event = try JSONDecoder().decode(EvaEvent.self, from: JSONSerialization.data(
            withJSONObject: [
                "id": "cycle_2026-08-12",
                "type": "cycle",
                "localDate": "2026-08-12",
                "loggedAt": "2026-08-12T07:00:00",
                "payload": payload
            ]
        ))
        #expect(event.detail == .cycle(mark))
    }

    @Test("A cycle draft with no marker builds nothing")
    func cycleNeedsAMarker() {
        #expect(LogCycleDraft().payload == nil)
        #expect(LogCycleDraft(mark: .spotting).payload == .cycle(.spotting))
    }

    @Test("Editing a cycle entry opens on what was logged")
    func cycleDraftRoundTrips() {
        let event = EvaEvent(
            id: "1", detail: .cycle(.flow(.light)), localDate: Self.day,
            loggedAt: "2026-08-12T07:00:00", note: "Started overnight."
        )
        let draft = LogCycleDraft(editing: event)
        #expect(draft.mark == .flow(.light))
        #expect(draft.note == "Started overnight.")
    }

    // MARK: - Body signals

    static let symptoms: [EvaRefData.Item] = [
        EvaRefData.Item(code: "bloating", label: "Bloating"),
        EvaRefData.Item(code: "cramps", label: "Cramps", severable: true),
        EvaRefData.Item(
            code: "discharge", label: "Discharge", group: .more,
            values: ["dry", "sticky", "creamy", "watery", "egg-white"]
        )
    ]

    @Test("An unanswered rating is absent, not a 3 and not a null")
    func unansweredRatingsAreOmitted() throws {
        var draft = LogBodySignalsDraft()
        draft.energy = 2
        let payload = try #require(draft.payload(in: Self.symptoms))
        let body = try Self.payloadJSON(EvaEventWrite(
            payload: payload, localDate: Self.day, idempotencyKey: "a"
        ))

        #expect(body["energy"] as? Int == 2)
        #expect(body["mood"] == nil)
        #expect(body["sleep"] == nil)
        #expect((body["symptoms"] as? [Any])?.isEmpty == true)
    }

    @Test("A body-signals entry with nothing in it is not an entry")
    func emptyBodySignalsBuildsNothing() {
        #expect(LogBodySignalsDraft().payload(in: Self.symptoms) == nil)
        var withOneChip = LogBodySignalsDraft()
        withOneChip.tap(Self.symptoms[0])
        #expect(withOneChip.payload(in: Self.symptoms) != nil)
    }

    @Test("A severable chip takes three taps to get back to off; the others take two")
    func chipTapsFollowTheCatalogue() {
        var draft = LogBodySignalsDraft()

        draft.tap(Self.symptoms[1])                       // cramps, severable
        #expect(draft.state(of: "cramps") == .on(value: nil))
        draft.tap(Self.symptoms[1])
        #expect(draft.state(of: "cramps") == .severe(value: nil))
        draft.tap(Self.symptoms[1])
        #expect(draft.state(of: "cramps") == .off)

        draft.tap(Self.symptoms[0])                       // bloating, not severable
        #expect(draft.state(of: "bloating") == .on(value: nil))
        draft.tap(Self.symptoms[0])
        #expect(
            draft.state(of: "bloating") == .off,
            "A chip the catalogue does not mark severable went severe on its second tap"
        )
    }

    @Test("A chip's value survives being marked severe, and can be taken back off")
    func valueAxisIsIndependentOfSeverity() {
        var draft = LogBodySignalsDraft()
        draft.tap(Self.symptoms[2])
        draft.choose("egg-white", for: "discharge")
        #expect(draft.state(of: "discharge").value == "egg-white")

        draft.symptoms["discharge"] = draft.state(of: "discharge").settingValue("watery")
        #expect(draft.state(of: "discharge").value == "watery")

        draft.choose("watery", for: "discharge")
        #expect(
            draft.state(of: "discharge").value == nil,
            "Tapping the chosen value again did not clear it, so a mis-tap would be permanent"
        )
    }

    @Test("Symptoms are sent in catalogue order, with severity and value")
    func symptomsFollowCatalogueOrder() throws {
        var draft = LogBodySignalsDraft()
        // Tapped out of order on purpose: a dictionary has none, so the array's order has
        // to come from the catalogue or two saves of one selection differ.
        draft.tap(Self.symptoms[2])
        draft.choose("creamy", for: "discharge")
        draft.tap(Self.symptoms[1])
        draft.tap(Self.symptoms[1])
        draft.tap(Self.symptoms[0])

        let sent = draft.selectedSymptoms(in: Self.symptoms)
        #expect(sent.map(\.code) == ["bloating", "cramps", "discharge"])
        #expect(sent[1].severity == .severe)
        #expect(sent[2].value == "creamy")
        // The value key is absent when the chip has no axis — Firestore rejects undefined
        // and `parseSymptoms` only spreads the key when there is one.
        let body = try Self.json(sent[0])
        #expect(body["value"] == nil)
        #expect(body["severity"] as? String == "normal")
    }

    /// Editing an entry must not quietly drop the parts of it this build no longer offers.
    @Test("A retired code on an entry being edited is kept, not dropped")
    func retiredCodesSurviveAnEdit() {
        let event = EvaEvent(
            id: "1",
            detail: .bodySignals(EvaBodySignalsPayload(
                energy: 3,
                symptoms: [
                    EvaSymptom(code: "bloating"),
                    EvaSymptom(code: "low-libido", severity: .severe)
                ]
            )),
            localDate: Self.day,
            loggedAt: "2026-08-12T08:00:00"
        )
        // `low-libido` is retired, so it is not in `offered(.symptoms)` and not in the
        // catalogue this draft is built against.
        let draft = LogBodySignalsDraft(editing: event, refData: nil)
        let sent = draft.selectedSymptoms(in: Self.symptoms)

        #expect(sent.map(\.code).contains("low-libido"),
                "Editing the note on an old entry deleted a symptom it already carried")
        #expect(sent.first { $0.code == "low-libido" }?.severity == .severe)
    }

    @Test("An entry carrying a hidden chip opens with the hidden group already showing")
    func editingRevealsTheMoreGroup() {
        let catalogue = EvaRefData(
            version: "v1",
            catalogues: EvaRefData.Catalogues(symptoms: Self.symptoms)
        )
        let event = EvaEvent(
            id: "1",
            detail: .bodySignals(EvaBodySignalsPayload(symptoms: [EvaSymptom(code: "discharge")])),
            localDate: Self.day,
            loggedAt: "2026-08-12T08:00:00"
        )
        #expect(LogBodySignalsDraft(editing: event, refData: catalogue).showsMoreSymptoms)
    }

    // MARK: - Sport

    static let activities: [EvaRefData.Item] = [
        EvaRefData.Item(code: "yoga", label: "Yoga"),
        EvaRefData.Item(code: "other", label: "Other", freeText: true)
    ]

    @Test("A catalogue activity sends its code; the free-text one sends what was typed")
    func sportActivityIsACodeOrTheWordsBehindIt() throws {
        var draft = LogSportDraft()
        draft.activityCode = "yoga"
        draft.intensity = .light
        #expect(draft.activity(in: Self.activities) == "yoga")

        draft.activityCode = "other"
        // "Other" with nothing typed is not an activity: storing the code would record a
        // workout whose only description is that it was not one of the listed ones.
        #expect(draft.activity(in: Self.activities) == nil)
        #expect(draft.payload(in: Self.activities) == nil)

        draft.otherActivity = "  Trampolining "
        #expect(draft.activity(in: Self.activities) == "Trampolining")

        let body = try Self.payloadJSON(EvaEventWrite(
            payload: #require(draft.payload(in: Self.activities)),
            localDate: Self.day,
            idempotencyKey: "a"
        ))
        #expect(body["activity"] as? String == "Trampolining")
        #expect(body["durationMin"] as? Int == LogSportDraft.defaultDuration)
        #expect(body["intensity"] as? String == "light")
    }

    @Test("Duration stays inside the route's own 5–300")
    func durationIsClamped() {
        var draft = LogSportDraft()
        for _ in 0..<100 { draft.adjustDuration(by: -LogSportDraft.durationStep) }
        #expect(draft.durationMin == LogSportDraft.durationRange.lowerBound)
        for _ in 0..<100 { draft.adjustDuration(by: LogSportDraft.durationStep) }
        #expect(draft.durationMin == LogSportDraft.durationRange.upperBound)
    }

    @Test("Editing a sport entry tells a code from free text using the catalogue")
    func sportDraftRoundTrips() {
        let catalogue = EvaRefData(
            version: "v1",
            catalogues: EvaRefData.Catalogues(sportActivities: Self.activities)
        )
        let logged = EvaEvent(
            id: "1",
            detail: .sport(EvaSportPayload(activity: "yoga", durationMin: 30, intensity: .medium)),
            localDate: Self.day, loggedAt: "2026-08-12T18:00:00"
        )
        let fromCatalogue = LogSportDraft(editing: logged, refData: catalogue)
        #expect(fromCatalogue.activityCode == "yoga")
        #expect(fromCatalogue.otherActivity.isEmpty)
        #expect(fromCatalogue.durationMin == 30)
        #expect(fromCatalogue.intensity == .medium)

        let freeText = EvaEvent(
            id: "2",
            detail: .sport(EvaSportPayload(
                activity: "Trampolining", durationMin: 20, intensity: .hard
            )),
            localDate: Self.day, loggedAt: "2026-08-12T18:00:00"
        )
        let typed = LogSportDraft(editing: freeText, refData: catalogue)
        #expect(typed.activityCode == "other")
        #expect(typed.otherActivity == "Trampolining")
    }

    // MARK: - Appointment

    @Test("An appointment starts on its own day, at the time that was chosen")
    func appointmentStartAtIsWallClockOnTheDay() throws {
        var draft = LogAppointmentDraft()
        draft.hour = 20
        draft.minute = 5
        draft.typeCode = "scan"
        draft.questions = ["Is the iron supplement still needed?"]

        let body = try Self.payloadJSON(EvaEventWrite(
            payload: #require(draft.payload(on: Self.day)),
            localDate: Self.day,
            idempotencyKey: "a"
        ))
        // `LOCAL_DATETIME` wants seconds, and `parseAppointmentPayload` rejects a
        // `startAt` that is not on the entry's own `localDate`.
        #expect(body["startAt"] as? String == "2026-08-12T20:05:00")
        #expect(body["type"] as? String == "scan")
        #expect((body["questions"] as? [String])?.count == 1)
    }

    /// The one field where absent and null mean different things.
    @Test("A reminder that is off is an explicit null, never an omitted key")
    func reminderOffIsNullNotAbsent() throws {
        var draft = LogAppointmentDraft()
        draft.remind = false
        let off = try Self.payloadJSON(EvaEventWrite(
            payload: #require(draft.payload(on: Self.day)),
            localDate: Self.day, idempotencyKey: "a"
        ))
        // An omitted key would give the route's default of a day before — a reminder the
        // user turned off.
        #expect(off["reminderMinutesBefore"] is NSNull,
                "The reminder key was omitted, which the route reads as 'remind me'")

        draft.remind = true
        let on = try Self.payloadJSON(EvaEventWrite(
            payload: #require(draft.payload(on: Self.day)),
            localDate: Self.day, idempotencyKey: "a"
        ))
        #expect(on["reminderMinutesBefore"] as? Int == LogAppointmentDraft.reminderMinutesBefore)
    }

    @Test("A question is trimmed, and an empty one is not added")
    func questionsAreTrimmed() {
        var draft = LogAppointmentDraft()
        draft.draftQuestion = "   "
        draft.addDraftQuestion()
        #expect(draft.questions.isEmpty)

        draft.draftQuestion = "  Should I change the dose? "
        draft.addDraftQuestion()
        #expect(draft.questions == ["Should I change the dose?"])
        #expect(draft.draftQuestion.isEmpty, "The field kept what it had just added")
    }

    @Test("Editing an appointment reads its time back without a time zone touching it")
    func appointmentDraftRoundTrips() {
        let event = EvaEvent(
            id: "1",
            detail: .appointment(EvaAppointmentPayload(
                startAt: "2026-08-12T14:30:00", type: "gp",
                questions: ["Ask about iron"], reminderMinutesBefore: nil
            )),
            localDate: Self.day, loggedAt: "2026-08-12T09:00:00"
        )
        let draft = LogAppointmentDraft(editing: event)
        #expect(draft.hour == 14)
        #expect(draft.minute == 30)
        #expect(draft.typeCode == "gp")
        #expect(draft.questions == ["Ask about iron"])
        #expect(!draft.remind, "A stored null reminder came back as 'remind me'")
    }
}

// MARK: - What a day will take

/// #160: *a future date offers appointments only; the others are visibly unavailable, not
/// silently refused*. This is the half that decides; `LogPickerStep` draws it.
@Suite("Issue #160 · the date policy the picker draws")
struct CalendarLogAvailabilityTests {

    static let today = EvaDay(year: 2026, month: 8, day: 18)

    @Test("Tomorrow takes an appointment and refuses everything else")
    func futureDaysAreAppointmentsOnly() {
        let tomorrow = Self.today.adding(days: 1)
        #expect(EvaEventType.appointment.availability(on: tomorrow, today: Self.today)
                == .available)
        for type in [EvaEventType.cycle, .bodySignals, .sport] {
            #expect(type.availability(on: tomorrow, today: Self.today) == .futureDay,
                    "\(type.rawValue) was offered on a future day")
        }
    }

    @Test("Today is not the future")
    func todayIsAvailableToEverything() {
        for type in [EvaEventType.cycle, .bodySignals, .sport, .appointment] {
            #expect(type.availability(on: Self.today, today: Self.today) == .available)
        }
    }

    /// The same boundary `checkDatePolicy` applies — the day one year back is in, the day
    /// before it is out — so a day the picker offers is never one the route refuses.
    @Test("Twelve months back is the floor, and it is inclusive")
    func backdatingStopsAtTwelveMonths() {
        let floor = EvaEventType.backdateFloor(from: Self.today)
        #expect(floor == EvaDay(year: 2025, month: 8, day: 18))
        #expect(EvaEventType.cycle.availability(on: floor, today: Self.today) == .available)
        #expect(EvaEventType.cycle.availability(on: floor.adding(days: -1), today: Self.today)
                == .tooFarBack)
        // And the limit is not an exception for appointments either.
        #expect(EvaEventType.appointment.availability(on: floor.adding(days: -1), today: Self.today)
                == .tooFarBack)
    }

    @Test("Sex is unavailable on every day, and not because of the day")
    func sexIsReservedRatherThanRefusedByDate() {
        #expect(EvaEventType.sex.availability(on: Self.today, today: Self.today)
                == .notYetAvailable)
        #expect(EvaEventType.sex.availability(on: Self.today.adding(days: -3), today: Self.today)
                == .notYetAvailable)
    }

    @Test("Every unavailable reason has words; the available one has none")
    func everyRefusalCanBeShown() {
        #expect(EvaLogAvailability.available.reason == nil)
        for reason in [EvaLogAvailability.futureDay, .tooFarBack, .notYetAvailable] {
            #expect(reason.reason?.isEmpty == false,
                    "\(reason) would draw a dimmed row with nothing saying why")
        }
    }
}

// MARK: - Writing, and taking it back

@Suite("Issue #160 · logging, editing, deleting and the Undo that #50 narrowed")
@MainActor
struct CalendarWriteTests {

    static let today = EvaDay(year: 2026, month: 8, day: 18)

    static func model(_ source: RecordingCalendarSource) async -> CalendarModel {
        let model = CalendarModel(source: source, today: today)
        await model.start()
        return model
    }

    static func write(_ payload: EvaEventPayload, on day: EvaDay = today) -> EvaEventWrite {
        EvaEventWrite(payload: payload, localDate: day, idempotencyKey: "key")
    }

    @Test("A saved entry is on the grid before anything is re-fetched")
    func savingLandsOnTheGridWithoutAReload() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        #expect(model.showsEmptyState)

        try await model.save(Self.write(.cycle(.flow(.medium))))

        #expect(model.cycleMark(on: Self.today) == .flow(.medium))
        #expect(model.events(on: Self.today).count == 1)
        #expect(!model.showsEmptyState, "The first entry left the first-log card on screen")
        #expect(source.ranges.count == 1, "Saving triggered a re-fetch of the whole range")
        #expect(model.toast?.message.contains("Menstrual cycle saved") == true)
    }

    @Test("Body signals go through the day-addressed upsert; the rest through create")
    func bodySignalsUseTheirOwnRoute() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)

        try await model.save(Self.write(.bodySignals(EvaBodySignalsPayload(energy: 2))))
        #expect(source.bodySignalWrites.count == 1)
        #expect(source.bodySignalWrites.first?.localDate == Self.today)

        try await model.save(Self.write(.sport(EvaSportPayload(
            activity: "yoga", durationMin: 30, intensity: .light
        ))))
        #expect(source.bodySignalWrites.count == 1, "A sport entry went to /me/body-signals")
    }

    @Test("Editing patches the entry it opened, and does not add a second")
    func editingPatches() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let created = try await model.save(Self.write(.cycle(.flow(.light))))

        try await model.save(Self.write(.cycle(.flow(.heavy))), editing: created.id)

        #expect(source.patchedIds == [created.id])
        #expect(model.events(on: Self.today).count == 1)
        #expect(model.cycleMark(on: Self.today) == .flow(.heavy))
    }

    /// The server keeps one `cycle` per day at a day-derived id, so a second save replaces
    /// the first. The cache has to do the same or the day shows two entries that cannot
    /// both exist.
    @Test("Re-logging a one-per-day type replaces the day's entry rather than adding one")
    func onePerDayReplaces() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        try await model.save(Self.write(.cycle(.spotting)))
        try await model.save(Self.write(.cycle(.flow(.medium))))

        #expect(model.events(on: Self.today).count == 1)
        #expect(model.cycleMark(on: Self.today) == .flow(.medium))
        #expect(model.onePerDayEntry(.cycle, on: Self.today) != nil)
        // Sport is not one per day, so two of them are two.
        let sport = EvaSportPayload(activity: "yoga", durationMin: 30, intensity: .light)
        try await model.save(Self.write(.sport(sport)))
        try await model.save(Self.write(.sport(sport)))
        #expect(model.events(on: Self.today).count == 3)
        #expect(model.onePerDayEntry(.sport, on: Self.today) == nil)
    }

    @Test("Deleting takes the entry off the grid and offers Undo")
    func deleteOffersUndo() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let logged = try await model.save(Self.write(.cycle(.flow(.light))))
        source.restorable[logged.id] = logged

        await model.delete(logged)

        #expect(model.events(on: Self.today).isEmpty)
        #expect(source.deletedIds == [logged.id])
        #expect(model.offersUndo)
        #expect(model.toast?.message == "Menstrual cycle deleted")

        await model.undoDelete()

        #expect(source.restoredIds == [logged.id])
        #expect(model.events(on: Self.today).count == 1)
        #expect(!model.offersUndo, "Undo was still on offer after it had been taken")
    }

    /// **#50's decision, in one test.** Re-logging a one-per-day type overwrites the very
    /// document the delete soft-deleted, so there is nothing left to restore and the API
    /// answers `409 DAY_ALREADY_LOGGED`. The button has to be gone before the tap.
    @Test("Undo is withdrawn once the day has been logged again")
    func undoIsNotOfferedAfterTheDayIsRetaken() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let first = try await model.save(Self.write(.cycle(.flow(.light))))
        source.restorable[first.id] = first

        await model.delete(first)
        #expect(model.canRestore(first))

        try await model.save(Self.write(.cycle(.flow(.heavy))))

        #expect(!model.canRestore(first),
                "Undo was still offered for an entry the re-log had already overwritten")
        #expect(!model.offersUndo)
    }

    /// The same question, asked about an entry this device never saved.
    ///
    /// The rule is "is the day occupied", not "has this device tapped save since" — so an
    /// entry that arrived from another device through an ordinary load withdraws Undo just
    /// as a local re-log does. Asserted against a **loaded** cache rather than a written
    /// one, because that is the difference between reading the day and remembering an
    /// action. (C2 has no refresh, so this becomes visible on the next launch; the rule is
    /// written to be right when it does, not to depend on when.)
    @Test("Undo asks whether the day is taken, not what this device did")
    func canRestoreAsksTheDayNotTheHistory() async {
        let source = RecordingCalendarSource()
        let onAnotherDevice = EvaEvent(
            id: "cycle_\(Self.today.isoDate)", detail: .cycle(.flow(.heavy)),
            localDate: Self.today, loggedAt: "\(Self.today.isoDate)T10:00:00"
        )
        source.events = [onAnotherDevice]
        let model = await Self.model(source)

        // An entry soft-deleted earlier, at the same one-per-day address. Restoring it
        // would relabel the newer document rather than bring this one back, which is why
        // the API answers 409 and why the button must not be there.
        let deleted = EvaEvent(
            id: "cycle_\(Self.today.isoDate)", detail: .cycle(.flow(.light)),
            localDate: Self.today, loggedAt: "\(Self.today.isoDate)T07:00:00"
        )
        #expect(!model.canRestore(deleted))

        // A sport entry on the same day is untouched by it: sport is not one per day, so
        // nothing has overwritten anything.
        let deletedSport = EvaEvent(
            id: "e9",
            detail: .sport(EvaSportPayload(activity: "yoga", durationMin: 30, intensity: .light)),
            localDate: Self.today, loggedAt: "\(Self.today.isoDate)T18:00:00"
        )
        #expect(model.canRestore(deletedSport))
    }

    @Test("A non-one-per-day entry can always be restored")
    func sportUndoIsNeverSuperseded() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let sport = EvaSportPayload(activity: "yoga", durationMin: 30, intensity: .light)
        let logged = try await model.save(Self.write(.sport(sport)))
        source.restorable[logged.id] = logged

        await model.delete(logged)
        try await model.save(Self.write(.sport(sport)))

        #expect(model.canRestore(logged),
                "A second workout on the same day withdrew Undo for the first")
    }

    /// The race the button cannot close: another device retakes the day between the toast
    /// appearing and the tap, and the server refuses. The user is told, rather than left
    /// with a button that appeared to do nothing.
    @Test("A 409 from restore is reported, not swallowed")
    func restoreConflictIsShown() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let logged = try await model.save(Self.write(.cycle(.flow(.light))))
        await model.delete(logged)

        source.writeFailure = APIError.server(
            code: "DAY_ALREADY_LOGGED",
            message: "That day already has an entry, so this one can't be restored",
            status: 409
        )
        await model.undoDelete()

        #expect(model.toast?.message.contains("already has an entry") == true)
        #expect(!model.offersUndo)
    }

    @Test("A failed save changes nothing and is thrown to the sheet")
    func aFailedSaveLeavesTheCalendarAlone() async {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        source.writeFailure = APIError.network

        await #expect(throws: APIError.self) {
            try await model.save(Self.write(.cycle(.flow(.light))))
        }
        #expect(model.events(on: Self.today).isEmpty)
        #expect(model.toast == nil, "A failed save announced itself as a success")
    }

    @Test("A failed delete says so and leaves the entry where it is")
    func aFailedDeleteKeepsTheEntry() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let logged = try await model.save(Self.write(.cycle(.flow(.light))))
        source.writeFailure = APIError.network

        await model.delete(logged)

        #expect(model.events(on: Self.today).count == 1)
        #expect(model.toast?.message == APIError.network.localizedDescription)
        #expect(!model.offersUndo)
    }

    @Test("The picker opens an existing one-per-day entry instead of a second")
    func onePerDayEntryIsFoundForEditing() async throws {
        let source = RecordingCalendarSource()
        let model = await Self.model(source)
        let logged = try await model.save(Self.write(.bodySignals(
            EvaBodySignalsPayload(energy: 4)
        )))

        #expect(model.onePerDayEntry(.bodySignals, on: Self.today)?.id == logged.id)
        #expect(model.onePerDayEntry(.bodySignals, on: Self.today.adding(days: -1)) == nil)
    }
}

// MARK: - The catalogue

@Suite("Issue #160 · what the pickers may offer")
struct CalendarRefDataTests {

    static let catalogue = EvaRefData(
        version: "v1",
        catalogues: EvaRefData.Catalogues(
            symptoms: [
                EvaRefData.Item(code: "cramps", label: "Cramps", severable: true),
                EvaRefData.Item(code: "low-libido", label: "Low libido", status: .retired),
                EvaRefData.Item(code: "discharge", label: "Discharge", group: .more,
                                values: ["dry", "egg-white"])
            ]
        )
    )

    /// Retirement's whole point: the code still resolves, and it is not offered again.
    @Test("A retired code resolves to its label and is never offered")
    func retiredCodesResolveButAreNotOffered() {
        #expect(Self.catalogue.label(for: "low-libido", in: .symptoms) == "Low libido")
        #expect(!Self.catalogue.offered(.symptoms).contains { $0.code == "low-libido" })
        #expect(Self.catalogue.offered(.symptoms).map(\.code) == ["cramps", "discharge"])
    }

    @Test("A catalogue that never arrived offers nothing rather than inventing codes")
    func anAbsentCatalogueOffersNothing() {
        let missing: EvaRefData? = nil
        #expect(missing.offered(.symptoms).isEmpty)
        // …and a code still reads as itself rather than as "Unknown".
        #expect(missing.label(for: "cramps", in: .symptoms) == "cramps")
    }

    @Test("The server's own row shape decodes, retired rows and value axes included")
    func theWireShapeDecodes() throws {
        let json = """
        {"version":"abc","catalogues":{"symptoms":[
          {"code":"cramps","label":"Cramps","order":20,"status":"active",
           "group":"primary","severable":true,"values":null},
          {"code":"discharge","label":"Discharge","order":200,"status":"active",
           "group":"more","severable":false,"values":["dry","egg-white"]},
          {"code":"low-libido","label":"Low libido","order":220,"status":"retired",
           "group":"more","severable":false,"values":null}],
          "sportActivities":[{"code":"other","label":"Other","order":180,
           "status":"active","freeText":true}],
          "appointmentTypes":[]}}
        """
        let decoded = try JSONDecoder().decode(EvaRefData.self, from: Data(json.utf8))

        #expect(decoded.version == "abc")
        #expect(decoded.offered(.symptoms).count == 2)
        #expect(decoded.item("cramps", in: .symptoms)?.severable == true)
        #expect(decoded.item("discharge", in: .symptoms)?.values == ["dry", "egg-white"])
        #expect(decoded.item("cramps", in: .symptoms)?.values == nil)
        #expect(decoded.item("other", in: .sportActivities)?.freeText == true)
        #expect(decoded.appointmentTypes.isEmpty)
    }

    @Test("A value axis is shown as words, whatever the catalogue grows")
    func valuesAreShownAsWords() {
        #expect(EvaRefData.valueLabel("egg-white") == "Egg-white")
        #expect(EvaRefData.valueLabel("low") == "Low")
        #expect(EvaRefData.valueLabel("") == "")
    }
}

private extension EvaRefData {
    var appointmentTypes: [Item] { offered(.appointmentTypes) }
}

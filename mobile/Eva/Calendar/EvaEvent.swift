import Foundation

/// The six things a calendar entry can be — `EventType` in `api/src/events.ts`.
///
/// `sex` is on the wire and is not yet writable: the route reserves the case and rejects
/// it until C10 ships it with its privacy switch. The app decodes it because the calendar
/// has to be able to *draw* one the moment the server can store one, and because the
/// artboard already gives it a glyph.
///
/// `positiveTest` (#80) is writable at the route and is not offered by this build's log
/// picker — the row and the sheet that write one are the next slice. It is decoded and
/// drawn for the same reason `sex` is: the grid has to show an entry the account already
/// carries, and DESIGN.md §7 has specified its mark since C1.
enum EvaEventType: String, Codable, Sendable, CaseIterable {
    case cycle
    case bodySignals
    case sport
    case appointment
    case sex
    case positiveTest

    /// Whether the server keeps at most one of these per day.
    ///
    /// Mirrors `ONE_PER_DAY` in `api/src/events.ts`, and it is a *contract* rather than a
    /// convenience: these three live at a deterministic document id, so logging one replaces
    /// the day's entry instead of adding to it. Three behaviours follow from it and none of
    /// them is optional — the picker edits the day's entry instead of offering a second,
    /// `PATCH` refuses to move one to another day, and `restore` answers `409
    /// DAY_ALREADY_LOGGED` once the day has been re-logged (#50).
    var isOnePerDay: Bool {
        switch self {
        case .cycle, .bodySignals, .positiveTest: true
        case .sport, .appointment, .sex: false
        }
    }
}

/// Who put the entry there. `eva` is reserved for entries Eva derives; everything a user
/// logs is `user`.
enum EvaEventSource: String, Codable, Sendable {
    case user
    case eva
}

/// What a cycle entry says about the day.
///
/// **One case, not two optionals.** The API's `CyclePayload` is
/// `{ spotting: true } | { flow: … }` with `never` on the other arm, which makes "both at
/// once" unrepresentable on the wire — a day is either spotting or a flow day, never a
/// spotting day that is also heavy. Two `Optional`s here would have re-introduced the
/// state the API went out of its way to delete, and the first screen to read them would
/// have had to invent a rule for it.
enum EvaCycleMark: Hashable, Sendable {
    case spotting
    case flow(EvaFlowLevel)
}

/// How heavy the day was. Spotting is deliberately **not** a fourth level — a spotting
/// day does not start a period, which is why the API models it as a separate marker.
enum EvaFlowLevel: String, Codable, Sendable, CaseIterable {
    case light
    case medium
    case heavy
}

enum EvaSportIntensity: String, Codable, Sendable, CaseIterable {
    case light
    case medium
    case hard
}

enum EvaSymptomSeverity: String, Codable, Sendable {
    case normal
    case severe
}

/// One symptom chip as it was logged.
///
/// `severity` and `value` are two axes and neither can express the other: severity is an
/// intensity (the second tap on Cramps), `value` is a category the chip's own picker
/// offers. Only chips whose `/refdata` entry declares `values` carry one.
struct EvaSymptom: Hashable, Sendable, Codable {
    /// The catalogue code. **Never shown to the user** — `/refdata` owns the label.
    let code: String
    let severity: EvaSymptomSeverity
    let value: String?

    init(code: String, severity: EvaSymptomSeverity = .normal, value: String? = nil) {
        self.code = code
        self.severity = severity
        self.value = value
    }

    /// `value` is **omitted** rather than sent as null when the chip has no value axis.
    /// The route reads both as "no value", but Firestore rejects an undefined field and
    /// `parseSymptoms` builds the stored object by spreading the key only when it is
    /// present — so an absent key is what an entry written by this app looks like on the
    /// wire as well as at rest.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(value, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case code, severity, value }
}

struct EvaBodySignalsPayload: Hashable, Sendable, Codable {
    /// 1–5, or `nil` for "not answered" — which is not the same as a 3, so it stays
    /// optional all the way through.
    let energy: Int?
    let mood: Int?
    let sleep: Int?
    let symptoms: [EvaSymptom]

    init(energy: Int? = nil, mood: Int? = nil, sleep: Int? = nil, symptoms: [EvaSymptom] = []) {
        self.energy = energy
        self.mood = mood
        self.sleep = sleep
        self.symptoms = symptoms
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        energy = try container.decodeIfPresent(Int.self, forKey: .energy)
        mood = try container.decodeIfPresent(Int.self, forKey: .mood)
        sleep = try container.decodeIfPresent(Int.self, forKey: .sleep)
        symptoms = try container.decodeIfPresent([EvaSymptom].self, forKey: .symptoms) ?? []
    }

    /// An unanswered rating is **absent**, not null and not a 3.
    ///
    /// The route reads a null the same way, so this is not the difference between working
    /// and not — it is the difference between the app's own writes and everybody else's
    /// looking the same in Firestore, which is what makes a stored document readable.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(energy, forKey: .energy)
        try container.encodeIfPresent(mood, forKey: .mood)
        try container.encodeIfPresent(sleep, forKey: .sleep)
        try container.encode(symptoms, forKey: .symptoms)
    }

    private enum CodingKeys: String, CodingKey { case energy, mood, sleep, symptoms }
}

struct EvaSportPayload: Hashable, Sendable, Codable {
    /// A `sportActivities` catalogue code, or free text behind the catalogue's `Other`.
    let activity: String
    let durationMin: Int
    let intensity: EvaSportIntensity

    init(activity: String, durationMin: Int, intensity: EvaSportIntensity) {
        self.activity = activity
        self.durationMin = durationMin
        self.intensity = intensity
    }
}

struct EvaAppointmentPayload: Hashable, Sendable, Codable {
    /// Local wall clock `YYYY-MM-DDTHH:mm(:ss)`, the same day as `localDate`.
    let startAt: String
    /// An `appointmentTypes` catalogue code, or `nil`.
    let type: String?
    let questions: [String]
    /// Reminder *intent*. Nothing is scheduled by the API, and nothing is scheduled here.
    let reminderMinutesBefore: Int?

    init(
        startAt: String,
        type: String? = nil,
        questions: [String] = [],
        reminderMinutesBefore: Int? = nil
    ) {
        self.startAt = startAt
        self.type = type
        self.questions = questions
        self.reminderMinutesBefore = reminderMinutesBefore
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startAt = try container.decode(String.self, forKey: .startAt)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        questions = try container.decodeIfPresent([String].self, forKey: .questions) ?? []
        reminderMinutesBefore = try container.decodeIfPresent(Int.self, forKey: .reminderMinutesBefore)
    }

    /// `reminderMinutesBefore` is written as an explicit **null**, never omitted.
    ///
    /// This one is not cosmetic. The route reads an *absent* key as the PRD's default of a
    /// day before and an explicit null as "no reminder" — so omitting it for a user who
    /// turned the reminder off would silently give her one.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startAt, forKey: .startAt)
        try container.encode(type, forKey: .type)
        try container.encode(questions, forKey: .questions)
        try container.encode(reminderMinutesBefore, forKey: .reminderMinutesBefore)
    }

    private enum CodingKeys: String, CodingKey {
        case startAt, type, questions, reminderMinutesBefore
    }
}

/// The type and its payload as one value, so a payload can only ever be read through the
/// type that actually has one.
enum EvaEventDetail: Hashable, Sendable {
    case cycle(EvaCycleMark)
    case bodySignals(EvaBodySignalsPayload)
    case sport(EvaSportPayload)
    case appointment(EvaAppointmentPayload)
    /// Reserved (C10). The wire type carries no payload.
    case sex
    /// A positive pregnancy test on this day (#80). Payload-less on the wire and here:
    /// PRD §Positive test is "marks the day", so the entry is the whole of the fact and
    /// there is nothing to model. The API refuses any key on it.
    case positiveTest

    var type: EvaEventType {
        switch self {
        case .cycle: .cycle
        case .bodySignals: .bodySignals
        case .sport: .sport
        case .appointment: .appointment
        case .sex: .sex
        case .positiveTest: .positiveTest
        }
    }

    /// This entry as something that could be written back, or `nil` for a type this build
    /// does not write. See `EvaEventPayload`.
    var payload: EvaEventPayload? {
        switch self {
        case .cycle(let mark): .cycle(mark)
        case .bodySignals(let payload): .bodySignals(payload)
        case .sport(let payload): .sport(payload)
        case .appointment(let payload): .appointment(payload)
        case .sex: nil
        // `nil` for a different reason from `sex`, and it is worth keeping the two apart:
        // the route stores this one. What is missing is the picker row and the sheet that
        // would write it — #80 ships the type, the mark and the legend row, and the
        // logging affordance is its own slice.
        case .positiveTest: nil
        }
    }

    /// Whether re-opening this entry in the log sheet would show anything to change.
    ///
    /// False for the two entries that are their own whole content: a `sex` entry is a
    /// neutral dot with no label, and a positive test is a day and nothing else (#80). The
    /// day list hides Edit on those rather than offering a button that opens a form with no
    /// fields in it — `LogSheet.step(editing:)` has nowhere to send either. Delete is still
    /// there, which is what PRD §Positive test asks undo to be: one tap, no questions.
    var isEditable: Bool {
        switch self {
        case .cycle, .bodySignals, .sport, .appointment: true
        case .sex, .positiveTest: false
        }
    }
}

/// The `payload` half of a write, in the shape the route's validator reads.
///
/// **There is no `sex` arm, and that is the point.** `parseEventType` refuses the type
/// until C10 ships it with its privacy switch, so a sex write is not a request that fails
/// — it is a request this app cannot construct. The same trick `EvaCycleMark` plays on the
/// read side, one layer up: make the state the server refuses unrepresentable rather than
/// checked.
enum EvaEventPayload: Hashable, Sendable, Encodable {
    case cycle(EvaCycleMark)
    case bodySignals(EvaBodySignalsPayload)
    case sport(EvaSportPayload)
    case appointment(EvaAppointmentPayload)

    var type: EvaEventType {
        switch self {
        case .cycle: .cycle
        case .bodySignals: .bodySignals
        case .sport: .sport
        case .appointment: .appointment
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .cycle(let mark):
            var container = encoder.container(keyedBy: CycleKeys.self)
            // One key or the other, never both — `parseCyclePayload` rejects a body
            // carrying two, which is the wire's half of `EvaCycleMark`'s one-case model.
            switch mark {
            case .spotting: try container.encode(true, forKey: .spotting)
            case .flow(let level): try container.encode(level, forKey: .flow)
            }
        case .bodySignals(let payload):
            try payload.encode(to: encoder)
        case .sport(let payload):
            try payload.encode(to: encoder)
        case .appointment(let payload):
            try payload.encode(to: encoder)
        }
    }

    private enum CycleKeys: String, CodingKey { case spotting, flow }
}

/// One entry from `GET /me/events`.
///
/// Soft-deleted entries never arrive — the server filters them — so there is no
/// `deletedAt` here and nothing in the app has to remember to check one.
struct EvaEvent: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let detail: EvaEventDetail
    /// The day the user says this belongs to. Never derived from a device clock.
    let localDate: EvaDay
    /// Wall clock `YYYY-MM-DDTHH:mm(:ss)`, as the device recorded it.
    let loggedAt: String
    let note: String?
    let source: EvaEventSource
    let idempotencyKey: String?

    var type: EvaEventType { detail.type }

    init(
        id: String,
        detail: EvaEventDetail,
        localDate: EvaDay,
        loggedAt: String,
        note: String? = nil,
        source: EvaEventSource = .user,
        idempotencyKey: String? = nil
    ) {
        self.id = id
        self.detail = detail
        self.localDate = localDate
        self.loggedAt = loggedAt
        self.note = note
        self.source = source
        self.idempotencyKey = idempotencyKey
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        let rawDate = try container.decode(String.self, forKey: .localDate)
        guard let localDate = EvaDay(isoDate: rawDate) else {
            throw DecodingError.dataCorruptedError(
                forKey: .localDate, in: container,
                // The value is a date and nothing else — no payload, no note, no id —
                // so naming it here does not put health data in a log (GUARDRAILS 12).
                debugDescription: "localDate is not a YYYY-MM-DD day"
            )
        }
        self.localDate = localDate

        loggedAt = try container.decode(String.self, forKey: .loggedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        source = try container.decodeIfPresent(EvaEventSource.self, forKey: .source) ?? .user
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)

        switch try container.decode(EvaEventType.self, forKey: .type) {
        case .cycle:
            let payload = try container.decode(CycleWire.self, forKey: .payload)
            guard let mark = payload.mark else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload, in: container,
                    debugDescription: "cycle payload is neither spotting nor a flow level"
                )
            }
            detail = .cycle(mark)
        case .bodySignals:
            detail = .bodySignals(try container.decode(EvaBodySignalsPayload.self, forKey: .payload))
        case .sport:
            detail = .sport(try container.decode(EvaSportPayload.self, forKey: .payload))
        case .appointment:
            detail = .appointment(try container.decode(EvaAppointmentPayload.self, forKey: .payload))
        case .sex:
            // Reserved, and payload-less on the wire. Decoded tolerantly rather than not
            // at all, so the day this type starts arriving the calendar draws it.
            detail = .sex
        case .positiveTest:
            // `payload` is `{}` on the wire and is not read: the API refuses every key on
            // it, so there is nothing here that a stricter decode could check. Decoding it
            // as a value would only give a future server's extra field a way to drop the
            // whole entry — and `EvaEventsResponse` drops entries silently.
            detail = .positiveTest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, localDate, loggedAt, note, source, idempotencyKey, payload
    }

    /// The wire shape of `CyclePayload`, collapsed into `EvaCycleMark` at the boundary so
    /// nothing downstream ever sees the two-optionals form the API refuses to have.
    ///
    /// **Total, and loud.** Every combination the API's `never` arms make unrepresentable
    /// answers `nil`, and `nil` fails the event — it does not pick one. An earlier version
    /// preferred `flow` whenever it was present, which meant
    /// `{"spotting":true,"flow":"heavy"}` was read as a heavy period day and the spotting
    /// marker vanished without trace. Guessing which half of a contradiction to believe is
    /// how a calendar comes to show a period the user never logged.
    private struct CycleWire: Decodable {
        let spotting: Bool?
        let flow: EvaFlowLevel?

        var mark: EvaCycleMark? {
            // `spotting ?? false`, so the tuple is `(Bool, EvaFlowLevel?)` — four cases a
            // Swift 6.0 compiler can prove exhaustive, where `(Bool?, EvaFlowLevel?)`'s six
            // needed a newer one and failed CI's Xcode 16.4 with "switch must be
            // exhaustive". The collapse changes nothing: an absent `spotting` and an
            // explicit `false` already mapped to the same answer in every column.
            switch (spotting ?? false, flow) {
            // The one shape the API can actually produce for a flow day.
            case (false, .some(let flow)): .flow(flow)
            case (true, nil): .spotting
            // Both at once, and neither. Neither is a day.
            case (true, .some), (false, nil): nil
            }
        }
    }
}

/// `GET /me/events` → `{ "events": [...] }`.
///
/// **A row this build cannot read is skipped, not fatal.** One unrecognised `type`, one
/// unknown flow level, one malformed `localDate` would otherwise take the whole array with
/// it and blank the calendar — every entry gone because of one the server added after this
/// build shipped. Today's API refuses both at write time so it is not reachable now; it
/// becomes reachable the first time the API grows a type, which is C10's `sex`, and the
/// failure would land on the app's landing screen.
///
/// Dropping one entry is not free either — it is health data the user logged and cannot
/// see — but it is strictly better than dropping all of them, and it is the only one of the
/// two that degrades rather than breaks.
struct EvaEventsResponse: Decodable, Sendable {
    let events: [EvaEvent]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([Row].self, forKey: .events).compactMap(\.event)
    }

    private enum CodingKeys: String, CodingKey { case events }

    /// One element of the array, which always decodes.
    ///
    /// A wrapper rather than a loop over an `UnkeyedDecodingContainer`: a `decode` that
    /// throws does not advance that container's index, so the obvious version of this
    /// spins forever on the first bad row.
    private struct Row: Decodable {
        let event: EvaEvent?

        init(from decoder: any Decoder) throws {
            event = try? EvaEvent(from: decoder)
        }
    }
}

/// What create, edit, the body-signals upsert and restore all answer: `{ "event": … }`.
struct EvaEventResponse: Decodable, Sendable {
    let event: EvaEvent
}

/// `DELETE /me/events/{id}` → `{ "deleted": true }`.
///
/// Decoded rather than ignored so a 200 carrying something else is a decoding failure
/// rather than a silent success — the app takes the entry off the grid on the strength of
/// this, and "the request did not fail" is a weaker claim than "the server says it is gone".
struct EvaDeletedResponse: Decodable, Sendable {
    let deleted: Bool
}

/// A POST that carries no fields. `restore` takes none — the id is the whole request — and
/// `APIClient.post` needs *something* to encode.
struct EvaEmptyBody: Encodable, Sendable {}

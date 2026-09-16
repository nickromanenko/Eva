import Foundation

/// The five things a calendar entry can be — `EventType` in `api/src/events.ts`.
///
/// `sex` is on the wire and is not yet writable: the route reserves the case and rejects
/// it until C10 ships it with its privacy switch. The app decodes it because the calendar
/// has to be able to *draw* one the moment the server can store one, and because the
/// artboard already gives it a glyph.
enum EvaEventType: String, Codable, Sendable, CaseIterable {
    case cycle
    case bodySignals
    case sport
    case appointment
    case sex
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

enum EvaSportIntensity: String, Codable, Sendable {
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
struct EvaSymptom: Hashable, Sendable, Decodable {
    /// The catalogue code. **Never shown to the user** — `/refdata` owns the label.
    let code: String
    let severity: EvaSymptomSeverity
    let value: String?

    init(code: String, severity: EvaSymptomSeverity = .normal, value: String? = nil) {
        self.code = code
        self.severity = severity
        self.value = value
    }
}

struct EvaBodySignalsPayload: Hashable, Sendable, Decodable {
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

    private enum CodingKeys: String, CodingKey { case energy, mood, sleep, symptoms }
}

struct EvaSportPayload: Hashable, Sendable, Decodable {
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

struct EvaAppointmentPayload: Hashable, Sendable, Decodable {
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

    var type: EvaEventType {
        switch self {
        case .cycle: .cycle
        case .bodySignals: .bodySignals
        case .sport: .sport
        case .appointment: .appointment
        case .sex: .sex
        }
    }
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
            switch (spotting, flow) {
            // The two shapes the API can actually produce.
            case (nil, .some(let flow)), (false, .some(let flow)): .flow(flow)
            case (true, nil): .spotting
            // Both at once, `spotting: false` alone, and neither. None is a day.
            case (true, .some), (false, nil), (nil, nil): nil
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

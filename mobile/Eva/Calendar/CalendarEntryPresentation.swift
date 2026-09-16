import Foundation

/// One logged entry, turned into the words the day detail shows.
///
/// Separate from the view because every string here is a decision: what an entry is
/// called, how a code becomes a label, how a rating reads. DESIGN.md §8 binds all of them
/// — describe, never diagnose, never score — and they are easier to hold to the rule when
/// they are in one place that can be read and tested on its own.
struct CalendarEntryPresentation: Equatable, Sendable {
    /// The entry's own id, which is what its row is addressed by.
    ///
    /// Not the type name: two sport entries or two appointments on one day are both legal
    /// (only `cycle` and `bodySignals` are one-per-day on the server), so a row keyed on
    /// the type would collide — and `typeName` is user-facing copy, so keying on it would
    /// have made localising the day detail break the UI tests.
    let id: String
    /// The entry's kind, in the canvas' own words.
    let typeName: String
    /// Local wall-clock time, or `nil` if `loggedAt` was not a time this could read.
    let time: String?
    /// What was logged, in one line. Empty when the type has nothing to add — a sex entry
    /// is deliberately label-only.
    let summary: String
    /// The user's own note, if there is one. Shown under the summary, never merged into it.
    let note: String?
    /// Which corner mark this type owns, so the list and the grid say the same thing with
    /// the same shape. `nil` for `cycle`, which the grid draws as a wash.
    let glyph: EvaEventGlyph?
    /// The flow or spotting marker, for the cycle entry's own mark.
    let cycleMark: EvaCycleMark?

    init(event: EvaEvent, refData: EvaRefData?) {
        id = event.id
        time = EvaWallClock.time(from: event.loggedAt)
        note = event.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        glyph = event.type.glyph

        switch event.detail {
        case .cycle(let mark):
            typeName = "Menstrual cycle"
            summary = Self.summary(for: mark)
            cycleMark = mark
        case .bodySignals(let payload):
            typeName = "Body signals"
            summary = Self.summary(for: payload, refData: refData)
            cycleMark = nil
        case .sport(let payload):
            typeName = "Sport"
            summary = Self.summary(for: payload, refData: refData)
            cycleMark = nil
        case .appointment(let payload):
            typeName = "Doctor appointment"
            summary = Self.summary(for: payload, refData: refData)
            cycleMark = nil
        case .sex:
            // The canvas is explicit: "a neutral dot with no label". Nothing else is
            // shown here and nothing else is stored here (DESIGN.md §8 — sensitive events
            // stay neutral in language *and* in indicators).
            typeName = "Sex"
            summary = ""
            cycleMark = nil
        }
    }

    // MARK: - Per type

    private static func summary(for mark: EvaCycleMark) -> String {
        switch mark {
        case .spotting: "Spotting"
        case .flow(.light): "Light flow"
        case .flow(.medium): "Medium flow"
        case .flow(.heavy): "Heavy flow"
        }
    }

    private static func summary(for payload: EvaBodySignalsPayload, refData: EvaRefData?) -> String {
        var parts: [String] = []
        for scale in EvaBodySignalScale.allCases {
            guard let rating = scale.rating(in: payload), let word = scale.word(for: rating) else { continue }
            parts.append("\(scale.label) \(word)")
        }
        for symptom in payload.symptoms {
            let label = refData.label(for: symptom.code, in: .symptoms)
            // The word, not the colour. The severe chip is a fill *and* a bar glyph on the
            // canvas; in a list of words the word is the only mark there is.
            parts.append(symptom.severity == .severe ? "\(label) (severe)" : label)
        }
        return parts.joined(separator: ", ")
    }

    private static func summary(for payload: EvaSportPayload, refData: EvaRefData?) -> String {
        let activity = refData.label(for: payload.activity, in: .sportActivities)
        // `.minute` so "45 min" reads the way the canvas writes it, and so a locale that
        // abbreviates differently still gets its own.
        let duration = Duration.seconds(payload.durationMin * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(activity) · \(duration) · \(payload.intensity.rawValue) intensity"
    }

    private static func summary(for payload: EvaAppointmentPayload, refData: EvaRefData?) -> String {
        var parts: [String] = []
        if let type = payload.type {
            parts.append(refData.label(for: type, in: .appointmentTypes))
        }
        if let start = EvaWallClock.time(from: payload.startAt) {
            parts.append(start)
        }
        if !payload.questions.isEmpty {
            parts.append(payload.questions.count == 1
                ? "1 question to bring"
                : "\(payload.questions.count) questions to bring")
        }
        return parts.joined(separator: " · ")
    }
}

/// The three five-point scales a body-signals entry can carry, with the canvas' own words
/// for each point.
///
/// The words are the artboard's `scales[].words`, not a rewording of them. A number alone
/// ("Energy 2") reads as a score, which §8 rules out; the canvas already chose vocabulary
/// that describes instead, and this uses it.
enum EvaBodySignalScale: String, CaseIterable, Sendable {
    case energy
    case mood
    case sleep

    var label: String {
        switch self {
        case .energy: "Energy"
        case .mood: "Mood"
        case .sleep: "Sleep"
        }
    }

    /// Words for 1…5.
    var words: [String] {
        switch self {
        case .energy: ["Depleted", "Low", "Steady", "Good", "High"]
        case .mood: ["Low", "Down", "Neutral", "Good", "Bright"]
        case .sleep: ["Barely slept", "Restless", "Broken", "Solid", "Deep"]
        }
    }

    func rating(in payload: EvaBodySignalsPayload) -> Int? {
        switch self {
        case .energy: payload.energy
        case .mood: payload.mood
        case .sleep: payload.sleep
        }
    }

    /// The word for a rating, or `nil` if the value is outside 1…5 — which the server does
    /// not currently allow and a future one might.
    func word(for rating: Int) -> String? {
        guard (1...words.count).contains(rating) else { return nil }
        return words[rating - 1]
    }
}

/// Times that are wall clock and nothing else.
///
/// `loggedAt` and an appointment's `startAt` are `YYYY-MM-DDTHH:mm(:ss)` with **no zone**,
/// by design: they are what the user's device said the time was, so a later flight cannot
/// move an entry. Parsing one as an instant would attach the device's current zone to a
/// string that never had one and shift last month's entries by an hour when the clocks go
/// back — the exact failure the API's wall-clock storage exists to avoid.
enum EvaWallClock {

    /// The time part of a local date-time, formatted to the user's clock preference.
    ///
    /// `nil` rather than a guess when the string is not one this can read: the day detail
    /// then shows the entry without a time, which is honest, where a fallback of "00:00"
    /// would be a time that was never logged.
    static func time(from localDateTime: String) -> String? {
        let halves = localDateTime.split(separator: "T", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let fields = halves[1].split(separator: ":")
        guard fields.count >= 2,
              let hour = Int(fields[0]), let minute = Int(fields[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }

        // Anchored in UTC and formatted in UTC, so the components out are the components
        // in. Only the 12/24-hour preference and the separator come from the locale.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(
            from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
        ) else { return nil }
        return date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt)
                .locale(.autoupdatingCurrent)
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation

/// What each log sheet is holding before it is saved, and the payload it turns into.
///
/// Value types rather than an `@Observable` model, and held by the sheet in `@State`. The
/// reason is that everything interesting about them is a **pure function of the form**:
/// which chips are on, what a rating is, whether the entry is complete enough to save.
/// #160 asks for the payload builders to be tested, and a struct with a `payload` property
/// can be tested by constructing one — no view, no session, no network, no main actor.
///
/// Each draft can also be built **from** an entry, which is the whole of "re-opening a
/// logged day loads the existing entry for editing rather than creating a second". The two
/// directions live beside each other on purpose: a field that is written but never read
/// back is a field an edit silently drops.

// MARK: - Menstrual cycle

struct LogCycleDraft: Equatable, Sendable {
    /// Nothing is preselected. A cycle entry needs a marker, so `nil` is also what makes
    /// the sheet's CTA unavailable.
    var mark: EvaCycleMark?
    var note: String = ""

    init(mark: EvaCycleMark? = nil, note: String = "") {
        self.mark = mark
        self.note = note
    }

    init(editing event: EvaEvent) {
        if case .cycle(let mark) = event.detail { self.mark = mark }
        self.note = event.note ?? ""
    }

    var payload: EvaEventPayload? {
        mark.map { .cycle($0) }
    }
}

// MARK: - Body signals

/// How one symptom chip is currently set.
///
/// Three states, not a `Bool` plus a flag: "off" and "on, not severe" and "on, severe" are
/// what a chip cycles through, and the middle one is the one a two-state model loses.
enum LogSymptomState: Equatable, Sendable {
    case off
    case on(value: String?)
    case severe(value: String?)

    var isOn: Bool { self != .off }

    var isSevere: Bool {
        if case .severe = self { return true }
        return false
    }

    var severity: EvaSymptomSeverity? {
        switch self {
        case .off: nil
        case .on: .normal
        case .severe: .severe
        }
    }

    var value: String? {
        switch self {
        case .off: nil
        case .on(let value), .severe(let value): value
        }
    }

    /// The value axis survives a severity change — choosing "Egg-white" and then marking
    /// the chip severe must not silently drop the choice.
    func settingValue(_ value: String?) -> LogSymptomState {
        switch self {
        case .off: .on(value: value)
        case .on: .on(value: value)
        case .severe: .severe(value: value)
        }
    }
}

struct LogBodySignalsDraft: Equatable, Sendable {
    /// 1…5, or `nil` for not answered — which is not a 3, all the way to the wire.
    var energy: Int?
    var mood: Int?
    var sleep: Int?
    /// Keyed by catalogue code. Codes, never labels: `/refdata` owns the words and the
    /// route validates the code.
    var symptoms: [String: LogSymptomState] = [:]
    var note: String = ""
    /// Whether the "More…" group is revealed. Form state, not entry state — except that
    /// an entry carrying a `more` chip opens with the group already open, or the chip it
    /// is showing would be invisible.
    var showsMoreSymptoms = false

    init(energy: Int? = nil, mood: Int? = nil, sleep: Int? = nil) {
        self.energy = energy
        self.mood = mood
        self.sleep = sleep
    }

    init(editing event: EvaEvent, refData: EvaRefData?) {
        guard case .bodySignals(let payload) = event.detail else { return }
        energy = payload.energy
        mood = payload.mood
        sleep = payload.sleep
        for symptom in payload.symptoms {
            symptoms[symptom.code] = symptom.severity == .severe
                ? .severe(value: symptom.value)
                : .on(value: symptom.value)
        }
        note = event.note ?? ""
        showsMoreSymptoms = payload.symptoms.contains { symptom in
            // A code the catalogue has never heard of is treated as hidden, so a chip
            // logged by a newer build is still visible to this one.
            refData.item(symptom.code, in: .symptoms)?.group ?? .more == .more
        }
    }

    func state(of code: String) -> LogSymptomState { symptoms[code] ?? .off }

    /// One tap on a chip.
    ///
    /// `severable` comes from the catalogue, so the cycle is off → on → off for most chips
    /// and off → on → severe → off for the ones the catalogue marks. The API would accept
    /// severity on anything; offering it everywhere would make the second tap mean
    /// something different on every chip, which is the opposite of what a chip is for.
    mutating func tap(_ item: EvaRefData.Item) {
        switch state(of: item.code) {
        case .off:
            symptoms[item.code] = .on(value: nil)
        case .on(let value):
            symptoms[item.code] = item.severable ? .severe(value: value) : .off
        case .severe:
            symptoms[item.code] = .off
        }
    }

    mutating func choose(_ value: String, for code: String) {
        let current = state(of: code)
        // Tapping the chosen value again clears it: the axis is optional, and a picker
        // with no way back would make a mis-tap permanent.
        symptoms[code] = current.settingValue(current.value == value ? nil : value)
    }

    /// The symptoms this draft would send, in catalogue order.
    ///
    /// Order is taken from the catalogue rather than from a dictionary, which has none —
    /// so two saves of the same selection produce the same array, and a diff of two stored
    /// entries means something.
    func selectedSymptoms(in catalogue: [EvaRefData.Item]) -> [EvaSymptom] {
        var selected = catalogue.compactMap { item -> EvaSymptom? in
            let state = self.state(of: item.code)
            guard let severity = state.severity else { return nil }
            return EvaSymptom(code: item.code, severity: severity, value: state.value)
        }
        // Anything selected that this build's catalogue no longer offers — a chip on an
        // entry being edited whose code has since been retired. Dropping it would delete
        // part of someone's entry as a side effect of editing another part of it.
        let known = Set(catalogue.map(\.code))
        for (code, state) in symptoms.sorted(by: { $0.key < $1.key }) {
            guard !known.contains(code), let severity = state.severity else { continue }
            selected.append(EvaSymptom(code: code, severity: severity, value: state.value))
        }
        return selected
    }

    func bodySignals(in catalogue: [EvaRefData.Item]) -> EvaBodySignalsPayload {
        EvaBodySignalsPayload(
            energy: energy,
            mood: mood,
            sleep: sleep,
            symptoms: selectedSymptoms(in: catalogue)
        )
    }

    func payload(in catalogue: [EvaRefData.Item]) -> EvaEventPayload? {
        let signals = bodySignals(in: catalogue)
        // An entry with nothing in it is not an entry. The route would happily store a
        // body-signals document with three nulls and no symptoms, and it would then sit on
        // the grid as a mark meaning nothing.
        guard signals.energy != nil || signals.mood != nil || signals.sleep != nil
                || !signals.symptoms.isEmpty
        else { return nil }
        return .bodySignals(signals)
    }
}

// MARK: - Sport

struct LogSportDraft: Equatable, Sendable {
    /// A catalogue code, or `nil` until one is chosen.
    var activityCode: String?
    /// What the user typed behind the catalogue's free-text option ("Other").
    var otherActivity: String = ""
    var durationMin: Int = LogSportDraft.defaultDuration
    var intensity: EvaSportIntensity?
    var note: String = ""

    /// The route's own bounds (`durationMin` 5…300, in whole minutes).
    static let durationRange = 5...300
    static let durationStep = 5
    /// The middle of the artboard's own duration chips (15 · 30 · 45 · 60 · 90).
    static let defaultDuration = 45
    static let durationPresets = [15, 30, 45, 60, 90]

    init() {}

    init(editing event: EvaEvent, refData: EvaRefData?) {
        guard case .sport(let payload) = event.detail else { return }
        durationMin = payload.durationMin
        intensity = payload.intensity
        note = event.note ?? ""
        // What is stored is either a code or the words behind the free-text option, and
        // the catalogue is the only thing that can tell them apart.
        if refData.item(payload.activity, in: .sportActivities) != nil {
            activityCode = payload.activity
        } else {
            activityCode = refData.offered(.sportActivities).first(where: \.freeText)?.code
            otherActivity = payload.activity
        }
    }

    /// What goes on the wire as `activity`: a catalogue code, or the free text behind it.
    func activity(in catalogue: [EvaRefData.Item]) -> String? {
        guard let activityCode else { return nil }
        guard catalogue.first(where: { $0.code == activityCode })?.freeText == true else {
            return activityCode
        }
        let typed = otherActivity.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Other" with nothing typed is not an activity. Sending the code `other` would
        // store a workout whose only description is that it was not one of the listed ones.
        return typed.isEmpty ? nil : typed
    }

    func payload(in catalogue: [EvaRefData.Item]) -> EvaEventPayload? {
        guard let activity = activity(in: catalogue), let intensity,
              Self.durationRange.contains(durationMin)
        else { return nil }
        return .sport(EvaSportPayload(
            activity: activity, durationMin: durationMin, intensity: intensity
        ))
    }

    mutating func adjustDuration(by minutes: Int) {
        durationMin = min(
            Self.durationRange.upperBound,
            max(Self.durationRange.lowerBound, durationMin + minutes)
        )
    }
}

// MARK: - Doctor appointment

struct LogAppointmentDraft: Equatable, Sendable {
    /// An `appointmentTypes` code, or `nil` — the route allows an appointment with no type.
    var typeCode: String?
    /// Wall clock on the appointment's own day. Never an instant: an appointment is at ten
    /// o'clock wherever you are, and storing one as a moment moves it when you travel.
    var hour: Int = LogAppointmentDraft.defaultHour
    var minute: Int = 0
    var questions: [String] = []
    /// What the "Add a question" field is holding.
    var draftQuestion: String = ""
    var remind: Bool = true
    var note: String = ""

    /// The PRD's default reminder: a day before. The route applies the same number when
    /// the key is absent; it is written out here because the toggle has to be able to say
    /// *what* it turns on.
    static let reminderMinutesBefore = 1440
    static let defaultHour = 9
    /// The route's own cap.
    static let questionLimit = 50

    init() {}

    init(editing event: EvaEvent) {
        guard case .appointment(let payload) = event.detail else { return }
        typeCode = payload.type
        questions = payload.questions
        remind = payload.reminderMinutesBefore != nil
        note = event.note ?? ""
        if let time = LogAppointmentDraft.time(from: payload.startAt) {
            hour = time.hour
            minute = time.minute
        }
    }

    /// `HH:mm` out of a local `YYYY-MM-DDTHH:mm(:ss)`.
    ///
    /// Parsed by hand for the same reason `EvaWallClock` formats by hand: the string has no
    /// zone in it, and handing it to a date parser attaches the device's, which moves the
    /// appointment by an hour twice a year.
    static func time(from localDateTime: String) -> (hour: Int, minute: Int)? {
        let halves = localDateTime.split(separator: "T", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let fields = halves[1].split(separator: ":")
        guard fields.count >= 2, let hour = Int(fields[0]), let minute = Int(fields[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    /// The `startAt` the route validates: seconds included, and on the entry's own day.
    func startAt(on day: EvaDay) -> String {
        String(format: "%@T%02d:%02d:00", day.isoDate, hour, minute)
    }

    mutating func addDraftQuestion() {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, questions.count < Self.questionLimit else { return }
        questions.append(question)
        draftQuestion = ""
    }

    func payload(on day: EvaDay) -> EvaEventPayload? {
        .appointment(EvaAppointmentPayload(
            startAt: startAt(on: day),
            type: typeCode,
            questions: questions,
            // Explicitly nil, which the encoder writes as an explicit null. Omitting it
            // would give a user who turned the reminder off the route's default instead.
            reminderMinutesBefore: remind ? Self.reminderMinutesBefore : nil
        ))
    }
}

// MARK: - Notes

extension String {
    /// A note as the API stores it: trimmed, and `nil` rather than empty.
    ///
    /// The route does the same trim, so this is not validation — it is what stops an
    /// untouched note field from writing an empty string into a health record and then
    /// drawing a blank line under the entry that reads as a note nobody can see.
    var evaTrimmedNote: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

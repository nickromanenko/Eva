import Foundation

/// The option lists the client draws, from `GET /refdata`.
///
/// **Labels are never hard-coded in the app.** Symptom chips, sport activities and
/// appointment types are data rather than code (PRD:483): a new option ships without an
/// app release, and a label can be corrected without an app release either. What an event
/// stores is a `code` — opaque, permanent, never reused — and the only thing that turns a
/// code into words is this catalogue. A retired item still resolves, so an entry logged
/// last year still reads correctly.
///
/// Held in memory for the lifetime of the screen and no longer. The offline store that
/// makes it survive a launch is #78; until then a launch with no signal draws codes
/// through `EvaRefData.label(for:in:)`'s fallback rather than showing nothing.
struct EvaRefData: Decodable, Sendable, Hashable {
    /// Content-derived. `GET /refdata?version=` answers `304` when it matches — which is
    /// what #78 will cache against.
    let version: String
    let catalogues: Catalogues

    struct Catalogues: Decodable, Sendable, Hashable {
        let symptoms: [Item]
        let sportActivities: [Item]
        let appointmentTypes: [Item]
        /// The per-country emergency guidance table (#87). Empty until the server seeds
        /// it or sends it — every read below treats that as "no guidance", which leaves
        /// the red-flag card with its own (already neutral) wording.
        let emergencyGuidance: [EmergencyEntry]

        init(
            symptoms: [Item] = [],
            sportActivities: [Item] = [],
            appointmentTypes: [Item] = [],
            emergencyGuidance: [EmergencyEntry] = []
        ) {
            self.symptoms = symptoms
            self.sportActivities = sportActivities
            self.appointmentTypes = appointmentTypes
            self.emergencyGuidance = emergencyGuidance
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            symptoms = try container.decodeIfPresent([Item].self, forKey: .symptoms) ?? []
            sportActivities = try container.decodeIfPresent([Item].self, forKey: .sportActivities) ?? []
            appointmentTypes = try container.decodeIfPresent([Item].self, forKey: .appointmentTypes) ?? []
            emergencyGuidance = try container.decodeIfPresent(
                [EmergencyEntry].self, forKey: .emergencyGuidance) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case symptoms, sportActivities, appointmentTypes, emergencyGuidance
        }
    }

    /// One catalogue row.
    ///
    /// One struct for all three catalogues, where the API has two interfaces: `symptoms`
    /// carries `group`, `severable` and `values`, the option lists carry `freeText`. The
    /// alternative is three Swift types and three lookup paths for what is, on the wire,
    /// one document shape with optional keys — and a chip and a sport row are drawn by the
    /// same code here. Every field decodes leniently, because these documents are
    /// hand-editable in the console and a row typed in by a person must not break a screen.
    struct Item: Decodable, Sendable, Hashable, Identifiable {
        let code: String
        let label: String
        /// Retired items keep resolving to a label and are never **offered**. See `status`.
        let status: Status
        /// Symptoms only: the grid, or behind "More…".
        let group: Group
        /// Symptoms only, advisory: PRD chip requirement 4 marks *these* chips severe on a
        /// second tap. The API accepts `severity` on anything, so this narrows the UI, not
        /// the data.
        let severable: Bool
        /// The chip's own value axis — `nil` when it has no picker. A category, never an
        /// intensity: severity is the other axis and neither can express the other.
        let values: [String]?
        /// "Other" reveals a free-text field, so this code is not the whole answer.
        let freeText: Bool

        var id: String { code }

        enum Status: String, Decodable, Sendable { case active, retired }
        enum Group: String, Decodable, Sendable { case primary, more }

        init(
            code: String,
            label: String,
            status: Status = .active,
            group: Group = .primary,
            severable: Bool = false,
            values: [String]? = nil,
            freeText: Bool = false
        ) {
            self.code = code
            self.label = label
            self.status = status
            self.group = group
            self.severable = severable
            self.values = values
            self.freeText = freeText
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            label = try container.decode(String.self, forKey: .label)
            // An unknown `status` is treated as active rather than as a decode failure: a
            // value this app has not heard of must not take the whole catalogue down, and
            // the conservative reading of "I don't know what this is" for an option list
            // is to keep offering it.
            status = (try? container.decodeIfPresent(Status.self, forKey: .status))
                .flatMap { $0 } ?? .active
            group = (try? container.decodeIfPresent(Group.self, forKey: .group))
                .flatMap { $0 } ?? .primary
            severable = try container.decodeIfPresent(Bool.self, forKey: .severable) ?? false
            // `[]` and `null` both mean "no picker" — the server writes `null`, but a row
            // edited by hand can easily end up with an empty array.
            values = (try container.decodeIfPresent([String].self, forKey: .values))
                .flatMap { $0.isEmpty ? nil : $0 }
            freeText = try container.decodeIfPresent(Bool.self, forKey: .freeText) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case code, label, status, group, severable, values, freeText
        }
    }

    // MARK: Emergency guidance (#87)

    /// The code of the one entry that is not a country — what every country the table
    /// does not carry resolves to. Mirrors `FALLBACK_GUIDANCE_CODE` on the API.
    static let fallbackGuidanceCode = "fallback"

    /// One row of the per-country emergency guidance table (#87).
    ///
    /// `code` is an ISO 3166-1 alpha-2 country code (`US`, `GB`) — except the fallback
    /// row, whose code is `EvaRefData.fallbackGuidanceCode`. `label` is the country's
    /// display name, which is what the Settings picker draws. Fields decode leniently
    /// like every other catalogue row's, because the table is hand-editable in the
    /// console and one row typed by a person must not take the screen down.
    struct EmergencyEntry: Decodable, Sendable, Hashable, Identifiable {
        let code: String
        let label: String
        /// The country's national emergency number, or `nil` where the entry states
        /// none — which is always the case for the fallback: no number at all is safer
        /// than a guessed one (#87). `nil` is the seed file saying so, not a lost field.
        let emergencyNumber: String?
        /// The wording for urgent maternity care: the complete sentence(s) the red-flag
        /// card's guidance line becomes for this country. Rendered verbatim, never
        /// edited here — the device adds no copy of its own.
        let urgentCareWording: String
        /// Support resources (PRD §Pregnancy loss 5). Empty on the fallback.
        let support: [SupportResource]
        /// Retired entries still resolve — but a retired *country* resolves to the
        /// fallback, not to wording nobody stands behind any more. See `emergencyGuidance(forCountry:)`.
        let status: Item.Status

        var id: String { code }

        init(
            code: String,
            label: String,
            emergencyNumber: String? = nil,
            urgentCareWording: String = "",
            support: [SupportResource] = [],
            status: Item.Status = .active
        ) {
            self.code = code
            self.label = label
            self.emergencyNumber = emergencyNumber
            self.urgentCareWording = urgentCareWording
            self.support = support
            self.status = status
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? code
            emergencyNumber = try container.decodeIfPresent(String.self, forKey: .emergencyNumber)
            urgentCareWording = try container.decodeIfPresent(
                String.self, forKey: .urgentCareWording) ?? ""
            support = try container.decodeIfPresent(
                [SupportResource].self, forKey: .support) ?? []
            status = (try? container.decodeIfPresent(Item.Status.self, forKey: .status))
                .flatMap { $0 } ?? .active
        }

        private enum CodingKeys: String, CodingKey {
            case code, label, status, emergencyNumber, urgentCareWording, support
        }
    }

    /// One named support service and how to reach it. A row that cannot say both is not
    /// a resource, and the server's parser drops it before it is ever served — this side
    /// only decodes what survived.
    struct SupportResource: Decodable, Sendable, Hashable, Identifiable {
        let label: String
        let detail: String

        var id: String { label }

        init(label: String, detail: String) {
            self.label = label
            self.detail = detail
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case label, detail
        }
    }

    /// Which catalogue a code belongs to. The three are separate namespaces on the
    /// server, so a lookup has to say which one it means.
    enum Catalogue: Sendable {
        case symptoms
        case sportActivities
        case appointmentTypes
    }

    func items(_ catalogue: Catalogue) -> [Item] {
        switch catalogue {
        case .symptoms: catalogues.symptoms
        case .sportActivities: catalogues.sportActivities
        case .appointmentTypes: catalogues.appointmentTypes
        }
    }

    /// What a picker may **offer**, which is not the same list as what it can **resolve**.
    ///
    /// `/refdata` serves retired items on purpose — an entry logged last year still reads
    /// correctly, and the route still accepts a retired code on write so a stale client is
    /// never refused. Offering one as a fresh choice is the thing retirement exists to
    /// stop, so every picker in C2 reads through here and `label(for:in:)` still reads
    /// through `items(_:)`.
    ///
    /// Already in `order` when it arrives — the API sorts before it serves — so nothing
    /// here re-sorts and the two cannot disagree.
    func offered(_ catalogue: Catalogue) -> [Item] {
        items(catalogue).filter { $0.status == .active }
    }

    /// The label for a code, or `nil` if this catalogue has never heard of it.
    func label(for code: String, in catalogue: Catalogue) -> String? {
        items(catalogue).first { $0.code == code }?.label
    }

    /// One catalogue row by code, retired included.
    func item(_ code: String, in catalogue: Catalogue) -> Item? {
        items(catalogue).first { $0.code == code }
    }

    /// The guidance for a country, or `nil` when there is nothing to show.
    ///
    /// Convenience over `emergencyGuidance(from:forCountry:)` for a whole catalogue.
    func emergencyGuidance(forCountry country: String?) -> EmergencyEntry? {
        Self.emergencyGuidance(from: catalogues.emergencyGuidance, forCountry: country)
    }

    /// The device-side half of `resolveEmergencyGuidance` (api/src/refdata.ts), which is
    /// the written-down contract and the reason this function's rules read the way they
    /// do. The country **never leaves the device** (LAUNCH §2.4): the whole table
    /// arrives from `GET /refdata` and this lookup is the only thing that runs on it.
    ///
    /// - A country the table carries *and* stands behind (`status == .active`) wins.
    /// - A **retired** entry loses to the fallback: retirement here means "no longer
    ///   offering this country's wording", and showing it because the row still exists
    ///   would make retirement cosmetic.
    /// - An unknown, malformed or empty country resolves to the fallback too. This is
    ///   not an error path — it is a woman the table cannot name, and she still gets
    ///   the neutral line rather than nothing.
    /// - The fallback itself carries **no number and no resources**, so no code this
    ///   table has never heard of can ever be shown another country's emergency
    ///   number, however the table is edited.
    /// - `nil` — no fallback row in the table **and** no active entry for the country.
    ///   The caller then leaves the card's own wording in place, which is the same
    ///   neutral sentence the fallback carries (`refdata.test.ts` holds the two
    ///   byte-equal).
    ///
    /// The country code is whatever `Locale.region` and the Settings override produce:
    /// trimmed, uppercased, and required to be exactly two letters before it is looked
    /// up — anything else (`419`, `en_US`, `""`) is *unknown*, never a partial match.
    static func emergencyGuidance(
        from entries: [EmergencyEntry],
        forCountry country: String?
    ) -> EmergencyEntry? {
        let fallback = entries.first(where: { $0.code == Self.fallbackGuidanceCode })
        guard let country, !country.isEmpty else { return fallback }
        let code = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isLetter }), code.allSatisfy({ $0.isASCII })
        else { return fallback }
        guard let match = entries.first(where: { $0.code == code }), match.status == .active
        else { return fallback }
        return match
    }

    /// A value-axis option as words — `egg-white` → "Egg-white", `low` → "Low".
    ///
    /// The one place in C2 where the client puts words to catalogue data, and it is
    /// unavoidable: `values` is a bare `[String]` with no labels beside it, so either the
    /// app transforms the stored value or it ships a second vocabulary of its own. A
    /// transform stays honest when the catalogue grows a value this build has never seen,
    /// which a lookup table would not. Reported on #160 as something the canvas'
    /// hand-written "Egg-white" implies and the catalogue does not carry.
    static func valueLabel(_ value: String) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
    }
}

extension Optional where Wrapped == EvaRefData {

    /// The label for a code when the catalogue may not have arrived yet.
    ///
    /// Falls back to the code itself rather than to a placeholder word. A user reading
    /// `hot_flashes` has been shown something true and slightly ugly; a user reading
    /// "Unknown" or an empty row has been told their entry is not there. §8 asks the
    /// product to describe rather than soften, and this is the smallest version of that.
    func label(for code: String, in catalogue: EvaRefData.Catalogue) -> String {
        self?.label(for: code, in: catalogue) ?? code
    }

    /// What a picker may offer, or nothing at all when the catalogue has not arrived.
    ///
    /// Empty rather than a built-in fallback list, and that is the rule #24 settled:
    /// symptom codes are validated server-side, so a hard-coded chip would be a code this
    /// build invented and the route would refuse it. The sheets show the catalogue's own
    /// absence instead (see `LogBodySignalsStep`), which is at least true.
    func offered(_ catalogue: EvaRefData.Catalogue) -> [EvaRefData.Item] {
        self?.offered(catalogue) ?? []
    }

    func item(_ code: String, in catalogue: EvaRefData.Catalogue) -> EvaRefData.Item? {
        self?.item(code, in: catalogue)
    }

    /// The guidance for a country, or `nil` when the catalogue has not arrived — which
    /// leaves every consumer on the wording the card or the screen already carries, the
    /// same answer an unreadable catalogue gets.
    func emergencyGuidance(forCountry country: String?) -> EvaRefData.EmergencyEntry? {
        self?.emergencyGuidance(forCountry: country)
    }
}

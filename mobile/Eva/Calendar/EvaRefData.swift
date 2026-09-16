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

        init(symptoms: [Item] = [], sportActivities: [Item] = [], appointmentTypes: [Item] = []) {
            self.symptoms = symptoms
            self.sportActivities = sportActivities
            self.appointmentTypes = appointmentTypes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            symptoms = try container.decodeIfPresent([Item].self, forKey: .symptoms) ?? []
            sportActivities = try container.decodeIfPresent([Item].self, forKey: .sportActivities) ?? []
            appointmentTypes = try container.decodeIfPresent([Item].self, forKey: .appointmentTypes) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case symptoms, sportActivities, appointmentTypes
        }
    }

    /// One catalogue row, reduced to what C1 reads.
    ///
    /// The API also serves `order`, `group`, `severable`, `values` and `freeText`. They
    /// belong to the sheets that offer the options, which is C2 — decoding them here would
    /// be modelling a screen that does not exist yet.
    struct Item: Decodable, Sendable, Hashable {
        let code: String
        let label: String
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

    /// The label for a code, or `nil` if this catalogue has never heard of it.
    func label(for code: String, in catalogue: Catalogue) -> String? {
        items(catalogue).first { $0.code == code }?.label
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
}

import Foundation

/// One questionnaire option: the **code** the API stores and the **label** the chip draws.
///
/// The two are separate on purpose (#81, A8). `users.ts` holds the same codes and says why:
/// a code is opaque, permanent and never reused, so editing the wording of an option is a
/// copy change, and editing a code is a data migration. The app used to send the label, so
/// "Anemia" → "Anaemia" would have been a migration and nobody would have noticed until the
/// spelling was already in a thousand documents.
///
/// `id` is the code, so a `ForEach` re-identifies on the stored value rather than on text
/// that is expected to change.
struct ProfileOption: Identifiable, Hashable {
    let code: String
    let label: String

    var id: String { code }

    init(_ code: String, _ label: String) {
        self.code = code
        self.label = label
    }
}

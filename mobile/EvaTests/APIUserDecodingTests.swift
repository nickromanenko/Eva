import Foundation
import Testing
@testable import Eva

/// `APIUser.activated` and the one thing that is subtle about it (#6).
///
/// The field arrives from an API that did not always send it. Three values, two meanings:
/// `true` and `false` are the account's state, and **absent is `true`** — the same rule
/// the server applies to a `users/{uid}` document with no `activatedAt`. Getting that
/// backwards would sign out every account created before the field existed, and it would
/// do it silently, at launch, on a build that had passed every other test.
///
/// The absent case is not hypothetical here: `SessionExpiryTests` and
/// `OfflineLaunchTests` both stub `{ "user": … }` bodies without the field, which is what
/// a session validated against an older API looks like.
@Suite("Issue #6 · what `activated` means when the API does not send it")
struct APIUserDecodingTests {

    private static func user(_ json: String) throws -> APIUser {
        try JSONDecoder().decode(APIUser.self, from: Data(json.utf8))
    }

    @Test("an absent field means activated, because it predates the field")
    func absentIsActivated() throws {
        let user = try Self.user(
            #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true}"#
        )
        #expect(user.activated)
    }

    @Test("a present field is taken as it comes")
    func presentIsRead() throws {
        let json = #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":false,"activated":%@}"#
        #expect(try Self.user(json.replacingOccurrences(of: "%@", with: "true")).activated)
        #expect(try !Self.user(json.replacingOccurrences(of: "%@", with: "false")).activated)
    }

    @Test("a null profile still decodes, alongside the new field")
    func nullProfileDecodes() throws {
        let user = try Self.user(
            #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":false,"activated":false,"profile":null}"#
        )
        #expect(user.profile == nil)
        #expect(!user.activated)
    }
}

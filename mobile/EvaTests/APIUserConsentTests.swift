import Foundation
import Testing
@testable import Eva

/// The consent record on `APIUser`, and the one decision that hangs off it (#86).
///
/// Four shapes arrive on the wire and each means something different: no `consent` key at
/// all (an API that predates #86, which also has no refusal gate — gating on it would be
/// inventing an ask the server never made), an empty record (the real never-asked state),
/// a granted record under this build's version, and everything else — which is the screen
/// again. A withdrawn record is deliberately *not* the screen: the freeze keeps her in
/// the app, and the way back is Settings › Privacy, not a gate that re-asks what she has
/// already declined.
@Suite("Issue #86 · what the consent record asks of the session")
struct APIUserConsentTests {

    /// The version this build's screen displays — `ConsentPolicy.version` spelled out, so
    /// a copy change that forgets to bump it fails here as well as in the UI suite.
    private static let version = "2026-08-30"

    private static func user(_ consentJSON: String) throws -> APIUser {
        try JSONDecoder().decode(
            APIUser.self,
            from: Data(
                #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":false,"consent":\#(consentJSON)}"#
                    .utf8
            )
        )
    }

    private static func gate(_ consentJSON: String) throws -> Bool {
        try user(consentJSON).needsConsentGate(currentVersion: Self.version)
    }

    private static func record(version: String, withdrawnAt: String?) -> String {
        let withdrawn = withdrawnAt.map { #""\#($0)""# } ?? "null"
        return #"{"version":"\#(version)","at":"2026-09-19T08:00:00.000Z","withdrawnAt":\#(withdrawn)}"#
    }

    @Test("an API that sends no consent at all never asks — the gate must not invent one")
    func absentConsentDoesNotGate() throws {
        // Built whole rather than through `user(_:)`, which is the shape *with* a
        // `consent` key to fill — this is the shape without one.
        let user = try JSONDecoder().decode(
            APIUser.self,
            from: Data(
                #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":false}"#
                    .utf8
            )
        )
        #expect(user.consent == nil)
        #expect(!user.needsConsentGate(currentVersion: Self.version))
    }

    @Test("an empty record is the never-asked state, and that one gates")
    func emptyRecordGates() throws {
        #expect(try Self.gate(#"{"collect":null,"share":null}"#))
    }

    @Test("a share record alone is still not a collect consent")
    func shareAloneGates() throws {
        #expect(try Self.gate(#"{"collect":null,"share":\#(Self.record(version: Self.version, withdrawnAt: nil))}"#))
    }

    @Test("a granted record under this build's version is the consented state")
    func grantedDoesNotGate() throws {
        #expect(try !Self.gate(#"{"collect":\#(Self.record(version: Self.version, withdrawnAt: nil)),"share":null}"#))
    }

    @Test("a record under an older version gates again — the re-prompt")
    func oldVersionGates() throws {
        #expect(try Self.gate(#"{"collect":\#(Self.record(version: "2026-01-01", withdrawnAt: nil)),"share":null}"#))
    }

    @Test("a withdrawn record does not gate — the freeze is a state inside the app")
    func withdrawnDoesNotGate() throws {
        #expect(try !Self.gate(#"{"collect":\#(Self.record(version: Self.version, withdrawnAt: "2026-09-19T12:00:00.000Z")),"share":null}"#))
        // Even a withdrawal of an older text: she declined what she was shown, and the
        // screen does not re-ask what has been declined.
        #expect(try !Self.gate(#"{"collect":\#(Self.record(version: "2026-01-01", withdrawnAt: "2026-02-01T08:00:00.000Z")),"share":null}"#))
    }

    @Test("the record round-trips: version, granted instant, and withdrawal instant")
    func fieldsRoundTrip() throws {
        let consent = try Self.user(
            #"{"collect":\#(Self.record(version: Self.version, withdrawnAt: "2026-09-19T12:00:00.000Z")),"share":null}"#
        ).consent
        #expect(consent?.collect?.version == "2026-08-30")
        #expect(consent?.collect?.at == "2026-09-19T08:00:00.000Z")
        #expect(consent?.collect?.withdrawnAt == "2026-09-19T12:00:00.000Z")
        #expect(consent?.share == nil)
    }
}

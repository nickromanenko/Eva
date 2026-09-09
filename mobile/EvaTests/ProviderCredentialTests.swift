import Foundation
import Testing
@testable import Eva

/// Issue #7: the wire shapes the app and the API agreed on, and the field of
/// `APIUser` that says which providers an account has.
///
/// The bodies are pinned as JSON rather than as Swift, because the thing that can go
/// wrong is a key name — and a renamed key compiles, encodes, and is refused by a route
/// that cannot say which field it wanted.
@Suite("Issue #7 provider credential wire format")
struct ProviderCredentialTests {

    private static func json(_ credential: ProviderCredential) throws -> [String: String] {
        let data = try JSONEncoder().encode(credential)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        return try #require(object)
    }

    @Test("Apple sends the identity token and the RAW nonce, and nothing else")
    func appleBody() throws {
        let body = try Self.json(.apple(identityToken: "TOKEN", rawNonce: "RAW"))
        #expect(body == ["provider": "apple", "identityToken": "TOKEN", "rawNonce": "RAW"])
        // Named explicitly: sending the *hash* here is the mistake that makes the whole
        // pairing decorative, and it would look identical in a debugger.
        #expect(body["rawNonce"] == "RAW")
        #expect(body["nonce"] == nil)
    }

    @Test("Google sends the code, the verifier and the redirect, and nothing else")
    func googleBody() throws {
        let body = try Self.json(
            .google(code: "CODE", codeVerifier: "VERIFIER", redirectUri: "scheme:/oauth2redirect")
        )
        #expect(
            body == [
                "provider": "google",
                "code": "CODE",
                "codeVerifier": "VERIFIER",
                "redirectUri": "scheme:/oauth2redirect"
            ]
        )
        // A public client has none, and one on this body would be in the app binary.
        #expect(body["clientSecret"] == nil)
    }

    @Test("A credential knows its own provider in the API's spelling")
    func providerSpelling() {
        #expect(ProviderCredential.apple(identityToken: "T", rawNonce: "N").provider.rawValue == "apple")
        #expect(
            ProviderCredential.google(code: "C", codeVerifier: "V", redirectUri: "R")
                .provider.rawValue == "google"
        )
    }

    @Test("The delete body carries only the Apple authorization code")
    func deleteBody() throws {
        let data = try JSONEncoder().encode(DeleteAccountRequest(appleAuthorizationCode: "CODE"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object == ["appleAuthorizationCode": "CODE"])
    }

    // MARK: - authProviders

    private static func user(_ json: String) throws -> APIUser {
        try JSONDecoder().decode(APIUser.self, from: Data(json.utf8))
    }

    /// The JSON here is what the server actually sends: `apple.com`, Firebase's provider
    /// id. An earlier version of this test wrote `apple` — the request-body word — which
    /// made it agree with an `isConnected` that compared against `rawValue`, so the pair
    /// passed while the app showed no connected providers at all.
    @Test("authProviders decodes to the providers the server lists")
    func authProvidersDecode() throws {
        let user = try Self.user(
            #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true,"authProviders":["password","apple.com"]}"#
        )
        #expect(user.hasPassword)
        #expect(user.isConnected(.apple))
        #expect(!user.isConnected(.google))
    }

    /// The one that matters while the API agent's half is still landing: a build of this
    /// app against an API that does not send the field must not *invent* one. Empty means
    /// "this build cannot tell you", and Profile draws nothing rather than claiming a
    /// sign-in method the server never said existed.
    @Test("An absent authProviders is empty, not assumed")
    func absentAuthProvidersIsEmpty() throws {
        let user = try Self.user(
            #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true}"#
        )
        #expect(user.authProviders.isEmpty)
        #expect(!user.hasPassword)
        #expect(!user.isConnected(.apple))
    }

    /// The enum carries **two** strings, and conflating them is not hypothetical: an
    /// earlier version had only `rawValue` and used it for both, so `isConnected` answered
    /// `false` for every account — the connected-accounts card stayed blank and, worse,
    /// `DELETE /me` never sent an Apple authorization code, so revocation never ran.
    @Test("The enum's two provider strings are the two the API uses, and are not the same")
    func providerStringsMatchTheWire() {
        // The word `POST /auth/idp` and `POST /me/auth/providers` want in the body.
        #expect(EvaAuthProvider.apple.rawValue == "apple")
        #expect(EvaAuthProvider.google.rawValue == "google")
        // What the server stores in `authProviders`, which is Firebase's own id.
        #expect(EvaAuthProvider.apple.firebaseProviderID == "apple.com")
        #expect(EvaAuthProvider.google.firebaseProviderID == "google.com")
        for provider in EvaAuthProvider.allCases {
            #expect(provider.rawValue != provider.firebaseProviderID)
        }
        #expect(APIUser.passwordProvider == "password")
    }

    /// The bug the property above exists to prevent, asserted from the outside: a user the
    /// server says has Apple must read as connected, or revocation silently never runs.
    @Test("The request-body word alone does not read as connected")
    func theWireWordIsNotTheFirebaseID() throws {
        // The exact shape of the bug: a server that sent `apple` would not light Profile up,
        // and — the expensive half — would leave `DELETE /me` sending no revocation code.
        let user = try Self.user(
            #"{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true,"authProviders":["apple"]}"#
        )
        #expect(!user.isConnected(.apple))
    }
}

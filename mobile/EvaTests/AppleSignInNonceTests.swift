import AuthenticationServices
import Foundation
import Testing
@testable import Eva

/// Issue #118: which nonce goes to Apple and which to the Eva API.
///
/// `AuthCryptoTests` proves the hash is the right hash. This proves the pairing — the one
/// thing in Sign in with Apple that can be got backwards and still compile. Three ways it
/// can be wrong, each caught below:
///
/// - swapped: Apple gets the raw value, the API gets the hash. Loud in production — every
///   sign-in is refused — but only once it is in production.
/// - hash to both: Apple's check passes and the server's becomes "this hash equals this
///   hash", which a replayed token passes too. Silent, and the reason this suite exists.
/// - raw to both: Apple's request carries a value its token then echoes unhashed, and the
///   server's comparison fails. Loud, like the swap.
///
/// The expected digest is the published SHA-256 of `"abc"`, not `AuthCrypto.sha256Hex`
/// called again: a test that derived its expectation from the code under test would agree
/// with it whichever way round the code put the values.
@Suite("Issue #118 Apple nonce pairing")
@MainActor
struct AppleSignInNonceTests {

    private static let raw = "abc"
    private static let digestOfRaw = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test("The API is sent the raw nonce; Apple is sent its SHA-256")
    func pairDirection() {
        let nonce = AppleSignInNonce(rawNonce: Self.raw)
        #expect(nonce.apiNonce == Self.raw)
        #expect(nonce.requestNonce == Self.digestOfRaw)
    }

    /// The invariant the issue states, over a real random nonce rather than a fixture: the
    /// request value is the hash of the API value, and they are not the same string. The
    /// second line is what fails for "hash to both" and "raw to both".
    @Test("A fresh pair hashes the API value into the request value, and never repeats it")
    func freshPairInvariant() {
        let nonce = AppleSignInNonce()
        #expect(nonce.requestNonce == AuthCrypto.sha256Hex(nonce.apiNonce))
        #expect(nonce.requestNonce != nonce.apiNonce)
        // The raw nonce's own shape — `AuthCrypto.rawNonce()`'s 43 base64url characters —
        // so a pair that put a 64-hex digest in the API slot cannot satisfy the line above
        // by coincidence of both being hashes.
        #expect(nonce.apiNonce.count == 43)
        #expect(nonce.requestNonce.count == 64)
    }

    /// What `AppleSignInController` actually does with the pair: the request Apple sees.
    @Test("configure puts the hash on the Apple request, not the raw value")
    func requestCarriesTheHash() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        AppleSignInNonce(rawNonce: Self.raw).configure(request)
        #expect(request.nonce == Self.digestOfRaw)
        #expect(request.nonce != Self.raw)
    }

    /// …and the body the API receives, read back as JSON so the assertion is on the wire
    /// field `POST /auth/idp` validates, not on a Swift enum payload.
    @Test("credential sends the raw value to the API, not the hash")
    func credentialCarriesTheRawValue() throws {
        let credential = AppleSignInNonce(rawNonce: Self.raw).credential(identityToken: "TOKEN")
        let data = try JSONEncoder().encode(credential)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["rawNonce"] == Self.raw)
        #expect(body["rawNonce"] != Self.digestOfRaw)
        #expect(body["identityToken"] == "TOKEN")
        #expect(body["provider"] == "apple")
    }
}

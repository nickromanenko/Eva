import CryptoKit
import Foundation
import Testing
@testable import Eva

/// Issue #7: the nonce hash and the PKCE challenge, pinned against published vectors.
///
/// Both are values only a *server* ever checks, and both fail silently when they are
/// wrong: the app finishes its half of the flow, the sheet closes, and Apple or Google
/// refuse at an exchange that names none of this. Hex where base64url was wanted, padding
/// left on, the digest taken of the wrong string — each produces a well-formed value.
///
/// So these tests deliberately do not compare `AuthCrypto` against itself. Every expected
/// value here comes from outside the app: RFC 7636's own worked example, and digests
/// computed independently.
@Suite("Issue #7 provider sign-in crypto")
struct AuthCryptoTests {

    // MARK: - Apple's nonce

    /// The value Apple documents for `ASAuthorizationOpenIDRequest.nonce`: lowercase hex
    /// SHA-256. The two digests are the published ones for these inputs.
    @Test("sha256Hex is lowercase hexadecimal SHA-256 of the UTF-8 bytes")
    func sha256HexMatchesPublishedDigests() {
        #expect(
            AuthCrypto.sha256Hex("")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            AuthCrypto.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("sha256Hex is 64 lowercase hex characters for any input")
    func sha256HexShape() {
        for value in ["", "a", AuthCrypto.rawNonce(), "🙂 unicode ✓"] {
            let digest = AuthCrypto.sha256Hex(value)
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    /// The one property that makes the pairing worth anything. If `rawNonce()` repeated,
    /// a token captured once could be replayed with the raw value that produced it.
    @Test("Raw nonces do not repeat")
    func rawNoncesAreUnique() {
        let nonces = Set((0..<200).map { _ in AuthCrypto.rawNonce() })
        #expect(nonces.count == 200)
    }

    /// 32 bytes base64url — 43 characters, every one of them unreserved, so the value
    /// survives a JSON body and a query string without escaping.
    @Test("A raw nonce is 43 URL-safe characters")
    func rawNonceShape() {
        let nonce = AuthCrypto.rawNonce()
        #expect(nonce.count == 43)
        #expect(nonce.allSatisfy(Self.isUnreserved))
    }

    // MARK: - PKCE

    /// RFC 7636 Appendix B, verbatim. This is the vector the whole S256 method is
    /// specified against, and it catches padding, the `+/` → `-_` substitution and the
    /// digest all at once.
    @Test("The S256 challenge matches RFC 7636's worked example")
    func codeChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(
            AuthCrypto.codeChallenge(for: verifier)
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("A challenge is unpadded base64url, never standard base64")
    func codeChallengeIsBase64URL() {
        // A verifier chosen so its digest contains bytes that encode to `+` and `/` in
        // standard base64 — otherwise the substitution is untested and looks correct.
        let digests = (0..<64).map { AuthCrypto.codeChallenge(for: "verifier-\($0)") }
        #expect(digests.allSatisfy { !$0.contains("=") })
        #expect(digests.allSatisfy { !$0.contains("+") })
        #expect(digests.allSatisfy { !$0.contains("/") })
        #expect(digests.allSatisfy { $0.count == 43 })
        #expect(digests.contains { $0.contains("-") || $0.contains("_") })
    }

    /// RFC 7636 §4.1: 43–128 characters from `unreserved`. 43 is the floor, and a
    /// verifier one character under it is rejected by the authorization server.
    @Test("A code verifier is 43 unreserved characters and does not repeat")
    func codeVerifierShape() {
        let verifiers = (0..<200).map { _ in AuthCrypto.codeVerifier() }
        #expect(Set(verifiers).count == 200)
        #expect(verifiers.allSatisfy { $0.count >= 43 && $0.count <= 128 })
        #expect(verifiers.allSatisfy { $0.allSatisfy(Self.isUnreserved) })
    }

    @Test("The challenge is not the verifier")
    func challengeIsNotThePlainVerifier() {
        // `code_challenge_method=plain` sends the verifier itself, which hands the
        // exchange to anyone who can read the authorization request. The guard is that
        // the two values are never equal.
        let verifier = AuthCrypto.codeVerifier()
        #expect(AuthCrypto.codeChallenge(for: verifier) != verifier)
    }

    // MARK: - The encoder underneath both

    @Test("base64URLEncoded substitutes the two characters and drops the padding")
    func base64URLEncoding() {
        // `0xFB 0xFF 0xBE` is `+/++` in standard base64 — both substituted characters in
        // one input.
        #expect(AuthCrypto.base64URLEncoded(Data([0xFB, 0xFF, 0xBE])) == "-_--")
        // One byte encodes to two characters plus two `=` of padding.
        #expect(AuthCrypto.base64URLEncoded(Data([0x00])) == "AA")
        #expect(AuthCrypto.base64URLEncoded(Data()).isEmpty)
    }

    @Test("An OAuth state is a URL-safe value that does not repeat")
    func oauthStateShape() {
        let states = (0..<200).map { _ in AuthCrypto.oauthState() }
        #expect(Set(states).count == 200)
        #expect(states.allSatisfy { $0.count == 22 })
        #expect(states.allSatisfy { $0.allSatisfy(Self.isUnreserved) })
    }

    /// RFC 3986 `unreserved`, minus `.` and `~` which base64url never produces.
    private static func isUnreserved(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || character == "-" || character == "_"
    }
}

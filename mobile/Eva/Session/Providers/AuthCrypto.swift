import CryptoKit
import Foundation
import Security

/// The three derivations provider sign-in depends on: a random secret, its SHA-256, and
/// the base64url encoding both Apple and Google's OAuth expect.
///
/// They live together, and they are pure, because they share one failure mode: every one
/// of them produces a *plausible* string when it is wrong. A nonce hashed with the wrong
/// encoding, a PKCE challenge padded with `=`, a verifier one byte short — none of those
/// looks broken on this side. They fail at Apple or at Google, generically, at the end of
/// a flow that cannot be stepped through. `AuthCryptoTests` pins each against a published
/// vector rather than against this file's own behaviour.
///
/// Nothing here is logged, ever (GUARDRAILS 12). A verifier or a raw nonce in a log line
/// is the whole secret: the point of both is that only the app and the server ever see
/// them, so a replayed `identityToken` or an intercepted `code` is worthless on its own.
enum AuthCrypto {

    // MARK: - Sign in with Apple

    /// A fresh raw nonce for one Sign in with Apple request.
    ///
    /// **This is the value that goes to the Eva API; its SHA-256 is what goes to Apple.**
    /// That way round, and never the other. Apple embeds the hash it was given in the
    /// `nonce` claim of the `identityToken`, so a server holding the raw value can prove
    /// the token was minted for *this* request — and a token replayed by anyone else
    /// arrives without a raw nonce that hashes to its claim. Sending the hash to the API
    /// instead would make the check tautological and the replay free.
    ///
    /// 32 bytes, base64url — 43 characters, all of them unreserved, so nothing downstream
    /// has to think about escaping.
    static func rawNonce() -> String {
        base64URLEncoded(randomBytes(32))
    }

    /// Lowercase hexadecimal SHA-256 of `value`'s UTF-8 bytes — the form Apple's
    /// `ASAuthorizationOpenIDRequest.nonce` is documented to take.
    ///
    /// Hex, not base64url: this one is not an OAuth parameter and the two encodings are
    /// not interchangeable at the far end.
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - PKCE (RFC 7636)

    /// A fresh PKCE `code_verifier`.
    ///
    /// 32 random bytes base64url-encoded gives 43 characters — the minimum RFC 7636 §4.1
    /// allows, and every character is in its `unreserved` set.
    static func codeVerifier() -> String {
        base64URLEncoded(randomBytes(32))
    }

    /// The `S256` `code_challenge` for `verifier`: `base64url(sha256(ascii(verifier)))`,
    /// unpadded, per RFC 7636 §4.2.
    static func codeChallenge(for verifier: String) -> String {
        base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The `state` parameter: a nonce for the redirect rather than for the token.
    ///
    /// `ASWebAuthenticationSession` only ever hands back the callback of the session it
    /// opened, so this is belt and braces — but the check it enables costs one comparison
    /// and it is the documented defence against a callback that is not the answer to the
    /// request we made.
    static func oauthState() -> String {
        base64URLEncoded(randomBytes(16))
    }

    // MARK: - Primitives

    /// base64url without padding (RFC 4648 §5): `+` → `-`, `/` → `_`, no `=`.
    ///
    /// The padding matters. RFC 7636 requires the challenge unpadded, and a trailing `=`
    /// is legal base64 that Google rejects as a mismatched challenge — the failure lands
    /// at the token exchange, on the server, as a generic invalid-grant.
    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `count` cryptographically random bytes from the system CSPRNG.
    ///
    /// A trap rather than a fallback if `SecRandomCopyBytes` ever fails. There is no
    /// weaker source that would be acceptable here: every caller is generating a secret
    /// whose only property is unpredictability, and quietly substituting a guessable one
    /// would leave a flow that still works and no longer protects anything.
    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed (OSStatus \(status)).")
        }
        return Data(bytes)
    }
}

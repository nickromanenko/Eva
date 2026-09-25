import AuthenticationServices

/// The two nonces one Sign in with Apple request needs, derived from one raw value (#118).
///
/// Apple is sent **`sha256Hex(raw)`** in `ASAuthorizationOpenIDRequest.nonce`; the Eva API
/// is sent the **raw** value beside the `identityToken`. Apple copies the hash into the
/// token's `nonce` claim, and the server proves the token was minted for this request by
/// hashing what it was sent and comparing. `AuthCrypto.rawNonce()` says why that way round.
///
/// Both are opaque `String`s, so at a call site that handled them directly, swapping them
/// compiled — and so did the quieter mistake of sending the hash to both, which passes
/// Apple's check and makes the server's a tautology any replayed token also passes. This
/// type is where the pairing is decided, once, and `AppleSignInController` never touches
/// either string: it hands the request to `configure(_:)` and the token to
/// `credential(identityToken:)`. Both strings are `private` so that is enforced, not
/// merely followed (#330): a caller that built `.apple(rawNonce:)` from one of them
/// itself would bypass the pairing, and it no longer compiles. `AppleSignInNonceTests`
/// pins both methods against a digest computed outside the app.
///
/// Neither value is logged, ever (GUARDRAILS 12) — nor is this type made
/// `CustomStringConvertible`, so a stray interpolation cannot print the raw nonce.
struct AppleSignInNonce: Sendable {

    /// What goes to Apple: lowercase-hex SHA-256 of `apiNonce`.
    private let requestNonce: String

    /// What goes to the Eva API: the raw nonce itself.
    private let apiNonce: String

    /// A fresh pair for one request. `rawNonce` is injectable so a test can pin the pair
    /// against a known digest; production passes nothing.
    init(rawNonce: String = AuthCrypto.rawNonce()) {
        apiNonce = rawNonce
        requestNonce = AuthCrypto.sha256Hex(rawNonce)
    }

    /// Puts the hash on the request Apple will see.
    func configure(_ request: ASAuthorizationOpenIDRequest) {
        request.nonce = requestNonce
    }

    /// The credential `/auth/idp` and `/me/auth/providers` take, carrying the raw value.
    func credential(identityToken: String) -> ProviderCredential {
        .apple(identityToken: identityToken, rawNonce: apiNonce)
    }
}

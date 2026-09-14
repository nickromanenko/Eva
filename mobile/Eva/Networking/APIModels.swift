import Foundation

struct APIUser: Codable {
    let id: String
    let email: String
    let questionnaireCompleted: Bool
    /// Whether the address has been confirmed through the activation link (#6).
    ///
    /// Decoded when the API sends it and defaulted to `true` when it does not. Not a
    /// guess: a user this client can see at all is one it holds a session for, and the
    /// activation gate refuses a session to anyone who is not activated — so an absent
    /// field can only describe an activated account. Being tolerant here is what lets a
    /// build of this app validate a session against an API that predates the field.
    let activated: Bool
    /// The ways this account can be signed in to — `"password"`, `"apple.com"`,
    /// `"google.com"` (#7). The server's `users/{uid}.authProviders`, verbatim, which means
    /// **Firebase's** provider ids and not the words the app sends in a request body.
    ///
    /// This comment said `"apple"` and `"google"` until the review of #7. It was wrong, and
    /// it was the source of the defect: `EvaAuthProvider.rawValue` was compared against
    /// these strings, so Profile showed Apple as unconnected for every Apple user and the
    /// delete flow skipped Apple revocation — an App Review requirement — in silence. Use
    /// `EvaAuthProvider.firebaseProviderID`, never `rawValue`.
    ///
    /// Defaults to **empty**, not to `["password"]`, when the API does not send it. Empty
    /// is the honest reading of an absent field: it says *this build cannot tell you*,
    /// and Profile draws nothing rather than asserting a sign-in method the server never
    /// claimed. Guessing "password" would be right for every account that exists today
    /// and wrong for the first Apple-only one — and it would be the delete flow's cue to
    /// skip Apple revocation, which is the expensive way to be wrong.
    let authProviders: [String]
    let profile: ProfilePayload?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        questionnaireCompleted = try container.decode(Bool.self, forKey: .questionnaireCompleted)
        activated = try container.decodeIfPresent(Bool.self, forKey: .activated) ?? true
        authProviders = try container.decodeIfPresent([String].self, forKey: .authProviders) ?? []
        profile = try container.decodeIfPresent(ProfilePayload.self, forKey: .profile)
    }

    /// Whether an identity provider is attached to this account.
    ///
    /// `authProviders` holds Firebase's provider ids (`apple.com`), not the word the
    /// request body uses (`apple`) — so this compares against `firebaseProviderID`. Using
    /// `rawValue` here made this return `false` for every account ever.
    func isConnected(_ provider: EvaAuthProvider) -> Bool {
        authProviders.contains(provider.firebaseProviderID)
    }

    /// The provider string for an email-and-password sign-in. Not an `EvaAuthProvider`:
    /// there is no button for it, because it is the form underneath them.
    static let passwordProvider = "password"

    /// Whether an address and password can sign this account in.
    var hasPassword: Bool {
        authProviders.contains(Self.passwordProvider)
    }
}

struct ProfilePayload: Codable {
    let age: Int
    let weightKg: Int
    let heightCm: Int
    let goals: [String]
    let conditions: [String]
    let medications: String
    let lifestyle: String
    let sports: [String]
}

struct AuthResponse: Decodable {
    let token: String
    let user: APIUser
}

/// `POST /auth/signup` replies `201 { pending: true, email }` — no session (#6). The
/// account exists but cannot sign in until the emailed link is opened.
struct SignUpResponse: Decodable {
    let pending: Bool
    let email: String
}

/// `POST /auth/activation/resend` and `POST /auth/password/forgot` both reply
/// `{ sent: true }` whether or not the address is registered — the response must not say
/// which addresses have accounts (#6, ARCHITECTURE §3).
struct SentResponse: Decodable {
    let sent: Bool
}

struct UserResponse: Decodable {
    let user: APIUser
}

/// `DELETE /me` replies `{ "deleted": true }`. `AppSession.deleteAccount` checks the flag
/// rather than treating any 2xx as success — see the note there.
struct DeleteAccountResponse: Decodable {
    let deleted: Bool
}

struct Credentials: Encodable {
    let email: String
    let password: String
}

/// The body of every route that takes an address and nothing else: the two "send me an
/// email" routes, and — since #120 — sign-up, which no longer takes a password because it
/// no longer creates an account.
struct EmailAddress: Encodable {
    let email: String
}

/// What an identity provider handed the app, in the shape `POST /auth/idp` and
/// `POST /me/auth/providers` both take (#7).
///
/// The two routes take the **same** body and differ only in whether they carry a bearer
/// token: unauthenticated it signs you in or creates an account, authenticated it attaches
/// the provider to the account you are already in. So there is one type here rather than
/// two identical ones.
///
/// Note what is *not* in either case: no Firebase ID token, no Google access token, no
/// Apple refresh token. The app forwards a single-use credential and the API does
/// everything else (ARCHITECTURE §2), which is why the app never has a provider session
/// to keep, refresh or leak.
enum ProviderCredential: Encodable, Sendable {

    /// Apple's `identityToken`, with the **raw** nonce whose SHA-256 the app put in the
    /// authorization request. The pairing is the replay defence — see
    /// `AppleSignInController`.
    case apple(identityToken: String, rawNonce: String)

    /// Google's authorization `code`, the PKCE verifier that unlocks it, and the exact
    /// `redirect_uri` Google was given. All three are needed at the token exchange, and
    /// the redirect has to match character for character or Google refuses the grant.
    case google(code: String, codeVerifier: String, redirectUri: String)

    /// Which provider this is, in the API's own spelling.
    var provider: EvaAuthProvider {
        switch self {
        case .apple: .apple
        case .google: .google
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider, identityToken, rawNonce, code, codeVerifier, redirectUri
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider.rawValue, forKey: .provider)
        switch self {
        case .apple(let identityToken, let rawNonce):
            try container.encode(identityToken, forKey: .identityToken)
            try container.encode(rawNonce, forKey: .rawNonce)
        case .google(let code, let codeVerifier, let redirectUri):
            try container.encode(code, forKey: .code)
            try container.encode(codeVerifier, forKey: .codeVerifier)
            try container.encode(redirectUri, forKey: .redirectUri)
        }
    }
}

/// The optional body of `DELETE /me` (#7).
///
/// Apple requires an app that offers both Sign in with Apple and in-app account deletion
/// to revoke its token on delete, and Eva deliberately stores no Apple refresh token —
/// so the code is obtained fresh at the moment of deletion and sent here. It is optional
/// on the route on purpose: an account with no Apple provider has none, and a user who
/// declines the re-authorization still gets their account deleted.
struct DeleteAccountRequest: Encodable {
    let appleAuthorizationCode: String
}

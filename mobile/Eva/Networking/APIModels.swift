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
    let profile: ProfilePayload?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        questionnaireCompleted = try container.decode(Bool.self, forKey: .questionnaireCompleted)
        activated = try container.decodeIfPresent(Bool.self, forKey: .activated) ?? true
        profile = try container.decodeIfPresent(ProfilePayload.self, forKey: .profile)
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

/// The body of the two "send me an email" routes.
struct EmailAddress: Encodable {
    let email: String
}

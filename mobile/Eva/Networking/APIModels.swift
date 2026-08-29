import Foundation

struct APIUser: Codable {
    let id: String
    let email: String
    let questionnaireCompleted: Bool
    let profile: ProfilePayload?
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

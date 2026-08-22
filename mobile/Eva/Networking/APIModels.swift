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

struct Credentials: Encodable {
    let email: String
    let password: String
}

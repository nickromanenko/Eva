import SwiftUI

/// App-wide auth/session state. The server is the source of truth for
/// questionnaire completion; this replaces the old @AppStorage flag.
@MainActor
@Observable
final class AppSession {
    enum State {
        case loading
        case signedOut
        case needsQuestionnaire
        case ready
    }

    private(set) var state: State = .loading
    private(set) var user: APIUser?

    private let client: APIClient
    private let tokenStore: KeychainTokenStore

    init(client: APIClient = .default, tokenStore: KeychainTokenStore = .shared) {
        self.client = client
        self.tokenStore = tokenStore
    }

    /// Called at launch: a stored token is validated via GET /me.
    func bootstrap() async {
        #if DEBUG
        // UI tests need a clean slate (Keychain survives reinstalls on simulator).
        if ProcessInfo.processInfo.environment["EVA_UITEST_RESET"] == "1" {
            tokenStore.clear()
        }
        #endif
        guard tokenStore.token != nil else {
            state = .signedOut
            return
        }
        do {
            let response: UserResponse = try await client.get("/me", authorized: true)
            user = response.user
            state = response.user.questionnaireCompleted ? .ready : .needsQuestionnaire
        } catch {
            tokenStore.clear()
            state = .signedOut
        }
    }

    func signUp(email: String, password: String) async throws {
        let response: AuthResponse = try await client.post(
            "/auth/signup", body: Credentials(email: email, password: password)
        )
        apply(response)
    }

    func signIn(email: String, password: String) async throws {
        let response: AuthResponse = try await client.post(
            "/auth/signin", body: Credentials(email: email, password: password)
        )
        apply(response)
    }

    func submitQuestionnaire(_ profile: ProfilePayload) async throws {
        let response: UserResponse = try await client.put(
            "/me/questionnaire", body: profile, authorized: true
        )
        user = response.user
        // Stay in the onboarding flow for the done screen; enterDashboard()
        // completes the transition.
    }

    func enterDashboard() {
        state = .ready
    }

    func logOut() {
        tokenStore.clear()
        user = nil
        state = .signedOut
    }

    private func apply(_ response: AuthResponse) {
        tokenStore.save(response.token)
        user = response.user
        state = response.user.questionnaireCompleted ? .ready : .needsQuestionnaire
    }
}

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
            let response: UserResponse = try await authorized {
                try await client.get("/me", authorized: true)
            }
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
        let response: UserResponse = try await authorized {
            try await client.put("/me/questionnaire", body: profile, authorized: true)
        }
        user = response.user
        // Stay in the onboarding flow for the done screen; enterDashboard()
        // completes the transition.
    }

    /// Deletes the account server-side, then drops the local session. The server does not
    /// sign this client out, and a token left in the Keychain would name an account that
    /// no longer exists. A failure leaves the session untouched so the caller can show the
    /// error and offer a retry.
    func deleteAccount() async throws {
        let response: DeleteAccountResponse = try await authorized {
            try await client.delete("/me", authorized: true)
        }
        // The flag is read rather than assumed. `DELETE /me` has no `false` branch today,
        // so this only fires if the route grows one or something answers in its place —
        // and the failure it prevents is the expensive one: signing the user out and
        // returning them to onboarding, which is exactly what a successful deletion looks
        // like, for an account that still exists. Same class as #59, reached differently.
        guard response.deleted else { throw APIError.decoding }
        logOut()
    }

    func enterDashboard() {
        state = .ready
    }

    func logOut() {
        tokenStore.clear()
        user = nil
        state = .signedOut
    }

    /// Runs an authorized request and signs out if the credential it sent came back
    /// dead. Every authorized call goes through here so a mid-session 401 ends the
    /// session wherever it happens, not only at launch; the error is rethrown so the
    /// caller still gets to react. Sign-up and sign-in stay outside it — they send no
    /// token, and their 401 means "wrong password".
    private func authorized<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as APIError {
            if case .sessionExpired = error { logOut() }
            throw error
        }
    }

    private func apply(_ response: AuthResponse) {
        tokenStore.save(response.token)
        user = response.user
        state = response.user.questionnaireCompleted ? .ready : .needsQuestionnaire
    }
}

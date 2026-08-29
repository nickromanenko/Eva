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
        /// We have a token we could not validate, and we have **kept** it.
        ///
        /// Only a 401 on a request that carried the token says the credential is dead
        /// (#55, ARCHITECTURE.md §5). Everything else — no signal, a captive portal, a
        /// 503, a body we could not decode — says this request failed, which is not the
        /// same claim. This state exists so a launch can fail without either lying about
        /// the session or hanging on a spinner: the token stays, and `retry()` is offered
        /// (#61).
        case unreachable
    }

    private(set) var state: State = .loading
    private(set) var user: APIUser?

    /// Guards `bootstrap()` against overlapping runs — the retry screen can ask for
    /// another one while the first is still awaiting the network.
    private var isBootstrapping = false

    /// Bumped by `logOut()`. A `bootstrap()` that started before the log out must not
    /// apply its result afterwards — see the note where it is captured.
    private var sessionGeneration = 0

    private let client: APIClient
    private let tokenStore: KeychainTokenStore

    init(client: APIClient = .default, tokenStore: KeychainTokenStore = .shared) {
        self.client = client
        self.tokenStore = tokenStore

        #if DEBUG
        // UI tests need a clean slate (the Keychain survives reinstalls on simulator).
        //
        // Once per session object, not once per `bootstrap()`. #61 made `bootstrap()`
        // re-runnable, and leaving the reset inside it meant every tap of **Try again**
        // wiped the Keychain — so a test that exercised the retry screen would destroy
        // the very token it was there to prove survives, and fail looking like a session
        // bug rather than a harness bug.
        if ProcessInfo.processInfo.environment["EVA_UITEST_RESET"] == "1" {
            tokenStore.clear()
        }
        #endif
    }

    /// Called at launch: a stored token is validated via GET /me.
    ///
    /// Only `.sessionExpired` ends the session here. That is the same line
    /// `authorized(_:)` draws, and before #61 this method crossed it: its catch cleared
    /// the Keychain on *any* failure, so launching with no signal signed the user out and
    /// asked for a password they could not submit.
    ///
    /// Re-runnable — `retry()` calls it again, and overlapping calls return early rather
    /// than firing a second GET /me.
    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        guard tokenStore.token != nil else {
            state = .signedOut
            return
        }

        // Taken before the await. If the user logs out while this is in flight, the
        // session they logged out of is not the one this result describes, and applying
        // it would put them back on the dashboard they just left.
        let generation = sessionGeneration

        do {
            let response: UserResponse = try await authorized {
                try await client.get("/me", authorized: true)
            }
            guard generation == sessionGeneration else { return }
            user = response.user
            state = response.user.questionnaireCompleted ? .ready : .needsQuestionnaire
        } catch APIError.sessionExpired {
            // Dead today, and deliberately so. `authorized(_:)` has already cleared the
            // token and signed out, and `logOut()` bumps the generation — so the guard
            // below is always false and this arm never runs.
            //
            // It exists for the case where that stops being true. An unguarded
            // `state = .signedOut` here throws away a session created *while this
            // request was in flight* (the user logged out and signed back in), which is
            // a real defect this test suite caught. An empty arm leaves `.loading` — a
            // spinner with no way out — if the wrapper ever stops signing out. Falling
            // through to the generic `catch` would offer a retry for a credential the
            // server has already refused. None of the three is a state this method may
            // end in, so it says the one thing that is correct whenever it is reachable.
            guard generation == sessionGeneration else { return }
            logOut()
        } catch {
            // `.network`, `.decoding`, and any non-401 `.server`. None of them is the
            // server saying the credential is finished, so the token stays exactly as it
            // is and the user keeps their session.
            guard generation == sessionGeneration else { return }
            state = .unreachable
        }
    }

    /// Re-runs the launch validation. The `.unreachable` screen's only action.
    ///
    /// This is `bootstrap()` again rather than a second path that could drift from it:
    /// `.unreachable` is only reachable with a token still in the Keychain, which is
    /// exactly the precondition `bootstrap()` already checks.
    func retry() async {
        await bootstrap()
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
        let generation = sessionGeneration
        let response: UserResponse = try await authorized {
            try await client.put("/me/questionnaire", body: profile, authorized: true)
        }
        guard generation == sessionGeneration else { return }
        user = response.user
        // Stay in the onboarding flow for the done screen; enterDashboard()
        // completes the transition.
    }

    /// Deletes the account server-side, then drops the local session. The server does not
    /// sign this client out, and a token left in the Keychain would name an account that
    /// no longer exists. A failure leaves the session untouched so the caller can show the
    /// error and offer a retry.
    func deleteAccount() async throws {
        let generation = sessionGeneration
        let response: DeleteAccountResponse = try await authorized {
            try await client.delete("/me", authorized: true)
        }
        // The same guard the other awaits carry. A slow `DELETE /me` that returns after
        // the user has logged out and signed in again would otherwise tear down the
        // *second* session and delete a token it never saw. That it cannot be reached
        // from today's UI is a property of two `.disabled` modifiers on another screen —
        // which is exactly the argument `apply(_:)` refuses to rely on.
        guard generation == sessionGeneration else { return }
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
        sessionGeneration += 1
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
        // Captured before the await for the same reason `bootstrap()` captures it, and
        // guarding the same hazard one layer down: a request that started under an
        // earlier session must not act on the current one. Without this, a `/me` still
        // in flight when the user logs out and signs back in can return 401 and sign
        // out the *new* session — clearing a token it never saw.
        let generation = sessionGeneration
        do {
            return try await work()
        } catch let error as APIError {
            if case .sessionExpired = error, generation == sessionGeneration { logOut() }
            throw error
        }
    }

    private func apply(_ response: AuthResponse) {
        // A new session is a new generation, enforced here rather than by whichever
        // screen happened to call this. Signing in currently always follows a `logOut()`,
        // which bumps it — but that is a property of today's navigation, not of the
        // session, and the first screen that signs someone in without logging them out
        // first would silently reopen the in-flight-request hole this counter closes.
        sessionGeneration += 1
        tokenStore.save(response.token)
        user = response.user
        state = response.user.questionnaireCompleted ? .ready : .needsQuestionnaire
    }
}

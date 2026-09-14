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

    /// What signing up leaves the caller with. One case today, and an enum anyway: the
    /// point of #6 is that sign-up **no longer returns a session**, and a return type
    /// that could not express "you are not signed in yet" would invite the next caller
    /// to assume it did.
    enum SignUpOutcome: Equatable {
        /// The account exists, an activation email is on its way to `email`, and sign-in
        /// is refused until its link is opened.
        case pendingActivation(email: String)
    }

    /// Creates the account. Does **not** sign in — the session state is untouched, and
    /// the caller shows the activation screen (#6).
    /// Asks for an activation link. **Sends no password** (#120): sign-up creates no
    /// account, so there is nothing for a credential to attach to yet, and one set here
    /// would sit on an address nobody had proved. The password is chosen on the activation
    /// page, in the same request that spends the link.
    func signUp(email: String) async throws -> SignUpOutcome {
        let response: SignUpResponse = try await client.post(
            "/auth/signup", body: EmailAddress(email: email)
        )
        // Read, not assumed — the same rule `deleteAccount` applies to its flag. The
        // route has no `false` branch; if one ever answers, "pending" is the only thing
        // this screen knows how to be, and saying so for an account that is not would
        // leave the user waiting for an email that is never coming.
        guard response.pending else { throw APIError.decoding }
        return .pendingActivation(email: response.email)
    }

    /// Signs in. Throws `APIError.notActivated` for an account whose password was right
    /// but whose address has not been confirmed — the caller routes to the activation
    /// screen rather than showing a field error. Every other failure, including the
    /// combined "wrong email or password", is thrown as it came.
    func signIn(email: String, password: String) async throws {
        do {
            let response: AuthResponse = try await client.post(
                "/auth/signin", body: Credentials(email: email, password: password)
            )
            apply(response)
        } catch APIError.server(let code, let message, let status) where status == 403 && code == "NOT_ACTIVATED" {
            throw APIError.notActivated(message: message)
        }
    }

    /// Signs in with Apple or Google, or creates the account the provider names (#7).
    ///
    /// **Outside `authorized(_:)`, like `signUp` and `signIn`.** The route sends no token,
    /// so a 401 from it means the provider credential was refused — not that this device's
    /// session ended — and running it through the wrapper would log a signed-in user out
    /// for a failed *link-a-second-provider* attempt they made from Profile.
    ///
    /// There is no activation gate here and no `NOT_ACTIVATED` branch: the address comes
    /// from Apple or Google having already proved it, which is the whole reason #6's
    /// emailed link exists for passwords and not for these.
    func signInWithProvider(_ credential: ProviderCredential) async throws {
        let response: AuthResponse = try await client.post("/auth/idp", body: credential)
        apply(response)
    }

    /// Attaches another provider to the account already signed in (#7).
    ///
    /// Not the only way two sign-in methods end up on one account — Firebase links them
    /// itself when the addresses match — but the only way for an address that does *not*
    /// match, which is every Apple Hide My Email relay. Those users get a new account no
    /// matter what, so joining is something they do deliberately, from Profile, while
    /// signed in to the account they want to keep. Matching on email instead would not work
    /// for Hide My Email relays anyway (#7's decision).
    ///
    /// Inside `authorized(_:)`, unlike `signInWithProvider`, because this one carries the
    /// token. That is safe only because `APIClient` now ends the session on a 401 solely
    /// when the server says `UNAUTHORIZED`: this route answers 401 INVALID_CREDENTIALS when
    /// *Apple's* credential is refused, and a comment here once claimed its 401 "really does
    /// mean the session is finished". It does not, and connecting a provider with a stale
    /// credential logged the user out.
    func attachProvider(_ credential: ProviderCredential) async throws {
        let generation = sessionGeneration
        let response: UserResponse = try await authorized {
            try await client.post("/me/auth/providers", body: credential, authorized: true)
        }
        // The same guard every other await carries: a slow link that returns after the
        // user logged out must not write a user into a session that is not theirs.
        guard generation == sessionGeneration else { return }
        user = response.user
    }

    /// Asks for the activation email again. Sends no token and touches no state: the
    /// screen owns the 60-second cooldown, the server owns the throttle behind it
    /// (`429 RATE_LIMITED`), and the reply is the same whether or not the address exists.
    func resendActivation(email: String) async throws {
        let response: SentResponse = try await client.post(
            "/auth/activation/resend", body: EmailAddress(email: email)
        )
        guard response.sent else { throw APIError.decoding }
    }

    /// Asks for a password-reset email. The reset form itself is on the website in v1;
    /// the app only ever sends the request and later receives `eva://open` (#6).
    func requestPasswordReset(email: String) async throws {
        let response: SentResponse = try await client.post(
            "/auth/password/forgot", body: EmailAddress(email: email)
        )
        guard response.sent else { throw APIError.decoding }
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
    ///
    /// `appleAuthorizationCode` is a fresh code from a Sign in with Apple re-authorization,
    /// which the API exchanges to **revoke** Apple's token — required of any app offering
    /// both Sign in with Apple and in-app deletion (#7). It is optional at every layer,
    /// including here, because deletion must never be the thing that fails: an account
    /// with no Apple provider has no code to send, and a user who dismisses Apple's sheet
    /// still gets their account deleted.
    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        let generation = sessionGeneration
        let response: DeleteAccountResponse = try await authorized {
            if let appleAuthorizationCode {
                return try await client.delete(
                    "/me",
                    body: DeleteAccountRequest(appleAuthorizationCode: appleAuthorizationCode),
                    authorized: true
                )
            }
            return try await client.delete("/me", authorized: true)
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
    /// caller still gets to react. Sign-up, sign-in, resend and forgot stay outside it —
    /// they send no token, and sign-in's 401 means "wrong password".
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

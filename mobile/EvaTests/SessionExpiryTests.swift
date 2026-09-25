import Foundation
import Testing
@testable import Eva

/// Issue #55: **a 401 ends the session only when the request that got it actually
/// carried a bearer token.**
///
/// This is the distinction the whole issue turns on, and #55's Risks section says why:
/// `POST /auth/signin` answers a wrong password with 401 `INVALID_CREDENTIALS` and sends
/// no token, so a rule keyed on status alone would sign a user out for mistyping their
/// password. The rule lives in two places, and both halves are covered here — the
/// mapping in `APIClient.send`, and what `AppSession` does with the result.
///
/// Every test drives real `URLSession` traffic, under the configuration the app ships,
/// through `EvaStubURLProtocol` rather than a fake client, so what is under test is the
/// shipped `send` path, including the header it actually put on the wire.
///
/// `.serialized` is load-bearing: the stub is one global response and the Keychain is
/// one global entry, so these must not interleave with each other.
@Suite("Issue #55 · a 401 ends the session only when the request carried a token", .serialized)
struct SessionExpiryTests {

    // MARK: - The mapping

    @Suite("APIClient.send")
    struct ClientMapping {

        /// What the API sends when a token is missing, expired, or names an account that
        /// no longer exists — `requireAuth` / `requireAccount` in `api/src/index.ts`.
        static let deadToken = #"{"error":{"code":"UNAUTHORIZED","message":"Missing or invalid token"}}"#

        /// What `POST /auth/signin` sends for a wrong password. Same status, same shape,
        /// opposite meaning — this body is the reason the rule cannot key on status.
        static let wrongPassword =
            #"{"error":{"code":"INVALID_CREDENTIALS","message":"Wrong email or password"}}"#

        /// What `POST /me/auth/providers` sends when Apple or Google refuses the credential
        /// (#7). A bearer token was presented and accepted; it is the *provider's* one that
        /// failed, so the session is fine.
        static let rejectedProvider =
            #"{"error":{"code":"INVALID_CREDENTIALS","message":"That sign-in couldn't be completed. Please try again."}}"#

        static let user = #"{"user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true}}"#

        static func client(token: String?) -> APIClient {
            APIClient(baseURL: EvaStubURLProtocol.baseURL, token: { token }, session: EvaStubURLProtocol.session)
        }

        @Test("401 on a request that sent a token is a dead session")
        func sentTokenMakesItSessionExpired() async {
            EvaStubURLProtocol.stub(status: 401, body: Self.deadToken)
            let client = Self.client(token: "a-live-looking-token")

            let error = await thrownAPIError {
                let _: UserResponse = try await client.get("/me", authorized: true)
            }

            #expect(error?.isSessionExpired == true, "401 with a bearer token mapped to \(String(describing: error))")
            #expect(error?.errorDescription == "Missing or invalid token")
            // The premise of the assertion above, checked rather than assumed: this
            // request really did present a credential.
            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer a-live-looking-token")
            #expect(EvaStubURLProtocol.requestCount == 1, "A dead credential was retried")
        }

        /// The #7 half of the same rule, and the case that made the token alone
        /// insufficient. `POST /me/auth/providers` carries a bearer token *and* answers 401
        /// INVALID_CREDENTIALS when Apple's or Google's credential is what was refused — an
        /// expired `identityToken`, a spent authorization code, a mismatched nonce. Reading
        /// that as a dead session signed the user out of Eva, and cleared their Keychain,
        /// for tapping "Connect Google" a minute too late.
        @Test("401 INVALID_CREDENTIALS on a token-carrying request is not a dead session")
        func rejectedProviderCredentialIsNotSessionExpiry() async {
            EvaStubURLProtocol.stub(status: 401, body: Self.rejectedProvider)
            let client = Self.client(token: "a-live-looking-token")

            let error = await thrownAPIError {
                let _: UserResponse = try await client.post(
                    "/me/auth/providers",
                    body: ["provider": "apple"],
                    authorized: true
                )
            }

            #expect(error?.isSessionExpired == false, "a refused provider credential mapped to \(String(describing: error))")
            #expect(error?.serverCode == "INVALID_CREDENTIALS")
            // The premise, checked rather than assumed: this request really did carry a
            // token, so it is the *code* and not the absence of a credential doing the work.
            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer a-live-looking-token")
        }

        /// The regression #55 exists to prevent. Sign-in sends no token, so its 401 is an
        /// ordinary failure the screen shows — not a reason to tear a session down.
        @Test("401 on an unauthorized request is an ordinary server error")
        func signInFailureIsNotSessionExpiry() async {
            EvaStubURLProtocol.stub(status: 401, body: Self.wrongPassword)
            let client = Self.client(token: "a-token-that-must-not-be-sent")

            let error = await thrownAPIError {
                let _: AuthResponse = try await client.post(
                    "/auth/signin", body: Credentials(email: "e2e+unit@e2e.evaapp.dev", password: "wrong")
                )
            }

            #expect(error?.isSessionExpired == false, "A wrong password was read as an expired session")
            #expect(error?.code == "INVALID_CREDENTIALS")
            #expect(error?.serverStatus == 401)
            #expect(EvaStubURLProtocol.lastAuthorization == nil, "An unauthorized request still sent a token")
        }

        /// `authorized: true` with nothing in the Keychain. The request goes out bare, so
        /// the 401 is the server refusing an anonymous call — a client bug, not a session
        /// that ended. Signing out here would be signing out over a bug.
        @Test("401 on an authorized request that had no token to send is a server error")
        func missingTokenIsNotSessionExpiry() async {
            EvaStubURLProtocol.stub(status: 401, body: Self.deadToken)
            let client = Self.client(token: nil)

            let error = await thrownAPIError {
                let _: UserResponse = try await client.get("/me", authorized: true)
            }

            #expect(error?.isSessionExpired == false, "A nil token was read as an expired session")
            #expect(error?.serverStatus == 401)
            #expect(EvaStubURLProtocol.lastAuthorization == nil)
        }

        /// The other edge of the same rule: a token was sent, but the status is not 401.
        /// 403 is the nearest neighbour and must stay ordinary.
        @Test("A non-401 failure is unaffected by the token")
        func otherFailuresAreUnaffected() async {
            EvaStubURLProtocol.stub(
                status: 403, body: #"{"error":{"code":"FORBIDDEN","message":"Nope"}}"#
            )
            let client = Self.client(token: "a-live-looking-token")

            let error = await thrownAPIError {
                let _: UserResponse = try await client.get("/me", authorized: true)
            }

            #expect(error?.isSessionExpired == false, "A 403 signed the user out")
            #expect(error?.code == "FORBIDDEN")
            #expect(error?.serverStatus == 403)
        }

        /// A 401 whose body is not the API's error envelope. `send` was rewritten on this
        /// branch to build the message before it branches, and a 500 HTML page or an empty
        /// body from a proxy is the realistic way that path is reached — the credential is
        /// still dead, and the fallback message still has to be the one shown.
        @Test("A 401 with an unparseable body is still a dead session")
        func unparseableBodyStillEndsTheSession() async {
            EvaStubURLProtocol.stub(status: 401, body: "<html>gateway</html>")
            let client = Self.client(token: "a-live-looking-token")

            let error = await thrownAPIError {
                let _: UserResponse = try await client.get("/me", authorized: true)
            }

            #expect(error?.isSessionExpired == true)
            #expect(error?.errorDescription == "Something went wrong (401).")
        }

        @Test("A success still decodes")
        func successDecodes() async throws {
            EvaStubURLProtocol.stub(status: 200, body: Self.user)
            let client = Self.client(token: "a-live-looking-token")

            let response: UserResponse = try await client.get("/me", authorized: true)

            #expect(response.user.email == "e2e+unit@e2e.evaapp.dev")
            #expect(response.user.questionnaireCompleted)
        }

        /// `DELETE /me` is new on this branch and is the only caller of `APIClient.delete`.
        @Test("DELETE reaches the route and decodes its reply")
        func deleteDecodes() async throws {
            EvaStubURLProtocol.stub(status: 200, body: #"{"deleted":true}"#)
            let client = Self.client(token: "a-live-looking-token")

            let response: DeleteAccountResponse = try await client.delete("/me", authorized: true)

            #expect(response.deleted)
            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer a-live-looking-token")
        }
    }

    // MARK: - What the session does about it

    /// `AppSession` is the half that acts on the mapping.
    ///
    /// These use the real `KeychainTokenStore` — `AppSession.init` takes the concrete
    /// class, not a protocol, so there is nothing else to pass. That works because
    /// `EvaTests` is hosted in the signed Eva app process (`TEST_HOST` in project.yml),
    /// which is the same reason `scripts/verify-mobile.sh` refuses to build unsigned.
    /// The store is a single global entry, so every test here clears it on both sides.
    @Suite("AppSession")
    @MainActor
    struct SessionReaction {

        let store = KeychainTokenStore.shared

        /// Brings the session up the way launch does — a stored token, a 200 from `/me` —
        /// so "signed out" afterwards is a change this test caused, not the state it
        /// started in.
        func signedInSession() async -> AppSession {
            store.clear()
            store.save("a-live-looking-token")
            let session = AppSession(
                // Reads the Keychain on every request, exactly as `APIClient.default`
                // does — so a test that clears it mid-flow is testing the real path.
                client: APIClient(
                    baseURL: EvaStubURLProtocol.baseURL,
                    token: { KeychainTokenStore.shared.token },
                    session: EvaStubURLProtocol.session
                ),
                tokenStore: store
            )
            EvaStubURLProtocol.stub(status: 200, body: ClientMapping.user)
            await session.bootstrap()
            #expect(session.state.isReady, "The fixture never got signed in, so nothing below means anything")
            #expect(store.token != nil, "The Keychain is not writable in this process")
            return session
        }

        /// The acceptance criterion: *a 401 from any authenticated route signs the user
        /// out*, not just at launch. `/me/questionnaire` is deliberately not `/me` and not
        /// the delete route — it is an ordinary mid-session call.
        @Test("A mid-session 401 on any authorized route signs out")
        func midSessionExpiryEndsTheSession() async {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(status: 401, body: ClientMapping.deadToken)
            let error = await thrownAPIError {
                try await session.submitQuestionnaire(Self.profile)
            }

            #expect(error?.isSessionExpired == true)
            #expect(session.state.isSignedOut, "A 401 mid-session left the user on the screen they were on")
            #expect(store.token == nil, "A dead token was left in the Keychain")
            // #59 gave one route a reason to leave on the signed-out screen. Every other
            // route signs out exactly as before — with nothing to say — and a reason that
            // leaked here would tell someone whose calendar read failed that a deletion
            // they never asked for did not happen.
            #expect(session.signedOutReason == nil, "An ordinary 401 left a reason on the signed-out screen")
        }

        /// Issue #59, at the session layer: a delete whose credential died.
        ///
        /// The central rule still fires — signed out, Keychain cleared — because #59 is
        /// explicit that the route must not be exempted from it. What changes is that the
        /// sign-out carries a reason, since the modal that would have shown the error is
        /// torn down by the sign-out itself.
        @Test("A delete refused for a dead credential signs out and says the account survives")
        func aDeadTokenDeleteSignsOutWithAReason() async {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(status: 401, body: ClientMapping.deadToken)
            let error = await thrownAPIError { try await session.deleteAccount() }

            #expect(error?.isSessionExpired == true, "A dead-token delete threw \(String(describing: error))")
            // The premise, checked: this was the delete route, carrying the token.
            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer a-live-looking-token")
            #expect(session.state.isSignedOut, "The 401 rule stopped applying to DELETE /me")
            #expect(store.token == nil, "A dead token was left in the Keychain")
            #expect(
                session.signedOutReason == .deletionRefusedSessionEnded,
                "The sign-out after a refused delete says nothing, which reads as a deletion that worked"
            )
        }

        /// The reason describes one sign-out. A new session clears it, so it cannot be
        /// waiting on the signed-out screen the next time she logs out on purpose.
        @Test("Signing in again clears the reason")
        func signingInClearsTheReason() async throws {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(status: 401, body: ClientMapping.deadToken)
            _ = await thrownAPIError { try await session.deleteAccount() }
            #expect(session.signedOutReason == .deletionRefusedSessionEnded, "No reason to clear — the premise failed")

            EvaStubURLProtocol.stub(
                status: 200,
                body: #"{"token":"a-fresh-token","user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true}}"#
            )
            try await session.signIn(email: "e2e+unit@e2e.evaapp.dev", password: "uitest-pass-1")

            #expect(session.state.isReady)
            #expect(session.signedOutReason == nil, "A new session kept the last one's sign-out reason")

            session.logOut()
            #expect(session.signedOutReason == nil, "A plain log out showed the old reason")
        }

        /// The other direction, on the route #55 added. A failure that is not a dead
        /// credential must leave the session exactly as it was, so the modal can show the
        /// error and offer a retry — which is what `deleteAccount`'s own doc comment
        /// promises.
        @Test("A failed delete leaves the session standing")
        func aFailedDeleteKeepsTheSession() async {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(
                status: 500, body: #"{"error":{"code":"INTERNAL","message":"Something went wrong"}}"#
            )
            let error = await thrownAPIError { try await session.deleteAccount() }

            #expect(error?.serverStatus == 500)
            #expect(session.state.isReady, "A failed delete signed the user out anyway")
            #expect(store.token != nil, "A failed delete cleared the Keychain")
        }

        /// The success path the UI test then proves end to end: the server does not sign
        /// this client out, so `deleteAccount` has to.
        @Test("A successful delete clears the Keychain and signs out")
        func aSuccessfulDeleteSignsOut() async throws {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(status: 200, body: #"{"deleted":true}"#)
            try await session.deleteAccount()

            #expect(session.state.isSignedOut)
            #expect(store.token == nil, "The token for a deleted account stayed in the Keychain")
            // #59's banner says the profile was *not* deleted. On this path it was.
            #expect(session.signedOutReason == nil, "A deletion that worked is reported as refused")
        }

        /// The reply is read, not assumed.
        ///
        /// `DELETE /me` has no `false` branch today, so this fires only if the route grows
        /// one or something answers in its place — a proxy, a stub, a rewritten handler.
        /// The failure it prevents is the expensive one, and the reason it is worth a test
        /// for a branch that cannot currently be taken: a signed-out app back on
        /// onboarding is exactly what a successful deletion looks like, so an account that
        /// still exists would be indistinguishable from one that is gone.
        @Test("A 200 that says the account was not deleted does not sign anyone out")
        func aDeniedDeleteDoesNotSignOut() async {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(status: 200, body: #"{"deleted":false}"#)
            let error = await thrownAPIError { try await session.deleteAccount() }

            #expect(error?.isDecoding == true, "A refused delete threw \(String(describing: error))")
            #expect(session.state.isReady, "A delete that did not happen signed the user out")
            #expect(store.token != nil, "A delete that did not happen cleared the Keychain")
        }

        /// The regression, at the session layer.
        ///
        /// A live session is the fixture only because "unchanged" needs something to be
        /// unchanged *from* — nobody signs in while signed in. What it catches is a change
        /// that routes `signIn` through the same sign-out handler as the authorized calls;
        /// it does **not** catch a status-only rule inside `APIClient`, because `signIn`
        /// is outside that handler either way. `signInFailureIsNotSessionExpiry` above is
        /// the half that catches that one.
        @Test("A wrong password does not sign anyone out")
        func aWrongPasswordDoesNotSignOut() async {
            let session = await signedInSession()
            defer { store.clear() }

            EvaStubURLProtocol.stub(status: 401, body: ClientMapping.wrongPassword)
            let error = await thrownAPIError {
                try await session.signIn(email: "e2e+unit@e2e.evaapp.dev", password: "wrong")
            }

            #expect(error?.code == "INVALID_CREDENTIALS")
            #expect(session.state.isReady, "A wrong password tore the session down")
            #expect(store.token != nil, "A wrong password cleared the Keychain")
        }

        static let profile = ProfilePayload(
            dateOfBirth: "1996-03-14", weightKg: 60, heightCm: 165,
            goals: ["Energy"], conditions: ["noneOfThese"], medications: "none",
            lifestyle: "active", sports: ["Yoga"], timeZone: "UTC"
        )
    }
}

// MARK: - Test-local helpers

/// Runs work that must fail and hands back the `APIError` it threw.
///
/// Succeeding is itself a failure — a rule about which error comes back proves nothing if
/// no error came back at all.
/// The `isolation` parameter is what lets a `@MainActor` test hand in a closure that
/// touches `AppSession`: without it the closure would have to cross an isolation boundary
/// it cannot cross.
private func thrownAPIError(
    isolation: isolated (any Actor)? = #isolation,
    _ work: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> APIError? {
    do {
        try await work()
        Issue.record("The request succeeded; this test needs it to fail.", sourceLocation: sourceLocation)
        return nil
    } catch let error as APIError {
        return error
    } catch {
        Issue.record("Threw \(error), which is not an APIError.", sourceLocation: sourceLocation)
        return nil
    }
}

private extension APIError {
    var isSessionExpired: Bool {
        switch self {
        case .sessionExpired: true
        default: false
        }
    }

    var isDecoding: Bool {
        switch self {
        case .decoding: true
        default: false
        }
    }

    var serverCode: String? {
        switch self {
        case .server(let code, _, _): code
        default: nil
        }
    }

    var serverStatus: Int? {
        switch self {
        case .server(_, _, let status): status
        default: nil
        }
    }
}

private extension AppSession.State {
    var isSignedOut: Bool {
        switch self {
        case .signedOut: true
        default: false
        }
    }

    var isReady: Bool {
        switch self {
        case .ready: true
        default: false
        }
    }
}

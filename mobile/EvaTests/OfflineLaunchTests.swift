import Foundation
import Testing
@testable import Eva

/// Issue #61: **a launch that could not reach the API keeps the session.**
///
/// `bootstrap()` used to clear the Keychain in a bare `catch`, so `APIError.network` —
/// airplane mode, a captive portal, a tunnel — signed the user out and asked them for a
/// password they could not submit. The rule now matches `authorized(_:)`: only a 401 on a
/// request that carried the token ends the session; everything else keeps the token and
/// goes to `.unreachable`.
///
/// Every test here asserts the **Keychain value**, not only the state. The state is what
/// the user sees; the token is what the issue is about, and a version that showed
/// `.unreachable` while quietly clearing the token would satisfy a state-only test and
/// still sign the user out at the next launch.
///
/// Traffic goes through `EvaStubURLProtocol` and a real `URLSession` built from the app's
/// own configuration, so what runs is the shipped `APIClient.send` path including the
/// header it put on the wire.
///
/// Nested inside `SessionExpiryTests` for a mechanical reason rather than a conceptual
/// one: that suite is `.serialized`, and `.serialized` orders a suite only against its
/// own children. The stub is one global armed outcome and `KeychainTokenStore.shared` is
/// one global entry, so a peer suite in another file would run in parallel with #55's and
/// the two would arm each other's exchanges and clear each other's fixtures. Sharing the
/// serialized parent is what makes either file's assertions mean anything — and it is
/// also what keeps the parameterised cases below from running concurrently with each
/// other.
///
/// A user who has not finished their profile. `.unreachable` sits in front of the app
/// either way, so a recovered launch lands on the dashboard whether or not the profile is
/// complete (#19 removed the post-auth questionnaire gate).
///
/// File scope rather than a member of the suite below: a `@Test`'s `arguments:` are
/// evaluated outside the suite's `@MainActor` isolation and cannot read its statics.
private let unfinishedUser =
    #"{"user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":false}}"#

/// The session the user creates after walking away from a launch that hung. A different
/// account and a different token on purpose: the assertions below are about which session
/// survives, and two identical tokens would make either answer look right.
private let signedInAgain =
    #"{"token":"a-second-token","user":{"id":"u2","email":"e2e+again@e2e.evaapp.dev","questionnaireCompleted":true}}"#

extension SessionExpiryTests {

    @Suite("Issue #61 · a launch that cannot reach the API keeps the session")
    @MainActor
    struct OfflineLaunch {

        /// The value in the Keychain. Asserted by equality rather than for non-nil: a
        /// bootstrap that cleared and rewrote a token would pass a nil check.
        static let token = "a-live-looking-token"

        let store = KeychainTokenStore.shared

        /// The state a launch actually starts from: a token in the Keychain, nothing yet
        /// asked of the network.
        ///
        /// The client reads the Keychain per request exactly as `APIClient.default` does,
        /// so a test whose token gets cleared mid-flow is testing the real path.
        func storedSession() -> AppSession {
            store.clear()
            store.save(Self.token)
            #expect(store.token == Self.token, "The Keychain is not writable in this process")
            return AppSession(
                client: APIClient(
                    baseURL: EvaStubURLProtocol.baseURL,
                    token: { KeychainTokenStore.shared.token },
                    session: EvaStubURLProtocol.session
                ),
                tokenStore: store
            )
        }

        // MARK: - Failures that are not the server refusing the credential

        /// The issue itself. `URLSession` throws, `APIClient` maps it to `.network`, and
        /// nothing about that says the token is dead.
        @Test("A launch with no signal keeps the token")
        func noSignalKeepsTheToken() async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stubNetworkFailure()

            await session.bootstrap()

            #expect(store.token == Self.token, "An offline launch destroyed the stored session")
            #expect(session.state.isUnreachable, "An offline launch left the app in \(session.state)")
            // The premise, checked rather than assumed: the request that failed is the
            // one that carried the credential.
            #expect(EvaStubURLProtocol.lastAuthorization == "Bearer \(Self.token)")
        }

        /// The server answered, and what it said was that it could not serve this request
        /// — not that the credential is finished. A 503 from a load balancer arrives as an
        /// HTML page, which is why the bodies differ: the rule must not depend on the
        /// failure being well-formed.
        @Test(
            "A server that answers but cannot serve keeps the token",
            arguments: [
                (500, #"{"error":{"code":"INTERNAL","message":"Something went wrong"}}"#),
                (503, "<html><body>503 Service Unavailable</body></html>"),
            ]
        )
        func aServerFailureKeepsTheToken(status: Int, body: String) async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stub(status: status, body: body)

            await session.bootstrap()

            #expect(store.token == Self.token, "A \(status) at launch cleared the Keychain")
            #expect(session.state.isUnreachable, "A \(status) at launch left the app in \(session.state)")
            // `.unreachable` is also what a request that never reached the stub looks like
            // (#279): a client built without `session:` fails on `.invalid` as a network
            // error. This is what tells the two apart.
            #expect(EvaStubURLProtocol.requestCount > 0, "The launch never reached the stub")
        }

        /// A 200 that is not a `UserResponse` — the captive portal that answers every
        /// request with its own sign-in page, and the shape `APIError.decoding` is reached
        /// through. The status says success, so a rule keyed on status alone would treat
        /// this as a valid session; the old bare `catch` treated it as a dead one. It is
        /// neither.
        @Test("A 200 the app cannot decode keeps the token")
        func anUndecodableBodyKeepsTheToken() async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stub(status: 200, body: "<html><body>Sign in to hotel wifi</body></html>")

            await session.bootstrap()

            #expect(store.token == Self.token, "An undecodable reply cleared the Keychain")
            #expect(session.state.isUnreachable, "An undecodable reply left the app in \(session.state)")
            // `.unreachable` is also what a request that never reached the stub looks like
            // (#279): a client built without `session:` fails on `.invalid` as a network
            // error. This is what tells the two apart.
            #expect(EvaStubURLProtocol.requestCount > 0, "The launch never reached the stub")
        }

        // MARK: - The failure that is

        /// The other half of the acceptance criteria, and the one #61 must not break: a
        /// 401 on a request that actually sent the token still ends the session. A
        /// deleted account keeps no credential on the device (#8, #55).
        @Test("A 401 on the token it sent still clears it")
        func aDeadTokenIsStillCleared() async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stub(status: 401, body: ClientMapping.deadToken)

            await session.bootstrap()

            #expect(store.token == nil, "A dead token was left in the Keychain")
            #expect(session.state.isSignedOut, "A dead token left the app in \(session.state)")
            // What separates this test from the ones above. Without it, a rule keyed on
            // status alone would pass here and sign users out for a wrong password.
            #expect(
                EvaStubURLProtocol.lastAuthorization == "Bearer \(Self.token)",
                "The 401 came back on a request that never presented the credential"
            )
        }

        /// Nothing stored is not a failure to reach anything — it is a user who has not
        /// signed in. `.unreachable` here would offer a retry for a token that does not
        /// exist, and the request itself would be a bare call the API answers with 401.
        @Test("A launch with no stored token signs out without asking the API")
        func noTokenAsksNothing() async {
            store.clear()
            let session = AppSession(
                client: APIClient(
                    baseURL: EvaStubURLProtocol.baseURL,
                    token: { KeychainTokenStore.shared.token },
                    session: EvaStubURLProtocol.session
                ),
                tokenStore: store
            )
            // Armed to *succeed*, so a bootstrap that asked anyway would end `.ready` and
            // fail loudly rather than fall through to the same `.signedOut` by accident.
            EvaStubURLProtocol.stub(status: 200, body: ClientMapping.user)

            await session.bootstrap()

            #expect(session.state.isSignedOut, "A launch with no token landed in \(session.state)")
            #expect(EvaStubURLProtocol.requestCount == 0, "A launch with no token still called GET /me")
        }

        // MARK: - Getting back out of `.unreachable`

        /// The escape the issue asks for: the user waits for signal and taps *Try again*,
        /// and the session they never lost resumes — on the same token, on the dashboard.
        ///
        /// Both a completed and an incomplete profile are covered: `.unreachable` sits in
        /// front of both, and #19 removed the post-auth gate so either lands `.ready`. It
        /// also catches a `retry()` that re-authenticates instead of reusing the token,
        /// and a missing `defer { isBootstrapping = false }` — the second `bootstrap()`
        /// would return early and the state would never move.
        @Test(
            "Retrying after the signal comes back resumes the same session",
            arguments: [ClientMapping.user, unfinishedUser]
        )
        func retryResumesTheSession(body: String) async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stubNetworkFailure()
            await session.bootstrap()
            #expect(session.state.isUnreachable, "The fixture never reached .unreachable, so nothing below means anything")

            EvaStubURLProtocol.stub(status: 200, body: body)
            await session.retry()

            #expect(
                EvaStubURLProtocol.lastAuthorization == "Bearer \(Self.token)",
                "The retry went out without the token the failed launch kept"
            )
            #expect(store.token == Self.token, "The retry replaced the token it was supposed to reuse")
            #expect(session.user?.email == "e2e+unit@e2e.evaapp.dev")
            #expect(session.state.isReady, "A recovered launch landed in \(session.state)")
        }

        /// The other way out, and the reason it exists: keeping the token removed the
        /// ejection that used to be automatic, so a `/me` that fails for this account
        /// every time would otherwise be a screen with no exit.
        ///
        /// Log out must not need the network — it is reached precisely when there isn't
        /// any — so the stub stays armed to fail throughout.
        @Test("Logging out of an unreachable launch clears the token without the network")
        func loggingOutOfUnreachableClearsTheToken() async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stubNetworkFailure()
            await session.bootstrap()
            #expect(session.state.isUnreachable, "The fixture never reached .unreachable")

            session.logOut()

            #expect(store.token == nil, "Logging out of the unreachable screen kept the token")
            #expect(session.state.isSignedOut, "Logging out left the app in \(session.state)")
        }

        // MARK: - What happens while a launch is still in flight

        /// `bootstrap()` is re-runnable now, so it can be asked to run while it is already
        /// running — the retry button and `EvaRootView`'s `.task` are two callers of the
        /// same method. The guard exists so that costs one `GET /me`, not two.
        ///
        /// The first response is **held** open rather than raced against: the second call
        /// is made while the first request is provably still on the wire, so there is no
        /// scheduling assumption left in this test. It is not two tasks that might
        /// interleave — it is one call made during another.
        @Test("A second bootstrap while the first is in flight does not fire a second GET /me")
        func overlappingBootstrapsMakeOneRequest() async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stubHeld(status: 200, body: ClientMapping.user)

            async let first: Void = session.bootstrap()
            await EvaStubURLProtocol.waitForRequestInFlight()

            await session.bootstrap()
            #expect(EvaStubURLProtocol.requestCount == 1, "The re-entrant launch fired its own GET /me")

            EvaStubURLProtocol.releaseHeldRequest()
            await first

            #expect(EvaStubURLProtocol.requestCount == 1, "Overlapping launches asked GET /me twice")
            #expect(session.state.isReady, "Overlapping launches left the app in \(session.state)")
        }

        /// The race `sessionGeneration` is for.
        ///
        /// **Log out** on the retry screen is deliberately live while a retry is running,
        /// because a connection that is accepted and never answered hangs on URLSession's
        /// 60s default and an exit that is unavailable for a minute is not an exit. That
        /// makes this ordering reachable by an ordinary user, not just in theory: the
        /// `/me` they walked away from lands *after* the session ended.
        ///
        /// Applying it would be the worst of both — the user is put back on the dashboard
        /// they just left, holding a session whose token `logOut()` already deleted, so
        /// every request from there fails and the only way out is to log out again.
        ///
        /// Held rather than raced, for the same reason as above: the log out happens while
        /// the request is provably open, so this fails on the behaviour and not on an
        /// unlucky schedule.
        @Test("Logging out while a launch is in flight is not undone by the late reply")
        func loggingOutDuringALaunchIsNotUndone() async {
            let session = storedSession()
            defer { store.clear() }
            EvaStubURLProtocol.stubHeld(status: 200, body: ClientMapping.user)

            async let launch: Void = session.bootstrap()
            await EvaStubURLProtocol.waitForRequestInFlight()

            session.logOut()
            EvaStubURLProtocol.releaseHeldRequest()
            await launch

            #expect(
                session.state.isSignedOut,
                "A GET /me that landed after the log out put the user in \(session.state)"
            )
            #expect(store.token == nil, "The token the log out cleared came back")
            #expect(session.user == nil, "A signed-out session is still carrying the user the late reply named")
        }


        /// The same race one layer down, and the reason `authorized(_:)` captures the
        /// generation as well: the counter protects `bootstrap()`'s own arms, but the
        /// sign-out that actually mutates state lives in the wrapper.
        ///
        /// The sequence is ordinary, not contrived. A launch hangs — a connection that is
        /// accepted and never answered waits out URLSession's 60s default — so the user
        /// takes the exit the retry screen offers and signs in again. The abandoned `/me`
        /// then lands, carrying the *old* token, and gets the 401 that token deserves.
        /// Nothing about that says anything at all about the session the user is now in.
        ///
        /// Two requests are open at once here, which is the whole reason the stub routes
        /// by method and path: `GET /me` is held while `POST /auth/signin` completes.
        @Test("A 401 from an abandoned launch does not sign out the session that replaced it")
        func aLate401DoesNotEndTheSessionThatReplacedIt() async {
            let session = storedSession()
            defer { store.clear() }

            EvaStubURLProtocol.route {
                $0.held(.get("/me"), status: 401, body: ClientMapping.deadToken)
                $0.responds(.post("/auth/signin"), status: 200, body: signedInAgain)
            }

            async let launch: Void = session.bootstrap()
            await EvaStubURLProtocol.waitForRequestInFlight(.get("/me"))

            // What the user does while the launch hangs.
            session.logOut()
            do {
                try await session.signIn(email: "e2e+again@e2e.evaapp.dev", password: "uitest-pass-1")
            } catch {
                Issue.record("The fixture could not sign back in: \(error)")
            }
            #expect(session.state.isReady, "The fixture never reached a second session")
            #expect(store.token == "a-second-token", "The fixture never stored the second token")

            // Only now does the abandoned launch hear back, and what it hears is that the
            // token it sent — the old one — is dead.
            EvaStubURLProtocol.releaseHeldRequest(.get("/me"))
            await launch

            #expect(
                EvaStubURLProtocol.lastAuthorization(for: .get("/me")) == "Bearer \(Self.token)",
                "The abandoned launch did not send the old token, so its 401 proves nothing"
            )
            #expect(store.token == "a-second-token", "A 401 on the old token cleared the new one")
            #expect(
                session.state.isReady,
                "A 401 from the abandoned launch left the new session in \(session.state)"
            )
            #expect(
                session.user?.email == "e2e+again@e2e.evaapp.dev",
                "The new session is carrying the wrong user"
            )
            #expect(
                EvaStubURLProtocol.unroutedRequests.isEmpty,
                "A rule was armed on the wrong path, so this test proved something else: \(EvaStubURLProtocol.unroutedRequests)"
            )
        }

        /// The `apply(_:)` half of the same counter, and the only one of its bumps that
        /// is not already covered by a log out.
        ///
        /// Signing in *without* logging out first is not reachable from today's screens —
        /// every path to `signIn` goes through `logOut()`, which bumps the generation on
        /// its own. That is exactly why this is worth a test: the invariant "a new session
        /// is a new generation" was being enforced by a navigation path rather than by
        /// `AppSession`, and the first screen that signs someone in directly would reopen
        /// the hole silently. `signIn` is public API; this is the contract it has to keep
        /// whether or not a screen currently exercises it.
        ///
        /// The abandoned launch is answered with a *different* account than the sign-in,
        /// and one that has not finished the questionnaire, so a launch that wrongly
        /// applied its result would be visible twice over — wrong user, wrong screen.
        @Test("A launch that resolves after a sign-in does not overwrite the new session")
        func aLateSuccessDoesNotOverwriteASignIn() async {
            let session = storedSession()
            defer { store.clear() }

            EvaStubURLProtocol.route {
                $0.held(.get("/me"), status: 200, body: unfinishedUser)
                $0.responds(.post("/auth/signin"), status: 200, body: signedInAgain)
            }

            async let launch: Void = session.bootstrap()
            await EvaStubURLProtocol.waitForRequestInFlight(.get("/me"))

            do {
                try await session.signIn(email: "e2e+again@e2e.evaapp.dev", password: "uitest-pass-1")
            } catch {
                Issue.record("The fixture could not sign in: \(error)")
            }

            EvaStubURLProtocol.releaseHeldRequest(.get("/me"))
            await launch

            #expect(
                session.user?.email == "e2e+again@e2e.evaapp.dev",
                "The abandoned launch replaced the signed-in user with the one it was validating"
            )
            #expect(
                session.state.isReady,
                "The abandoned launch put the new session in \(session.state) — its own account's screen"
            )
            #expect(store.token == "a-second-token", "The new session's token did not survive")
            #expect(
                EvaStubURLProtocol.unroutedRequests.isEmpty,
                "A rule was armed on the wrong path, so this test proved something else: \(EvaStubURLProtocol.unroutedRequests)"
            )
        }

        /// Brings the session up the way launch does, so "signed out" afterwards is a
        /// change the test caused rather than the state it started in. The caller's
        /// `route` block has to answer `GET /me` for this to work.
        func signedIn() async -> AppSession {
            let session = storedSession()
            await session.bootstrap()
            #expect(session.state.isReady, "The fixture never signed in, so nothing below means anything")
            return session
        }

        /// The call site the counter missed until the security review found it, and the
        /// only one where a late reply does something irreversible.
        ///
        /// `DELETE /me` is slow — it deletes the Firestore document and then the Identity
        /// Toolkit account — so the window is wider here than anywhere else. A reply that
        /// lands after the user has logged out and signed in again would run `logOut()` on
        /// the **second** session: clearing a token that request never carried, for an
        /// account it never touched, and dropping the user onto onboarding for a deletion
        /// that happened to somebody else.
        ///
        /// That it cannot be reached from today's UI rests on two `.disabled` modifiers on
        /// `DeleteAccountModal`, which is the same argument `apply(_:)` deliberately
        /// refuses to rely on.
        @Test("A delete that returns after the user signed in again does not end the new session")
        func aLateDeleteDoesNotEndTheSessionThatReplacedIt() async {
            EvaStubURLProtocol.route {
                $0.responds(.get("/me"), status: 200, body: ClientMapping.user)
                $0.held(.delete("/me"), status: 200, body: #"{"deleted":true}"#)
                $0.responds(.post("/auth/signin"), status: 200, body: signedInAgain)
            }
            let session = await signedIn()
            defer { store.clear() }

            async let deletion: Void = session.deleteAccount()
            await EvaStubURLProtocol.waitForRequestInFlight(.delete("/me"))

            session.logOut()
            do {
                try await session.signIn(email: "e2e+again@e2e.evaapp.dev", password: "uitest-pass-1")
            } catch {
                Issue.record("The fixture could not sign in: \(error)")
            }

            EvaStubURLProtocol.releaseHeldRequest(.delete("/me"))
            do {
                try await deletion
            } catch {
                Issue.record("The delete itself failed, so its late reply proves nothing: \(error)")
            }

            #expect(
                store.token == "a-second-token",
                "A delete for the abandoned account deleted the new session's token"
            )
            #expect(
                session.state.isReady,
                "A delete for the abandoned account left the new session in \(session.state)"
            )
            #expect(session.user?.email == "e2e+again@e2e.evaapp.dev", "The new session lost its user")
            #expect(
                EvaStubURLProtocol.unroutedRequests.isEmpty,
                "A rule was armed on the wrong path, so this test proved something else: \(EvaStubURLProtocol.unroutedRequests)"
            )
        }

        /// The same guard on `submitQuestionnaire`, for completeness rather than because
        /// it was dangerous.
        ///
        /// This one protects a single `user` write and nothing structural: a late reply
        /// would leave the new session showing the previous account's profile until the
        /// next `/me`, which is a wrong name on a screen, not a lost session or a deleted
        /// token. It is here because the seam makes it about fifteen lines, not because
        /// skipping it would have been a risk.
        @Test("A questionnaire reply that lands after a sign-in does not overwrite the new user")
        func aLateQuestionnaireDoesNotOverwriteTheNewUser() async {
            EvaStubURLProtocol.route {
                $0.responds(.get("/me"), status: 200, body: ClientMapping.user)
                $0.held(.put("/me/questionnaire"), status: 200, body: unfinishedUser)
                $0.responds(.post("/auth/signin"), status: 200, body: signedInAgain)
            }
            let session = await signedIn()
            defer { store.clear() }

            async let submission: Void = session.submitQuestionnaire(SessionReaction.profile)
            await EvaStubURLProtocol.waitForRequestInFlight(.put("/me/questionnaire"))

            session.logOut()
            do {
                try await session.signIn(email: "e2e+again@e2e.evaapp.dev", password: "uitest-pass-1")
            } catch {
                Issue.record("The fixture could not sign in: \(error)")
            }

            EvaStubURLProtocol.releaseHeldRequest(.put("/me/questionnaire"))
            do {
                try await submission
            } catch {
                Issue.record("The submission itself failed, so its late reply proves nothing: \(error)")
            }

            #expect(
                session.user?.email == "e2e+again@e2e.evaapp.dev",
                "The abandoned questionnaire replaced the signed-in user with the account it was answering for"
            )
            #expect(
                EvaStubURLProtocol.unroutedRequests.isEmpty,
                "A rule was armed on the wrong path, so this test proved something else: \(EvaStubURLProtocol.unroutedRequests)"
            )
        }
    }
}

// MARK: - Test-local helpers

/// `private` and therefore distinct from the same-named helpers in
/// `SessionExpiryTests.swift`; duplicated rather than shared because a matcher that
/// several files depend on is a matcher nobody edits when a case is added.
private extension AppSession.State {
    var isUnreachable: Bool {
        switch self {
        case .unreachable: true
        default: false
        }
    }

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

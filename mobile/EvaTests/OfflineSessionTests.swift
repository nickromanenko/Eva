import Foundation
import Testing

@testable import Eva

/// ARCHITECTURE §8's session half (#78), through the real `AppSession` and `APIClient` over
/// `EvaStubURLProtocol` — the harness §8.6 names. Nested in `SessionExpiryTests` because the
/// stub is one global and the Keychain is shared, and that suite is `.serialized`.
extension SessionExpiryTests {

    @Suite("Issue #78 · the store across the session's boundaries")
    @MainActor
    struct OfflineSession {

        /// A JWT whose `sub` is `u1` — the uid `ClientMapping.user` names, so the store
        /// Continue offline opens is the one a validated launch opens.
        /// `{"alg":"HS256","typ":"JWT"}.{"sub":"u1"}`
        static let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.sig"

        static let day = EvaDay(year: 2026, month: 9, day: 1)

        static func created(key: String, id: String = "srv1") -> String {
            #"{"event":{"id":"\#(id)","type":"sport","localDate":"2026-09-01","loggedAt":"2026-09-01T09:00:00","source":"user","idempotencyKey":"\#(key)","payload":{"activity":"run","durationMin":20,"intensity":"medium"}}}"#
        }

        static let refdata =
            #"{"version":"v1","catalogues":{"symptoms":[],"sportActivities":[{"code":"run","label":"Run","order":1,"status":"active"}],"appointmentTypes":[]}}"#

        static func write(key: String = UUID().uuidString) -> EvaEventWrite {
            EvaEventWrite(
                payload: .sport(EvaSportPayload(activity: "run", durationMin: 20, intensity: .medium)),
                localDate: day,
                idempotencyKey: key
            )
        }

        static let consentRequired =
            #"{"error":{"code":"CONSENT_REQUIRED","message":"Eva stores nothing about your health until you consent to it"}}"#

        static let withdrawnUser =
            #"{"user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true,"consent":{"collect":{"version":"\#(ConsentPolicy.version)","at":"2026-09-19T08:00:00.000Z","withdrawnAt":"2026-10-01T08:00:00.000Z"},"share":null}}}"#

        /// A JWT for a second account, `u2`. `{"alg":"HS256","typ":"JWT"}.{"sub":"u2"}`
        static let tokenB = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MiJ9.sig"
        static let signedInAsB =
            #"{"token":"\#(tokenB)","user":{"id":"u2","email":"e2e+b@e2e.evaapp.dev","questionnaireCompleted":true}}"#
        static let signedInAsA =
            #"{"token":"\#(token)","user":{"id":"u1","email":"e2e+unit@e2e.evaapp.dev","questionnaireCompleted":true}}"#

        let store = KeychainTokenStore.shared
        /// This test's own defaults, so the consent-gate marks do not leak between tests or
        /// into the app's.
        let defaults = UserDefaults(suiteName: "eva-offline-session-\(UUID().uuidString)")!

        /// `storeOpens: false` makes every store file refuse to open, the device fault the
        /// session's in-memory fallback is for (#382).
        func session(storeOpens: Bool = true) -> AppSession {
            store.clear()
            store.save(Self.token)
            let refuse: @MainActor (String) throws -> EvaStore = { _ in throw CocoaError(.fileReadCorruptFile) }
            return AppSession(
                client: APIClient(
                    baseURL: EvaStubURLProtocol.baseURL,
                    token: { KeychainTokenStore.shared.token },
                    session: EvaStubURLProtocol.session
                ),
                tokenStore: store,
                inMemoryStore: true,
                defaults: defaults,
                openStore: storeOpens ? nil : refuse
            )
        }

        /// Marks `u1` as having passed the consent gate here, as an earlier `.ready` launch
        /// would have.
        func markConsentPassed() {
            defaults.set(["u1"], forKey: AppSession.consentGateKey)
        }

        /// A session that has launched and been validated.
        func readySession() async throws -> (AppSession, EventSync) {
            let session = session()
            EvaStubURLProtocol.route {
                $0.responds(.get("/me"), status: 200, body: ClientMapping.user)
            }
            await session.bootstrap()
            let sync = try #require(session.eventSync, "A validated launch opened no store")
            #expect(sync.store.belongsTo("u1"))
            return (session, sync)
        }

        var deviceRoute: EvaStubURLProtocol.Route {
            .delete("/me/devices/\(KeychainTokenStore.shared.deviceId)")
        }

        // MARK: §8.6 · the retry that matters

        /// §8.6's own case: a `POST` that times out, then a `201` for the same key. The
        /// second send carries the **same** `idempotencyKey`, which is what lets the server
        /// answer with the document the first one may already have written.
        @Test("§8.6 · a create that timed out is re-sent with the same idempotencyKey, and syncs once")
        func aTimedOutCreateIsReplayedWithTheSameKey() async throws {
            let (_, sync) = try await readySession()
            defer { store.clear() }
            let draft = Self.write()

            EvaStubURLProtocol.route { $0.fails(.post("/me/events"), .timedOut) }
            sync.save(draft)
            await sync.drain()
            let first = EvaStubURLProtocol.bodies(for: .post("/me/events"))

            EvaStubURLProtocol.route {
                $0.responds(.post("/me/events"), status: 201, body: Self.created(key: draft.idempotencyKey))
            }
            await sync.drain()
            let second = EvaStubURLProtocol.bodies(for: .post("/me/events"))

            let keys = (first + second).compactMap {
                (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["idempotencyKey"] as? String
            }
            #expect(keys == [draft.idempotencyKey, draft.idempotencyKey])
            let row = try #require(sync.store.row(clientId: draft.idempotencyKey))
            #expect(row.serverId == "srv1")
            #expect(row.state == .synced)
            #expect(sync.eventsByDay()[Self.day]?.count == 1)
        }

        // MARK: §8.5 · log out, a 401, account deletion

        @Test("§8.5 · log out wipes the store and the queue")
        func logOutWipes() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            EvaStubURLProtocol.route {
                $0.fails(.post("/me/events"))
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(Self.write())
            await sync.drain()
            #expect(session.unsyncedEntryCount == 1)

            session.logOut()
            await session.deviceRemoval?.value

            #expect(session.eventSync == nil)
            #expect(sync.eventsByDay().isEmpty)
            #expect(sync.store.operations().isEmpty, "Log out left the queue behind")
        }

        @Test("§8.4 · a 401 signs out but discards nothing")
        func a401KeepsTheQueue() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            EvaStubURLProtocol.route {
                $0.responds(.post("/me/events"), status: 401, body: ClientMapping.deadToken)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(Self.write())
            await sync.drain()
            await session.deviceRemoval?.value

            #expect(session.state.isSignedOut)
            #expect(sync.store.operations().count == 1, "A 401 discarded the queued entry")
            #expect(sync.eventsByDay()[Self.day]?.count == 1)
        }

        @Test("§8.5 · account deletion wipes the store after DELETE /me, and a queued entry is dropped")
        func deletionWipes() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            EvaStubURLProtocol.route {
                $0.fails(.post("/me/events"))
                $0.responds(.delete("/me"), status: 200, body: #"{"deleted":true}"#)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(Self.write())
            await sync.drain()
            let attempts = EvaStubURLProtocol.requestCount(for: .post("/me/events"))

            try await session.deleteAccount()
            await session.deviceRemoval?.value
            await sync.drain()

            #expect(session.eventSync == nil)
            #expect(sync.store.operations().isEmpty)
            #expect(EvaStubURLProtocol.requestCount(for: .post("/me/events")) == attempts,
                    "A queued entry was sent after the account was deleted")
        }

        // MARK: Continue offline (A3, the `unreachable` artboard)

        @Test("Continue offline opens the token's account's store and logs to it")
        func continueOffline() async throws {
            let session = session()
            markConsentPassed()
            defer { store.clear() }
            EvaStubURLProtocol.route { $0.fails(.get("/me")) }
            await session.bootstrap()
            guard case .unreachable = session.state else {
                Issue.record("The fixture never reached the retry screen (\(session.state))")
                return
            }

            session.continueOffline()

            guard case .offline = session.state else {
                Issue.record("Continue offline left the session in \(session.state)")
                return
            }
            let sync = try #require(session.eventSync)
            #expect(sync.store.belongsTo("u1"), "The offline store is not the token's account's")
            #expect(store.token == Self.token, "Going offline touched the token")
        }

        @Test("an offline session revalidates when a request gets through")
        func offlineRevalidates() async throws {
            let session = session()
            markConsentPassed()
            defer { store.clear() }
            EvaStubURLProtocol.route { $0.fails(.get("/me")) }
            await session.bootstrap()
            session.continueOffline()
            let sync = try #require(session.eventSync)

            // A revalidation that fails again leaves her in the app.
            await session.bootstrap()
            guard case .offline = session.state else {
                Issue.record("A failed revalidation threw her out of the app (\(session.state))")
                return
            }

            let draft = Self.write()
            EvaStubURLProtocol.route {
                $0.responds(.post("/me/events"), status: 201, body: Self.created(key: draft.idempotencyKey))
                $0.responds(.get("/me"), status: 200, body: ClientMapping.user)
            }
            sync.save(draft)
            await sync.drain()
            for _ in 0..<200 where !session.state.isReady { await Task.yield() }

            #expect(session.state.isReady, "The session stayed offline after the API answered")
            #expect(session.user?.id == "u1")
        }

        // MARK: Review fixes (#371)

        /// Security review 1: a 401 closes A's store while one of A's creates is on the
        /// wire; B signs in before it answers. Nothing of A's may go out after that — least
        /// of all with B's token, which is what the Keychain would hand the next request.
        @Test("a store closed by a 401 sends nothing more, even after another account signs in")
        func noCrossAccountSend() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            let first = Self.write()
            EvaStubURLProtocol.route {
                $0.held(.post("/me/events"), status: 201, body: Self.created(key: first.idempotencyKey))
                $0.responds(.get("/refdata"), status: 401, body: ClientMapping.deadToken)
                $0.responds(.post("/auth/signin"), status: 200, body: Self.signedInAsB)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(first)
            sync.save(Self.write())
            await EvaStubURLProtocol.waitForRequestInFlight(.post("/me/events"))

            _ = try? await session.refData()      // A's token is refused: 401, signed out
            await session.deviceRemoval?.value
            try await session.signIn(email: "e2e+b@e2e.evaapp.dev", password: "uitest-pass-1")
            #expect(session.eventSync?.store.belongsTo("u2") == true)
            EvaStubURLProtocol.releaseHeldRequest(.post("/me/events"))
            await sync.drain()
            for _ in 0..<50 { await Task.yield() }

            #expect(EvaStubURLProtocol.requestCount(for: .post("/me/events")) == 1,
                    "A's queue kept sending after its session ended")
            #expect(EvaStubURLProtocol.lastAuthorization(for: .post("/me/events")) == "Bearer \(Self.token)")
            #expect(sync.store.operations().isEmpty, "A's queue survived B signing in on this device")
            #expect(EvaStubURLProtocol.unroutedRequests.isEmpty)
        }

        /// #382: the variant that tests the guard rather than the wipe. `noCrossAccountSend`
        /// releases A's POST only after B has signed in, and B's sign-in wipes A's queue —
        /// so it passes with the guard gone. Here nobody signs in: the 401 closes the store
        /// with A's create on the wire and a second one queued behind it, and the held answer
        /// arrives to a closed store. Without `ensureOpen()` and the drain-cancel in
        /// `close()`, the pass acknowledges the first and sends the second (2 POSTs).
        @Test("a store closed by a 401 sends nothing more when its in-flight answer lands")
        func noSendAfterA401() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            let first = Self.write()
            EvaStubURLProtocol.route {
                $0.held(.post("/me/events"), status: 201, body: Self.created(key: first.idempotencyKey))
                $0.responds(.get("/refdata"), status: 401, body: ClientMapping.deadToken)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(first)
            sync.save(Self.write())
            await EvaStubURLProtocol.waitForRequestInFlight(.post("/me/events"))

            _ = try? await session.refData()      // A's token is refused: 401, signed out
            await session.deviceRemoval?.value
            #expect(session.state.isSignedOut)
            EvaStubURLProtocol.releaseHeldRequest(.post("/me/events"))
            // Not `sync.drain()`: with the guard gone the second POST is held by the same
            // rule, and a drain would wait it out. A second request arrives within
            // milliseconds of the release when it is going to arrive at all.
            for _ in 0..<100 where EvaStubURLProtocol.requestCount(for: .post("/me/events")) < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(EvaStubURLProtocol.requestCount(for: .post("/me/events")) == 1,
                    "A's queue kept sending after its session ended")
            #expect(sync.store.operations().count == 2, "A 401 discarded a queued entry")
            #expect(EvaStubURLProtocol.unroutedRequests.isEmpty)
        }

        /// Security review follow-up 1 (#378): a store file that will not open used to leave
        /// `eventSync` nil, and the calendar built an in-memory store of its own that nothing
        /// ever closed — so a 401 or a log out left A's queue draining under whatever token
        /// came next. The fallback is the session's now, and ends with the session.
        @Test("a store that will not open falls back to an in-memory one the session owns")
        func theFallbackStoreIsTheSessions() async throws {
            let session = session(storeOpens: false)
            defer { store.clear() }
            EvaStubURLProtocol.route { $0.responds(.get("/me"), status: 200, body: ClientMapping.user) }
            await session.bootstrap()
            let sync = try #require(session.eventSync, "A store that would not open left no store at all")
            #expect(sync.store.belongsTo("u1"))

            // A 401 closes it: nothing queued afterwards goes out.
            EvaStubURLProtocol.route {
                $0.responds(.get("/refdata"), status: 401, body: ClientMapping.deadToken)
                $0.responds(.post("/me/events"), status: 201, body: Self.created(key: "unused"))
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            _ = try? await session.refData()
            await session.deviceRemoval?.value
            #expect(session.eventSync == nil)
            sync.save(Self.write())
            await sync.drain()
            #expect(EvaStubURLProtocol.requestCount(for: .post("/me/events")) == 0,
                    "The fallback store kept sending after a 401")
        }

        @Test("log out wipes and closes the session's fallback store")
        func logOutClosesTheFallbackStore() async throws {
            let session = session(storeOpens: false)
            defer { store.clear() }
            EvaStubURLProtocol.route {
                $0.responds(.get("/me"), status: 200, body: ClientMapping.user)
                $0.fails(.post("/me/events"))
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            await session.bootstrap()
            let sync = try #require(session.eventSync)
            sync.save(Self.write())
            await sync.drain()
            let attempts = EvaStubURLProtocol.requestCount(for: .post("/me/events"))

            session.logOut()
            await session.deviceRemoval?.value
            sync.save(Self.write())
            await sync.drain()

            #expect(session.eventSync == nil)
            #expect(EvaStubURLProtocol.requestCount(for: .post("/me/events")) == attempts,
                    "The fallback store sent after log out")
        }

        /// Security review follow-up 2 (#378): consent withdrawn on another device. The mark
        /// says "this account was consented when last seen here"; a queued write the server
        /// refuses with `CONSENT_REQUIRED` says it no longer is, and the mark goes.
        @Test("a write refused with CONSENT_REQUIRED withdraws Continue offline")
        func consentRequiredClearsTheMark() async throws {
            let session = session()
            markConsentPassed()
            defer { store.clear() }
            EvaStubURLProtocol.route { $0.fails(.get("/me")) }
            await session.bootstrap()
            session.continueOffline()
            let sync = try #require(session.eventSync)
            #expect(session.canContinueOffline)

            EvaStubURLProtocol.route {
                $0.responds(.post("/me/events"), status: 403, body: Self.consentRequired)
                $0.fails(.get("/me"))
            }
            sync.save(Self.write())
            await sync.drain()

            #expect(sync.failedCount == 1)
            #expect(!session.canContinueOffline,
                    "Continue offline is still offered after the server refused for want of consent")
            // The mark is gone from the device, not just from this session object.
            #expect(self.session().canContinueOffline == false)
        }

        /// The same follow-up, from the other side: a validated launch that finds the consent
        /// withdrawn lands in the app (the freeze is not re-asked), and must not record the
        /// mark that would put Continue offline back.
        @Test("a validated launch with consent withdrawn does not mark the gate passed")
        func withdrawnConsentIsNotMarked() async throws {
            let session = session()
            markConsentPassed()
            defer { store.clear() }
            EvaStubURLProtocol.route { $0.responds(.get("/me"), status: 200, body: Self.withdrawnUser) }
            await session.bootstrap()
            #expect(session.state.isReady)

            #expect(!session.canContinueOffline,
                    "A launch that read a withdrawn consent left Continue offline on offer")
        }

        /// Security review 2: after a 401 nothing is discarded — but a launch with no token
        /// (the account was deleted elsewhere, or she never signed back in) wipes it.
        @Test("a store a 401 closed is wiped when the next launch finds no token")
        func a401StoreIsWipedWithNoToken() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            EvaStubURLProtocol.route {
                $0.responds(.post("/me/events"), status: 401, body: ClientMapping.deadToken)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(Self.write())
            await sync.drain()
            await session.deviceRemoval?.value
            #expect(sync.store.operations().count == 1)

            await session.bootstrap()

            #expect(sync.store.operations().isEmpty, "An orphaned queue outlived the account's token")
            #expect(sync.eventsByDay().isEmpty)
        }

        @Test("the same account signing back in after a 401 resumes its queue")
        func theSameAccountResumes() async throws {
            let (session, sync) = try await readySession()
            defer { store.clear() }
            let draft = Self.write()
            EvaStubURLProtocol.route {
                $0.responds(.post("/me/events"), status: 401, body: ClientMapping.deadToken)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            sync.save(draft)
            await sync.drain()
            await session.deviceRemoval?.value

            EvaStubURLProtocol.route {
                $0.responds(.post("/auth/signin"), status: 200, body: Self.signedInAsA)
                $0.responds(.post("/me/events"), status: 201, body: Self.created(key: draft.idempotencyKey))
            }
            try await session.signIn(email: "e2e+unit@e2e.evaapp.dev", password: "uitest-pass-1")
            await sync.drain()

            #expect(session.eventSync === sync)
            #expect(sync.store.operations().isEmpty)
            #expect(sync.store.row(clientId: draft.idempotencyKey)?.serverId == "srv1")
        }

        /// Security review 3: Continue offline must not skip the consent gate.
        @Test("Continue offline is offered only to an account that has passed the consent gate here")
        func continueOfflineNeedsConsent() async throws {
            let session = session()
            defer { store.clear() }
            EvaStubURLProtocol.route { $0.fails(.get("/me")) }
            await session.bootstrap()

            #expect(!session.canContinueOffline)
            session.continueOffline()
            guard case .unreachable = session.state else {
                Issue.record("Continue offline went through without a consent mark (\(session.state))")
                return
            }

            // A validated launch that lands in the app records the mark…
            EvaStubURLProtocol.route { $0.responds(.get("/me"), status: 200, body: ClientMapping.user) }
            await session.bootstrap()
            EvaStubURLProtocol.route { $0.fails(.get("/me")) }
            let offline = self.session()
            await offline.bootstrap()
            #expect(offline.canContinueOffline)

            // …and log out removes it.
            EvaStubURLProtocol.route {
                $0.responds(.get("/me"), status: 200, body: ClientMapping.user)
                $0.responds(deviceRoute, status: 200, body: #"{"removed":true}"#)
            }
            await offline.bootstrap()
            offline.logOut()
            await offline.deviceRemoval?.value
            store.save(Self.token)
            #expect(!offline.canContinueOffline)
        }

        // MARK: §8.3 · refdata's version handshake

        @Test("§8.3 · refdata is cached; ?version= goes out, a 304 keeps the copy, offline answers from it")
        func refdataHandshake() async throws {
            let (session, _) = try await readySession()
            defer { store.clear() }

            EvaStubURLProtocol.route { $0.responds(.get("/refdata"), status: 200, body: Self.refdata) }
            let fresh = try await session.refData()
            #expect(fresh.version == "v1")

            EvaStubURLProtocol.route { $0.responds(.get("/refdata"), status: 304, body: "") }
            let revalidated = try await session.refData()
            #expect(EvaStubURLProtocol.queries(for: .get("/refdata")) == ["version=v1"])
            #expect(revalidated == fresh)

            EvaStubURLProtocol.route { $0.fails(.get("/refdata")) }
            let offline = try await session.refData()
            #expect(offline == fresh, "An unreachable API emptied the pickers")
        }
    }
}

private extension AppSession.State {
    var isSignedOut: Bool {
        if case .signedOut = self { true } else { false }
    }

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

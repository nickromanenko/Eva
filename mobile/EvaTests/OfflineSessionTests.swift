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

        let store = KeychainTokenStore.shared

        func session() -> AppSession {
            store.clear()
            store.save(Self.token)
            return AppSession(
                client: APIClient(
                    baseURL: EvaStubURLProtocol.baseURL,
                    token: { KeychainTokenStore.shared.token },
                    session: EvaStubURLProtocol.session
                ),
                tokenStore: store,
                inMemoryStore: true
            )
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

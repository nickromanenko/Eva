import SwiftUI

/// App-wide auth/session state. The server is the source of truth for
/// questionnaire completion; this replaces the old @AppStorage flag.
@MainActor
@Observable
final class AppSession {
    enum State {
        case loading
        case signedOut
        /// We have a session the server validated, and the account owes the consent
        /// screen (#86): no collect consent on record, or one recorded against a text
        /// this build no longer displays. The server refuses health writes either way —
        /// this state is the screen that asks, not the enforcement. A **withdrawn**
        /// consent never routes here: the freeze keeps her in the app with collection
        /// stopped, and the way back is Settings › Privacy, not a gate that re-asks
        /// what she has already declined.
        case needsConsent
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

    /// Why the session ended, when the signed-out screen owes the user an explanation (#59).
    ///
    /// Almost every sign-out explains itself — the user tapped Log out, or a deletion
    /// they confirmed went through — and carries no reason. This exists for the one where
    /// the screen that would have said what happened is torn down *by* the sign-out.
    enum SignedOutReason: Equatable {
        /// `DELETE /me` came back 401: the credential died before the request could act,
        /// so nothing was deleted. Without saying so, the signed-out screen that follows
        /// is exactly what a successful deletion looks like.
        case deletionRefusedSessionEnded
    }

    private(set) var state: State = .loading
    private(set) var user: APIUser?
    /// Set only by a sign-out that has a `SignedOutReason`, and cleared by the next
    /// session and by every other sign-out — so it describes the sign-out the user is
    /// looking at, never an earlier one. In memory only: after a relaunch the context
    /// that made it worth saying is gone.
    private(set) var signedOutReason: SignedOutReason?

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
            state = Self.state(for: response.user)
            // The device token is registered only once a session is proven (#79): before this
            // there is nothing to authorize the request with.
            await registerStoredDeviceToken()
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
    }

    /// Dismisses the "complete your profile" nudge, server-side (#19).
    ///
    /// The flag lives on `users/{uid}` so a dismissal made on one device is not asked again
    /// on a second. It never blocks anything: the only side effect is the flag, and the
    /// Profile route and every other write keep working regardless.
    func dismissProfileNudge() async throws {
        let generation = sessionGeneration
        let response: UserResponse = try await authorized {
            try await client.post("/me/profile-nudge/dismiss", body: EvaEmptyBody(), authorized: true)
        }
        guard generation == sessionGeneration else { return }
        user = response.user
    }

    // MARK: Device registry (#79)

    /// The APNs environment this build belongs to: Debug uses Apple's sandbox push service,
    /// Release the production one. Sent with the token so the server fans out to the right
    /// endpoint.
    private var pushEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Registers this device's push token with the API (#79, A9) — the app's half of "the iOS
    /// app talks only to the Eva API". The device id is minted once per install in the
    /// Keychain, so a token rotation is a replace, never a second row. An unchanged token is
    /// not sent twice. Best-effort: a failure here must not disturb the session it rides
    /// behind, and the next bootstrap retries.
    func registerDevice(token: String, timeZone: TimeZone = .current) async {
        guard tokenStore.registeredDeviceToken != token else { return }
        do {
            let response: DeviceRegisteredResponse = try await client.put(
                "/me/devices/\(tokenStore.deviceId)",
                body: DeviceRegistration(
                    token: token,
                    environment: pushEnvironment,
                    timeZone: timeZone.identifier
                ),
                authorized: true
            )
            if response.registered { _ = tokenStore.markDeviceTokenRegistered(token) }
        } catch {
            // Deliberately swallowed: the session is what matters, and the sender job drops a
            // dead token on its own once one is registered.
        }
    }

    /// Registers the token the system last delivered, if it has not been sent already. Called
    /// after a successful `bootstrap()`, which is the moment §9.4 names ("after any successful
    /// bootstrap") rather than at launch, so the request always has a live session.
    private func registerStoredDeviceToken() async {
        guard let token = tokenStore.deviceToken else { return }
        await registerDevice(token: token)
    }

    /// Records or withdraws one consent kind (#86). The consent screen sends both of its
    /// toggles through here on Continue; Settings › Privacy sends one at a time.
    ///
    /// The state is recomputed from the returned user rather than guessed at the call
    /// site: a grant made from `.needsConsent` lands in `.ready`, and a withdrawal made
    /// from Profile lands back in `.ready` too — the freeze is a state *in* the app, and
    /// recomputing is what makes both paths the same code instead of two that drift.
    func setConsent(_ kind: EvaConsentKind, granted: Bool) async throws {
        let generation = sessionGeneration
        let response: UserResponse = try await authorized {
            try await client.put(
                "/me/consent/\(kind.rawValue)",
                body: ConsentRequestBody(
                    granted: granted,
                    // Withdrawal sends no version: the text being withdrawn from is the
                    // one the record already holds.
                    version: granted ? ConsentPolicy.version : nil
                ),
                authorized: true
            )
        }
        guard generation == sessionGeneration else { return }
        user = response.user
        state = Self.state(for: response.user)
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
    ///
    /// **A dead credential still signs out here, like everywhere else (#59).** The route
    /// is not exempt from `authorized(_:)`'s 401 rule; it only hands that rule a reason to
    /// leave on the signed-out screen. The modal that would have shown the error goes
    /// with the screen the sign-out replaces, so without one the user would be returned
    /// to onboarding in silence — which is what a deletion that *worked* looks like.
    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        let generation = sessionGeneration
        let response: DeleteAccountResponse = try await authorized(
            signedOutReason: .deletionRefusedSessionEnded
        ) {
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

    /// Everything stored under the account, as the one file `GET /me/export` (#58) serves.
    ///
    /// The body is not read here — not decoded, not validated, not logged. The app's job is
    /// to hand the user their record, and a client-side idea of its shape would be a second
    /// copy of the server's that goes stale the first time the export grows a field.
    ///
    /// Inside `authorized(_:)` like every other call that carries the token.
    func exportData() async throws -> EvaDataExport {
        let download = try await authorized {
            try await client.download("/me/export", authorized: true)
        }
        // A 200 is not proof of a whole file. The route streams, and a Firestore failure
        // mid-stream ends the body early with the status already sent — the only signal is
        // that the closing `]}`, written last on purpose, never arrived. Parsing is the
        // check, not a reading of the record: a truncated file offered to the user would
        // look like their export and silently be missing the rest of it.
        guard EvaDataExport.isComplete(download.data) else { throw APIError.decoding }
        return EvaDataExport(data: download.data, serverFilename: download.filename)
    }

    // MARK: - Calendar

    /// The user's entries for one visible range (#159).
    ///
    /// **A range, never a day.** The calendar draws six weeks at a time and the grid for
    /// one month reaches into the two either side of it, so a request per cell would be
    /// forty-two round trips to paint one screen — invisible at C1's read-only speed and
    /// the thing that makes C2's logging feel broken. `CalendarModel` caches what comes
    /// back by month and only asks for the months it has not got.
    ///
    /// The server caps a range at 400 days and rejects `from > to`; both are the caller's
    /// to respect, and both arrive as `APIError.server("VALIDATION", …)` if it does not.
    /// Soft-deleted entries are excluded server-side, so nothing here has to filter.
    ///
    /// Inside `authorized(_:)` like every other call that carries the token: a 401
    /// `UNAUTHORIZED` from here ends the session wherever the user happens to be standing.
    func events(from: EvaDay, through to: EvaDay) async throws -> [EvaEvent] {
        let response: EvaEventsResponse = try await authorized {
            try await client.get(
                "/me/events",
                query: [
                    URLQueryItem(name: "from", value: from.isoDate),
                    URLQueryItem(name: "to", value: to.isoDate)
                ],
                authorized: true
            )
        }
        return response.events
    }

    /// The option catalogues that turn an event's stored codes into words.
    ///
    /// No `version` is sent, so this is always a `200` and never the `304` the route also
    /// serves. Revalidating against a cached copy needs somewhere to cache it, which is
    /// the local store in #78; until then the catalogue is fetched once per launch and
    /// held in memory by `CalendarModel`.
    func refData() async throws -> EvaRefData {
        try await authorized {
            try await client.get("/refdata", authorized: true)
        }
    }

    /// The per-country emergency guidance table (#87), or `nil` when it cannot be had.
    ///
    /// The same `GET /refdata` document the calendar's catalogue comes from, sliced to
    /// the guidance rows. `nil` is the "not available" answer — a failed read, an API
    /// that predates the table — and every consumer treats it the same way: the red-flag
    /// card keeps the neutral wording it arrived with, which is the fallback sentence
    /// anyway (`refdata.test.ts` holds the two byte-equal). A missing table must never
    /// blank an escalation card.
    ///
    /// **Takes no country argument, on purpose.** The country is resolved on the device
    /// (`EvaCountrySetting`) and never sent anywhere — LAUNCH §2.4's data minimisation,
    /// and the reason this method's signature has nothing to pass. The table travels
    /// whole to every client; the lookup is local.
    ///
    /// Errors are swallowed rather than thrown, unlike `refData()`: the calendar treats a
    /// failed catalogue read as "draw the codes", and the card treats a failed guidance
    /// read as "keep the card's own words" — neither is worth a failed session over, and
    /// a dead session is `authorized`'s to handle on the card read that shares the
    /// refresh with this one.
    func emergencyGuidance() async -> [EvaRefData.EmergencyEntry]? {
        guard let refData = try? await refData() else { return nil }
        return refData.catalogues.emergencyGuidance
    }

    /// The calendar's prediction overlay. `GET /me/cycle/predictions?from=&to=&timeZone=`
    /// (#205, C12a).
    ///
    /// **A range, for the same reason `events(from:through:)` takes one** — one month grid,
    /// one fetch model. The route validates and caps the range through the same
    /// `parseDateRange` that route uses, so there is no second set of limits to respect.
    ///
    /// The zone identifier, never a date. The *range* says what to draw and `timeZone` says
    /// which local day the estimate is measured from; they are different questions, and a
    /// device that sent its own answer to the second would be asserting the prediction
    /// instead of asking for it.
    ///
    /// Answers `503 SERVICE_UNAVAILABLE` wherever the `CYCLE_*` constants are unset, which
    /// is every environment today (#176, #191). That reaches the caller as an ordinary
    /// `APIError.server` and `CalendarModel` draws no overlay for it — see `loadPrediction`.
    ///
    /// Nothing here logs the response. A predicted date is derived from her logged periods
    /// and is health data under GUARDRAILS 12 exactly as an event payload is.
    func predictions(from: EvaDay, through to: EvaDay) async throws -> EvaCyclePredictions {
        try await authorized {
            try await client.get(
                "/me/cycle/predictions",
                query: [
                    URLQueryItem(name: "from", value: from.isoDate),
                    URLQueryItem(name: "to", value: to.isoDate),
                    URLQueryItem(name: "timeZone", value: TimeZone.current.identifier)
                ],
                authorized: true
            )
        }
    }

    // MARK: - Reading the Dashboard (#99)

    /// The Home tab's card for the user's local date. `GET /me/today?timeZone=` (#98, D3).
    ///
    /// **The route does not exist yet.** This is the client half of the contract #98
    /// specifies, written now so that D4 could be built against it and so that wiring the
    /// real route up is this one method answering rather than a rewrite — see
    /// `TodayCardSource`, and `EvaTodayCard` for what is assumed about the body.
    ///
    /// The zone identifier, never a date: the server resolves "today" from it the way the
    /// events routes do, and a device that sent its own date would be asserting the answer
    /// rather than asking the question.
    ///
    /// Nothing here logs the response. A filled card is a sentence about the user's cycle
    /// and symptoms, which is health data under GUARDRAILS 12 exactly as an event payload is.
    func todayCard(timeZone: TimeZone) async throws -> EvaTodayResponse {
        try await authorized {
            try await client.get(
                "/me/today",
                query: [URLQueryItem(name: "timeZone", value: timeZone.identifier)],
                authorized: true
            )
        }
    }

    // MARK: - Writing the calendar (#160)
    //
    // Five routes, one rule: each returns the **server's** copy of the entry, and the
    // caller puts that on the grid rather than the draft it just built. The two are not
    // interchangeable — the server assigns the id, resolves `loggedAt` from the zone that
    // was sent, and for a one-per-day type may have replaced a document that was already
    // there. Echoing the local draft would draw a calendar that is nearly right and
    // impossible to tell apart from one that is.
    //
    // None of these logs anything. An event payload is health data (GUARDRAILS 12), and a
    // failure here surfaces as `APIError`'s own message on the sheet.

    /// Creates one entry. `POST /me/events`.
    ///
    /// For `cycle` this is also how a day is **re-logged**: the route stores one-per-day
    /// types at a deterministic id, so a second write replaces the day's entry rather than
    /// adding to it — and clears a previous soft delete in the process, which is the
    /// supersession `restore` then refuses (#50).
    func createEvent(_ write: EvaEventWrite) async throws -> EvaEvent {
        let response: EvaEventResponse = try await authorized {
            try await client.post("/me/events", body: write, authorized: true)
        }
        return response.event
    }

    /// The one-per-day upsert. `PUT /me/body-signals/{date}`.
    func upsertBodySignals(_ write: EvaBodySignalsWrite) async throws -> EvaEvent {
        let response: EvaEventResponse = try await authorized {
            try await client.put(
                "/me/body-signals/\(write.localDate.isoDate)", body: write, authorized: true
            )
        }
        return response.event
    }

    /// Edits one entry. `PATCH /me/events/{id}`.
    ///
    /// The body carries `type` and `localDate` because the route requires both — with them
    /// it can validate the payload at its edge instead of reading Firestore first. Moving a
    /// one-per-day entry to another day is refused there, which is why nothing in the app
    /// offers it: the day is part of that entry's identity.
    func updateEvent(id: String, _ write: EvaEventWrite) async throws -> EvaEvent {
        let response: EvaEventResponse = try await authorized {
            try await client.patch("/me/events/\(id)", body: write, authorized: true)
        }
        return response.event
    }

    /// Soft-deletes one entry. `DELETE /me/events/{id}`.
    ///
    /// Recoverable for thirty days by `restoreEvent(id:)` — *unless* the day has been
    /// logged again in between.
    func deleteEvent(id: String) async throws {
        let _: EvaDeletedResponse = try await authorized {
            try await client.delete("/me/events/\(id)", authorized: true)
        }
    }

    /// Undo. `POST /me/events/{id}/restore`.
    ///
    /// Throws `APIError.server(code: "DAY_ALREADY_LOGGED", …)` with a 409 when the day has
    /// been retaken since the delete. That is not a failure to retry and not a missing
    /// entry: restoring would have to overwrite something newer, so the server refuses and
    /// the caller has to stop offering Undo (#50).
    func restoreEvent(id: String) async throws -> EvaEvent {
        let response: EvaEventResponse = try await authorized {
            try await client.post(
                "/me/events/\(id)/restore", body: EvaEmptyBody(), authorized: true
            )
        }
        return response.event
    }

    /// Ends the session. The local half always happens, whatever the Keychain says.
    ///
    /// `clear()` reports now (#64), and `false` means it could neither delete the item nor
    /// overwrite it — a Keychain that refuses both, which is a device fault with nothing an
    /// app can do about it. Signing out anyway is still the right answer: the user asked to
    /// leave, this is the only exit from `.unreachable` since #61, and refusing to take it
    /// would strand them in a degraded app to protect them from a token they already have.
    /// The result is deliberately *used* rather than discarded, so the choice is visible to
    /// whoever reads this next instead of being the absence of a line.
    ///
    /// Clears any `signedOutReason` left from an earlier sign-out: a log out the user asked
    /// for explains itself.
    func logOut() {
        logOut(reason: nil)
    }

    /// `logOut()`, leaving `reason` for the signed-out screen to show (#59). Private: the
    /// only sign-out with something to explain is one `authorized(_:)` performs.
    private func logOut(reason: SignedOutReason?) {
        sessionGeneration += 1
        // Captured before the token is cleared: the removal request below carries it, and
        // once the Keychain is empty there is nothing to authorize with.
        let deviceId = tokenStore.deviceId
        let token = tokenStore.token
        if !tokenStore.clear() {
            // Nothing to show a user here, and no state to keep: a flag would not survive
            // the relaunch that is the only moment it could matter.
            assertionFailureInDebug("Keychain would neither clear nor neutralise the token")
        }
        user = nil
        signedOutReason = reason
        state = .signedOut
        // Best-effort removal of the push token (#79): the app's half of "sign out", fired
        // after the state has flipped, with the token captured above so the cleared Keychain
        // does not matter. A failure leaves a row the sender job drops when APNs answers 410.
        if let token {
            Task { [client] in
                var removalClient = client
                removalClient.token = { token }
                let _: DeviceRemovedResponse? = try? await removalClient.delete(
                    "/me/devices/\(deviceId)", authorized: true
                )
            }
        }
    }

    /// Runs an authorized request and signs out if the credential it sent came back
    /// dead. Every authorized call goes through here so a mid-session 401 ends the
    /// session wherever it happens, not only at launch; the error is rethrown so the
    /// caller still gets to react. Sign-up, sign-in, resend and forgot stay outside it —
    /// they send no token, and sign-in's 401 means "wrong password".
    /// `T: Sendable` because the result crosses an isolation boundary on the way back, and
    /// Swift 6.0 says so where 6.2 infers it — CI's Xcode 16.4 failed with "non-sendable
    /// result type 'T' cannot be sent from nonisolated context". Every caller already
    /// returns a value type of `Sendable` parts, so this documents what was true rather
    /// than narrowing anything.
    ///
    /// `signedOutReason` changes what the signed-out screen says, never whether the
    /// sign-out happens (#59): the rule is the same for every route, and a route whose
    /// failure the user could misread passes the words to explain it rather than an
    /// exemption from it.
    private func authorized<T: Sendable>(
        signedOutReason: SignedOutReason? = nil,
        _ work: () async throws -> T
    ) async throws -> T {
        // Captured before the await for the same reason `bootstrap()` captures it, and
        // guarding the same hazard one layer down: a request that started under an
        // earlier session must not act on the current one. Without this, a `/me` still
        // in flight when the user logs out and signs back in can return 401 and sign
        // out the *new* session — clearing a token it never saw.
        let generation = sessionGeneration
        do {
            return try await work()
        } catch let error as APIError {
            if case .sessionExpired = error, generation == sessionGeneration {
                logOut(reason: signedOutReason)
            }
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
        // A failed save does not fail the sign-in (#64). The user has authenticated and
        // the server has granted a session; refusing it would strand someone whose
        // Keychain is broken, while proceeding costs them signing in again after a
        // relaunch — the recoverable direction, and the one they can act on.
        if !tokenStore.save(response.token) {
            assertionFailureInDebug("Keychain refused to store the session token")
        }
        user = response.user
        // The reason described the sign-out this session replaces. Carried into the next
        // one, it would be waiting on the signed-out screen the next time she logs out.
        signedOutReason = nil
        state = Self.state(for: response.user)
    }

    /// Which state a session for `user` lands in: the app, or the consent screen (#86).
    ///
    /// One seam for both places a session is born — sign-in (`apply`) and launch
    /// (`bootstrap`) — so the two can never disagree about who owes the screen. A session
    /// that carries a user at all has been validated by the server; what is decided here
    /// is only whether the consent record it sent names the text this build displays.
    private static func state(for user: APIUser) -> State {
        user.needsConsentGate(currentVersion: ConsentPolicy.version) ? .needsConsent : .ready
    }
}

/// Fails loudly in a debug build and does nothing in a release one.
///
/// The two Keychain failures `AppSession` can hit (#64) are unactionable by the user and
/// close to unreachable in practice, so there is no screen for them — but they must not be
/// *silent* either, which is the defect the issue is about. A debug trap puts them in front
/// of whoever is running the app when they happen; shipping code carries on.
///
/// `EVA_UITEST_RESET` is honoured because a UI test drives `logOut()` deliberately, and a
/// simulator Keychain occasionally refuses under a fresh install — a trap there would fail
/// the run for the harness rather than for the app.
private func assertionFailureInDebug(
    _ message: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    #if DEBUG
    guard ProcessInfo.processInfo.environment["EVA_UITEST_RESET"] != "1" else { return }
    assertionFailure(message(), file: file, line: line)
    #endif
}

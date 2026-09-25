# Eva — Architecture

Written intent for humans and agents. If code and this document disagree, one of
them is a bug — say which, don't silently pick a side.

## 1. Shape of the system

```
┌─────────────┐        HTTPS/JSON          ┌──────────────┐
│  iOS app    │ ─────────────────────────► │  Eva API     │
│  SwiftUI    │  Bearer <Eva JWT>          │  Hono + Bun  │
└─────────────┘                            └──────┬───────┘
                                                  │ Admin SDK (ADC)
┌─────────────┐                                   ▼
│  website    │  Astro static ──► Firebase  ┌──────────────┐
│  (landing)  │      Hosting               │  Firestore   │
└─────────────┘                            │  users/{uid} │
                                            └──────────────┘
                                                  ▲
                              Identity Toolkit REST│ (email/password credentials)
                                            ┌──────┴───────┐
                                            │ Firebase Auth│
                                            └──────────────┘
```

| Surface | Stack | Deploys to | Trigger |
|---|---|---|---|
| `api/` | Hono + Bun, Docker | Cloud Run `eva-api` (`us-central1`) | push to `main` touching `api/**` |
| `website/` | Astro (static) | Firebase Hosting | push to `main` touching `website/**` |
| `mobile/` | SwiftUI, iOS 18+, Swift 6, XcodeGen | TestFlight / App Store (manual) | manual |
| root | `firestore.rules`, `storage.rules`, indexes | Firebase | **manual only** (`firebase deploy`) |

## 2. The load-bearing decision: the API mediates auth

The iOS app **never talks to Firebase directly**. It only knows the Eva API.

Why:

- One server-owned place to create the `users/{uid}` document, so a user can never
  exist in Auth but not in Firestore.
- Additional providers (Apple, Google) can be attached later without the client
  learning a second protocol — same uid, same document.
- The client holds one credential type (an Eva JWT), not Firebase ID tokens plus
  refresh-token lifecycle.

Consequences you must respect:

- `firestore.rules` denies everything (`allow read, write: if false`). That is
  **correct and deliberate** — only the Admin SDK, which bypasses rules, reaches
  Firestore. Do not open rules to "make the app work"; the app is not supposed to
  reach Firestore. See [GUARDRAILS.md](GUARDRAILS.md).
- The Admin SDK cannot verify a password, so `api/src/identity-toolkit.ts` calls the
  Identity Toolkit REST API (`accounts:signUp`, `accounts:signInWithPassword`,
  `accounts:signInWithIdp`, `accounts:signInWithCustomToken`) with the Firebase **web**
  API key. That file is the only user of that key, and the only thing that validates a
  credential.
- **Apple and Google go the same way (#7).** The app obtains a provider credential
  *natively* and sends it here; the API spends it at `accounts:signInWithIdp`. So the app
  still holds one credential type, still never speaks to Firebase, and the provider does
  not become a second protocol the client has to learn. The two things Firebase cannot do
  for us — Google's PKCE code exchange and Apple's token revocation — are the whole of
  `api/src/providers.ts`, which is the second outbound auth dependency and deliberately
  the last.

Full rationale: [`superpowers/specs/2026-07-18-email-auth-design.md`](superpowers/specs/2026-07-18-email-auth-design.md).

## 3. API module map (`api/src/`)

| File | Owns | Rule |
|---|---|---|
| `index.ts` | Routes, request validation, HTTP status/error mapping | No Firestore or `fetch` calls here — delegate |
| `auth.ts` | Minting and verifying the Eva JWT, `requireAuth` middleware | The only place `JWT_SECRET` is used. Takes the token version as an argument; never reads it, because it may not reach Firestore |
| `identity-toolkit.ts` | The Firebase Auth account: password and provider credentials verified via Google REST, delete via the Admin SDK, and which federated identities it holds — the Auth half of every served `User.authProviders` (#117, §4) | The only place the web API key is used; the only place an Auth user is deleted |
| `providers.ts` | The two calls that go to Apple and Google *directly*: Google's PKCE code exchange, Apple's client secret and token revocation | The only place `GOOGLE_IOS_CLIENT_ID` and the Apple keys are used; writes no log line |
| `rate-limit.ts` | In-memory attempt counters for `/auth/*`, and for `GET /me/export` (#58) | Holds no identity state; never logs its keys (addresses, IPs, uids) |
| `users.ts` | The `users/{uid}` document: read, create, update, bump the token version, mark deleted, delete, list IDs. Also `assertAccountLive`, the account read every subcollection writer makes inside its own transaction (#286), which also refuses a session a reset ended after the gate (#294) | The only module that touches `users/`. `bumpTokenVersion` carries the written-down rule for what ends a session (#76) |
| `events.ts` | The `users/{uid}/events/` subcollection: create, range read, edit, soft delete, restore, purge, delete-all, and the export's paged read of every entry (#58) | The only module that touches `events/`. Every write is a transaction that also reads the account (#286, §4) |
| `refdata.ts` | The `refdata/` collection: the option lists the client draws, and the version they are cached against. Also the source of a symptom code's reviewed label for the Today card's `{signal}`/`{symptom}` slots (#200) | The only module that touches `refdata/` |
| `content.ts` | The `content/` collection: the Dashboard's words — card templates, banners, nudges, and the signal vocabulary that fills `{signal}` (#200) — and the version they are cached against | The only module that touches `content/`; refuses a write carrying no reviewer |
| `dashboard-rules.ts` | The Today card's priority ladder (#96): a day's inputs in, the card's *subject* out — rung, template id, slot values, confidence wording class. Also the banner rail's selection (`selectBanners`, #102): the rows, the mode, the subject and a finished setup's focus areas in; up to three rows out, never padded | Pure: no Firestore, no clock, no `fetch`; every input is passed in. Holds no text and no clinical threshold. Called by D3's card module, never by `index.ts` |
| `today.ts` | The `users/{uid}/today/{date}` subcollection (#98): gathers the ladder's inputs, calls it, fills the template from `content.ts`, chooses the day's banner rail with the card (#102), caches both, pages them out for `GET /me/export` without the cache bookkeeping (#58), deletes them all. Also **the seam the cycle maths is read through** — `cycleEstimate` for the card, `cycleAnalysisFor` for the calendar (#205) | The only module that touches `today/`. The card's rung and template id come from the subject, never from a phraser. The cache write reads the account in its transaction (#286). Both cycle readers share one event window, one `CycleDay` mapping and one call to `analyzeCycles` |

| `cycle.ts` | The cycle maths (C11, #176): logged flow days in — the periods they group into (#186), counted cycles, the median next-period date, the fertile window, the FIGO irregularity band and the confidence class out | Pure: no Firestore, no clock, no `fetch`, no log line. Holds no constant of its own — every number arrives from `config.ts` and it refuses to answer without them. Every gate fails closed. The one reader of `periodEnd`, for one decision (§4) |
| `nutrition.ts` | The nutrition targets engine (S2, #222): body metrics, goal, target weight and focus areas in — the day's calorie target, the macronutrient split, the clamp that bound it and the timeline that follows out | Pure: no Firestore, no clock, no `fetch`, no log line, and **no import at all**. Holds no dose of its own — every number arrives from `config.ts` and it refuses to answer without them. Takes no cycle phase and no calendar mode, which is what keeps S12 outside it. Every clamp is a floor on calories, and the timeline is derived from the clamped target |
| `nutrition-profile.ts` | The `users/{uid}/nutrition/` subcollection (#221, S1 of #25): the Nutrition coach's setup answers — goal, focus areas, meal pattern, target weight, the hide-numbers preference — and the setup-progress marker; read, patch, delete-all. Also **the one definition of a finished setup**, `completedSetup` | The only module that touches `nutrition/`. The field list is exactly the setup answers — no disordered-eating field (#212), no score (S8). `complete` is derived on every read, never stored. The PATCH's transaction also reads the account (#286). Logs nothing |
| `email-tokens.ts` | The `authTokens/` collection: activation and reset tokens — issue, spend, expire, revoke | The only module that touches `authTokens/`; stores hashes, never a token; logs nothing |
| `email.ts` | Sending the two transactional messages, over Postmark's REST API | The only place `POSTMARK_API_KEY` is used; no address, link or token in a log line |
| `firebase.ts` | Admin SDK singleton (Application Default Credentials) | Never construct a second app |
| `config.ts` | Required env vars, fail-fast at boot | Every new env var is declared here **and** in `.env.example` |
| `data-export.ts` | The body of `GET /me/export` (#58): the account, the nutrition profile (#221) and two page generators in, one JSON document out as a stream | Pure leaf: no Firestore, no clock, no `fetch`, no log line; its imports are `import type`. Reads the first page of each collection before the route sends headers, and writes the closing brackets last, so a truncated body is never valid JSON |
| `request-timeout.ts` | The per-request timeout that names a hung request in the log before Bun's `idleTimeout` kills the connection (#225) | Pure leaf: wraps the handler in a timer, reads no clock and no Firestore. Logs only the route path — no payload, address or token |

Layering: `index.ts` → (`auth`, `identity-toolkit`, `providers`, `rate-limit`, `users`,
`events`, `refdata`, `content`, `today`, `nutrition-profile`, `email-tokens`, `email`) →
(`firebase`, `config`). Never call upward,
never sideways along the middle row.

**`today.ts` is the one sanctioned exception to "never sideways", and it is one by
construction.** A Today card is a *join* — the ladder's inputs come from `events.ts` and
`users.ts`, its words from `content.ts` — and the join has to live somewhere. Putting it in
`index.ts` would mean the route querying Firestore, which rule 10 exists to prevent; putting
it in `events.ts` would make the calendar's module own the Dashboard. So it reads the
owning modules through their public functions and never their collections: `today.ts`
touches exactly one collection, its own. The reads it needed that did not exist yet —
`lastEventChangeAt`, `lastLoggedDate`, `lastUserChangeAt`, and for the banner rail (#102)
`lastNutritionProfileChangeAt` beside `getNutritionProfile` — were added to the owning modules
rather than performed here, which is the test of whether the boundary held. The rail's one
read-side check on `content/` — an unsigned `banners` document yields no rail — is
`content.ts`'s `getSignedContent`, not a read of the document here.

**`events.ts` and `nutrition-profile.ts` call `users.ts` too, for one function (#286).** Each
writes under `users/{uid}/…` and must not write under an account `DELETE /me` has tombstoned,
and that question can only be asked of `users/{uid}` inside the writer's own transaction —
so the writer calls `assertAccountLive(tx, uid, session)` rather than reading `users/` itself
(GUARDRAILS 10). It is a downward edge onto the document every subcollection hangs from, not
a join: neither module reads anything else of `users.ts`, and `users.ts` imports neither.

`dashboard-rules.ts` is not in that middle row — it is a leaf *below* it. It imports nothing at
runtime, so it cannot call anything, upward or sideways; D3's card module calls it, fills the
template it names from `content.ts`, and caches the result. The one import it does carry is an
`import type` from `content.ts`, which `verbatimModuleSyntax` erases at compile time. That is
deliberate rather than convenient: sharing `Slot` instead of restating it is what makes "no
comparison to other users, no scores for the person, no streaks" structural, because the card's
slot vocabulary then has exactly one definition and a score cannot be introduced by editing a
Firestore document.

`cycle.ts` (C11, #176) is a leaf on the same terms, and shares vocabulary the same way: its
two imports are `import type`, one from `dashboard-rules.ts` for the `CycleEstimate` D1
consumes and one from `users.ts` for the `Profile` the age band is derived from. Neither exists
at runtime, so the maths still reaches nothing — the caller reads the flow entries and hands
them in, which is what makes "recomputed on every edit to a flow entry, never a nightly
batch" a property of the design rather than a job. Producing D1's shape rather than a parallel
one is the same mechanism as sharing `Slot`: the ≥3-cycle gate and the irregularity band have
exactly one definition, so the number the Today card speaks from cannot drift from the number
the calendar draws. `today.ts` carries two *value* imports from it. `CycleRulesUnsetError` is
re-exported so the route can map that refusal to a 503 rather than letting it fall through to
`app.onError` as a 500. `ageYearsOn` is re-exported for a different reason (#81): `parseProfile`
enforces the 18+ floor at the route edge and has to measure an age exactly as `bandForAge`
does, and a second implementation of that is not a theoretical drift — the spelling a route
would reach for disagrees with this one on 29 February. Both are downward calls to a leaf, the
same shape as `today.ts → dashboard-rules.ts`, and they cost nothing at runtime.

`nutrition.ts` (S2 of the Nutrition coach, #222) is a leaf on the same terms and one step
further: it imports **nothing at all**, so it shares no vocabulary with anything and cannot
reach anything. That is deliberate in one place in particular — it does not take `Profile`.
It declares `ActivityBand` as a closed four-member union, and the factor table is a `Record`
over that union, so a band without a factor is a compile error rather than a plausible 1.2.
Since #221 that union is also the profile's: `users.ts` re-exports the engine's own array as
`ACTIVITY_BAND_CODES` (a downward value import from a leaf with no imports, free at runtime),
`parseProfile` refuses anything outside it, and `Profile.lifestyle` is `ActivityBand | null` —
so there is one list of bands in the codebase, and a `null` the caller has to narrow away
(nutrition setup asks) before the engine can be called at all. `nutrition-profile.ts` imports
the engine's goal types the same way, `import type` only, so a stored goal is handed to
`planDailyTargets` untranslated. The other thing its
signature carries is the whole of "cycle-agnostic": there is no cycle phase and no calendar
mode among its arguments, so S12's luteal and mode adjustments wrap it rather than reaching
inside it, and cannot arrive later as an optional parameter with a default.

`data-export.ts` (`GET /me/export`, #58) is a leaf below the middle row too: `index.ts` hands
it the account the gate read, the nutrition profile `nutrition-profile.ts` reads
(`getNutritionProfile`, #221), and the two page generators `events.ts` and `today.ts` export,
and it turns them into a byte stream. Its four imports are `import type`, so it can reach
no collection — which is what keeps "each collection is read only by its owner" true of the
one route that reads all of them.

**There are two imports that point the other way**, and they are worth stating because the
rule above forbids it in general: `config.ts` imports `cycleRulesProblem` from `cycle.ts` and
`nutritionRulesProblem` from `nutrition.ts`. Those constants decide whether a fertile window is
drawn at all, and how much a woman is told to eat, and each set is checked twice — at boot, so
an operator is told at startup, and on every evaluation, so a set assembled in code cannot get
past it. Two copies of those checks is the drift the single import exists to prevent. Both are
free at runtime for the reason above: `cycle.ts` loads nothing and `nutrition.ts` imports
nothing.

### Contracts

Errors are always `{ "error": { "code": string, "message": string } }`. `code` is a
stable machine identifier (`VALIDATION`, `EMAIL_EXISTS`, `INVALID_CREDENTIALS`,
`UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`, `BACKDATE_LIMIT_EXCEEDED`,
`UNKNOWN_SYMPTOM_CODE`, `WEAK_PASSWORD`, `RATE_LIMITED`, `SERVICE_UNAVAILABLE`,
`DAY_ALREADY_LOGGED`, `NOT_ACTIVATED`, `INVALID_TOKEN`, `TOKEN_EXPIRED`,
`PROVIDER_ALREADY_LINKED`, `CONSENT_REQUIRED`, `INTERNAL`);
`message` is human-facing and may be shown in the app. Changing a code is a breaking
change for the iOS client.

**"Always" is now literal (#53).** Two answers used to escape the shape, and neither
reached `app.onError`: a thrown value that is not an `Error`, which Hono rethrows at the
runtime, and an unmatched path, which is a miss rather than a throw. A wildcard middleware
registered ahead of every route re-throws non-`Error`s as `Error`s — recording the thrown
value's *type* and never the value, because a thrown object could be a payload — and
`app.notFound` answers `404 NOT_FOUND` as JSON. So every response the API can produce now
carries the shape above, including the ones nobody wrote a handler for.

**Every response is `Cache-Control: no-store` unless its route says otherwise (#280).** A
response with no `Cache-Control` may be stored heuristically by any client or intermediary,
and most of what this API answers is a session token, an account or health data. So
`noStoreByDefault`, registered ahead of everything — outside #53's `wrapNonErrors`, so a thrown
value of any kind reaches it as an answered response rather than skipping it — sets the
header on every response that has none: success, refusal, `404` for an unmatched path. Two
rules around it: a route's own `Cache-Control` stands (`/content` and `/refdata` send
`private, no-cache` with an `ETag`, and their `304` handshake depends on it), and a response
`app.onError` built is `no-store` regardless of what the route had set before it threw. It
replaced the per-route `noStore` on the two link routes, which set its header after the
handler and so skipped it for a non-`Error` throw. `GET /me/export` still names `no-store`
itself, which the default leaves alone.

| Route | Auth | Success |
|---|---|---|
| `GET /health` | — | `{ status: "ok" }` |
| `POST /auth/signup` | — | `201 { pending: true, email }` — no session; an activation link is sent |
| `POST /auth/signin` | — | `200 { token, user }`; `403 NOT_ACTIVATED` until the address is confirmed |
| `POST /auth/activate` | Token in the link | `{ activated: true }` — token in the body, never a query string |
| `POST /auth/activation/resend` | — | `{ sent: true }`, always |
| `POST /auth/password/forgot` | — | `{ sent: true }`, always |
| `POST /auth/password/reset` | Token in the link | `200 { token, user }` — sets the password and signs in |
| `POST /auth/idp` | — | `200 { token, user }` — Apple or Google; signs up and signs in at once, already activated |
| `GET /me` | Bearer | `{ user }` |
| `GET /me/export` | Bearer | `200` JSON attachment `eva-export-YYYY-MM-DD.json` (UTC), `Cache-Control: no-store`, streamed: `{ format: "eva-export", version: 2, exportedAt, account, nutritionProfile, events, today }` — `account` is `GET /me`'s `user`, `nutritionProfile` is `GET /me/nutrition/profile`'s `nutritionProfile` or `null` before setup is started (#221), `events` every stored entry in `GET /me/events`' shape **including soft-deleted ones** (`deletedAt` set), `today` every stored card in `GET /me/today`'s shape (#58). `429 RATE_LIMITED` per account and per IP. §4 "Data export" lists what is left out |
| `POST /me/auth/providers` | Bearer | `{ user }` — attaches a provider to *this* account; `409 PROVIDER_ALREADY_LINKED` when its `sub` belongs to another |
| `DELETE /me` | Bearer | `{ deleted: true }` — the account and all of its data, immediately; an optional `appleAuthorizationCode` also revokes the Apple token. `429 RATE_LIMITED` past `RATE_LIMIT_DELETE_PER_ACCOUNT` calls for one account in a window (#119) |
| `PUT /me/questionnaire` | Bearer | `{ user }` — behind `requireCollectConsent` (#86): the profile is health data, and nothing about her is written before the collect consent exists |
| `GET /me/nutrition/profile` | Bearer | `{ nutritionProfile }` — the Nutrition coach's setup answers and progress (#221), with a derived `complete` flag; `404 NOT_FOUND` until setup is started |
| `PATCH /me/nutrition/profile` | Bearer | `{ nutritionProfile }` — any subset of `goal`, `focusAreas`, `mealPattern`, `targetWeightKg`, `hideNumbers`, `step`; an absent key is left as it was. Creates the document on the first write. `400 VALIDATION` for an unknown key, a fourth focus area (refused, never truncated), `step: "done"` with a required answer missing, or a target weight for a goal that has none; behind `requireCollectConsent` (#86) |
| `POST /me/profile-nudge/dismiss` | Bearer | `{ user }` — marks the "complete your profile" nudge dismissed (#19); server-side, survives reinstall |
| `PUT /me/consent/{kind}` | Bearer | `{ user }` — records or withdraws one consent (#86). `kind` is `collect` or `share`; `{ granted: true, version }` records the consent with the version of the text the client showed, `{ granted: false }` withdraws — the freeze: the record keeps its version and `at`, and gains `withdrawnAt`. `share` governs nothing today; it is recorded because the screen offers it. Withdrawing a never-granted consent is a no-op |
| `GET /me/events?from=&to=` | Bearer | `{ events }` — inclusive `localDate` range, soft-deleted excluded |
| `POST /me/events` | Bearer | `201 { event }` — behind `requireCollectConsent` (#86) |
| `PATCH /me/events/{id}` | Bearer | `{ event }` — body must carry `type` and `localDate`; behind `requireCollectConsent` (#86) |
| `DELETE /me/events/{id}` | Bearer | `{ deleted: true }` — soft delete; deliberately not consent-gated: deleting is collection's opposite |
| `POST /me/events/{id}/restore` | Bearer | `{ event }` — undo a soft delete, within 30 days and while the entry has not been superseded (`409 DAY_ALREADY_LOGGED`); behind `requireCollectConsent` (#86) |
| `PUT /me/body-signals/{date}` | Bearer | `{ event }` — upsert by day; behind `requireCollectConsent` (#86) |
| `GET /me/cycle/predictions?from=&to=&timeZone=` | Bearer | `{ from, to, predictedPeriod, fertileWindow, peak, confidence, withheld }` — the calendar's overlay for a range (#205). Three lists of `localDate`s, clipped to the range; `confidence` is C11's own `wide`/`narrow` band, `null` when nothing is predicted, and `withheld` then names the gate that closed (`no-flow-logged`, `too-few-counted-cycles`, `irregular-cycles`, `uncountable-cycle`). The last two are deliberately separate (#190): the first says her cycles vary, the second says one interval in the window fell outside the countable range — a fact about a log, not about her — and answering the first for the second told a woman with a single missed period start something false for six cycles. Range validated and capped exactly as `/me/events` is, with the same `VALIDATION` code. `503 SERVICE_UNAVAILABLE` while the cycle maths' constants are unconfigured (#176) |
| `GET /me/today?timeZone=` | Bearer | `{ date, generatedAt, contentVersion, card, banners }` — the day's card, and its "Worth reading" rail (#102): `banners` is `[{ id, title, meta, url }]`, zero to three items in display order, always present (empty rather than absent), stored with the card and stable across the day; `url` is always an absolute `https://` article. `timeZone` decides which local day, optional with the same UTC fallback events use. `503 SERVICE_UNAVAILABLE` while the pattern rung is unconfigured (#26), the cycle maths' constants are unconfigured (#176), or `content/` is unseeded (#97) |
| `GET /refdata?version=` | Bearer | `{ version, catalogues }` — `304` when `version` (or `If-None-Match`) already matches |
| `GET /content?version=` | Bearer | `{ version, templates, banners, nudges }` — same `304` handshake |

**Health writes sit behind the collect consent (#86, A21).** `requireCollectConsent`
guards the routes that create or change health data — events (write, patch, restore),
body signals, the questionnaire, and the nutrition profile (#221) — and answers `403 CONSENT_REQUIRED` for both shapes
of "no": no record (every pre-#86 account, every new account until the screen is
through) and a withdrawn record (the freeze). Reads, deletes and preference-only writes
(the profile nudge) stay open, because collecting is what needs
consent and nothing else does. The client tells the two shapes apart from `GET /me`'s
`consent` record, not from the error — the remedy is the same screen either way, or
Settings › Privacy when it is a withdrawal, which the app deliberately does not re-ask
as a gate.

**Sign-up hands out no session (#6).** The account exists after `201`, but the address is
not proven, and `POST /auth/signin` refuses it with `403 NOT_ACTIVATED` until it is. The
`user` object carries `activated: boolean` for the client to route on. Where that gate sits
is the design: **after** Identity Toolkit has verified the password, so the only caller who
can ever see the 403 already knows it — answering earlier would tell anyone holding an
address that an Eva account stands behind it. `api/test/auth.test.ts` pins the ordering by
comparing the bytes of an unconfirmed account's wrong-password 401 with an unknown
address's.

`users/{uid}.activatedAt` is `null` from creation and a timestamp after. **Absent means
activated**: every document written before #6 has no such field, and those accounts signed
in on a password alone for months.

**The links, and who owns them.** Eva issues its own tokens rather than using Firebase's
action emails: a reset link has to be revocable (asking for a new one kills the old) and
the page it lands on is ours. A token is 32 random bytes, handed out once as base64url and
stored only as its SHA-256 under `authTokens/{hash}` — a leaked read of that collection
opens nothing. Single-use, spent in a transaction, activation 24h, reset 60min.

**A token never appears in a URL a server can see.** Links point at the website with the
token in the **fragment** — `${PUBLIC_WEB_URL}/activate#token=…`, `/reset#token=…` — which
browsers do not transmit, so it is in no Hosting access log and no `Referer`. The page
reads it from `location.hash`, scrubs it, and sends it in a **POST body**; there is no
`GET /auth/activate?token=`, because Cloud Run's request log records the query string and
a reset token is a live account credential for an hour. Hash-only storage is not worth
much with the raw token sitting in two retained log streams. Both routes answer
`Cache-Control: no-store` and carry a per-IP throttle.

One consequence to know before changing those pages: the confirm call has to stay
client-side. Mail-security scanners fetch the emailed URL before the person does and do not
run JavaScript, so today the token survives the scan. Server-rendering `/activate` would
let a scanner spend the link and hand the user a dead one.

Only reset tokens are revoked on reissue. Asking for a second activation link leaves the
first alive, deliberately: someone who presses Resend and then clicks the older email
should still get in, whereas a reset link left live in an old inbox is a standing
credential.

`/auth/activation/resend` and `/auth/password/forgot` answer `200 { sent: true }` for every
well-formed address, registered or not — the sign-in property above, extended to the two
routes that would otherwise give it away for free. Both are throttled to one attempt per
address per `RATE_LIMIT_RESEND_PER_EMAIL_SECONDS` (60), on separate counters, and the
throttled answer is byte-identical across both branches, refused and served alike.

Timing had to be closed too, and was not free. A registered address costs a Firestore
write and a POST to Postmark; an unknown one costs a failed Auth lookup — hundreds of
milliseconds against tens, readable from one request rather than by statistics. Both
branches are held to a fixed floor (`SEND_LINK_FLOOR_MS`, 800ms) above the slow one. That
is a floor, not a constant: a Postmark call slower than it still overruns, so the residue
is bounded by Postmark's variance rather than by the difference between doing the work and
skipping it. Answering before the send would be exact, but Cloud Run throttles CPU after
the response and the mail would then go out whenever the next request happened to arrive.

`POST /auth/password/reset` mints a session, because the user has just proven control of
the address and chosen a password, which is more than a sign-in asks for. It also stamps
`activatedAt`: a reset proves the address as surely as the activation link does. The
password rule is checked **before** the token is spent, so a weak password costs a retry,
not the link.

**CORS is on exactly two routes** — `/auth/activate` and `/auth/password/reset`, the ones
the website's link pages call from the browser — for exactly `PUBLIC_WEB_URL`'s origin.
Never `*`: an allowed origin is a page that can spend a token it was handed.

**Password rule — where the password is set, which is no longer sign-up.** Since #120 the
rule is enforced by `POST /auth/activate` and `POST /auth/password/reset`: *at least 8
characters, including one number*. A password that fails it is `400 WEAK_PASSWORD`, and the
`message` **is** the helper text the page states verbatim, so the user is never told two
different rules. The server's copy of the string lives in `api/src/index.ts` and the
client's in `website/src/pages/activate.astro` — not in the iOS app, which has no password
field any more; `api/test/auth.test.ts` reads the Astro page and asserts they still match.
Both routes check the rule **before** spending the token, so a weak password costs a retry
rather than the only link. `POST /auth/signin` **never** applies the rule — accounts that
predate it hold passwords with no digit and must keep working.

**Sign-in answers identically whether the password was wrong or the address was never
registered** — same status, same code, same message. This is deliberate: knowing that an
address has an Eva account is itself sensitive. Note the property currently rests on two
layers, ours and Identity Toolkit's own collapse of both cases upstream, so a regression in
ours would not be visible from outside. `api/test/signin-non-enumeration.test.ts` pins it by
controlling the upstream boundary.

**And identically in time (#34), which it did not used to.** Byte-identical was never
time-identical: Identity Toolkit refuses an address it has no record of without verifying a
password hash, and the difference is measurable from outside. Measured against the real
project, one fresh address per sample so neither branch is competing with the upstream's own
per-identifier throttle:

| branch | p50 | p95 |
|---|---|---|
| registered, wrong password | 196.5ms | 277.3ms |
| never registered | 166.9ms | 265.3ms |
| **difference** | **mean 21.3ms** | **median 29.6ms, z = 3.01** |

Samples alternate between the branches within each iteration, so drift across the run —
cold TLS, a warming Cloud Run instance — lands on both rather than on one. What is not
controlled is account age: the registered addresses are created immediately before they are
sampled, so this is "just-created account" against "never existed".

A two-sample test needs about 35 samples per branch for 80% power at α=0.05 (pooled sd
31.65, Cohen's *d* = 0.673). An attacker does not need one: both reference distributions
are buildable for free from addresses they own, so classifying a *target* is a one-sample
question, and at ten samples its mean already sits 2.1 standard errors from the reference.
Ten is exactly `RATE_LIMIT_SIGNIN_PER_EMAIL`, so that read fit inside the free-attempt
budget at no wait at all — which is to say the throttle, not the floor, was what bounded
this before, and it bounded it at one usable read per address per cycle rather than none.

So the channel is real, and `/auth/signin` now answers no sooner than `SIGNIN_FLOOR_MS`
(350ms) whichever branch it took. It costs the person the route exists for nothing: a
*successful* sign-in additionally reads and writes `users/{uid}` and mints a token, which
measured min 464.9ms and p50 866.2ms — already past the floor. Someone who mistyped their
password waits an extra tenth of a second on a request that was going to fail.

Three things about that, stated rather than discovered later:

- **A floor, and not the "do the same work on both branches" #34 asked for first.** That
  remedy is the right one in general and loses here on cost, not on principle. The differing
  work is not ours — the ~21ms is Identity Toolkit verifying a password hash — so the only
  way to make the unknown branch do it is a *second* upstream call against an address known
  to exist, with any password: the verification happens either way. Two constructions, both
  priced against the same measurements:

  Sent **after** the real call, the decoy costs what the real one costs (p50 ~175ms), so it
  does not equalise the branches, it inverts them. Sent **concurrently**, the wall clock is
  `max(real, decoy)` — no inversion and no added latency, which is the strongest form of the
  idea and the one worth beating properly.

  Both fail on the same two things. Every sign-in would make **two** Identity Toolkit
  requests, forever, on the API's busiest auth route — double the upstream bill for a
  21ms channel. And Identity Toolkit throttles per identifier at around six attempts, so a
  single decoy address is throttled almost immediately and its latency stops resembling the
  real branch's under exactly the load where equalisation matters most. The concurrent form
  does not even win on security: a `max()` leaves the real branch's signal in the tail
  whenever it is the slower draw, where the floor truncates it to nothing below 350ms. It
  would also mean a permanent production Auth user whose only purpose is timing padding —
  a human decision, though not a secret one: the decoy needs an identifier, not a password.

  A floor buys a strictly better residual for one `setTimeout` and no upstream call.
- **It is a floor, not a constant delay.** When the upstream is slower than the floor
  nothing is added, and the residue is the upstream's own variance rather than the
  difference between doing the work and not doing it. Under enough load to push both
  branches past 350ms the channel comes back — load an attacker can also induce, though the
  variance they add costs them more signal than it uncovers. 350ms is 1.26× the slower
  branch's measured p95, which is margin rather than comfort, and the 465ms upper bound it
  sits under is a minimum of thirty samples, the noisiest statistic in the set. Both are
  the numbers available; neither is a guarantee. It also assumes Cloud Run concurrency
  above 1: at `--concurrency 1` a 350ms floor is a per-request instance lock, and
  `deploy-api.yml` sets no concurrency today.
- **Every failed sign-in now holds a request slot about twice as long** — ~350ms against
  the ~180ms it measured. That is the same held-connection cost the `429` carve-out below
  refuses to pay, accepted here because the number of unthrottled failures is what `#5`
  and `#37` bound.
- **The throttle's own answers are outside the floor.** A `400 VALIDATION` and a
  `429 RATE_LIMITED` return immediately. Neither depends on whether the address has an
  account — the budget is spent on arrival, keyed by the *submitted* address, before
  Identity Toolkit is asked anything — so a `429` is a function of the caller's own history,
  which they already know. Padding a refusal would buy nothing and would make every refused
  attempt cost a held connection.
- **How much it was worth, without flattering the fix.** `POST /auth/signup` also discloses
  registration, as `409` against `201` — which the paragraph below argues for on its own
  terms. But it answers the *narrower* question, whether an address is **activated**
  (`existing.user?.activated`), where the clock answered whether any Identity Toolkit record
  exists at all; and it answers **loudly**, because the `201` branch mails the address it
  was asked about, so bulk enumeration through signup is visible to its victims. The timing
  channel was silent, and a usable read of one address fit inside the free-attempt budget
  (above) rather than costing the ~5 hours a full two-sample test would under #37's backoff.
  So this was worth closing on its own, not merely because it was cheap to close.

`POST /auth/signup` deliberately does the **opposite** and returns `EMAIL_EXISTS` — the
caller already holds the address, and the canvas' account-linking banner depends on knowing.
The asymmetry is intended; do not "fix" it.

**Every Identity Toolkit failure is mapped (#32).** `identity-toolkit.ts` reduces whatever
Google said to one of three kinds and `index.ts` maps the kind — never the reason — onto
the contract:

| Upstream | Kind | `/auth/signup` | `/auth/signin` |
|---|---|---|---|
| `EMAIL_EXISTS` | `email-exists` | `409 EMAIL_EXISTS` | `401 INVALID_CREDENTIALS` (unreachable) |
| any other 4xx (`INVALID_EMAIL`, `INVALID_LOGIN_CREDENTIALS`, an unrecognised reason) | `rejected` | `400 VALIDATION` | `401 INVALID_CREDENTIALS` |
| 5xx, 429, `TOO_MANY_ATTEMPTS_TRY_LATER`, `QUOTA_EXCEEDED`, `OPERATION_NOT_ALLOWED`, `ADMIN_ONLY_OPERATION`, a network failure, a non-JSON body | `unavailable` | `503 SERVICE_UNAVAILABLE` + constant `Retry-After: 30` | same |

The status decides before the reason does, so a 5xx whose body claims something about the
address cannot be read as a verdict about the caller. Sign-in has **no 400 branch on
purpose**: "that address is malformed" would answer exactly the question its 401 refuses to.
The 503 branch is chosen from the upstream status, which does not vary with the address, and
`Retry-After` is a constant for the same reason the throttle's is (§3 above) — a per-caller
value in a header is a channel.

The reason string never leaves `IdentityToolkitError`: not into a body, a header, or a log
line (GUARDRAILS 12), and the failing `fetch`'s own error is dropped rather than attached,
because its message contains the request URL and that URL carries the web API key.

*How an operator tells an outage from a bug:* `unavailable` is the one branch that logs —
one line, `{"event":"identity_toolkit_unavailable","route","upstreamStatus"}`, carrying no
address and no reason. So a `503` plus that line means Google did not answer us, and a
`500 INTERNAL` from an auth route means anything else failed — Firestore, or a bug of ours
— because every upstream failure is mapped. Alert on the event name; `upstreamStatus: null`
distinguishes "never landed" from "answered badly". `rejected` deliberately logs nothing —
a wrong password per line is a log full of nothing.

**Apple and Google (#7).** Two routes, one mechanism.

| Route | Body | Answers |
|---|---|---|
| `POST /auth/idp` | `{ provider: "apple", identityToken, rawNonce }` or `{ provider: "google", code, codeVerifier, redirectUri }` | `200 { token, user }` — the same shape `/auth/signin` returns |
| `POST /me/auth/providers` | the same two shapes, with a bearer token | `200 { user }`, with the provider in `user.authProviders` — read back from Auth (#117, §4) |

Apple is native: the app already holds an `identityToken`, and it sends the **raw** nonce it
hashed into its `ASAuthorization` request. That nonce is forwarded to `signInWithIdp`, where
Firebase hashes it and compares — which is the whole of what stops a captured
`identityToken` being replayed at this route by somebody else. Google is PKCE against a
*public* iOS OAuth client: the app returns an authorization code, `providers.ts` exchanges it
at `https://oauth2.googleapis.com/token` with the code verifier and **no client secret**
(an iOS client has none), takes the `id_token` out, and that is what gets spent. Doing the
exchange server-side is what keeps the GoogleSignIn SDK and its transitive packages out of
the app (GUARDRAILS 25).

**The account is whichever uid Firebase returns, and this code never looks up an address.**
`signInWithIdp` hands back the uid Firebase keyed to the provider's `sub`; `ensureUser` lands
on that `users/{uid}` document and `arrayUnion`s the provider. Whether a shared address
resolves to one account or two is a **console setting** — `Authentication → Settings → User
account linking`, set to *"Link accounts that use the same email"* (decided 2026-09-03) — and
it is decided before this code sees anything. So a Google sign-in on an address that already
has a password account logs into that account, which is what the PRD's edge case always
asked for. The rule lives in one place; a second copy here is how two copies come to
disagree, invisibly.

**Hide My Email is the case that setting cannot help.** Apple's relay address matches
nothing, so those users get a new account regardless. `POST /me/auth/providers` — deliberate,
authenticated, from Profile — is their only route into an existing one, which is why it is
not optional.

**A 200 from `signInWithIdp` is not always a sign-in, and there is more than one of them.**
Identity Toolkit has several outcomes that are refusals wearing a success status, each
carrying **somebody else's `localId`**:

- `needConfirmation` — the `sub` is linked to nothing, an account already holds the address
  the credential asserts, and the credential's own `email_verified` is falsy. What the
  Firebase JS SDK surfaces as `account-exists-with-different-credential`.
- `emailRecycled` — the address matches an account that already holds an entry for *this
  same provider under a different `sub`*. The provider reassigned the address; a workplace
  mailbox given to a new employee is the ordinary way it happens. Firebase merges anyway,
  hands back the previous owner's uid, **and issues a token** — this one is a full sign-in
  as far as the wire is concerned, which is why it needs a named check rather than the
  backstop below.
- an MFA challenge — `mfaPendingCredential` and no token. Not reachable today because MFA is
  off on the project, and one console switch from being reachable silently.

These were found one at a time, in consecutive reviews of #7, which is the argument against
enumerating them: the list belongs to Google. So `identity-toolkit.ts` names the two it
knows and then requires `idToken` to be present on any sign-in response — every request sets
`returnSecureToken: true`, so its absence catches the shapes that have not been met yet, the
MFA challenge being the one that is known to exist. The backstop is *not* sufficient on its
own: `emailRecycled` carries a token. Both mechanisms are needed, and they run in **both**
transports — `call`, which serves sign-up and password sign-in, and `signInWithIdp`. An
earlier version guarded only the provider route while this section claimed it guarded every
sign-in, which left the password path — the one with more users — open.

Reading past any of them hands the caller a 30-day session on an account they have never
authenticated to, and — because an activated account skips the claim entirely — with nothing
downstream to catch it.

### Sign-up creates nothing; activation creates everything (#120)

**The invariant: a password only works if the person who set it proved the address.**

`POST /auth/signup` takes an address and nothing else. It creates no Firebase Auth user, no
`users/{uid}` document and no credential — it issues an activation token and sends a link.
`POST /auth/activate` takes that token **and a password**, and does both halves in one
request: the link proves the address, the form supplies the credential, and only then does
the account come into existence.

Before this, sign-up created the Auth user with the caller's password. That reserved the
address for whoever asked first and put a working credential on it before anyone had proved
it was theirs. An attacker signed up as a victim; the victim clicked the confirmation mail
they never asked for; the attacker's password then opened an activated account holding the
victim's cycle and symptom history. Everything §3 describes above — the claim, the address
test, the retraction at activation, the withheld `emailVerified` — was a way of living with
that rather than removing it.

Three consequences worth stating, because each reads as a regression until you see why:

- **`403 NOT_ACTIVATED` is unreachable through the normal flow.** There is no password to try
  before activation. The gate still exists and still matters, for accounts predating #120 and
  for addresses reserved by calling Identity Toolkit directly.
- **A valid activation link on an *already activated* account is a dead link**, where it used
  to answer `200` idempotently. That was right while activation only stamped a flag. The link
  sets a password now, so honouring a stale one would make every activation email anybody
  ever saw a password-reset primitive.
- **Activation sets `emailVerified` again.** Withholding it was the subtlest decision in #7 —
  a true fact suppressed so Firebase's merge-wipe would stay armed against a pre-registering
  attacker's password. There is no such password any more: the only credential an account can
  have at activation is the one supplied in that same request by whoever proved the address.

**What this does not close.** The Firebase web API key is public, so anyone can call
`accounts:signUp` at Identity Toolkit directly and reserve an address. That is denial of
service, not takeover — Eva never emails the victim, so the victim never activates — and
activation handles it: an Auth account nobody has proved is *claimed* by the holder of a
valid link rather than refusing them. Disabling public sign-up in the console would close
even that, and must not be done: it returns `ADMIN_ONLY_OPERATION` for **federated** account
creation too, so every first-time Apple and Google user would fail.

**Auto-linking is only safe because `/auth/idp` claims an unproven account.** Sign-up (#6)
creates the Firebase Auth user *before* the address is confirmed, and **the web API key is
public** — Firebase Hosting serves it at `/__/firebase/init.json`, and Identity Toolkit
accepts it. So anyone who pre-registers an address is a first-class client for that account
and can, without touching Eva: sign in at Identity Toolkit with the password they chose,
attach *their own* Apple identity to the account with the ID token that returns, and wait.
When the real owner signs in with Google, Firebase merges onto the same uid and Eva marks
it activated on their behalf — and the attacker signs in with Apple from then on.

Overwriting the password does not stop that; the attacker never uses it again. So
`claimUnprovenAccount` (`identity-toolkit.ts`) takes **everything**: it overwrites the
password, unlinks every *federated* identity except the one that just signed in, and
revokes outstanding refresh tokens. The password is overwritten rather than unlinked, both
because an account with no password provider has nothing for forgot-password to reset and
because Firebase will not accept "set this password" and "remove the password provider" in
one call. It asks `adminAuth.getUser` rather than `users/{uid}` — Eva's stored
`authProviders` is not a record of Auth's identities (§4), and sign-up writes the Auth user
before the document, so a failure between the two leaves an account the document cannot
see.

**Unlinking closes only one of the two orderings, so the address is checked as well.** The
paragraph above assumes the *victim* reaches `/auth/idp` first. Nothing makes them: the
attacker knows when they pre-registered, and can simply sign in here themselves as soon as
their identity is attached. Then nothing is stripped — `password` and their own `apple.com`
are both kept — and the account is marked activated, which disarms the claim permanently, so
the victim's later Google sign-in merges onto an account the attacker holds.

What separates the two orderings is the address. Firebase merged the victim's provider into
the account *because* the provider's own address equals the account's; an identity attached
out of band has no such equality and cannot manufacture one without controlling the address,
at which point they are the owner. So on an account **nobody has proved the address of** —
`emailVerified` false — the provider signing in must carry that account's address.

The trigger is `emailVerified`, not "does it have a password", because it has to be a fact
the attacker cannot move. A password entry is not one: Identity Toolkit derives it from
`email && passwordHash`, an idToken holder adds and drops credentials on their own account,
and the claim's own write sets a password. It also missed a takeover outright — an attacker
can create a federated-only account with their own Apple `sub`, then point its address at a
victim who has not signed up yet, so no password is ever attached and a password-shaped
trigger skips the test entirely. `emailVerified` is admin-only on `accounts:update`, and
changing an address forces it false. Otherwise `claimUnprovenAccount` returns `refused`, the route answers
`401 INVALID_CREDENTIALS`, and crucially **does not activate**: the stamp is what would make
the takeover permanent. It fails closed on a missing provider address, and only in that
branch, so Apple's Hide My Email relay — which creates a fresh account with no password — is
never affected. The function also re-reads the account after writing it, so the loser of a
race between two concurrent claims is refused rather than handed a session for an account
that no longer carries its identity.

**The claim runs before anything is written.** `/auth/idp` reads the account document
rather than calling `ensureUser` first, because `ensureUser` writes: it unions the provider
into the stored `authProviders`. Calling it ahead of the gate meant a credential the route
was about to refuse still left its provider on the account it collided with, permanently,
and where the app could see it — Profile reads `authProviders` to decide whether to offer
"Connect Apple". The write happens once the claim has returned `claimed`, and `ensureUser`'s
own tombstone check closes the window between the read and it.

Since #117 the served list takes Apple and Google from Auth (§4), where a refused
identity *does* stay linked — Firebase linked it before Eva saw the request. It still never
reaches the owner: a refusal mints nothing and leaves the account unactivated, and every
path to a session on an unactivated account — activation (`claimForActivation`), a reset,
a successful claim — unlinks federated identities first.

**Proving the address retracts what was attached while it was not.** The claim above guards
`/auth/idp` and is gated on `activatedAt` — but the activation link and a password reset also
stamp `activatedAt`, and for four review rounds they stamped it and nothing else. So the
takeover survived by waiting: reserve the address, attach a provider identity out of band,
be refused at `/auth/idp`, and then sign in the moment the real owner activates or recovers.
`retractUnprovenIdentities` (`identity-toolkit.ts`) runs on that transition — and only on the transition,
so a provider linked deliberately from Profile survives a later password reset. It runs
**before** `activatedAt` is stamped, not after: the stamp is what disarms the claim gate, so
retracting afterwards leaves a window in which `/auth/idp` skips the claim and mints a
30-day session nothing can revoke, and leaves a failed retraction permanently unrepeatable
because the transition has already been spent. Retract first and every failure leaves the
account unactivated with the gate still armed. `retractUnprovenIdentities` unlinks every
federated identity and revokes outstanding refresh tokens.

**The merge behavior is observed, not inferred.** Against the Auth emulator's real
`accounts:signInWithIdp` implementation, a verified provider credential for an address held
by an unverified password account resolves to that existing uid, sets `emailVerified`,
links the provider and removes the password. The CI test uses the emulator's documented
fake provider token format and then proves the old password no longer signs in. Once the
account is already verified, that wipe does not run. This is why manufacturing
`emailVerified: true` on a moved address changes the outcome from self-healing to takeover.

**#120 changed what activation proves.** Sign-up now creates no account and no password;
activation takes the link and the new password together. Both activation and reset therefore
call `markCredentialsProven`, after `markActivated`, because in both cases the link holder
both proved the address and chose the only password the account can hold.

**The address in that proof is the link's address, not merely the token's uid (#140).** A
reset token carries both. Before changing a credential, `/auth/password/reset` compares its
address with the account's current Auth address and treats a mismatch as a dead link. Eva
has no address-change route, so the legitimate recovery is to request a fresh reset for the
current address. The issue expected that comparison to reuse values already in hand, but the
route had no current-Auth-address read; this adds one authoritative lookup before the
password change. Moving it after that change would detect the mismatch only after damage.
The final proof write in both activation and reset sets the link's address and
`emailVerified` together. That closes the smaller race after resolution: if an idToken
holder moved the account first, the write restores the address that was actually proved; if
the move lands later, Identity Toolkit clears `emailVerified` again.

It fires on `activatedAt` being null and nothing else. No legitimate flow puts a second
provider on an unactivated account: Eva's link route is behind `requireAuth`, and an
unactivated account cannot sign in to obtain a token. A confirmed address has already
proven its credentials belong to its owner, so nothing is taken there — invalidating an
activated account would lock a real user out for adding Apple to it.

The route **fails closed**: the throw is not a provider failure, so it reaches
`app.onError` as `500 INTERNAL` and no token is minted. Continuing would hand out a session
for an account still carrying credentials we meant to take away. The cost is that a real
user who never clicked their activation link and then used Google must reset a password
they did own — nothing can distinguish them from the attacker, and forgot-password is the
flow they needed anyway.

**A provider session comes back activated.** Google's address is verified and Apple's relay
is Apple's own, so a provider sign-in proves the address at least as well as the link #6
emails — and without the stamp every Apple user would meet `403 NOT_ACTIVATED` and we would
mail a confirmation link to a relay address to prove what Apple already proved.

**No display name is stored, and `users/{uid}` does not change.** Apple offers a name on
first authorization; Eva shows a name nowhere, so collecting it would be personal data kept
for no purpose. It is dropped where it arrives.

**Linking goes through Firebase rather than around it.** The Admin SDK mints a custom token
for the signed-in uid, `signInWithCustomToken` exchanges it for a Firebase ID token, and
`signInWithIdp` links against that. The one-call alternative,
`adminAuth.updateUser(uid, { providerToLink })`, takes a `sub` we would have had to verify
ourselves — Apple's and Google's JWKS, `iss`, `aud`, `exp` and the nonce, and the rotation of
both — so this keeps Firebase the only validator of a provider token, which is the same
choice §2 makes for passwords. It has one operational requirement: `createCustomToken` needs
Admin credentials that can sign, so the Cloud Run runtime service account needs
`roles/iam.serviceAccountTokenCreator` **on itself**. Until that is granted this route is the
only thing that fails.

A `sub` already attached to a different account is `409 PROVIDER_ALREADY_LINKED`, never a
silent merge. Adding that code is additive; it is the only new one #7 introduces.

**`DELETE /me` revokes the Apple token.** Apple requires it of any app offering Sign in with
Apple *and* in-app account deletion, and App Review rejects on it. Eva does **not** store an
Apple refresh token: a long-lived third-party credential in a health app's user document is
worse than what it buys, and it would be a `users/{uid}` schema change. Instead `DELETE /me`
accepts an **optional** fresh `appleAuthorizationCode` — the app re-prompts for authorization
at delete time — exchanges it at Apple, and revokes. It is optional because deletion cannot
depend on it, and **a failed revocation never fails the delete**: one log line
(`apple_revocation_failed`, carrying a stage and an upstream status and nothing else) and the
sweep carries on. The cost, stated: an account deleted without a code is deleted without
revocation, and nothing is kept that could revoke it afterwards.

**It is throttled per account, and the Apple code is not bound to the account (#119).** The
route skips the account gate so an interrupted delete can be retried with the same token,
which also let one token replay it for the thirty days a JWT lives — each call a POST to
Apple, a tombstone write, a sweep and a log line. `RATE_LIMIT_DELETE_PER_ACCOUNT` (10 per
`RATE_LIMIT_WINDOW_SECONDS`) is counted against the token's verified `sub`, after the body
is validated and before the first write or upstream call. Ten is several interrupted deletes
and their retries, so the route stays idempotent inside it and the retry after the
tombstone still answers `200`. There is **no per-IP dimension**, unlike every other
throttle: deletion is the one thing a user must always be able to do, and behind carrier NAT
a per-IP budget is one a stranger can spend for her, while a uid's budget can only be spent
by someone holding a token for that account — who could delete it anyway. Deleting does not
forget the counter; the replay it bounds is of a token whose account is already gone.

The submitted `appleAuthorizationCode` is still not checked against *this* account's Apple
identity. Binding it would mean verifying the `id_token` Apple's token endpoint returns
alongside the refresh token — its signature against Apple's JWKS, `iss`, `aud`, `exp` — and
comparing its `sub` with the account's `apple.com` entry: the JWKS ownership §3 already
declines for sign-in, where Firebase does it for us. What leaving it costs is bounded: a
usable code comes only from a real device authorization for our own App ID, it is
single-use and minutes-lived, it is spent at Apple for the Apple ID that authorized it, and
the route deletes the caller's own account either way. So the worst a mismatched code does
is revoke Eva's Sign in with Apple grant for the Apple ID that produced it — a sign-out at
Apple, not data — and it takes holding that code to do it.

**Failures map by the same rule as everything else.** `providers.ts` reduces Apple's and
Google's answers to `unconfigured | rejected | unavailable`, `identity-toolkit.ts` gains a
fourth kind, `provider-linked`, and the routes branch on the kind and never on the reason:
a rejected credential is `401 INVALID_CREDENTIALS` in our own words, a 5xx or 429 or network
failure is `503 SERVICE_UNAVAILABLE` with the constant `Retry-After`. `unconfigured` — a
provider whose credentials this deploy was never given — is answered as `503` too, because
the capability genuinely is unavailable, and is logged as
`{"event":"provider_endpoint_unavailable","route","kind","upstreamStatus"}`, which
distinguishes "Google is down" from "page somebody, we never set `GOOGLE_IOS_CLIENT_ID`".
Every provider credential (`GOOGLE_IOS_CLIENT_ID`, `APPLE_CLIENT_ID`, `APPLE_TEAM_ID`,
`APPLE_KEY_ID`, `APPLE_SIGNIN_KEY`) is **optional** in `config.ts` for the same reason
`POSTMARK_API_KEY` is: none is provisioned yet, and an API that will not boot without Apple's
signing key is an API that cannot serve email/password sign-in either.

Both routes are throttled **per IP only** (`RATE_LIMIT_IDP_PER_IP`, separate budgets). There
is no per-address dimension: the only address in the request is inside a provider token that
has not been verified yet, so counting against it would hand anyone a lockout primitive
aimed at any address they cared to name.

*What is not tested, and cannot be here.* `api/test/provider-signin.test.ts` fakes the
provider boundary — no test process can obtain a real Apple `identityToken` or a real Google
authorization code — so what is proven is our half: the identity rule against the live
Firestore, the activation stamp, `authProviders` (both halves, #117), the 409, the
validation, and that the raw
nonce reaches the wire. That Firebase rejects a replayed nonce, that Google accepts our PKCE
exchange, and that Apple accepts our client secret are unproven until a device and a
provisioned provider exist.

**Nothing escapes the error shape (#48).** `app.onError` in `index.ts` is the floor under
every route: any throw no handler answered for is `500 { error: { code: "INTERNAL",
message } }`, where `message` is one constant sentence plus an eight-character `ref`. It is
never the thrown error's own text. That is the whole point of the handler rather than a
detail of it — a failing `fetch` puts the request URL in its message and that URL carries
the web API key (#32), a Firestore error puts the document path in its message and that
path is a uid, and neither string was written by anyone who was thinking about who reads
it. `err.stack` is out for the same reason (its first line *is* the message), and so is
`err.cause`. The Firestore outage inside `ensureUser` that both auth routes could not
answer for is the case this closes.

The log line is `{"event":"unhandled_error","ref","method","route","errorName"}` and
nothing else. `route` is the **registered** path (`/me/events/:id`), never `c.req.path`,
which would write down an event id — and at `/me/body-signals/2026-08-27` the day a user
logged health data on, which GUARDRAILS 12 keeps out of logs as surely as the payload.
`errorName` is the error's class name, sanitized to an identifier, so `FirebaseAppError`
and `TypeError` are distinguishable without any data in the line. `ref` is random,
generated per failure, and is the one field the caller is also given: a user can quote it
from the app's error and it names exactly one line. The cost, stated: no stack, so the
line locates a fault to a route and a class rather than a line number. If that is ever too
thin the answer is a reviewed field — an error class of ours carrying a safe code — not
the message.

**A JSON body that is not an object is `400 VALIDATION`, answered once (#119).** Every route
that reads a body reads it through `readBody` in `index.ts`: no body, or a body that is not
JSON, is `{}` as it always was, so each route's own validation answers — and `DELETE /me`,
whose body is optional, still deletes. Valid JSON that is not an object (`null`, an array, a
number, a string) throws `BodyNotAnObjectError`, and `onError` answers it `400 VALIDATION`
**before** it writes its line. That was the one throw `onError` recognised by class until
#286 added `AccountGoneError` (§4, "A write racing the delete") — and #294 its twin
`SessionSupersededError`, answered identically: `null`
used to reach `body.provider` as a `TypeError`, which was a 500 and an `unhandled_error` line
on the unauthenticated `/auth/idp` — a free way to fill the signal that is meant to mean "we
shipped a bug". Hono calls `onError` at the handler's own level of its `compose`, so
middleware around the route (`noStoreByDefault`, CORS) still wraps the answer.

Two limits worth knowing. Hono hands `onError` only a thrown `Error`; anything else
(`throw "boom"`) is rethrown to the runtime and answers its own unshaped 500 — nothing in
the stack does that today. And an unmatched path is still Hono's plain-text `404`, because
it is a miss rather than a throw; both are filed, not fixed here.

**`/auth/*` is throttled, per instance only.** Both auth routes count each attempt against
two counters — the caller's IP and the submitted address — and answer
`429 RATE_LIMITED` with a constant `Retry-After` once either is over its limit. Limits come
from `config.rateLimit` (`RATE_LIMIT_*`, all optional; any *limit* set to `0` disables that
dimension — the two knobs that are not limits behave differently, and say so below).
Sign-up and sign-in hold separate budgets.

*What that actually buys, stated plainly:* **the counters are in each Cloud Run instance's
memory, so the real limit is `limit × instance count`, and every deploy, scale-up, and cold
start resets every window.** It makes bulk password guessing and bulk account creation
expensive; it does not bound them. This is rate limiting *partial*, not rate limiting
*done* — issue #5 delivers the route behaviour and the contract, not an accurate counter.
Making it accurate means moving the counters into a store every instance shares, which
means a Firestore read+write on the path of every sign-in or a new Redis dependency; the
swap is confined to `createRateLimiter` in `api/src/rate-limit.ts`, and nothing outside that
file knows where the counters live.

Two consequences worth knowing before tuning the numbers. The per-IP limits are deliberately
loose because iOS traffic arrives through carrier NAT, where one address fronts many
unrelated users. And a per-address limit is a lockout primitive: someone who knows a user's
address can spend that user's sign-in budget for them, which is inherent to per-identifier
throttling rather than to this implementation.

**The two dimensions use different penalty shapes (#37, decided 2026-08-29.)** Per IP stays
a fixed window, because carrier NAT means an escalating penalty there would punish
bystanders for each other's attempts. Per address, on sign-in and sign-up, is an
**exponential backoff**: `RATE_LIMIT_SIGNIN_PER_EMAIL` / `..._SIGNUP_PER_EMAIL` free
attempts, then a block of `RATE_LIMIT_BACKOFF_BASE_SECONDS` that doubles each time, capped
at `RATE_LIMIT_WINDOW_SECONDS`, and forgotten entirely after that long without a served
attempt.

The point is what a lockout costs the person causing it — but the honest summary is that
this trade **bought guessing resistance with lockout cost**, not both. Under a fixed window
a lockout is a purchase: spend the budget on an address you know and its owner is refused
for the rest of the window whatever they do. Under the backoff it is rent — a refused
attempt is inert (it raises no tier, extends no block and does not keep the record alive),
and each expired block hands the key back **one** attempt, so somebody guessing gets one
guess per doubling interval. A drive-by burst costs its victim 30 seconds instead of 15
minutes, and sustained guessing gets 6–9× fewer attempts (measured: 37 vs 240 over six
hours, 109 vs 960 over a day). Note the sign in the *first* fifteen minutes, where the ramp
hands back four extra attempts: 14 against the window's 10. The win is asymptotic.

The rent is cheaper than the purchase was. Simulated against the shipped limiter at the
defaults, an attacker who knows the schedule and sends only the requests that buy denial:

| holding one address out | backoff | fixed window | |
|---|---|---|---|
| for 6 hours | 65 requests | 240 requests | 3.7× cheaper |
| for 24 hours | 209 requests | 960 requests | 4.6× cheaper |

With `RATE_LIMIT_SIGNIN_PER_IP = 60`, one attacker IP that could hold about 6 addresses out
under the window can hold about 30 under this. Three residuals follow, none of them
theoretical:

- **The victim's own retries pay the rent, and roughly halve it.** An expired block gives
  back one attempt and nothing says whose. An attacker who spends it leaves the owner's next
  keystroke to be the request that arms the next block — so under active attack she races
  for one slot per cycle where the window gave her ten. The six-hour figure above drops
  from 65 attacker requests to 38 — the *per-cycle* rent halves, from two requests to one,
  while the opening burst of eleven is paid either way.
- **The tier is shed all at once.** It lives until the whole record decays, so after an
  attack ends the address still gets one attempt per cycle. A second attempt inside the
  residue — a mistyped password, a correct one on a second device, the app's own retry after
  a network error — is refused, and arms the *next* block: twice the last one, up to the
  15-minute cap. Nor does signing in successfully clear it; each served attempt pushes the
  decay out, so someone signing in more often than once per window never sheds the tier at
  all. "Types their password once and is in" holds only for the first attempt.
- **The gentler wait does not reach the app yet.** `Retry-After` stays the constant
  `RATE_LIMIT_WINDOW_SECONDS` on purpose — the real block length is a function of how often
  *this address* has been blocked, so quoting it would publish a per-address attack history
  — and #38 holds the CTA for exactly what the header says. So a 30-second block is
  presented to the user as 15 minutes until a bucketed or padded value replaces it.

What is not in doubt is the direction of the dimension itself: per-address throttling is the
only thing standing against a distributed attack on one account, and dropping it was
rejected. Per-instance like everything else here.

The send-link routes (`resend`, `forgot`) keep their fixed one-per-60s. That is a cooldown
the canvas counts down, not a defence against guessing, and backing it off would make the
Resend button's wait vary with how often an address had been asked for — which
`authRetryAfterSeconds` quotes as a constant precisely so it cannot.

**Each dimension has its own key budget, and always did.** #37 filed this as a defect —
"today's single shared map" — and it was not one: `createRateLimiter` allocates its `Map`
per instance, so a flood of invented addresses fills the per-address map of one route and
cannot evict the per-IP counters that are the backstop in that state. Verified against the
commit that introduced the file, not just against today's, and now pinned by a test, because
hoisting the map to module scope to "save memory" would hand an attacker exactly the
eviction tool the issue was worried about.

**Which `X-Forwarded-For` entry is the caller is configuration, not a constant.** The per-IP
counter keys on the entry `RATE_LIMIT_TRUSTED_PROXY_HOPS` from the right — `1` today, which
is a direct Cloud Run service, verified against the deployed API answering on its `run.app`
host with no balancer in front of it. Everything to the left of the trusted entries is
whatever the caller chose to send, so reading from the left would make a per-IP budget cost
one header to reset. Put a Google external load balancer in front and there are two trusted
hops: leave the value at `1` and the rightmost entry becomes the balancer's, collapsing
every caller into one bucket and turning the per-IP limit into a global one. **Nothing
detects that** — no header distinguishes the two shapes — so the value is written down where
a topology change has to meet it, and the two-hop path is tested before anyone needs it.

Raising it is half a change. `deploy-api.yml` deploys with `--allow-unauthenticated` and no
`--ingress`, so the `run.app` URL stays publicly reachable: set the value to `2` without
also passing `--ingress=internal-and-cloud-load-balancing`, and a request sent straight to
`run.app` carries a one-entry header, resolves to no caller, and skips the per-IP dimension
entirely. That is the same outage as leaving it at `1`, reached from the other side. Below
`1` the API refuses to boot — `0` would read like the per-dimension disable switch every
other `RATE_LIMIT_*` value has, while in fact removing per-IP throttling from `/auth/idp`,
`/me/auth/providers`, `/auth/activate` and `/auth/password/reset`, where it is the only
dimension there is.

The throttle is applied **after** validation and **before** the Identity Toolkit call, so it
can never see, and never depends on, whether an address is registered — that is what keeps
the non-enumeration property above intact. `api/test/signin-non-enumeration.test.ts` pins
that a throttled registered address and a throttled unknown one are byte-identical.

The JWT is HS256, 30-day TTL, claims `{ sub, email, tv, iat, exp }`. **There is no refresh
token in v1** — expiry means sign in again. Adding refresh is an architecture change,
not a task.

**Every authenticated route is gated twice (#8).** `requireAuth` proves the token was ours;
`requireAccount`, right after it, proves the account it names still exists — one `getAccount`
call, and a `401 UNAUTHORIZED` with the same message a bad token gets when it does not.
The gate exists because the token above is stateless and unrevocable: without it a token
minted before an account was deleted would keep working for up to 30 days, and at `GET /me`
— which used to fall back to `ensureUser` when no document was found — it would have
**recreated the deleted account** from its own claims. The user document is what does the
revoking, rather than a list of deleted uids: it stops answering the moment a delete starts
and is gone when the delete finishes, so nothing about a deleted account is retained in
order to keep refusing it. The cost is one Firestore read per authenticated request.

### `users/{uid}.email` is the Auth account's address, or there is no session (#119)

**What the field means.** `users/{uid}.email` is the address of the Firebase Auth account
with that uid, written when the document is created and never rewritten. `GET /me` serves it
and the app shows it (Home, Profile) and keys nothing on it. It is not an identifier — the
uid is (GUARDRAILS 9) — and it is not the provider's address: an Apple relay or a Google
address linked from Profile is a *credential* on the account, not its address.

**The rule.** No route mints a session on a document whose address is not the Auth
account's current one. Decided on #119 as *refuse*, not *refresh*: nothing rewrites the
document's address to match.

*Why it can diverge.* The document is written once; Firebase's copy can move under it.
`accounts:update` with the public web API key moves an Auth address (the live project
currently refuses an unverified target — `account-deletion.test.ts` pins that — so this is
defence in depth there and the whole defence wherever that setting is off), and then
"link accounts that use the same email" does the rest: someone creates a provider-only
account, has Eva write its document, repoints the Auth address at a victim with no account,
and the victim's first Google sign-in merges onto that uid. Firebase strips the repointer's
credential on the merge, so it is not a takeover, but the victim was handed a session on a
document whose address, profile and events were the repointer's.

*Why refuse rather than refresh.* Refreshing would give the victim a document full of a
stranger's health data under her own address, silently, and would change what `GET /me`
returns for an account without anyone deciding it should. A document naming a different
address from the credential that just signed in is a state no Eva flow produces, and the
data behind it belongs to whoever the document names.

*What it is compared against, and why not the credential's claim.* `signInWithIdp`'s
`email` is the provider token's claim, never the account's (`identity-toolkit.ts` says why).
On a Firebase **merge** the account holds the credential's address by construction — that
equality is why Firebase merged — so the account's address and the credential's are the same
thing exactly where #119 needs them to be. They differ for a `sub` that was already linked:
Apple's relay on a password account (`POST /me/auth/providers`, the only route Hide My Email
users have into an existing account) or an Apple ID whose address changed. Firebase neither
merges nor rewrites the account's address there, so comparing with the claim would lock those
users out on every sign-in. **That is verified against the Auth emulator only** — its
`signInWithIdp` applies no account update when it resolves by provider — **not against the
real project**, where no test can obtain a real provider token. If production ever did
rewrite the account's address on a linked sign-in, those users would be refused here, and a
device test with a linked relay is how to find out. `/auth/idp` therefore reads the
Auth account (`addressOfAuthAccount`, one Admin read per provider sign-in) and compares
the document with that.

Where it is enforced, which is every route that mints:

| Route | Compared | Refusal |
|---|---|---|
| `POST /auth/idp` | document vs. the Auth account's address; with **no document yet**, the credential's claim vs. the Auth account's address. Both before the claim writes anything | `401 INVALID_CREDENTIALS`, logged as `provider_signin_refused` with `stage: "address"` |
| `POST /auth/password/reset` | document vs. the link's address, which #140 has already required to be the Auth account's | `400 INVALID_TOKEN`, before the bump and the password write |
| `POST /auth/signin` | document vs. the address Identity Toolkit matched the password on, read **before** `ensureUser` writes | `401 INVALID_CREDENTIALS`, byte-identical to a wrong password and inside the floor |

`/auth/activate` mints nothing and is not on the list.

**The first sign-in is checked too, or the attack runs in the other order.** Without it: make
an Auth account with one's own Apple identity at Firebase directly, repoint its address at a
victim, and call `/auth/idp` first — the document is born naming the victim, activated, and
the victim's later merge passes the comparison above. So with no document, the credential's
claim must equal the Auth account's address before one is written. On a fresh provider
account Firebase copied the claim onto the account, so they agree; a returning Apple user
whose token carries no address gets the account's own address from `signInWithIdp`, so they
agree there too. Only an address moved out of band separates them. (The claim's own address
test also refuses the literal case — a moved address clears `emailVerified` — but that rests
on the flag, and this does not.) The document is then written with the Auth account's
address, and `/auth/idp`'s token carries the document's, so the token and `GET /me` agree
(the mismatch between them is how #119 was noticed).

Case and surrounding whitespace are not a difference — Firebase stores addresses lower-cased,
and a document written before `normalizeEmail` may not be — and an absent address on either
side is. Every document Eva writes has one.

**The cost, stated.** The victim in the merge case is refused on every door: Google, a reset
link to her own address, and a password. Her address is held by an account she cannot enter
and nobody else can either, and there is no self-serve way out; recovering it is a support
action (delete that uid by hand). That is the direction chosen — a stranger's document
handed to her was the alternative — and the state is only reachable where `accounts:update`
accepts an unverified address.

### A password reset invalidates every session (#76)

The same gate is where a reset takes effect, and it is the same argument one step further:
a stateless 30-day token meant that resetting a password left the *other* session live, and
the reason a woman resets a password is usually that somebody else has it. A reset that does
not end that session defeats its own purpose. It is **not** an opt-in "sign out everywhere",
because a second control is found by the people who least need it.

`users/{uid}.tokenVersion` (§4) is the account's session generation, and `tv` above is the
generation a token was minted at. `requireAccount` compares them. **The value rides back on
the read the gate already made** — `getAccount` returns the user and the version out of one
snapshot — so this costs one integer comparison and no extra round trip. A design needing a
second read per request would be the wrong design, which is why the version lives on the user
document rather than in a revocation list of its own.

- **What bumps it**: `POST /auth/password/reset`, always; and `POST /auth/activate` on the
  *claim* path, which sets a password on an account it did not create and already revokes
  Firebase's refresh tokens beside it. A provider **unlink** should bump when such a route
  exists — there is none today. Linking a provider, signing in, and ordinary writes do not:
  none of them takes a credential away. `DELETE /me` does not need to; the tombstone already
  refuses every token. The rule and its reasoning live on `bumpTokenVersion` in `users.ts`.
- **The resetting device is not signed out**, and it is identified by being the one the new
  token is handed to rather than by any device id this API does not have: `/auth/password/reset`
  already mints a session, so it bumps first and mints at the new generation. Every session
  outstanding before it carries a lower one.
- **No error code changes.** A superseded token is answered byte-for-byte as an expired one,
  so `APIClient`'s existing `sessionExpired` handling (§5) applies to it unchanged.
- **The deploy signs nobody out.** A token minted before #76 carries no `tv` and a document
  written before it carries no `tokenVersion`; both absences read as `0` and compare equal.
- **A write already past the gate is held to it too (#294).** The gate reads the version
  before the handler runs, so a write could pass it and commit after the reset. Every
  per-user subcollection writer compares the token's version again inside its own write
  transaction — §4, "A write racing a password reset".

`DELETE /me` is the single exception to the gate, deliberately: it would reject the very token
a client needs to retry an interrupted delete with. All that token can do there is delete an
account that is already gone. **The generation check is not part of that exception** — it is
made by hand in the route, and only while a document still exists to check against, so the
retry (which happens after the tombstone) falls through exactly as before. A superseded
session locked out of every read but still able to destroy the account would be worse than no
revocation at all.

## 4. Data model

`users/{uid}` — document ID is the Firebase Auth uid, deliberately, so any future
provider resolving to the same Auth account lands on the same document.

```
email                  string          // the Auth account's address at creation; never rewritten (§3, #119)
authProviders          string[]        // arrayUnion. ONLY "password" is read (#117); see below
questionnaireCompleted boolean
profile                Profile | null  // see api/src/users.ts
consent                Consent         // #86 (A21): { collect, share } records. ABSENT = never asked
nutritionQualitativeOnly boolean       // DORMANT (#283): #252's hide-numbers flag. Never read, never written
profileNudgeDismissed  boolean         // #19: "complete your profile" nudge dismissed. ABSENT = false
activatedAt            Timestamp | null  // #6; null = unconfirmed, ABSENT = pre-#6 = confirmed
tokenVersion           number          // #76; the session generation. ABSENT = 0 = never bumped
deletedAt              Timestamp       // absent until a delete starts; see below
createdAt, updatedAt   serverTimestamp
```

`authProviders` **is not what the client is served under the same name** (#117). The
`User.authProviders` every route answers with is assembled per response from two owners:

- `apple.com` / `google.com` from Firebase Auth's `providerData`, read at request time by
  `federatedProvidersOf` (`identity-toolkit.ts`). The stored copy of them drifted —
  `claimUnprovenAccount` and `retractUnprovenIdentities` unlink identities from Auth and
  nothing pruned this array — so Profile could show a provider Firebase no longer held.
- `password` from this array containing `"password"` (`passwordChosen` in `users.ts`). That
  is an Eva fact, not a copy: Firebase also lists `password` for every account a claim has
  run on, because the claim overwrites the password with random bytes nobody chose, so
  Auth cannot say whether she has one she knows.

**The federated entries stored here are dormant.** `ensureUser` still unions them in and
nothing reads them. The write is kept so that a rollback to the build before #117, which
reads the array whole, does not find Apple accounts created in between without `apple.com`
— the app skips Apple revocation on delete for such an account. Stop writing them once no
deployable build reads them. **Nothing removes the ones already stored**: pruning them is a
deletion of user data and needs a human (AUTONOMY). A later reader must not start trusting
them again; the list in no case feeds a server-side authorization decision, which reads
`providerData` directly (#113).

The composition happens at the route edge (`servedUser` in `users.ts`, handed Auth's answer
by `index.ts`), so neither module reads the other's store. Cost: one Admin SDK `getUser` per
response that carries a `User`, measured from a laptop against the real project at ~170 ms
p50 / ~245 ms p90 — about one Firestore read. `GET /me` issues it beside the account gate's
read (`requireServedAccount`), the write routes beside their write, and the sign-in and link
routes after the step that changes Auth; no route that does not answer with a `User` pays it.
Not yet measured from Cloud Run, where it is expected to be smaller.

`tokenVersion` is the session generation (#76, §3). A token carries the generation it was
minted at and the account gate compares the two, so bumping this number ends every session
that is already out. **Absent is `0`**, the same convention `activatedAt` uses one line up and
for the same kind of reason: no document written before #76 has the field and no token minted
before it has the claim, and the two absences have to compare equal or the deploy signs out
every user Eva has. Nothing writes it at creation — the first bump creates it.

It is deliberately **not** on the `User` shape `users.ts` serves, which is what `GET /me`
returns verbatim: it is a server-side fact about sessions and the client has no use for it.
`getAccount` carries it alongside the user instead, out of the same snapshot.

`deletedAt` on a *user* is not a soft delete and has no undo. It is the tombstone that
makes account deletion safe to interrupt: while it is set, `getUser` answers `null`, so the
account gate refuses every token, and `ensureUser` refuses to revive the document, so
signing in cannot bring the account back either.

`activatedAt` distinguishes three states with two values, which is the one subtle thing
about it: `null` means the address has not been confirmed, a timestamp means it has, and
**absent means confirmed too** — every document written before #6 lacks the field and those
accounts must keep signing in. A truthiness test would lock them out.

`consent` is the consent record (#86, A21), and **absence is not withdrawal**. A grant
writes `consent.collect = { version, at, withdrawnAt: null }`; a withdrawal stamps
`withdrawnAt` and touches nothing else, because the record's meaning is "the consent
recorded here no longer holds" and erasing the grant it withdrew would stop the record
saying what was withdrawn. That is the freeze decided on #86: withdrawal stops new
collection and keeps the stored data, which leaves only by export or `DELETE /me`. The
`version` is the consent text's own version string, sent by the client that displayed it
and stored verbatim — the server keeps no table of known versions, because the record
exists precisely so a *future* text can be recognised as not the one she agreed to; the
app makes that comparison against the version it ships. One writer, `saveConsent`: a
consent record anything else could change cannot testify.

`Profile` is validated at the edge in `parseProfile` (`index.ts`): weight 30–200 kg,
height 120–220 cm, `medications` one of `MEDICATION_CODES`, `conditions` a list drawn
from `CONDITION_CODES`, and `lifestyle` one of `ACTIVITY_BAND_CODES` (#221) — `mostlySitting`,
`lightlyActive`, `active`, `veryActive` — or `null`/absent, stored as `null` for "not answered
yet", because every profile editor re-sends the whole profile and an account with no band
must still be able to save the rest (all in `users.ts` — opaque, permanent codes, the rule
`refdata.ts` follows and for the same reason; the band's array is the nutrition engine's own,
re-exported, so the codes the route accepts and the factors the engine holds are one list). Widening a range or adding a code is a product decision,
not a bug fix; changing an existing code is a data migration.

**The profile stores a date of birth; the age is derived and never stored** (#81, A8). A
stored age is wrong within a year of being written and wrong silently, and the one thing it
is read for — `bandForAge` in `cycle.ts`, the FIGO irregularity band — is a gate on whether
a fertile window is drawn at all. `dateOfBirth` is a `YYYY-MM-DD` calendar label, never an
instant, exactly as an event's `localDate` is.

**Eva is 18+** (A12), enforced in `parseProfile` against the caller's own day — the route
takes the same optional `timeZone` the calendar routes do, and without one measures against
the earliest day it could currently be anywhere, so a missing zone can delay somebody's
eighteenth birthday by a day but never admit a seventeen-year-old. The floor stays at the
point the date is captured even after #19 moves the rest of the questionnaire into Profile:
it gates the account, not the personalisation. `cycle.ts` holds the other half — an age
below the floor **throws** (`ImpossibleAgeError`) rather than falling back to a band, which
is the one place in that module where an unusable age is not read as unknown. The asymmetry
is deliberate and argued where it lives: absent is a fact we do not have, and under-18 is a
fact that contradicts a check that ran.

**Documents written before #81 carry `profile.age`, and nothing rewrites them.** There is no
date of birth derivable from an age, so the migration is a read: `users.ts` drops the legacy
key, serves a profile with no `dateOfBirth` as no profile at all, and reports
`questionnaireCompleted` as false over it — so the app asks for the profile again and the 18+
floor is applied to the answer. The account still opens and nothing is deleted; the stored
map is replaced the next time she saves the profile.

**Documents written before #221 store `lifestyle` as the English label the chip drew, and
nothing rewrites them either.** The band is the one profile answer arithmetic reads (the
activity factor), so a label is a live defect the moment a target is computed: a reworded or
localised chip would match no band, and a lookup with a fallback lands every such user on the
sedentary factor, which is also the most-chosen band and so invisible. Decided on #221: the
four strings the app ever offered — "Mostly sitting", "Lightly active", "Active", "Very
active" — map to the four codes **on read**, by an explicit table in `users.ts`
(`storedLifestyle`), matched exactly. **Any other string is absent** (`lifestyle: null`), and
absent means nutrition setup asks rather than a band being guessed. The profile is still
served and `questionnaireCompleted` is unaffected; the stored label stays until she next saves
her profile, which replaces the map with a code.

`authTokens/{sha256(token)}` — the activation and password-reset links (#6). Top-level
rather than under `users/`, because the document is looked up by the token alone, before
anyone knows whose it is. Owned by `api/src/email-tokens.ts`.

```
uid        string | null     // the account the link opens; null until one exists (#120)
email      string            // the address it was sent to
kind       'activation' | 'reset'
expiresAt  Timestamp         // 24h for activation, 60min for reset
usedAt     Timestamp | null  // null until spent; spending is a transaction
createdAt  serverTimestamp
```

Retention is a **TTL policy on `expiresAt`**, not code — one `gcloud firestore fields ttls
update`, in the README's setup block. It matters more than it looks: nothing bounds how
many tokens an account accumulates (every Resend issues one, and activation tokens are
never revoked), and each document holds the address it was sent to. Without the policy,
`authTokens/` becomes a permanent index of every Eva address with its signup and reset
times — which for a health app is the sensitive artefact, even though the tokens
themselves are useless. `deleteTokensForAccount` pages in batches for the same reason: an
unbounded collection needs an unbounded delete, and one 500-op batch would leave
`DELETE /me` unable to finish at all. It always sweeps by **uid**, and also by address only
when the account is still live and Firebase Auth says it proved that address. That weaker
address sweep is bounded to rows created before the deletion request began, so a delayed,
overlapping delete cannot erase a link issued after another request released the address.
Since #120 an activation token is issued before its account exists and carries `uid: null`,
so the address half is needed to remove those links — but an unproven address is movable
account state, and a tombstoned address may already have a next holder. In either case
deletion skips the address half and TTL reaps the stranded row; retaining one's own expiring
row is safer than deleting another person's link (#139).

The document ID **is** the hash, so nothing here can be turned back into a link, and there
is no index from an account to a usable token. Account deletion takes every row keyed to
the uid and, for a live account's proven address, the pre-account rows that both could not
carry it yet and predate the deletion request.

`users/{uid}/events/{eventId}` — one subcollection for every calendar entry,
discriminated by `type` (`cycle`, `bodySignals`, `sport`, `appointment`, `positiveTest`;
`sex` is reserved for C10). Owned by `api/src/events.ts`.

```
type          'cycle' | 'bodySignals' | 'sport' | 'appointment' | 'positiveTest'
localDate     'YYYY-MM-DD'    // the stored query key, sent by the device
loggedAt      'YYYY-MM-DDTHH:mm:ss'   // local wall clock, same day as localDate
note          string | null   // ≤280 chars, uncapped for appointments
source        'user' | 'eva'
payload       shape depends on type — see api/src/events.ts
idempotencyKey string | null   // client-supplied, for the offline queue
deletedAt     Timestamp | null  // soft delete; range reads skip it
createdAt, updatedAt  serverTimestamp
```

Two kinds of time, deliberately: `localDate` / `loggedAt` / `startAt` are the user's
**wall clock**, stored as strings and never derived from an instant, so a timezone
change cannot move an entry to another day (PRD edge case 5). `createdAt`,
`updatedAt` and `deletedAt` are system audit **instants**.

Date policy, validated at the edge: future dates are for `appointment` only
(`FUTURE_DATE_NOT_ALLOWED`), backdating is capped at 12 months
(`BACKDATE_LIMIT_EXCEEDED`), and `loggedAt` defaults to now for today and 12:00
otherwise. "Today" is computed in the request's optional `timeZone` (IANA, not
stored); without one the server uses UTC and allows a day of slack either side.

`cycle`, `bodySignals` and `positiveTest` are one entry per user per day, enforced by a
deterministic document ID (`cycle_2026-08-27`), so re-logging replaces rather than
accumulates. As a consequence their `localDate` cannot be changed by `PATCH` — delete and
re-log.

**A positive test is its own type, and nothing reads it (#80).** PRD §Positive test is
"marks the day": the entry *is* the fact, so its payload is `{}` and `parsePositiveTestPayload`
refuses every key rather than dropping it — which is what stops `{ negative: true }` being
stored under a type named `positiveTest`, and what keeps a beta-hCG reading out of the one
door it could arrive through (GUARDRAILS 35). It is deliberately **not** a third arm of
`CyclePayload`: both of those arms require flow or spotting and a test needs neither, a
`cycle` arm would put a test and a spotting day on the same date into one one-per-day
document, and `toCycleDay` maps *cycle* entries — so a separate type is what makes "the
cycle maths cannot see this" a property of the model rather than a rule to remember. No mode
moves, no card changes and no prediction shifts because of one; the cycle-to-pregnancy
transition it will trigger is D10's, and its semantics are not decided. The client draws it
as the grid's top-left outlined square (DESIGN.md §7) and cannot yet write one — the log
picker's row is a later slice.

**The explicit period-end mark is a flag on the last flow day (#75).** A `cycle` payload is
`{ spotting: true }` or `{ flow: 'light' | 'medium' | 'heavy', periodEnd?: true }`, and
`periodEnd` is the "my period ended" mark the day sheet sets. It may not appear with
`spotting: true`, and may not appear without a flow level on the same entry: a period cannot
end on a day that records no bleeding, and spotting is by definition not flow.
`parseCyclePayload` refuses both combinations at the edge, and the arms of `CyclePayload`
make them unrepresentable in the type.

**A mark is `true` or absent, never `false` (#188).** `spotting` and `periodEnd` accept
exactly `true`. Any other value (`false`, `0`, `"true"`) is `400 VALIDATION` and is never
coerced: a stored `spotting: true` the user did not send would change how her cycles are
grouped. To say "not spotting" or "not the end", the client leaves the key out, and `null`
means the same as leaving it out.

It rides on the last day *with* flow rather than taking its own entry on the first dry day,
which is what keeps it inside the deterministic ID above: an entry at `cycle_<first dry day>`
would have to share that ID with a spotting entry on the same date, and the payload is a
union rather than a record. So setting and clearing are both edits to the day's existing
entry — `PATCH` replaces `payload` whole, so the mark is set by sending it and cleared by
sending the day's payload without it — `localDate` never moves, and the one-per-day rule is
untouched.

**Inference and the explicit mark are two different facts, and only the second is stored.**
The period end the PRD infers — the first day with no flow logged — is unchanged and still
inferred; the mark exists because "the user said so" must not be represented by the absence
of a flow entry. The two can disagree, once a flow day is logged after a marked one, and #75
stored the fact and deliberately resolved nothing.

**#186 resolves it, and is the field's one reader.** Flow logged within
`CYCLE_MIN_PERIOD_GAP_DAYS` of a mark means the period had not ended — the mark is stale
data rather than a contradiction to arbitrate — and flow at or beyond it opens a new period,
with the mark standing. That is the same grouping rule `cycle.ts` applies to every history,
so marked days get no rule of their own; what the mark changes is that a *spotting* day
after it no longer carries the period forward to a later flow day, because she has said the
period is over. It is read for that decision and for nothing else — not an end date, not a
period length, not a cycle length — which is #75's scope line kept rather than lifted. The
stored field reaches the maths through `toCycleDay` in `today.ts` (#179), which is the only
mapping between it and its one reader.

**Retention — the 30 days are a clock, not a wish (#28).** `DELETE /me/events/{id}` is
soft: it stamps `deletedAt` and range reads skip the entry. For the next 30 days
(`RETENTION_DAYS` in `events.ts`, the one place the number lives) it can be brought back
by `POST /me/events/{id}/restore` — the Undo on the delete toast. After that a job
removes it for good. Restore's `deletedAt >= cutoff` and the purge's `deletedAt < cutoff`
are exact complements, so no entry is ever both restorable and purgeable. All of it is
instant arithmetic on the server-set `deletedAt`; none of it touches `localDate`, so no
time zone, DST change or client clock can move the boundary.

Restore answers `404` for an unknown id, for an entry that was never deleted, and for one
past its window. The interesting case is one-per-day: because those types
live at a deterministic ID, re-logging that day **overwrites the very document** that held
the deleted entry, so there is nothing left to restore. Restore refuses with
`409 DAY_ALREADY_LOGGED` rather than creating a duplicate or relabelling the newer entry
as restored. One consequence is worth knowing before it surprises someone: a live document
at a one-per-day ID cannot distinguish "the day was retaken" from "this was never deleted"
— replacing keeps the ID and `createdAt` and leaves no trace of the delete — so both
answer `409`. That is the price of the deterministic ID, and it is paid here rather than
by keeping a second copy of every deleted day.

**The promise was narrowed to match, rather than the storage widened (#50, decided
2026-09-16.)** "Recoverable for 30 days" was written flatly in the PRD, in the route table
above, in `REQUESTS.md`'s data map and on the public `/transparency` page, and for a
one-per-day type it is not true once the day is re-logged. Two other options were on the
table — moving one-per-day enforcement off the document ID to a query plus a transaction,
which restores full recoverability and gives up the structural guarantee #23 chose; and a
supersession marker letting restore tell "retaken" from "never deleted", which keeps the ID
design and adds a write-path record. Both were declined for now: the behaviour the code
already has is defensible, the UI already withdraws Undo once a day is retaken, and a
promise that is true is worth more than a wider one that is not. The marker stays the right
answer if the promise ever needs to be wide again.

**Deleting an account is immediate and complete (#8).** `DELETE /me` removes the Firebase
Auth user, `users/{uid}`, the whole `users/{uid}/events` subcollection — **including
soft-deleted entries still inside their 30-day window** — and `users/{uid}/today` with it. That is a deliberate difference
from event retention above, not a conflict with it: deleting one entry is an edit someone
may want to undo, deleting an account is a decision about all of it, and a recovery window
inside an account that no longer exists is a promise to nobody. Nothing else is keyed to a
uid except `authTokens/` (#6). Its uid-linked rows always go; its pre-account `uid: null`
rows go by address only while the account is still live and Auth says that address was
proven (#139). An unproven address is not a deletion key, so those rows expire by TTL.
`refdata/` and `content/` are global, and the `/auth/*` throttle's counters are in memory
and keyed by address and IP rather than by account. The one counter keyed by uid is
`DELETE /me`'s own (#119), in memory, and it outlives the delete on purpose — it bounds the
replay of a token whose account is already gone — and expires with its window.

The order is the design, because a partial failure has to be safe *and* resumable:

1. delete uid-linked tokens and, only for a proven address, its pre-account tokens. This is
   before the tombstone and Auth deletion: the live activated document makes sign-up refuse
   that reserved address, so a new holder's link cannot appear inside the sweep (#139);
2. mark `users/{uid}` deleted — from that instant the account is inert (every gated route
   `401`s, sign-in refuses to revive it);
3. delete the Firebase Auth user — the credentials open nothing and the address is free
   again;
4. delete every event, soft-deleted ones included, a batch at a time, then every stored
   Today card, then the nutrition profile (#221);
5. delete `users/{uid}`, the tombstone step 2 wrote.

`today/` is in step 4 rather than forgotten because a filled card is her own logged data
written out as prose: leaving it would make the Dashboard cache the one readable summary of
an account that no longer exists. It is also a *subcollection*, which in Firestore outlives
the parent document, so deleting it after step 5 would orphan it rather than remove it —
the same reason the events go where they do. `api/test/account-deletion.test.ts` enumerates
both subcollections with `listDocuments`, and `api/test/nutrition-profile.test.ts` does the
same for `nutrition/` — which is what makes a sweep removed later fail the suite rather than
pass it quietly. It does not catch a *new* subcollection added with no sweep at all: that is
still review's to see.

Link-token cleanup goes before the tombstone mark; health data goes after the mark and
before the tombstone document is removed, so that **a missing user document implies a
missing Auth user**. There is therefore no state in which health data
outlives its owner unmarked, and none in which someone can sign in to an account whose
document has already gone — which is the state in which `ensureUser` would create a fresh
one. The failure mode that remains is the mild one: an interrupted delete can leave an Auth
user with nothing behind it, and the account is already unusable when it does. Every step
is idempotent, so a retry resumes rather than errors, and deleting twice is a `200`.

**A write racing the delete (#286).** `requireAccount` reads `users/{uid}` before the handler
runs, so a write can pass it, and then land after step 2 *and* after step 4 has swept the
collection it writes to — a document under an account nothing links to and nothing will ever
delete. So every write to a per-user subcollection reads the account **inside its own write
transaction**, through `users.ts`'s `assertAccountLive`, and throws `AccountGoneError` when
the document is tombstoned or gone: `events.ts` (create — all three paths, the plain one now
a transaction too — edit, soft delete, restore), `nutrition-profile.ts`'s PATCH, and
`today.ts`'s card cache. Putting the account in the write's read set is what makes it
sufficient rather than likelier: if step 2 commits between that read and the commit, the
transaction retries and sees the tombstone, so a committed write is ordered either before
step 2 — and step 4 removes it — or it is refused. The cache is included because a card is
her data in prose (above), so a cache written after the sweep is the same orphan as an event.
The edits cannot create a document (`update` fails on a missing one) and are included for one
consistent answer rather than for survival: a racing edit gets what a racing create gets.

`app.onError` answers `AccountGoneError` exactly as the gate answers a deleted account's
token — `401 UNAUTHORIZED`, `Invalid or expired token`, no log line — because that is what
the caller is, one step earlier. No error code was added. `api/test/delete-race.test.ts`
forces the interleaving two ways, and each fails with any one check removed: the tombstone
and the sweeps run after the gate and before the write's transaction starts (every writer, and
the three routes), and — the case that pins "inside" — they start *after* the transaction's
account read and before its commit, which an account read outside the transaction lets through.

**A write racing a password reset (#294).** The same gap, against #76 instead of #8: a request
passes `requireAccount` at one token version, the reset bumps it, and the write commits under
a session the reset exists to end — a stolen token's in-flight write outliving the victim's
reset by milliseconds. The account snapshot the write already reads settles it: every writer
takes the request's `session` — `tokenVersionOf(claims)`, passed in by the route — and
`assertAccountLive` compares it with the stored `tokenVersion` (equality, as the gate does)
and throws `SessionSupersededError` on a mismatch. One comparison, no extra read or round
trip, and the read-set argument above carries over unchanged: a bump committing after that
read forces a retry that sees it. `app.onError` answers it byte-for-byte as the gate answers a
superseded token, which is the dead-token answer — no code added, no log line.
`DELETE /me` is not a subcollection writer and keeps its own by-hand check (§3).

A writer with no request behind it — none exists today; a job writing Eva-sourced entries
would be the first — passes `NO_SESSION`, which skips the comparison and nothing else: a
tombstone still refuses it. It is an explicit value, not an optional argument, so leaving
the session out is a compile error — and a `unique symbol`, so it cannot be typed as a string
literal either, only imported by name; and `delete-race.test.ts` fails if any module but
`users.ts` names it, so the first production use is a decision made in review rather than a
quiet opt-out. That file forces the reset *inside* the write's transaction, just before its
account read — the read set would otherwise order the bump after the commit — for each
`POST /me/events` path, `PATCH`/`DELETE /me/events/:id`, `POST /me/events/:id/restore`,
`PUT /me/body-signals/:date`, the nutrition PATCH and the Today cache write, and each case fails with the comparison removed.

The cost, from throwaway timing runs made while implementing #286 — a laptop against the
production Firestore, not a benchmark kept in the repo. **Every write pays one extra billed
document read.** Round trips depend on whether the writer reads anything of its own:

- A writer that already reads its document — one-per-day create, edit, soft delete, restore,
  the nutrition PATCH — passes that reference to `assertAccountLive`, which reads it and the
  account in one `tx.getAll`. No extra round trip. The first version used a separate `tx.get`,
  one round trip more per write, and that alone took `cycle-predictions.test.ts`'s first case
  (22 sequential posts) from the edge of its 20s ceiling to past it: a warm `POST /me/events`
  measured ~711ms against `main`'s ~656ms, and ~615ms once folded.
- A writer with nothing of its own to read — a plain create, the idempotency-key create
  (its read is a query, which `getAll` cannot carry), the Today cache write — pays one
  round trip. A plain create went from ~135ms (a bare `set`) to ~262ms (a transaction). The
  round trip is the laptop's ~130ms; from Cloud Run in the same region it is a few ms.

Contention: the read holds a lock on `users/{uid}` for the length of a short transaction, so
a profile save or `markUserDeleted` on the *same* account may wait that long; subcollection
writers only share the lock and do not contend with each other. The same lock runs the other
way: a burst of writes landing while `DELETE /me` stamps the tombstone can make that write
wait and, under enough contention, fail — the route then answers `500`, and a retry resumes
it, because every step is idempotent (within the per-account delete throttle's budget).

One residual race is worth knowing rather than discovering: a sign-in that passed Identity
Toolkit microseconds before step 2 can land its `ensureUser` after step 5 and recreate the
document. It needs the password and a window of milliseconds, and the account owner is the
one deleting; closing it would mean keeping a permanent record of every deleted uid, which
is a worse trade for a health app than the race is.

**Data export (#58).** `GET /me/export` is the access and portability answer (GDPR Art. 15
and 20, CCPA — LAUNCH.md §2.3), decided on the issue as JSON, delivered as an in-app
download: no email and no link, so the file exists nowhere but in the response and on her
device. `Cache-Control: no-store` keeps it out of every cache on the way.

What is in it, and in which shape — each the shape an existing route already serves, so the
app's decoders and the export cannot drift apart:

- `account` — exactly `GET /me`'s `user`, from the same gate (`requireServedAccount`): the
  account snapshot plus Auth's federated identities, assembled as §4 `authProviders`
  describes (#117). Profile, consent records, providers, activation, settings.
- `nutritionProfile` — exactly `GET /me/nutrition/profile`'s `nutritionProfile` (#221): the
  setup answers, the hide-numbers preference, the progress marker and the derived `complete`
  flag. **`null`, present, when she has not started setup** — so "none" reads differently
  from an export written before the key existed. One document, read whole by the route
  before the headers go, so a failure reading it is an ordinary `500` like the account's.
  Added without a `version` bump: adding a key is not one.
- `events` — **every document** in `users/{uid}/events/`, in `GET /me/events`' shape. That
  includes soft-deleted entries, marked by a non-null `deletedAt`, and it includes entries
  past their 30-day window that the purge has not reached yet (the purge job does not exist
  in production yet, §4 "Retention"): the export answers "what does Eva hold", and a stored
  entry is held whatever the promise says should have happened to it.
- `today` — every stored card under `users/{uid}/today/`, in `GET /me/today`'s shape
  (`date`, `generatedAt`, `contentVersion`, `card`, `banners` — the day's rail, #102, `[]`
  for a day stored before it), in date order. Added without a `version` bump: adding a key is
  not one. A filled card is her
  logged data in prose — the reason account deletion takes it, and the reason it is here.

What is left out, deliberately:

- `tokenVersion` (#76), `activatedAt`, `deletedAt`, `createdAt`/`updatedAt` on the user
  document — session and audit bookkeeping, not facts about her; `User` already omits them.
- A stored event's fields outside the event shape, if any were ever written: the export
  serves `toEvent`'s whitelist, never the raw document.
- A dormant `nutritionQualitativeOnly` on the user document (#283): `account` is `User`, which
  no longer carries it; the preference's live home, `nutritionProfile.hideNumbers`, is
  exported. Its removal from `account` is why `version` is `2`.
- `dataChangedAt` and `storedAt` on a card — the cache's regeneration bookkeeping.
- `createdAt`/`updatedAt` on the nutrition profile document — audit stamps; the route's
  shape already omits them.
- `authTokens/` — link-token hashes are credentials (GUARDRAILS 12a), not her data, and the
  address they were sent to is already `account.email`.
- The Firebase Auth record — the password hash is a credential; the address and the linked
  Apple/Google identities are already in `account` (the latter read from Auth, #117). The
  dormant federated entries of the stored `authProviders` array are not exported: they are
  a stale copy of those identities, not a separate fact about her (§4). The `/auth/*` throttle's counters are in memory and
  keyed by address and IP, not by account.
- `refdata/` and `content/` are global: an entry's symptom *codes* are exported, their labels
  are the catalogue's (§4 above), so the file is complete about her and not about Eva.

**It is streamed, and that decides how it fails.** Twenty thousand entries read with one
`.get()` would be her whole history in memory at once, so `events.ts` (`exportEvents`) and
`today.ts` (`exportTodayCards`) each hand over pages of `EXPORT_PAGE_SIZE` (500) ordered by
document id — the one ordering no document can be dropped from for lacking the field, and a
strictly increasing cursor, so nothing appears twice. `data-export.ts` reads the next page
only when the response asks for more bytes. It is not a point-in-time snapshot: an entry
written while the download runs may or may not be in it. Once the headers are out, a
failure cannot become a `{ error }` response, so the route is shaped around that: the
account and the **first page of each collection** are read before the headers go (a
Firestore that is down at the start is an ordinary `500 INTERNAL`), and the closing `]}` is
written only after the last page, so a body cut short anywhere is never valid JSON — the
brackets are the completeness flag, and the client must treat a parse failure as a failed
export. A mid-stream failure logs `{"event":"export_aborted","route","errorName"}` and
nothing else — no uid, no count, no date (GUARDRAILS 12).

**Throttled** per account (`RATE_LIMIT_EXPORT_PER_USER`, 5) and per IP
(`RATE_LIMIT_EXPORT_PER_IP`, 30) over `RATE_LIMIT_WINDOW_SECONDS`, in `rate-limit.ts` and
per instance like every counter there (§3). It is the one authenticated route with a
throttle because it is the one whose cost grows with the account. It is not behind
`requireCollectConsent`: reading her own data is not collecting it, and a withdrawal's freeze
says stored data leaves by export or by `DELETE /me`.

**The purge is a script, not a route** (`api/scripts/purge-events.ts`, over
`purgeUserEvents` in `events.ts`), for the same reasons as the refdata scripts below: the
Admin SDK bypasses `firestore.rules`, and there is no admin role to authorize an HTTP
caller with. It also means the most destructive operation in the system has **no HTTP
surface at all** — no endpoint a user's bearer token, stolen or forged, could reach, and
no shared purge secret to leak, rotate, or accidentally log. Authorization is IAM on the
identity the job runs as, which is Google's to check rather than ours.

Running it:

```sh
cd api && bun run purge:events --dry-run        # count only, deletes nothing
cd api && bun run purge:events                  # delete
cd api && bun run purge:events --uid=<uid>      # one account
gcloud run jobs execute eva-purge-events --region "$REGION"   # manual production run
```

**In production it is a Cloud Run job**, built from the same image as the service with the
entrypoint overridden, triggered daily by Cloud Scheduler. **A human must create it — this
repo does not.** Once it exists, `Deploy API` points it at each newly deployed image, so it
cannot drift onto stale retention code; its env and secrets are set at creation and do not
change with code deploys. Until it exists, nothing purges and deleted events accumulate;
the code is inert, not wrong. What is needed:

```sh
gcloud run jobs create eva-purge-events \
  --image <the image Deploy API pushed> --region "$REGION" \
  --command bun --args run,scripts/purge-events.ts \
  --set-env-vars "FIREBASE_PROJECT_ID=...,FIREBASE_WEB_API_KEY=..." \
  --set-secrets "JWT_SECRET=eva-jwt-secret:latest"

gcloud scheduler jobs create http eva-purge-events-daily \
  --schedule "17 3 * * *" --http-method POST \
  --uri "https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT/jobs/eva-purge-events:run" \
  --oauth-service-account-email <scheduler SA>     # needs roles/run.invoker on the job
```

The job needs the service's whole env because `config.ts` is all-or-nothing at import —
it will demand `JWT_SECRET` it has no use for. Worth fixing when config grows a second
consumer; not worth a bespoke config path today.

Scale: the job fans out over `listAllUids()` and runs one bounded query per user, which
is right at v1 size and linear in accounts. The cheaper shape is a single collection-group
query on `deletedAt`, and it is deliberately not what ships — a collection-group query
needs a `COLLECTION_GROUP` field override in `firestore.indexes.json` that a human must
deploy, and, more to the point, a project-wide destructive query is one nobody can safely
exercise from a test. Per-user scoping means the code that runs in production is the same
code the tests run, pointed at one account.

`refdata/{catalogueId}` — the option lists the client draws, one document per
catalogue (`symptoms`, `sportActivities`, `appointmentTypes`), plus the per-country
emergency guidance table (`emergencyGuidance`, #87) — emergency number, urgent-care
wording and support resources per ISO country, with a `fallback` entry that carries no
number at all. Owned by `api/src/refdata.ts`. Content is data, not code: adding an
option or fixing a label is a Firestore write, never a deploy (PRD:483).

```
items[]        { code, label, order, status: 'active' | 'retired', … }
               symptoms also carry: group ('primary' | 'more'), severable,
               values (the chip's own picker, or null)
updatedAt      serverTimestamp   // not served, and not part of the version
```

Three rules make this safe to change under a client that is already storing codes:

- **A `code` is permanent and opaque.** Labels are editable; a code is what events
  point at, is never renamed, and is never reused for a different meaning.
- **Nothing is deleted, only retired.** A retired item is still served (flagged
  `status: 'retired'`) so a historical entry still resolves to a label, and it is still
  accepted on write so a queued offline entry is never rejected. It is simply not
  offered as a new choice. Reads never validate, so an entry whose code has left the
  catalogue entirely still returns verbatim — nothing is ever migrated retroactively.
- **`version` is a hash of the content**, so it changes exactly when a catalogue does
  and an idempotent re-seed does not invalidate anyone's cache. The client stores it
  beside its copy and sends it back as `?version=` (or `If-None-Match`); an unchanged
  catalogue answers `304` with no body.

Symptom codes are validated at the route edge against this catalogue
(`UNKNOWN_SYMPTOM_CODE`) — that is what makes one vocabulary serve both the cycle
sheet's inline chips and the body-signals grid (PRD:484). Sport activities and
appointment types are *not* validated: both offer "Other" with free text. A symptom's
`severity` (`normal | severe`) and its `value` (the chip's own picker — discharge
`dry|sticky|creamy|watery|egg-white`, libido `low|high`) are separate axes — an
intensity and a category. A chip whose interesting signal is a *direction* carries it
as `values` rather than as two codes, so the readings aggregate (#24).

Catalogues are seeded with `cd api && bun run seed:refdata` (additive; `--relabel` also
resets labels) and pruned with `bun run retire:refdata`, which applies a declared list of
retirements and can only flip `status`. They are scripts, not routes: the Admin SDK
bypasses `firestore.rules`, so neither needs a rules change or an admin authorization
surface. Removal is deliberately not a flag on the seeder — a re-seed must never be able
to take an option away. Retired codes stay listed in the seed file carrying
`status: 'retired'`, so a project seeded for the first time reproduces the retirements
instead of depending on the retire script having been run against it afterwards.

`content/{contentId}` — the Dashboard's words, one document per kind
(`templates`, `banners`, `nudges`). Owned by `api/src/content.ts`, served by
`GET /content`, seeded with `cd api && bun run seed:content`. Same shape and the same
reasoning as `refdata/` above: copy is data, not code, and the client caches it against a
content-derived `version` and revalidates with `?version=` or `If-None-Match` (#97).

```
items[]        templates: { id, rung, mode, state, confidence: 'hedged' | 'plain',
                            tone?, kicker?, title, line2?, line3?, meta?, actions[],
                            slots[], status, order }
               banners:   { id, phase, mode, focus, title, meta, url, subjects[],
                            focusAreas[], status, order }
               nudges:    { id, withinDays: number | null, trigger, text, sub?,
                            action, status, order }
reviewedBy     string            // who signed this copy off
reviewedAt     string            // ISO date
source         string            // what they reviewed it against
updatedAt      serverTimestamp   // not served, and not part of the version
```

Three things differ from `refdata/`, and each is the point of the collection:

- **This repo's tooling will not write a document with no reviewer.** `applyContent`
  throws `UnreviewedContentError` unless all three of `reviewedBy`, `reviewedAt` and
  `source` are non-empty, and the seed ships with them blank — so seeding the real
  project needs a person's name added in a commit, not a flag (PRD §Dashboard, Other
  requirements 4: clinical content follows the same review requirement as the rest of
  the product, and #26 has no retained clinician yet). There is deliberately no argument
  or env var that gets past it; a test drives the script with the obvious candidates and
  requires a refusal. The refusal is transitive as far as it goes: a document that
  already holds items under a *missing* signature is refused rather than merged into and
  re-signed. It is **not per-item provenance** — the signature is on the document, and
  the merge is additive, so an item somebody added in the console *under an existing
  signature* is carried forward by the next seed and written out under the next
  reviewer's name. The record can say the wrong person reviewed a line while every
  document in the collection is properly signed.

  Stored rows with no usable non-empty string `id` are refused by both `applyContent`
  and `retireContent`; the writers never silently normalise them away. Every raw row
  counts when `applyContent` decides whether an existing document needs a signature,
  so malformed unsigned copy cannot bypass the review refusal. A signed document with
  such rows raises `UnusableContentRowsError` and must be repaired explicitly in the
  console before either writer can proceed (option A from #151).

  **Two paths still write unsigned, and the read path does not re-check.** The Firebase
  console bypasses the module entirely — the Admin SDK is the only way in, and a person
  with project access is one of the ways in. `retireContent` is the other: flipping an
  item to `retired` changes what is served and takes no `Review`, so the stored signature
  keeps covering items it no longer exactly describes. `GET /content` serves what the
  collection holds rather than re-validating it, deliberately: a signature check on the
  read path would blank the Dashboard on an operator's typo. So the guarantee is "the
  supported way to change this copy makes you sign it", not "everything served is
  signed"; a release check has to look at the collection, not only at the code.
  **The one exception is the banner rail (#102)**: `getSignedContent` yields no banners for
  an unsigned `banners` document, so a row the console added without a signature can be
  served by `GET /content` but never selected onto a rail — refusing there costs a missing
  rail, not a blank Dashboard.
- **The signature is stored beside the items, never inside them, and is not hashed.**
  Who reviewed the copy is an operational fact the device has no use for, so it is in
  neither the body nor the `version` — re-reviewing the same words must not push a new
  bundle to everyone.
- **Templates may only *declare* an enumerated slot** (`SLOTS` in `content.ts`:
  `cycleDay`, `phase`, `pregnancyWeek`, …), and the parser drops any other name from the
  `slots` list on the way out — the string keeps whatever `{placeholder}` it was written
  with, which is #145. What that bounds is the set of computed values a card can ever be filled
  with: no score, streak or cross-user comparison can reach a card without adding a slot
  in code, under review. What it does **not** bound is what a card *says* — `title`,
  `line2` and the rest are free text and are served verbatim, so a document written in
  the console can assert anything in prose. PRD §Dashboard's "no comparison to other
  users, no scores for the person, no streaks" is held by both halves together: `SLOTS`
  for the computed half, the review requirement above for the words.

Ids are permanent and opaque and nothing is deleted, only retired (`retireContent`),
exactly as for `refdata/`. **Retirement is a selection contract:** a consumer must use
only `status: 'active'` rows when choosing a new card, banner or nudge. The Today-card
consumer enforces this in `TemplatePhraser`, the banner rail in `selectBanners` (#102); D6
inherits the same requirement for nudges. Retired rows remain in `GET /content` only so an already-rendered or
stored card can still resolve its id; retirement does not blank a card already on screen.

There is no harder `withdrawn` status in v1. Omitting copy from the bundle would orphan
stored references, while a device that already cached or rendered it would still keep it
until revalidation, so omission does not provide immediate retraction. If a future
incident policy requires hard withdrawal, the client first needs an explicit missing-id
fallback; only then can the API safely omit withdrawn rows. With no live clinical copy,
that extra state and fallback are not justified for v1 (#146).

Until someone seeds it the collection is simply empty: `GET /content` answers `200` with
three empty arrays and warns on the server the way `refdata.ts` does, because a Dashboard
with no copy is a deployment state, not a request error. The empty bundle is the one
result the 60s cache does not hold, so an instance is serving the real copy within a
request of the seed rather than a minute later.

`users/{uid}/today/{date}` — the Today card, one document per local day (#98, slice D3
of #10). Owned by `api/src/today.ts`. The document id **is** the user's local date, so
"which day is this" is answered by the request's `timeZone` and never by the server's clock
— the same rule `localDate` follows on an event.

```
date            'YYYY-MM-DD'   // the user's local date; also the document id
generatedAt     string          // ISO-8601 instant, system time
contentVersion  string          // the content.ts bundle the text was filled from
dataChangedAt   string | null   // newest change to her own data this was built from
card            { templateId, rung, state, tone?, kicker?, title, line2?, line3?, meta?, actions }
banners         [{ id, title, meta, url }]   // the day's rail, 0–3, display order (#102)
storedAt        serverTimestamp
```

**Generated once per day, and regenerated only when her data moves.** PRD §Dashboard, Other
requirements 3 and Edge case 5: the card "does not change between opens. It updates on new
data, not on refresh." So a stored document is returned *untouched* — not re-filled, not
re-stamped — unless something it was built from changed: an event created, edited, deleted
or restored, body signals upserted, the profile saved, or — since the banner rail ranks by
its focus areas (#102) — the nutrition profile saved. New copy in `content/` is
deliberately **not** such a thing; an existing day keeps its filled text and its
`contentVersion`, because new data changes the card and new words do not.

The comparison is against `dataChangedAt`, not against `generatedAt`, and that is the point
rather than an implementation detail: it is exact, it cannot be moved by server clock skew,
and it closes the window between reading the inputs and stamping the card. Comparing a
freshly read `now` against `generatedAt` is the shape that regenerates on every read while
looking correct, which is the failure #98's byte-identical test exists to catch.

What the card holds is the **filled text** plus the routing targets — `templateId`, `rung`
and the canvas `state`. No raw signal value beyond what the reviewed copy already says, and
no event of any kind: the only logged input the ladder receives is body signals, so a Sex
entry (PRD Edge case 6) cannot reach a card by any path, and hiding one changes nothing
because nothing here ever had it.

All three of its inputs are unsupplied today, and the route says so rather than improvising:
the pattern rung's thresholds are #26's and unconfigured, `content/` is unseeded in every
environment because #97 refuses to seed it without a reviewer, and the `CYCLE_*` group is
unset everywhere (#176, #191). Any one of them makes `GET /me/today` answer
`503 SERVICE_UNAVAILABLE`.

**The cycle maths is wired in as of #179.** `today.ts` reads the logged `cycle` entries over
a window derived from the constants — `(historyCycles + 2) × maxCycleLengthDays`, about a
year, so the median and the variation see the history they are defined over — maps each to
`cycle.ts`'s `CycleDay` (flow, spotting, and #75's `periodEnd` mark), and hands them to
`analyzeCycles` with the profile `bandForAge` reads one field of. `toCycleEstimate` projects
the answer into the `CycleEstimate` D1 already consumed, so no gate or band is decided
twice. Body signals stay on rung 2's own, much shorter span: entries outside it change no
answer, and a year of them in memory is a year of health data read for nothing.

The estimate asks the maths *before* the ladder is consulted, so an unset `CYCLE_*` group
refuses at `gatherInput` rather than at rung 4 — which is why the route's third 503 arm is
the one a deployment hits first. What is still withheld is not engineering: `phase_energy`
is the only phase card the canvas has drawn, it is selected for `follicular` alone (#184,
#195), and every other phase falls through to the educational card until the variants are
drawn.

**The irregularity answer is not a boolean, as of #190.** `analyzeCycles` returns
`irregularity: 'none' | 'cycles-vary' | 'uncountable-cycle'`, and every value but `none`
withholds the prediction, the fertile window and the phase exactly as the boolean did — the
gate #181 closed is untouched, and `[28, 60, 28, 60, 28, 60]` is still refused. What the
union adds is *which* fact refused her. The spread the band measures runs over every interval
in the window, so a woman logging 28-day cycles who misses one period start has two of them
merged into a 56-day interval and is suppressed until `historyCycles` further counted cycles
push it out — about six months — and for all of it she was shown `home_c`, "Your recent cycle
lengths vary significantly", which was false: her counted cycles were all 28 days.
`uncountable-cycle` is that case (exactly one interval in the window outside the countable
range, and counted cycles inside her band); anything else is `cycles-vary`, because more than
one out-of-range interval is FIGO's infrequent menstruation rather than a mislog, and
`irregular-cycles` is the reason whose card points at care. Rung 4 selects `home_c` for
`cycles-vary` alone and `uncountable-cycle` falls through to the educational card — the card
that would explain it is one the canvas has not drawn (#177's rule: a request, not an
invention in the seed). The duration is unchanged and is now pinned from both sides in
`api/test/cycle.test.ts`, so it is a decision rather than a side effect of `historyCycles`.

**And the calendar reads the same seam as of #205.** `GET /me/cycle/predictions` answers
**by range**, because `CalendarModel` already fetches events by range and caches by month and
a month grid spans up to three of them — a per-day prediction would give one screen two fetch
models. `cycleAnalysisFor` gathers what `gatherInput` gathers, through the same `toCycleDay`
mapping and the same derived window, and hands it to the same `analyzeCycles`; what differs
is only which shape the answer is projected into. The calendar needs `CycleAnalysis` rather
than `CycleEstimate`: the latter is D1's projection and carries no `cycles` list, so "unusual
length" cannot surface through it and neither can the fertile window's own dates. The route
clips C11's dates to the range asked for and adds nothing — in particular, predicted period
is the *one* day `nextPeriodStart` names, because `cycle.ts` deliberately produces no period
length and painting four more cells would mean inventing one. Every gate stays
`analyzeCycles`'s: a withheld prediction reaches the wire as empty lists, a `null` confidence
and the reason that closed it, so `[28, 60, 28, 60, 28, 60]` cannot produce a fertile window
by any path (PRD §Phase 1 rule 5). Nothing is cached under the route, which is what makes
"recomputed on every edit to a flow entry" (A25 item 5) a property of it rather than a job.

**The client half (#206) draws that answer and computes none of it.** `CalendarModel` asks
for the overlay over the same range as the entries and caches it by month, so one screen
keeps one fetch model; the days are mapped onto cells and nothing else happens to them —
the three files that touch a predicted date are scanned for date arithmetic by
`CalendarPredictionTests`, because "extend the predicted period by four days" is four lines
of plausible Swift that no behavioural test would catch. A25 item 5 reaches the device as an
invalidation: writing, editing, deleting or restoring a `cycle` entry drops the whole
overlay and re-asks, because the route recomputes on read and a moved anchor moves the whole
projection. A `503` from the route draws nothing and says nothing — which is deliberately
*not* what a withheld prediction does, since only one of the two is an answer about her
data.

**The banner rail is chosen with the card, and stored with it (#102, D7).** `today.ts` hands
`selectBanners` (in `dashboard-rules.ts`, beside the ladder, pure on the same terms) the
banner rows, the mode, the template id the ladder just chose, and the focus areas of a
*finished* Nutrition setup; the answer is copied into the day's document as `{ id, title,
meta, url }` — the words, not a reference, so the rail neither changes when `content/` does
nor needs the bundle to render offline. The rule, each clause a refusal rather than a
preference:

- **Eligible** only if `status: 'active'` (#146), `mode` equal to today's — exactly: the
  parser defaults a missing tag to `'any'` and that is never a wildcard for a banner, so an
  untagged row reaches no rail, the loss-mode one included — not tagged in `subjects` with
  the card's template id (PRD Banner area 3), and carrying a title, a meta line and an
  absolute `https://` URL **already in its normal form** — the stored string must equal
  `new URL(url).href`, so a URL the parser would have to repair (surrounding space, an
  embedded newline or tab, an upper-case host, a `..`) is refused rather than checked in one
  form and served in another.
- **Ranked** by how many of her declared focus areas a row carries, then by the store's
  `order`, then by id. Focus areas rank; they never filter. Only a finished setup's count —
  PRD §Nutrition coach, nothing suggested from partial data.
- **Cut** at three and **never padded**: fewer eligible rows is a shorter rail, and none is
  `[]` (the client then draws no "Worth reading" section at all).
- **A row with no article is not served.** The whole card is the tap target and the tap
  opens the URL, so a row without one is a dead link. Every seeded row's `url` is still
  empty — the Blog is unspecified (PRD §Blog) — so **no environment shows a rail today**, by
  construction rather than by accident.
- **An unsigned `banners` document yields no rail.** `GET /content` deliberately serves what
  the collection holds; the rail is fresh selection every day of links out of the app, so it
  alone re-checks the signature, through `content.ts`'s `getSignedContent`.
- **The cycle phase is not an input yet.** No row carries a within-cycle phase tag (D2's
  `phase` field is the canvas set, which `mode` already covers), and #102's tone criterion
  limits a banner's tags to topic, mode and focus area. A phase tag is a content decision
  for the reviewer; when it exists it ranks below focus areas.

A day stored before the rail existed is served with `banners: []` for the rest of that day
rather than filled in on a later open, which would change the document on a refresh.

`users/{uid}/nutrition/profile` — the Nutrition coach's setup answers (#221, S1 of #25).
Owned by `api/src/nutrition-profile.ts`. **A subcollection with its own route rather than a
map on `users/{uid}`**, decided on #221: `GET /me` serves the user document's shape verbatim,
so a goal and a target weight there would reach every caller of `/me` — the `tokenVersion`
argument above. One document, `profile`, in a collection so a later slice can add a sibling
without a second top-level owner.

```
goal            'lose' | 'gain' | 'buildMuscle' | 'maintain' | 'eatBetter' | null   // PRD Step 1
focusAreas      FocusAreaCode[]    // PRD Step 2: 17 codes, at most 3, optional ([])
mealPattern     { mealsPerDay: 2|3|4|5, snacks: boolean, mealTimes: 'HH:mm'[] | null } | null
targetWeightKg  number | null      // PRD Step 5; kg, always (§5). Only with goals 1–3
hideNumbers     boolean | null     // #212: hide calories, macros, weight targets. null = not yet asked
step            'goal' | 'focusAreas' | 'mealPattern' | 'bodyMetrics' | 'targetWeight' | 'done'
createdAt, updatedAt  serverTimestamp
```

Served as those fields plus **`complete`, which is derived on every read and never stored**:
`step` is `done` *and* every required answer is present (goal, meal pattern, the preference,
and a target weight for goals 1–3). PRD line 677 — *"Nothing is calculated, displayed or
suggested from partial data"* — and Edge case 1's resumable draft are one field apart, so
completeness has exactly one definition, `completedSetup`, which is also the only function
that hands out a goal *paired* with its target weight in the shape the engine takes. A
document that says `done` over a missing answer reads as partial. `PATCH` refuses `done` while
an answer is missing, and refuses an edit that would leave a finished setup missing one.

The codes are permanent (the medication rule); the goal codes are the engine's own
`NutritionGoal`, and the focus areas' PRD item numbers — which `nutrition.ts` reads for the
fibre rule — are a total table, `FOCUS_AREA_PRD_ITEM`, in the owning module. Item 18
(*"Support pregnancy nutrition"*) is added as a new code with Pregnancy mode (S12).

**What is not here, deliberately.** No disordered-eating field (#212: Eva holds none), no
"Meal fit" score (S8, gated on #26), and no body metrics — Step 4 confirms the Sign Up
profile's own. An unknown key on a `PATCH` is refused rather than dropped, which is what
stops one being added by reflex; the test pins the key set. **`hideNumbers` changes only when
a request names it** — an absent key leaves it as it was and `null` is refused — so no write
can silently turn the numbers back on (#212's "worst version").

**`hideNumbers` is the preference's one home.** #252 first put it on the user document as
`users/{uid}.nutritionQualitativeOnly`, behind `PUT /me/nutrition-settings`, before #221
decided where it lives. #283 removed the route and the `User` field with no deprecation
window (no client ever called or decoded either). A value already stored on a user document
is **dormant**: nothing reads it, nothing writes it, and nothing deletes it — deleting
stored user data is a human call (AUTONOMY) — so it leaves only with `DELETE /me`. Do not
read it as a fallback for an unanswered `hideNumbers`; `null` means "not yet asked".

**Planned (A3, A9 — §8 and §9 below; not yet in code):**

```
users/{uid}/devices/{deviceId}         // §9 — one per installed device
  apnsToken      string                // rotated by iOS; replaced in place
  environment    'sandbox' | 'production'
  timeZone       string                // IANA; the device's, for scheduling
  updatedAt      serverTimestamp

users/{uid}/notifications/{id}         // §9 — what was, or will be, delivered
  kind           'appointment' | 'meal' | 'cycle' | 'wellbeing' | 'education' | 'update'
  dueAt          Timestamp             // instant, derived from a local wall-clock time
  sentAt         Timestamp | null
  readAt         Timestamp | null      // the notification centre marks it
  ref            { type, id } | null   // what it points at; never its content
  createdAt      serverTimestamp
```

Both are keyed under the uid so **account deletion (§4 above) must enumerate them too** —
`DELETE /me` fans out over `events/` today and nothing else; adding a subcollection without
adding it to the delete is the way health-adjacent identifiers outlive their owner.

## 5. iOS app structure (`mobile/Eva/`)

| Folder | Owns |
|---|---|
| `Networking/` | `APIClient` (generic async JSON), `APIError`, `APIModels` (wire types) |
| `Session/` | `AppSession` — the single source of app state; `KeychainTokenStore` — the only place the JWT is persisted |
| `Session/Providers/` | Sign in with Apple and Google: the two controllers, the PKCE/nonce derivations, and the buttons that run them (#7) |
| `Onboarding/` | `OnboardingModel` (flow state machine) + `Steps/` + `Components/` |
| `Profile/` | `ProfileView` (identity, connected accounts, log out, danger zone) and `DeleteAccountModal` |
| `Navigation/` | `EvaTabView` and `EvaTabBar` — the signed-in shell — and `EvaTabRouter`, which holds the tab selection and the one request a tab makes of another |
| `Home/` | The Dashboard's Home tab (#99, D4): `HomeModel` and its `TodayCardSource`, `EvaTodayCard` (the `GET /me/today` wire types), `TodayCardView` in its four tones, the header and the offline bar |
| `Calendar/` | `CalendarModel` and its `CalendarEventSource`, the month grid and its marks, and the prediction overlay (#206): `EvaCyclePredictions` (the `GET /me/cycle/predictions` wire types) with `EvaPredictionOverlay`, the dashed-and-patterned `EvaPredictionMark`, and the summary card |
| `Units/` | The units setting (#82): `EvaUnitSystem`, `EvaUnitPreference`, and the conversion boundary — `EvaBodyUnits`, `EvaBodyRange`, `EvaMassInput`, `EvaHeightInput` |
| `Theme/` | Colors, gradients, `PrimaryButton`, progress style — see [DESIGN.md](DESIGN.md) |

**The Home tab reads through a protocol, not through `AppSession` directly.**
`TodayCardSource` is the seam §8.1 describes — "screens read the store; only the sync
engine talks to the API" — with `AppSession` standing in as its only implementation until
#78 builds the store. `LocalTodayCard` (§8.2) is what replaces it, and nothing in
`HomeModel` changes when it does. The same shape `CalendarEventSource` has.

`AppSession.State` (`loading → signedOut | ready | unreachable`) drives the root view.
**The server is the source of truth for `questionnaireCompleted`** — never reintroduce a
local `@AppStorage` flag for it. #19 removed the post-auth questionnaire gate: a new user
lands in the app and completes the profile from Profile.

### The canonical unit: SI, always (#82)

**Every body measurement Eva stores is metric — `weightKg` in kilograms, `heightCm` in
centimeters — whatever the device is set to display.** The units setting
(`EvaUnitPreference`) decides what a screen draws and what an entry control hands back,
and nothing else. It is a device preference in `UserDefaults`, not a field on
`users/{uid}`; a second device does not follow it yet, and moving it onto the account
(the canvas' "account preference") is an always-human schema gate that should ride with
the A8/A12 change rather than open the document twice.

**No stored value may depend on a display preference.** If one did, changing the setting
would rewrite history — a weight logged as 150 lb would become 150 kg — and the rewrite
would be invisible, because the wrong number is a plausible number. So conversion is a
**boundary**: `EvaBodyUnits` holds two functions per quantity, one each way, and they are
the only place in the app where SI meets imperial.

Two consequences worth stating, because both look like details and are not:

* **The canonical value is a `Double`, not an `Int`.** A kilogram is 2.2 lb, so at whole
  kilograms 150 lb and 151 lb are the same stored number and both come back as 150.
  Stored values land on a 0.01 kg / 0.1 cm grid, which is fine enough that every pound
  and every inch round-trips exactly and coarse enough that nothing drifts across edits.
  The wire format did not change: `parseProfile` has always validated these as finite
  numbers in a range rather than as integers, and `JSONEncoder` writes a whole `Double`
  as `64`, so a metric profile sends the bytes it always sent.
* **A compound unit is two fields.** Feet and inches, stones and pounds — never one
  decimal. `5.75` for 5'9" is how a height silently becomes wrong by two inches
  ([LAUNCH.md](LAUNCH.md) §4.2).

`EvaBodyRange` derives the imperial input ranges from §4's SI ranges (30–200 kg,
120–220 cm) by rounding inward, so an imperial control can never reach a value the
server would refuse with a message in kilograms.

### Apple and Google, without an SDK and without a Firebase token (#7)

The app obtains a **provider credential** natively and posts it to the API, which does
everything else (§2). It never holds a Firebase ID token, a Google access token or an
Apple refresh token — one credential type, still, and one protocol.

`Session/Providers/` is four files and one idea each:

| File | Owns |
|---|---|
| `AuthCrypto` | The raw nonce, its SHA-256, the PKCE verifier and its S256 challenge. Pure, and unit-tested against published vectors — every value here fails *silently* when it is wrong |
| `AppleSignInController` | One `ASAuthorizationAppleIDProvider` request, as an `async` call. Also the fresh authorization code account deletion needs |
| `GoogleOAuthConfiguration` | The client id, the redirect it implies, the authorization URL, and what the callback means. All pure |
| `GoogleSignInController` | The `ASWebAuthenticationSession` that presents it |
| `ProviderSignInButtons` | The two buttons plus the flow behind them, shared by sign-up, log in and Profile |

Four things about it are load-bearing:

**The nonce goes to Apple hashed and to us raw.** `request.nonce` is
`sha256(rawNonce)`; the API is sent the **raw** value beside the `identityToken`. Apple
copies the hash into the token's `nonce` claim, so the API can prove the token was minted
for the request this app just made. Send the hash to the API instead and the check becomes
"this hash equals this hash", which a replayed token also passes.

**Google is PKCE in an `ASWebAuthenticationSession`, with no SDK.** An iOS OAuth client is
a public client with no secret, so the app can run the authorization-code flow itself and
the `code` is protected by the verifier rather than by a shared secret. Adding a
dependency is an always-human gate (AUTONOMY) and this one was decided against; the app
still has zero Swift Package dependencies. A real `WKWebView` is not an alternative —
Google answers `disallowed_useragent` — so the sheet is what "a web view, not a browser
redirect" means in practice. The app never spends the code; the API does.

**Which calls go through `authorized(_:)`, and why it is not both.** `signInWithProvider`
posts `/auth/idp` **outside** the wrapper, like `signUp` and `signIn`: it carries no token,
so its 401 means the provider credential was refused, not that this device's session is
over. `attachProvider` posts `/me/auth/providers` **inside** it, because that one does
carry the token. Getting this backwards would log a signed-in user out for a failed
attempt to link a second provider.

**Deleting an account offers Apple a revocation.** Apple requires an app that offers both
Sign in with Apple and in-app account deletion to revoke on delete, and Eva deliberately
stores no Apple refresh token — so `DeleteAccountModal` runs a fresh authorization and
sends the resulting `authorizationCode` in the `DELETE /me` body. **Cancelling that step
does not stop the deletion.** A provider handshake is never allowed to be what stands
between someone and the destruction of their own data; the cost is a token that stays
unrevoked, which is Eva's problem with Apple rather than the user's with Eva.

There is **no new `OnboardingStep`**. Provider sign-in draws no screen: it starts from a
button on a step that exists and lands where every other authentication lands. The enum is
a list of screens, and a case with nothing behind it would leave a raw value
`EVA_ONBOARDING_STEP` could still jump to.

**None of it can be driven by a UI test.** Sign in with Apple needs a device signed in to
an Apple ID — the simulator answers `ASAuthorizationError.unknown` — and Google needs a
provisioned OAuth client and a real account. `EvaTests` covers the derivations, the wire
shapes and the callback parsing, which is the part that fails silently; the flows
themselves are exercised by hand on a device. This is the same honest gap
`docs/PROVIDER-SIGNIN.md` names, and it is stated rather than papered over.

### A dead credential signs the user out, wherever it lands (#55)

The JWT is stateless and lives 30 days, so the server's only way to say "this credential
is finished" is a `401 UNAUTHORIZED` — which `requireAccount` now returns for a deleted
account on every authenticated route, and since #76 for a session a password reset has
superseded (§3). The client has to hear that everywhere, not just at launch. Both are the
same 401 with the same message, deliberately: no client change was needed for the second,
which is what "no existing error code changes" bought.

Two pieces, and the split matters:

- **`APIClient.send` decides what a 401 *means*.** It throws `APIError.sessionExpired`
  only when the response is 401 **and** the request actually went out carrying a bearer
  token. The second half is load-bearing: `POST /auth/signin` answers a wrong password
  with 401, and a rule keyed on status alone would sign a user out for mistyping. The
  flag is set in the same binding that writes the `Authorization` header so the two
  cannot drift apart.
- **`AppSession.authorized(_:)` decides what to *do* about it** — clear the Keychain,
  drop to `.signedOut`, and rethrow so the caller can still react. Every authorized call
  goes through it. Adding an authorized request without it is the regression this
  paragraph exists to prevent.

`signUp` and `signIn` stay outside the wrapper deliberately: they present no token, and
their 401 means "wrong password".

**It holds at launch too (#61).** `bootstrap()` used to clear the Keychain on *any*
failure, `.network` included, so opening the app with no signal signed the user out and
asked for a password they could not submit. It now draws the same line as the wrapper:
only `.sessionExpired` ends the session; a `.network`, a `.decoding` or any non-401
`.server` leaves the token exactly as it is and the app goes to `.unreachable`.

`.unreachable` means *we have a token we could not validate, and we kept it*. It offers a
retry and — the part that is easy to leave out — a way to log out. Before #61 every launch
failure ejected the user, so being stuck was impossible; keeping the token removes that
exit, and a retry button is not a substitute for one when `/me` fails for this account
every time.

One consequence is filed rather than fixed (#59): if a `DELETE /me` fails *because* the
token died, the sign-out tears down the modal before it can say so, and a user sees the
signed-out screen for an account that still exists.

`OnboardingStep` is a linear enum with explicit `next()`/`back()`. Add a screen by
adding a case and wiring both transitions — there is no implicit ordering.

Escape hatches used by tooling — keep them working:
- `EVA_ONBOARDING_STEP=<rawValue>` jumps straight to a step. DEBUG-only.
- `EVA_UITEST_RESET=1` clears the Keychain at launch. DEBUG-only.
- `EVA_API_BASE_URL` repoints the client (used by `scripts/e2e.sh` and, via
  `TEST_RUNNER_EVA_API_BASE_URL`, by `scripts/verify-mobile.sh`). Compiled into **every**
  configuration, not just DEBUG, so a Release build can be pointed at a test API.

Without that override the base URL comes from the `EVAAPIBaseURL` Info.plist key, which
XcodeGen fills from the `EVA_API_BASE_URL_DEFAULT` build setting in `mobile/project.yml`
— `http://localhost:3003` for Debug, the Cloud Run URL for Release. `APIClient` treats a
missing or non-absolute value as fatal rather than falling back to a plausible default:
the failure mode being guarded against is a Release build that quietly talks to
localhost, which no test would catch.

### Versioning: which commit is this build? (#46)

`CFBundleVersion` is **`git rev-list --count HEAD`** and `EvaGitSHA` is the short commit,
both stamped into the *built* bundle by a script phase in `mobile/project.yml`. So build 47
is the 47th commit, and the bundle also carries the SHA outright — the question is
answerable without inverting anything.

`CURRENT_PROJECT_VERSION: "1"` stays as a floor. It is what a build gets when there is no
git to count (a source export), and it is never edited by hand — that was #42's bug, and a
literal that only changes when someone remembers is what #46 removed.

Three consequences worth knowing before you archive:

- **Re-archiving the same commit produces the same number**, and App Store Connect rejects
  it. Deliberate: re-uploading an identical commit is a mistake, and a rejection beats two
  different binaries sharing one build number.
- **Archive from `main`, from a full clone.** The count only rises along one line of
  history — a merged branch can count higher than the `main` it squashed into, and a
  shallow clone counts fewer. Both fail as a rejected upload rather than a wrong build.
- **`EvaGitSHA` gains a `-dirty` suffix** when `mobile/` has uncommitted changes. An
  archive should never carry one; if it does, that build cannot be reproduced from the repo.

There is no mobile CI (#67), so none of this is enforced by a pipeline — it is enforced by
being inside the build, which is why it is a script phase rather than a generated config
file that someone can forget to regenerate.

`mobile/Eva.xcodeproj` is **generated and gitignored**. Edit `mobile/project.yml`, then
`xcodegen generate`.

## 6. Environments & secrets

| Var | Local | Cloud Run |
|---|---|---|
| `FIREBASE_PROJECT_ID` | `api/.env` | `--set-env-vars` from repo var |
| `FIREBASE_WEB_API_KEY` | `api/.env` | `--set-env-vars` from repo var |
| `JWT_SECRET` | `api/.env` | Secret Manager `eva-jwt-secret:latest` |
| Admin credentials | `gcloud auth application-default login`, or a key in `api/.secrets/` | runtime service account (ADC) |

The `RATE_LIMIT_*` knobs (§3) are optional in both environments — unset means the
defaults in `api/src/config.ts`, and they are configuration, not secrets.

The website has one build-time value, `PUBLIC_API_BASE_URL`: the API origin that the
email-link pages (`/activate`, `/reset`) call. Locally it comes from `website/.env`
(see `website/.env.example`); in CI from the `API_BASE_URL` repo variable, and the
deploy workflow refuses to build without it. It is a public URL, not a secret — Astro
inlines `PUBLIC_*` values into the static output. Those two pages are the only part of
the site that talks to the API, and they do so from the browser, so the API must allow
the site's origin on those routes.

CI authenticates by Workload Identity Federation — **no key files in CI, ever**.
`api/.env` and `api/.secrets/` are gitignored and stay that way.

## 6a. What CI runs, and what it does not (#67)

| Suite | Workflow | Runs on | Gates |
|---|---|---|---|
| `scripts/ci-api.sh` | `Test API` | PR touching `api/**`, then again on `main` | the API deploy |
| `scripts/verify-website.sh` | `Test Website` | PR touching `website/**`, then again on `main` | the website deploy |
| `scripts/verify-rules.sh` | `Test Rules` | PR + push touching the rules | — (rules deploy is manual) |
| `scripts/verify-mobile.sh --build` | `Test Mobile` / `Build` | PR touching `mobile/**`, then again on `main` | — |
| `scripts/ci-mobile.sh` | `Test Mobile` / `Full suite` | push to `main`, and nightly — **not** on a PR | — |

Before #67 exactly one of those ran, and `Deploy API` pushed to production Cloud Run on
every merge touching `api/**` with no typecheck and no test in between. The deploys now
`needs:` their suite, so a red one stops the release.

**The API suite runs against the Firebase emulators in CI, not against a real project**
(`scripts/ci-api.sh`). `api/test/` makes real Identity Toolkit and Firestore calls and
creates real accounts; pointing that at production on every pull request is the obvious
cheap move and the wrong one. The emulators need no credential, so the workflow holds no
GCP token and is not granted the `id-token` permission that would let it get one — a
`pull_request` workflow runs code from the branch, and this one can reach nothing.

Two seams make it work, and both are in the emulators' own vocabulary rather than ours:
`firebase.ts` skips `applicationDefault()` when `FIRESTORE_EMULATOR_HOST` is set (it
throws when there is no credential to find), and `identity-toolkit.ts` takes its origin
from `config.identityToolkitBaseUrl`, which points at `FIREBASE_AUTH_EMULATOR_HOST` when
that is set. `firebase emulators:exec` sets both, so nothing has to remember to.

All tests pass under the emulators, in ~28s against ~210s for the real project, and with
**one** second code path in the whole suite (#56). It is worth knowing where, because the
rule is otherwise "no offline mode, no skips, no branching on the environment":
`account-deletion.test.ts` asserts that `accounts:update` cannot repoint an account at an
unverified address. The real project refuses it — email-enumeration protection is on — and
the **emulator allows it**, so there is no single assertion that is true of both. Each
branch asserts the one that holds where it runs, and both are worth having: the refusal is
why #139 and #140 are not reachable today, and the emulator's permissiveness is the premise
`DELETE /me`'s `proven` gate gives defence in depth against.

That is also the sharpest available example of the paragraph below. The emulator is the
**more permissive** environment here, so the branch that would go red if someone turned the
setting off is the one CI never runs. That tripwire lives in `bun run verify` alone. The error-mapping suites
survive the swap because they already control the upstream boundary themselves rather
than provoking real Google errors (`auth-upstream-failures.test.ts`,
`signin-non-enumeration.test.ts`), which is the property that made the emulators viable
at all.

**What it still costs, stated rather than implied: the emulators are a reimplementation.**
A green CI run proves our code against Firebase's model of Firebase, not against Google.
Anything whose behaviour is Google's rather than ours — the real Identity Toolkit reason
strings behind §3's mapping table, Firestore TTL policies, production transaction
contention — is unproven by CI whatever the count says. `scripts/verify-api.sh` still
points at the real project and is what runs locally before a PR. CI is the floor, not the
ceiling, and a green tick is not a substitute for the real run on anything that touches
the auth boundary.

**iOS compiles in CI on a PR; it is not *run* there.** `scripts/verify-mobile.sh` needs a
macOS runner and a simulator, takes ~350s, and macOS runners bill at a premium multiplier;
running the whole suite per PR was considered and declined on cost (#67), and #158 kept
that call. So a pull request gets `--build` — xcodegen, the Info.plist guard, and a
compile of every target including `EvaTests` and `EvaUITests` — while the suite itself
runs on `main` and nightly. A test that compiles and fails is therefore still found a
merge late. Sign in with Apple could not be driven in CI regardless — it cannot be
completed in a simulator.

**A compile is worth a job of its own, and the reason is measured.** `--build` ran plain
`xcodebuild build` until the fix below, and the Eva scheme lists only the app under
`build:` — so the PR job compiled the app and none of the tests. `EvaUITests` had never
once compiled under CI's Xcode 16.4 in that window: every XCUITest API is `@MainActor` in
the SDK and the nine suites were nonisolated, which 16.4 rejects as an error and Xcode
26.2 — the machine they were written on — reports as a warning and builds anyway. The
`Full suite` job failed on every push from the day #158 landed; the pull requests that
added to it were green. `build-for-testing` is what closed that.

**What that cost, once, measured (#135).** The UI suite sat red across at least two
changes and nobody was told. When it was finally run, it held three separate breakages
that had accumulated independently: a Swift 6 key-path error in a file added by #38, which
meant the target did not even compile; a `clearAndType` helper whose one-burst delete left
37 characters of an address behind on iOS 26 — the caret landed mid-string, backspace only
reaches what is to its left, and the new address was then inserted *before* the surviving
tail — so the app sent a malformed address and
`/auth/signin` answered "Wrong email or password" — the same sentence it answers for
everything (§3), which made a harness bug look like an auth regression for eight tests; and
two assertions in `testSignUpLandsOnTheActivationGateWithResendOnCooldown` whose setup #120
had removed, one of them requiring the same screen to be in the opposite state to an
assertion twenty lines above it. Each was invisible to the others until the one in front of
it was fixed. That is the shape of the risk this section describes, and the reason to
reconsider the cost trade rather than a reason to re-litigate it here.

One consequence worth naming: **`docs/AUTONOMY.md`'s ratchet rule can now legitimately
advance for `api/` and `website/`, and still cannot for `mobile/`.** The rule requires a
surface's verify command to have caught a real regression a human would have missed, and
a command nobody runs automatically cannot do that. (`mobile/`'s Plan approval and Deploy
cells did move to `AI` on 2026-09-16 — by direct instruction, not by the ratchet, which is
recorded as such in that file. The gap this paragraph describes is unchanged: it is why
they could not have been *earned*.)

**A red suite does not block the merge**, only the deploy. That half of #67 is not
implementable from this repository: required status checks are branch protection or a
ruleset, and GitHub serves both with `403 Upgrade to GitHub Pro or make this repository
public` for a private repo on a free personal account. So the merge button stays green on
a red suite, and the deploy that follows it does not run — the failure is caught one step
later than intended, and `main` can hold a commit that does not pass.

Closing it costs a GitHub Pro subscription, and is a decision rather than a task. Making
the repository public is not the alternative it looks like: this is a health app whose
issues and PRs discuss real user data handling.

## 7. Known gaps (deliberate, not oversights)

- No refresh tokens. (Password reset landed in #6; account deletion in #8.)
- The retention purge (§4) exists as code and a script but has no scheduler behind it
  until a human creates the Cloud Run job and the Cloud Scheduler trigger. Deleted
  events stay recoverable-forever until then.
- `/auth/*` throttling is per Cloud Run instance and in memory (see §3): it raises the
  cost of credential stuffing, it does not bound it. A shared store is the real fix.
- `firestore.rules` / `storage.rules` are deny-all. CI proves they still deny
  everything (`Test Rules`, `scripts/verify-rules.sh`) but never deploys them on push:
  `Deploy Rules` is `workflow_dispatch`-only. It was run by a human until 2026-09-16,
  when AUTONOMY's Deploy row moved to `AI`; what gates it now is `needs: test` and
  `everyAllowIsDenied()` (GUARDRAILS 6a), not who presses the button.
- Firebase iOS SDK is not linked (commented out in `project.yml`).
- **One region, and no backups.** Everything lives in `us-central1`; the Firestore
  location is immutable, so serving another region later is a migration, not a setting.
  Nothing schedules a Firestore backup — a daily schedule with a stated retention is a
  one-time human act (`docs/LAUNCH.md` §7, A23). Until it exists, a bad deploy or a bad
  purge is unrecoverable.
- No local store on iOS and no push transport — designed in §8 and §9, not built.
- The production API base URL is out of the source (§5) but still baked in at build
  time: changing it means a new build and a new release, and there is still no staging
  configuration to point at — `Release` is the only non-local one.

Anything here is a candidate backlog item, not something to "fix while nearby".

## 8. Offline: the local store and the sync queue (A3)

**Decision (2026-08-30, A3):** offline is v1, and the store comes first — before Calendar
slice C3 (#11), because every screen from C3 on reads from it. This section is the design
those slices build to; its implementation issue is gated on this text being approved.

### 8.1 The rule

**Screens read the store. Only the sync engine talks to the API.** No view, view model or
`AppSession` path fetches events, refdata or the Today card from the network for display;
it reads the local copy, and the sync engine refreshes that copy when it can. The one
exception stays: authentication (`/auth/*`, `/me`) is online-only and goes through
`AppSession` exactly as §5 describes — a token is not health data and does not queue.

The PRD asks for three things this rule delivers at once: full logging offline with entries
that queue and sync (§Calendar Edge cases 4), a calendar that reads from the local store
(same line), and a Today card that is cached and does not change on repeated opens
(§Dashboard Other requirements 3).

### 8.2 What is stored

SwiftData, one model per wire type, mirroring `APIModels` field for field — the store is a
cache of the server's shape, not a second schema:

| Model | Mirrors | Key |
|---|---|---|
| `LocalEvent` | `EvaEvent` (§4) | `serverId` (nullable until acknowledged) + `clientId` (UUID, created on device, **is** the `idempotencyKey`) |
| `LocalRefdata` | `/refdata` catalogues + `version` | catalogue id |
| `LocalContent` | `/content` templates, banners, nudges + `version` | content id |
| `LocalTodayCard` | the Dashboard card (#10, when it exists) | date |
| `PendingOperation` | the queue (§8.4) | FIFO sequence |

`LocalEvent` carries the server's `localDate`, `loggedAt`, `type`, `payload`, `note`,
`source`, `deletedAt`, `updatedAt` verbatim, plus two device-only fields: `syncState`
(`synced | pendingCreate | pendingUpdate | pendingDelete | failed`) and `lastError`
(the API error `code`, for the "Couldn't sync your last entry" card in the Design System).

The store's file is in Application Support with `NSFileProtectionCompleteUntilFirstUserAuthentication`
(background sync must be able to open it after a reboot-and-unlock; `Complete` would not),
and is **excluded from iCloud and iTunes backup** — the server is the copy of record, and a
device backup would be a second copy of a health record living somewhere Eva does not
control. The Keychain token was backup-restorable until #64 and is now written
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — never in a backup, readable after the
first unlock following a reboot, which is what a launch needs. `save` deletes and re-adds
rather than updating, because `SecItemUpdate` does not migrate accessibility in place and
that is the only path that moves an existing install off the old attribute. The local store
follows the same rule for the same reason.

### 8.3 Reads

- The month grid and day sheet query `LocalEvent` by `localDate` range, excluding
  `deletedAt != nil` — the same predicate the API's range read applies.
- On foreground, on a month change, and after the queue drains, the engine calls
  `GET /me/events?from=&to=` for the visible range ±1 month and **reconciles by `serverId`**:
  server rows replace local rows in `synced` state; local rows in any `pending*` state are
  left alone (their operation has not been acknowledged yet, so the server's view is older
  than the device's); server rows absent locally are inserted; local `synced` rows absent
  from the server response inside the fetched range are deleted (they were purged or
  deleted elsewhere).
- Refdata uses the version handshake that already exists: the stored `version` goes out as
  `?version=`, a `304` means keep the copy.
- A screen never blocks on the network. The first-run empty state (PRD §Calendar Edge cases
  9) is the empty store, not a spinner.

### 8.4 Writes and the queue

Every user action writes the store first and appends a `PendingOperation`; the UI reflects
the store immediately. The engine drains the queue FIFO whenever the network is reachable,
one operation at a time, and never reorders — because an edit to an entry must follow its
creation, and a delete must follow both.

| Local action | Store | Queued operation | On acknowledgement |
|---|---|---|---|
| Log an entry | insert, `pendingCreate`, `clientId` = new UUID | `POST /me/events` with `idempotencyKey: clientId` | write `serverId`, `synced` |
| Edit | update fields, `pendingUpdate` | `PATCH /me/events/{serverId}` (must carry `type` and `localDate`, §3) | `synced` |
| Body signals for a day | upsert, `pendingUpdate` | `PUT /me/body-signals/{date}` | `synced` |
| Delete | set `deletedAt` locally, `pendingDelete` — the row leaves the screen now | `DELETE /me/events/{serverId}` | `synced` |
| Undo, toast still up | clear `deletedAt`; if the delete op is still queued, **remove it** | — (or `POST …/restore` if it already went) | `synced` |

**How the API's idempotency actually works, verified against `api/src/events.ts`:**

- For `sport`, `appointment` (and `sex` when C10 lands) `createEvent` runs a transaction
  that looks up `idempotencyKey` and returns the existing document if one matches. A
  `POST` the device retries after a timeout therefore cannot double-log. This is the
  guarantee the queue relies on, and `api/test/` must keep pinning it.
- For the one-per-day types `cycle`, `bodySignals` and `positiveTest` the key is **ignored** — the
  deterministic document ID (`cycle_2026-08-27`) makes the write idempotent by
  construction, and a repeat simply re-sets the same day. Same guarantee, different
  mechanism; the client does not need to know which.
- An edit to a one-per-day entry that would move its `localDate` is refused by the API
  (`immutable-date`); the client mirrors this by never offering a date change on those
  types — delete and re-log, as §4 already says.
- An operation that comes back `4xx` is **not retried**: the store row goes to `failed`
  with `lastError`, the entry shows the error card with Retry, and the queue moves on so
  one bad entry cannot block the rest. `5xx`, `429` (`Retry-After`) and network failures
  back off — 1 s, 2 s, 4 s … capped at 5 min — and the queue **does** block, because order
  matters. A `401` on a request that carried the token is the session's business (§5) and
  the queue pauses until there is a session again; nothing is discarded.

**Conflicts.** Two devices are possible (the token is not device-bound). The rule is
last-write-wins by the server's `updatedAt`, which is what a reconcile (§8.3) applies.
That is honest for a single-user health log: the newest entry the user made anywhere is the
one she meant. A one-per-day type resolves at the server by its document ID; the client
never sees a merge.

**Dates.** `localDate` and `loggedAt` are the device's wall clock at the moment of logging
and are stored as strings on both sides — a queued entry logged in Lisbon and synced from
New York keeps its Lisbon day (§4, PRD §Calendar Edge cases 5). The request's optional
`timeZone` is sent for the "today" check; it is still not stored on the event.

### 8.5 Session and account boundaries

- **Log out** wipes the store and the queue. Pending operations are lost, and the log-out
  confirmation must say so when the queue is non-empty ("2 entries have not synced yet").
- **Account deletion** wipes the store *after* `DELETE /me` succeeds; a queued operation
  is dropped, not sent.
- **`EVA_UITEST_RESET=1`** (§5) wipes the store as well as the Keychain — the hook's contract
  is "a fresh install", and a fresh install has no store.
- A second account signing in on the same device starts from an empty store; the store is
  keyed to the uid and a mismatch wipes it.

### 8.6 Testing

The store and the engine are the unit under test, driven through `EvaStubURLProtocol`
(already in `EvaTests`), which can answer a `POST` with a timeout and then a `201` for the
same `idempotencyKey` — the retry case that matters. The UI tests (`EvaUITests`) run with
the network stub set to "offline" for one flow: log, kill, relaunch, come online, assert one
entry on the server. `scripts/e2e.sh` gains that flow against the real API.

### 8.7 What this adds to GUARDRAILS.md (in the implementation PR, not here)

- Screens read the local store; only the sync engine calls `/me/events`, `/me/body-signals`
  and `/refdata` — and `/content`, which caches by the same `version` handshake (#97).
- Every created event carries a device-generated `idempotencyKey`; the API's lookup on it is
  a pinned test.
- The store is excluded from backups and wiped on log-out, account deletion and
  `EVA_UITEST_RESET`.
- The `events` composite index (#27) is deployed, and `listEvents` filters `deletedAt` in
  the query — the sync engine's first reconcile is that read.

## 9. Push notifications (A9)

**Decision (2026-08-30, A9):** APNs, sent directly from the API. The app does not link the
Firebase iOS SDK; "the iOS app talks only to the Eva API" (§2) stays true, because
registering a device token with the API is talking to the API.

### 9.1 Two kinds of notification, two transports

Not everything needs the server. With the local store (§8) on the device, anything the
device already knows can be a **local notification**, scheduled by iOS from the store:

| Notification | Source of truth is on the device? | Transport |
|---|---|---|
| Appointment reminder (`reminderMinutesBefore` on the entry) | yes | local |
| Meal reminders (usual meal times, Nutrition Step 3) | yes | local |
| Period predicted within two days (C11 output, once cached) | yes, once synced | local |
| Educational content, "your Today card is ready", well-being check-ins | no — the server chooses | **APNs** |
| Pregnancy-loss stop rule: cancel everything queued | both | local cancel + server marks `notifications/` |

Local notifications work offline, need no device registry to be correct, and cannot leak
what the server does not know. APNs is for what originates on the server. The rule is
"local if the device can compute it; APNs otherwise" — not "APNs for everything", which
would make an appointment reminder depend on a Cloud Scheduler tick.

### 9.2 API side

- **`apns.ts`** — the transport. Token-based auth (`.p8` key, key id, team id) over HTTP/2
  to `api.push.apple.com` / `api.sandbox.push.apple.com`. The key lives in Secret Manager
  as `eva-apns-key:latest`, declared as `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` in
  `config.ts` and `.env.example`; **this file is the only reader**, the way
  `identity-toolkit.ts` is the only reader of the web API key (GUARDRAILS 4).
- **`devices.ts`** — owns `users/{uid}/devices/` (GUARDRAILS 10: one owner per collection).
  `PUT /me/devices/{deviceId}` registers or replaces a token with its environment and IANA
  time zone; `DELETE /me/devices/{deviceId}` on log-out. Tokens rotate; the device id is
  a UUID the app mints once per install so a rotation is a replace, not a second row.
- **`notifications.ts`** — owns `users/{uid}/notifications/`: the intents, what was sent,
  what was read. `GET /me/notifications` is the notification centre the PRD's feature list
  names. Sends are recorded here **before** the APNs call (`sentAt` set in the same
  write that claims the row), so a job that dies mid-run re-sends nothing: reminders are
  at-most-once by design; a missed one is a smaller harm than a duplicate.
- **The sender is a Cloud Run job**, same image, entrypoint `scripts/send-notifications.ts`,
  on a Cloud Scheduler tick every 5 minutes — the same shape as the purge job (§4), for
  the same reasons: no HTTP surface, IAM-authorised, `--dry-run`. It selects
  `notifications` with `dueAt <= now` and `sentAt == null`, fans out to the account's
  devices, and handles APNs' answers: `410` / `BadDeviceToken` deletes the device row;
  `429` and `5xx` leave the row for the next tick.
- **Time zones.** `dueAt` is an instant computed from a local wall-clock time in the
  *device's* time zone (from the device row) at the moment the intent is created. A user
  who travels keeps the reminder at the time it was set for, in the zone it was set in —
  the same rule as `localDate` (§4). The device's zone is updated on every register call.

### 9.3 What a payload may contain

**Nothing.** The APNs payload is the fixed title `Eva`, the fixed body `Eva has an update`,
a `kind`, and the `notifications/{id}` — never a symptom, a flow level, a date that is a
cycle day, an appointment type, or a name. GUARDRAILS 12 already forbids health data in
logs; a push payload transits Apple and is displayed on a lock screen, so the rule extends
to it verbatim. The canvas' notification screen says exactly this ("Previews never show
symptoms, flow, sex or appointment details") and the PRD makes it a requirement
(§Notifications, Content rules). The app fetches the detail after unlock. `mutable-content`
and notification service extensions are not used — decrypting a richer payload on device
would only be a second way to get this wrong.

Local notifications follow the same rule for their *visible* text, and may carry the
entry's id in `userInfo` for deep-linking.

### 9.4 iOS side

`UNUserNotificationCenter` for permission and local scheduling;
`registerForRemoteNotifications` for the token, which `AppSession` sends to
`PUT /me/devices/{deviceId}` after any successful bootstrap. The permission prompt's
timing is open (`docs/LAUNCH.md`); the design only requires that it is **never** shown
before the first thing that would benefit from it exists (an appointment with a reminder,
a completed Nutrition setup). Device id and the last-registered token live in the Keychain
beside the JWT — `KeychainTokenStore` grows, no second store.

### 9.5 Deletion and privacy

- `DELETE /me` (§4) gains two steps: delete `devices/` and `notifications/`, before the
  user document. An APNs token is a device identifier and `notifications/` is a log of
  what Eva reminded someone about — both are exactly the kind of record `docs/LAUNCH.md`
  §2.4 wants gone when the account is gone.
- The sender job never logs a uid–token pair or a `kind` with a uid; its log line is
  counts, like the purge's.
- A pregnancy loss (PRD §Pregnancy loss 3) must stop everything *immediately, including
  anything already queued*: the app cancels its local notifications and calls the API,
  which marks every pending pregnancy-kind row `sentAt = now` with a `cancelled` flag in
  the same transaction that changes the mode. The 5-minute tick is not fast enough on its
  own; the cancellation is synchronous.

### 9.6 What this adds to GUARDRAILS.md (in the implementation PR, not here)

- No push payload, local or remote, carries health content; the visible text is fixed.
- `apns.ts` is the only reader of the APNs credentials.
- `devices.ts` and `notifications.ts` are the only modules touching their collections, and
  `DELETE /me` enumerates both.
- The sender is a job, not a route, and is at-most-once.

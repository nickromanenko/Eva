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
  Identity Toolkit REST API (`accounts:signUp`, `accounts:signInWithPassword`) with
  the Firebase **web** API key. That file is the only outbound auth dependency.

Full rationale: [`superpowers/specs/2026-07-18-email-auth-design.md`](superpowers/specs/2026-07-18-email-auth-design.md).

## 3. API module map (`api/src/`)

| File | Owns | Rule |
|---|---|---|
| `index.ts` | Routes, request validation, HTTP status/error mapping | No Firestore or `fetch` calls here — delegate |
| `auth.ts` | Minting and verifying the Eva JWT, `requireAuth` middleware | The only place `JWT_SECRET` is used |
| `identity-toolkit.ts` | Password credential create/verify via Google REST | The only place the web API key is used |
| `rate-limit.ts` | In-memory attempt counters for `/auth/*` | Holds no identity state; never logs its keys |
| `users.ts` | The `users/{uid}` document: read, create, update | The only module that touches `users/` |
| `events.ts` | The `users/{uid}/events/` subcollection: create, range read, edit, soft delete | The only module that touches `events/` |
| `refdata.ts` | The `refdata/` collection: the option lists the client draws, and the version they are cached against | The only module that touches `refdata/` |
| `firebase.ts` | Admin SDK singleton (Application Default Credentials) | Never construct a second app |
| `config.ts` | Required env vars, fail-fast at boot | Every new env var is declared here **and** in `.env.example` |

Layering: `index.ts` → (`auth`, `identity-toolkit`, `rate-limit`, `users`, `events`, `refdata`)
→ (`firebase`, `config`). Never call upward, never sideways along the middle row.

### Contracts

Errors are always `{ "error": { "code": string, "message": string } }`. `code` is a
stable machine identifier (`VALIDATION`, `EMAIL_EXISTS`, `INVALID_CREDENTIALS`,
`UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`, `BACKDATE_LIMIT_EXCEEDED`,
`UNKNOWN_SYMPTOM_CODE`, `WEAK_PASSWORD`, `RATE_LIMITED`);
`message` is human-facing and may be shown in the app. Changing a code is a breaking
change for the iOS client.

| Route | Auth | Success |
|---|---|---|
| `GET /health` | — | `{ status: "ok" }` |
| `POST /auth/signup` | — | `201 { token, user }` |
| `POST /auth/signin` | — | `200 { token, user }` |
| `GET /me` | Bearer | `{ user }` |
| `PUT /me/questionnaire` | Bearer | `{ user }` |
| `GET /me/events?from=&to=` | Bearer | `{ events }` — inclusive `localDate` range, soft-deleted excluded |
| `POST /me/events` | Bearer | `201 { event }` |
| `PATCH /me/events/{id}` | Bearer | `{ event }` — body must carry `type` and `localDate` |
| `DELETE /me/events/{id}` | Bearer | `{ deleted: true }` — soft delete |
| `PUT /me/body-signals/{date}` | Bearer | `{ event }` — upsert by day |
| `GET /refdata?version=` | Bearer | `{ version, catalogues }` — `304` when `version` (or `If-None-Match`) already matches |

**Password rule — creation only.** `POST /auth/signup` enforces the rule the sign-up
screen states as helper text: *at least 8 characters, including one number*. A password
that fails it is `400 WEAK_PASSWORD`, and the `message` **is** that helper text verbatim,
so the user is never told two different rules. The server's copy of the string lives in
`api/src/index.ts` and the client's in
`mobile/Eva/Onboarding/Steps/CreateAccountStepView.swift`; `api/test/auth.test.ts` reads
the Swift file and asserts they still match. `POST /auth/signin` **never** applies the
rule — accounts that predate it hold passwords with no digit and must keep working.

**Sign-in answers identically whether the password was wrong or the address was never
registered** — same status, same code, same message. This is deliberate: knowing that an
address has an Eva account is itself sensitive. Note the property currently rests on two
layers, ours and Identity Toolkit's own collapse of both cases upstream, so a regression in
ours would not be visible from outside. `api/test/signin-non-enumeration.test.ts` pins it by
controlling the upstream boundary.

`POST /auth/signup` deliberately does the **opposite** and returns `EMAIL_EXISTS` — the
caller already holds the address, and the canvas' account-linking banner depends on knowing.
The asymmetry is intended; do not "fix" it.

**`/auth/*` is throttled, per instance only.** Both auth routes count each attempt against
two counters — the caller's IP and the submitted address — and answer
`429 RATE_LIMITED` with a constant `Retry-After` once either is over its limit. Limits come
from `config.rateLimit` (`RATE_LIMIT_*`, all optional; any of them set to `0` disables that
dimension). Sign-up and sign-in hold separate budgets.

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
throttling rather than to this implementation, and is why the per-address limits are not
tighter.

The throttle is applied **after** validation and **before** the Identity Toolkit call, so it
can never see, and never depends on, whether an address is registered — that is what keeps
the non-enumeration property above intact. `api/test/signin-non-enumeration.test.ts` pins
that a throttled registered address and a throttled unknown one are byte-identical.

The JWT is HS256, 30-day TTL, claims `{ sub, email, iat, exp }`. **There is no refresh
token in v1** — expiry means sign in again. Adding refresh is an architecture change,
not a task.

## 4. Data model

`users/{uid}` — document ID is the Firebase Auth uid, deliberately, so any future
provider resolving to the same Auth account lands on the same document.

```
email                  string
authProviders          string[]        // arrayUnion, e.g. ["password"]
questionnaireCompleted boolean
profile                Profile | null  // see api/src/users.ts
createdAt, updatedAt   serverTimestamp
```

`Profile` is validated at the edge in `parseProfile` (`index.ts`) with hard ranges:
age 13–99, weight 30–200 kg, height 120–220 cm. Widening a range is a product
decision, not a bug fix.

`users/{uid}/events/{eventId}` — one subcollection for every calendar entry,
discriminated by `type` (`cycle`, `bodySignals`, `sport`, `appointment`; `sex` is
reserved for C10). Owned by `api/src/events.ts`.

```
type          'cycle' | 'bodySignals' | 'sport' | 'appointment'
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

`cycle` and `bodySignals` are one entry per user per day, enforced by a deterministic
document ID (`cycle_2026-08-27`), so re-logging replaces rather than accumulates. As
a consequence their `localDate` cannot be changed by `PATCH` — delete and re-log.

`refdata/{catalogueId}` — the option lists the client draws, one document per
catalogue (`symptoms`, `sportActivities`, `appointmentTypes`). Owned by
`api/src/refdata.ts`. Content is data, not code: adding an option or fixing a label is
a Firestore write, never a deploy (PRD:483).

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
`severity` (`normal | severe`) and its `value` (the chip's picker, e.g. discharge
`dry|sticky|creamy|watery|egg-white`) are separate axes — an intensity and a category.

Catalogues are seeded with `cd api && bun run seed:refdata` (additive; `--relabel` also
resets labels). It is a script, not a route: the Admin SDK bypasses `firestore.rules`,
so seeding needs no rules change and no admin authorization surface.

## 5. iOS app structure (`mobile/Eva/`)

| Folder | Owns |
|---|---|
| `Networking/` | `APIClient` (generic async JSON), `APIError`, `APIModels` (wire types) |
| `Session/` | `AppSession` — the single source of app state; `KeychainTokenStore` — the only place the JWT is persisted |
| `Onboarding/` | `OnboardingModel` (flow state machine) + `Steps/` + `Components/` |
| `Theme/` | Colors, gradients, `PrimaryButton`, progress style — see [DESIGN.md](DESIGN.md) |

`AppSession.State` (`loading → signedOut | needsQuestionnaire | ready`) drives the root
view. **The server is the source of truth for `questionnaireCompleted`** — never
reintroduce a local `@AppStorage` flag for it.

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

CI authenticates by Workload Identity Federation — **no key files in CI, ever**.
`api/.env` and `api/.secrets/` are gitignored and stay that way.

## 7. Known gaps (deliberate, not oversights)

- No refresh tokens; no password reset; no account deletion.
- `/auth/*` throttling is per Cloud Run instance and in memory (see §3): it raises the
  cost of credential stuffing, it does not bound it. A shared store is the real fix.
- `firestore.rules` / `storage.rules` are deny-all. CI proves they still deny
  everything (`Test Rules`, `scripts/verify-rules.sh`) but never deploys them on push:
  `Deploy Rules` is `workflow_dispatch`-only and run by a human.
- Firebase iOS SDK is not linked (commented out in `project.yml`).
- The production API base URL is out of the source (§5) but still baked in at build
  time: changing it means a new build and a new release, and there is still no staging
  configuration to point at — `Release` is the only non-local one.

Anything here is a candidate backlog item, not something to "fix while nearby".

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
| `users.ts` | The `users/{uid}` document: read, create, update | The only module that touches `users/` |
| `events.ts` | The `users/{uid}/events/` subcollection: create, range read, edit, soft delete | The only module that touches `events/` |
| `firebase.ts` | Admin SDK singleton (Application Default Credentials) | Never construct a second app |
| `config.ts` | Required env vars, fail-fast at boot | Every new env var is declared here **and** in `.env.example` |

Layering: `index.ts` → (`auth`, `identity-toolkit`, `users`, `events`) → (`firebase`, `config`).
Never call upward, never sideways between the middle three.

### Contracts

Errors are always `{ "error": { "code": string, "message": string } }`. `code` is a
stable machine identifier (`VALIDATION`, `EMAIL_EXISTS`, `INVALID_CREDENTIALS`,
`UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`, `BACKDATE_LIMIT_EXCEEDED`);
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

Two escape hatches, both DEBUG-only, both used by tooling — keep them working:
- `EVA_ONBOARDING_STEP=<rawValue>` jumps straight to a step.
- `EVA_UITEST_RESET=1` clears the Keychain at launch.
- `EVA_API_BASE_URL` repoints the client (used by `scripts/e2e.sh`).

`mobile/Eva.xcodeproj` is **generated and gitignored**. Edit `mobile/project.yml`, then
`xcodegen generate`.

## 6. Environments & secrets

| Var | Local | Cloud Run |
|---|---|---|
| `FIREBASE_PROJECT_ID` | `api/.env` | `--set-env-vars` from repo var |
| `FIREBASE_WEB_API_KEY` | `api/.env` | `--set-env-vars` from repo var |
| `JWT_SECRET` | `api/.env` | Secret Manager `eva-jwt-secret:latest` |
| Admin credentials | `gcloud auth application-default login`, or a key in `api/.secrets/` | runtime service account (ADC) |

CI authenticates by Workload Identity Federation — **no key files in CI, ever**.
`api/.env` and `api/.secrets/` are gitignored and stay that way.

## 7. Known gaps (deliberate, not oversights)

- No refresh tokens; no password reset; no account deletion.
- No rate limiting on `/auth/*`.
- `firestore.rules` / `storage.rules` are deny-all and not deployed by CI.
- Firebase iOS SDK is not linked (commented out in `project.yml`).
- The production API base URL is hardcoded in `APIClient.resolveBaseURL()`.

Anything here is a candidate backlog item, not something to "fix while nearby".

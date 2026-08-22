# Email/Password Sign-Up & Sign-In — Design Spec

**Date:** 2026-07-18 · **Status:** Draft for review

## 1. Context & Goals

Eva currently has a stubbed onboarding flow: the sign-up buttons only advance the UI, nothing is persisted, and "completion" lives in a local `@AppStorage` flag. This task makes email/password auth fully functional end-to-end:

- Real sign-up and sign-in with email + password (Firebase Auth; already enabled in the `eva-ai-made-for-women` console).
- A `users` collection in Firestore as the canonical user store — one record per person, keyed for future provider matching by email.
- The **API mints its own JWT**; the iOS app authenticates to the API with it.
- After sign-up/sign-in the app routes by questionnaire state: incomplete → questionnaire, complete → dashboard (today's placeholder home screen).
- The whole path is **automatically validated** against the real Firebase project: sign up → redirect asserted in UI tests; user record asserted in Firestore.

Out of scope (explicitly later): Google/Apple sign-in (UI buttons show "coming soon"), refresh tokens, password reset, email verification, the designed dashboard UI.

## 2. Architecture (decided: API-mediated)

The iOS app never talks to Firebase directly and does not embed the Firebase SDK. All auth flows through the API:

```
iOS ──(email+password)──▶ API (Hono/Bun, Cloud Run)
                           │ 1. Identity Toolkit REST (signUp / signInWithPassword)
                           │ 2. firebase-admin → Firestore users/{uid} (create/read)
                           │ 3. Mint JWT (HS256, 30 days)
iOS ◀──({ token, user })───┘
```

- **Firebase Auth** remains the credential store (password hashing, email uniqueness, future providers).
- **Identity Toolkit REST API** (`accounts:signUp`, `accounts:signInWithPassword`, with the project's Web API key) is how the API creates/verifies credentials — the Admin SDK cannot verify passwords.
- **firebase-admin** (runs on Bun) accesses Firestore using Application Default Credentials: the Cloud Run runtime service account in production, `gcloud auth application-default login` locally.
- **JWT**: HS256 via `hono/jwt`. Claims: `sub` (Firebase uid), `email`, `iat`, `exp` (+30 days). Secret from `JWT_SECRET` env var. No refresh tokens in v1 — on expiry or 401 the app returns to the welcome screen.

## 3. Data model: `users` collection

Document ID = **Firebase Auth uid**. One document per person, ever.

```jsonc
users/{uid} {
  "email": "maya@example.com",      // lowercase, trimmed
  "authProviders": ["password"],     // grows when Google/Apple are linked
  "questionnaireCompleted": false,
  "profile": null,                   // set by questionnaire submission:
  // { "age": 28, "weightKg": 64, "heightCm": 168,
  //   "goals": ["Energy"], "conditions": ["None of these"],
  //   "medications": "No", "lifestyle": "Active", "sports": ["Yoga"] }
  "createdAt": <serverTimestamp>,
  "updatedAt": <serverTimestamp>
}
```

**Email uniqueness & provider matching.** Firebase Auth's "one account per email" guarantees a single uid per email at the credential layer; the API additionally normalizes emails (lowercase/trim) and returns `409` on `EMAIL_EXISTS`. The standing rule for later providers: on Google/Apple sign-in, resolve the **existing Auth user by email and link the new credential to that same uid** — never create a second `users` document. Because the doc ID is the uid, matching-by-email reduces to "same uid → same doc".

**Security rules** stay deny-all for clients (already committed). Only the API (Admin credentials, which bypass rules) touches Firestore.

## 4. API changes (`api/`)

New env vars (local `.env` + Cloud Run): `FIREBASE_WEB_API_KEY`, `FIREBASE_PROJECT_ID=eva-ai-made-for-women`, `JWT_SECRET`.

New dependency: `firebase-admin`. Structure: `src/index.ts` (routes) + `src/auth.ts` (Identity Toolkit client, JWT helpers, middleware) + `src/users.ts` (Firestore repository).

| Endpoint | Auth | Request | Success | Errors |
|---|---|---|---|---|
| `POST /auth/signup` | — | `{email, password}` | `201 {token, user}` | `409` email exists · `400` invalid email / password < 8 chars |
| `POST /auth/signin` | — | `{email, password}` | `200 {token, user}` | `401` invalid credentials |
| `GET /me` | Bearer | — | `200 {user}` | `401` missing/expired/invalid token |
| `PUT /me/questionnaire` | Bearer | full profile object | `200 {user}` (sets `questionnaireCompleted: true`) | `400` validation · `401` |

`user` payload: `{ id, email, questionnaireCompleted, profile }`. Error body: `{ error: { code, message } }` with stable codes (`EMAIL_EXISTS`, `INVALID_CREDENTIALS`, `VALIDATION`, `UNAUTHORIZED`).

Signup writes the `users/{uid}` doc immediately after the Identity Toolkit call succeeds. Signin is defensive: if the doc is somehow missing, it is created on the spot (self-healing, also the hook where future providers attach).

## 5. iOS changes (`mobile/`)

New `Networking/` + `Session/` groups:

- **`APIClient`** — URLSession + async/await, JSON coding, auth header injection. Base URL: `#if DEBUG` `http://localhost:3003` `#else` the Cloud Run URL — overridable via `EVA_API_BASE_URL` launch environment (used by UI tests).
- **`KeychainTokenStore`** — JWT persisted in the Keychain (not UserDefaults).
- **`AppSession`** (`@Observable`) — replaces the `hasCompletedOnboarding` `@AppStorage` flag; the server is now the source of truth. States: `.signedOut`, `.needsQuestionnaire`, `.ready`. On launch: stored token → `GET /me` → route; 401 → signed out.

Screen work:

- **EmailSignUpStepView**: wire "Create account" to `POST /auth/signup` — loading state on the button, inline error on failure (409 shows "This email is already registered" with a link to Log in).
- **New LoginStepView**: email + password form in the same visual language (reuses the field styling), reached from "Log in" on the welcome screen. Errors surface inline ("Wrong email or password").
- **SignUpStepView**: Apple/Google buttons now show a "Coming soon" alert instead of fake-advancing.
- **Routing** after any successful auth: `questionnaireCompleted` false → `.aboutYou`; true → dashboard (current home screen). "Build my plan" (lifestyle step) submits `PUT /me/questionnaire`, then shows the done screen; "Enter Eva" → dashboard.
- **Dashboard placeholder** gains a "Log out" button (clears Keychain + session) — needed for testing and matches the design's dashboard.

## 6. Automated validation (against the real Firebase project)

Throwaway-account discipline: every test account uses `e2e+<uuid>@e2e.evaapp.dev`, and cleanup **always** deletes both the Auth user and the Firestore doc (admin SDK, in `afterEach`/finally). A standalone `scripts/e2e-cleanup.ts` sweeps any stragglers matching the prefix.

1. **API integration tests** (`bun test`, run with the API pointed at the real project):
   - signup → 201, JWT verifies, `users/{uid}` doc exists with correct email + `questionnaireCompleted: false` (asserted via firebase-admin)
   - duplicate signup → 409
   - signin (right/wrong password) → 200 / 401
   - `GET /me` with/without token → 200 / 401
   - `PUT /me/questionnaire` → flag flips, profile persisted, re-signin routes as completed
2. **iOS UI test** (XCUITest target `EvaUITests`): launches the app with `EVA_API_BASE_URL` → local API and a generated email; drives welcome → info → sign-up → email form; submits; **asserts the questionnaire screen appears** (the redirect requirement); completes the questionnaire; asserts dashboard. A companion assertion (in the orchestration script) confirms the Firestore record exists.
3. **`scripts/e2e.sh`** orchestrates: boot API locally (real Firebase env) → `bun test` → `xcodebuild test` on the simulator → cleanup sweep → non-zero exit on any failure. Runnable locally now; CI wiring can come later.

## 7. Deployment / manual steps (one-time, Nick)

- Set Cloud Run env: `FIREBASE_WEB_API_KEY`, `FIREBASE_PROJECT_ID`, `JWT_SECRET` (deploy workflow gains `--set-env-vars` / secret reference; `JWT_SECRET` ideally via Secret Manager).
- Grant the Cloud Run runtime service account `roles/datastore.user`.
- Local dev: `gcloud auth application-default login` with nick.romanenko@gmail.com (already the active gcloud account).

## 8. Risks & notes

- **Real-project testing** pollutes prod on failed cleanup — mitigated by the unique prefix + sweep script; worth revisiting emulators if test volume grows.
- **Identity Toolkit error surface** is stringly-typed (`EMAIL_EXISTS`, `INVALID_LOGIN_CREDENTIALS`…) — the API maps them to stable codes so iOS never parses Google strings.
- **JWT secret rotation** invalidates all sessions — acceptable at this stage.
- The Web API key is not a secret (it ships in every Firebase client app) but still lives in env config, not git.

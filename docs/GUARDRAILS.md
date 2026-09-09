# Eva — Guardrails

Non-negotiable rules for anyone, human or agent, changing this repo. A change that
breaks one of these is rejected regardless of whether tests pass.

Each rule is stated so a reviewer can check it mechanically.

## Secrets & credentials

1. **No secret ever enters the repo.** No API keys, service-account JSON, JWT secrets,
   or `.env` contents in source, tests, fixtures, docs, or commit messages.
   `api/.env` and `api/.secrets/` are gitignored — keep them that way.
2. **Every new env var is declared in `api/src/config.ts` and `api/.env.example`**
   (with a placeholder, never a real value). `config.ts` must fail fast at boot.
3. **CI never uses key files.** Authentication is Workload Identity Federation.
   Production secrets come from Secret Manager (`eva-jwt-secret:latest`).
4. `JWT_SECRET` is read only in `api/src/auth.ts`; the Firebase web API key only in
   `api/src/identity-toolkit.ts`; `POSTMARK_API_KEY` only in `api/src/email.ts`;
   `APPLE_SIGNIN_KEY` (and the rest of `config.providers`) only in `api/src/providers.ts`.
   Don't spread them. `APPLE_SIGNIN_KEY` signs for Apple and `JWT_SECRET` signs for us —
   neither file ever touches the other's key. This rule is about `api/src/`; `api/test/` is
   outside it, and has to be. A test that asked the owning module whether a credential still
   works would be asking a module `mock.module` has replaced — process-globally,
   permanently, by whichever suite loaded first. So `provider-signin.test.ts` reads the web
   API key to ask Identity Toolkit directly, and `apple-client-secret.test.ts` sets
   `config.providers.apple` to a key it generates. Neither is a real credential; rule 1
   still binds.

## Security rules (Firestore / Storage)

5. **`firestore.rules` and `storage.rules` stay deny-all** until a client is genuinely
   meant to reach Firebase directly. They are deny-all *by design* — the app talks to
   the API, and the Admin SDK bypasses rules. See [ARCHITECTURE.md §2](ARCHITECTURE.md).
6. Any loosening of either file is **fully supervised**: human plan approval, human
   review, human deploy. Never bundled into an unrelated change.
7. Rules are **never deployed automatically.**
   `.github/workflows/deploy-rules.yml` is `workflow_dispatch`-only and exists to make the
   human act auditable, not to remove it. Adding any automatic trigger to that workflow is
   a guardrail violation.

## Auth & data

8. The iOS app never calls Firebase directly. New backend capability = new API route.
9. `users/{uid}` document IDs are Firebase Auth uids. Never generate your own ID,
   never key users by email.
10. **Every Firestore collection has exactly one owning module, and nothing else touches
    it.** `users.ts` owns `users/`; `events.ts` owns `users/{uid}/events/`;
    `refdata.ts` owns `refdata/`; `email-tokens.ts` owns `authTokens/`. Routes
    delegate; they don't query. (Widened from "only `users.ts` touches Firestore" when the
    calendar needed a second collection — the intent was never one file, it was no
    scattered database access.)
11. Error responses keep the shape `{ error: { code, message } }`. Existing codes are a
    client contract — adding is fine, renaming or repurposing is a breaking change. The
    current set lives in [ARCHITECTURE.md](ARCHITECTURE.md) §3 and grows; do not duplicate
    it here, because the copy goes stale (it already did).
12. Never log a password, a token, a full JWT, a user's `profile` contents, or **any
    event payload** — cycle days, flow levels, symptoms, sex events. All of it is health
    data, and a symptom log in a log line is worse than a profile field. An activation or
    reset link is a token: never log the link, the raw token, its hash, or the address it
    went to. `EMAIL_TRANSPORT=log` is the one exception and is refused in production.
12a. **A link token is stored as a hash, handed out once, and never put in a URL a server
    can see.** `authTokens/` documents are keyed by `sha256(token)` and hold no copy of it,
    so a read of the collection opens nothing. Single-use, spent in a transaction, and
    always with an expiry. A link token is never a JWT and is never minted with
    `JWT_SECRET`. It travels in a POST body, and in the emailed link only as a URL
    **fragment** — never a query string, which Cloud Run and Firebase Hosting both record
    in their request logs.
12b. **No route may reveal whether an address has an account.** `/auth/signin` answers a
    wrong password and an unknown address identically, and its activation gate sits
    *after* the password is verified; `/auth/activation/resend` and
    `/auth/password/forgot` answer `200 { sent: true }` for every well-formed address,
    throttled the same way in both branches. Adding a route that takes an email and
    branches visibly on whether it is registered is a guardrail violation.
12c. **CORS is per route, for one origin.** Only the routes the website's link pages call
    carry it, and only for `PUBLIC_WEB_URL`'s origin. `origin: '*'` on any `/auth/` route
    is a violation: an allowed origin is a page that can spend a token it was handed.
13. Validate untrusted input at the route edge before it reaches a module
    (`normalizeEmail`, `parseProfile`). Don't push validation downward.

## Testing & verification

14. **Every API behavior change ships with a test.** New route, new error code, or
    changed validation → a case in `api/test/`.
15. `bun run verify` (api) and `scripts/verify-mobile.sh` (mobile) must pass before any
    PR is opened. A green run is the minimum, not the proof — say what you actually
    exercised.
16. `scripts/e2e.sh` hits the **real Firebase project**. Test accounts must use the
    `e2e+*@e2e.evaapp.dev` pattern so the cleanup sweep can find them. Never create
    test users outside that pattern.
17. Don't weaken, skip, or delete a failing test to get green. Fix the code, or
    explain why the test was wrong.

## iOS

18. **Never edit `mobile/Eva.xcodeproj`** — it is generated and gitignored. Edit
    `mobile/project.yml` and run `xcodegen generate`.
19. New Swift files go in the right folder under `mobile/Eva/`; `sources: [Eva]` picks
    them up automatically, no project edit needed.
20. Colors, fonts, and spacing come from the tokens in [DESIGN.md](DESIGN.md). No
    literal hex, no ad-hoc font sizes, no re-implemented primary button. New UI follows
    the Claude Design canvas, not the drifted existing screens (DESIGN.md §9), and
    user-facing copy follows the voice rules in DESIGN.md §8.
21. Keep the DEBUG hooks working: `EVA_ONBOARDING_STEP`, `EVA_UITEST_RESET`,
    `EVA_API_BASE_URL`. Tooling and e2e depend on them.
22. Interactive elements need a stable `accessibilityIdentifier`. Renaming one means
    updating `EvaUITests`.
23. Never pass `CODE_SIGNING_ALLOWED=NO` to an xcodebuild **test** run. Unsigned apps
    have no Keychain entitlement, so the JWT is never persisted and every authorized
    request silently 401s.
24. `AppSession` is the only owner of auth state; `KeychainTokenStore` the only place
    the token is persisted. No `@AppStorage` flag for `questionnaireCompleted`.

## Dependencies & scope

25. **No new dependency without a note in the PR** saying what it replaces and why the
    stdlib/existing stack won't do. The stack is deliberately small: Hono, Bun,
    firebase-admin, Astro, SwiftUI. No Firebase iOS SDK until it's a decided task.
26. Stay inside the issue's declared scope. Something else looks wrong? File it, don't
    fix it in the same PR.
27. No reformatting, renaming, or "while I was here" refactors mixed into a feature PR.

## Process

28. One issue → one branch → one PR. Commits are atomic and describe intent.
29. Never force-push or commit directly to `main`.
30. Respect [AUTONOMY.md](AUTONOMY.md) for who approves what. When a gate says human,
    stop and ask — don't proceed and note it afterwards.
31. Update [ARCHITECTURE.md](ARCHITECTURE.md) / [DESIGN.md](DESIGN.md) in the same PR
    that makes them stale.

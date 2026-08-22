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
   `api/src/identity-toolkit.ts`. Don't spread them.

## Security rules (Firestore / Storage)

5. **`firestore.rules` and `storage.rules` stay deny-all** until a client is genuinely
   meant to reach Firebase directly. They are deny-all *by design* — the app talks to
   the API, and the Admin SDK bypasses rules. See [ARCHITECTURE.md §2](ARCHITECTURE.md).
6. Any loosening of either file is **fully supervised**: human plan approval, human
   review, human deploy. Never bundled into an unrelated change.
7. Rules are **not** deployed by CI. `firebase deploy --only firestore:rules,storage`
   is a deliberate human act.

## Auth & data

8. The iOS app never calls Firebase directly. New backend capability = new API route.
9. `users/{uid}` document IDs are Firebase Auth uids. Never generate your own ID,
   never key users by email.
10. Only `api/src/users.ts` touches Firestore. Routes delegate; they don't query.
11. Error responses keep the shape `{ error: { code, message } }`. Existing codes
    (`VALIDATION`, `EMAIL_EXISTS`, `INVALID_CREDENTIALS`, `UNAUTHORIZED`) are a client
    contract — adding is fine, renaming or repurposing is a breaking change.
12. Never log a password, a token, a full JWT, or a user's `profile` contents.
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
    literal hex, no ad-hoc font sizes, no re-implemented primary button.
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

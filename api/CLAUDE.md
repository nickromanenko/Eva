# api/ — Eva API

Hono on Bun, deployed to Cloud Run as `eva-api`. Owns auth and all Firestore access.

Read [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) §2–§4 first — the API-mediated
auth decision explains most of the code's shape.

## Commands

```sh
bun install
bun run dev        # hot reload on :3003
bun run typecheck  # tsc --noEmit
bun test
bun run verify     # typecheck + test — must pass before a PR
bun run seed:refdata  # create any missing refdata/ catalogue (--relabel resets labels)
```

Needs `api/.env` (copy `.env.example`) and Application Default Credentials
(`gcloud auth application-default login`).

## Module boundaries — enforced by review

```
index.ts ──► auth.ts · identity-toolkit.ts · rate-limit.ts · users.ts · events.ts · refdata.ts
         ──► firebase.ts · config.ts
```

- `index.ts` — routes, validation, HTTP mapping. **No Firestore, no outbound fetch.**
- `auth.ts` — JWT mint/verify + `requireAuth`. The only user of `JWT_SECRET`.
- `identity-toolkit.ts` — password credentials via Google REST. The only user of the
  web API key. (The Admin SDK cannot verify passwords — that's why this exists.)
- `rate-limit.ts` — attempt counters behind the `/auth/*` throttle. In-memory, so the
  limit is per Cloud Run instance — the guarantee, and what would have to change to make
  it real, are written out at the top of the file and in ARCHITECTURE §3. It never sees
  whether an account exists, and it never logs a key (they are addresses and IPs).
- `users.ts` — the only module that touches `users/`.
- `events.ts` — the only module that touches `users/{uid}/events/`. Calendar entries:
  create, range read by `localDate`, edit, soft delete. Never log a payload — health data.
- `refdata.ts` — the only module that touches `refdata/`. The client's option lists
  (symptom chips, sport activities, appointment types) with a content-hash `version`.
  Codes are permanent; options are retired, never deleted. Seed with
  `bun run seed:refdata` (see `scripts/seed-refdata.ts` for why a script, not a route).
- `firebase.ts` — Admin SDK singleton. Never initialize a second app.
- `config.ts` — required env vars, fail-fast.

## Rules

- Errors are always `{ error: { code, message } }`. Codes are a client contract:
  adding is fine, renaming is breaking. Current set: `VALIDATION`, `EMAIL_EXISTS`,
  `INVALID_CREDENTIALS`, `UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`,
  `BACKDATE_LIMIT_EXCEEDED`, `UNKNOWN_SYMPTOM_CODE`, `WEAK_PASSWORD`, `RATE_LIMITED`.
- Validate at the route edge (`normalizeEmail`, `parseProfile`), not deeper.
- Every behavior change gets a test in `test/`.
- Never log passwords, tokens, profile contents, or event payloads (health data).
- New env var → `config.ts` + `.env.example` (placeholder only).
- No refresh tokens in v1. Adding them is an architecture change, not a task.

## Style

Arrow-function consts, no semicolons, single quotes, 2-space indent, 100-col-ish.
`interface` for exported shapes, `type` for unions. Explicit return types on exported
functions. Match `src/users.ts` if unsure.

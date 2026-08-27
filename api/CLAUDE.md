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
```

Needs `api/.env` (copy `.env.example`) and Application Default Credentials
(`gcloud auth application-default login`).

## Module boundaries — enforced by review

```
index.ts ──► auth.ts · identity-toolkit.ts · users.ts · events.ts ──► firebase.ts · config.ts
```

- `index.ts` — routes, validation, HTTP mapping. **No Firestore, no outbound fetch.**
- `auth.ts` — JWT mint/verify + `requireAuth`. The only user of `JWT_SECRET`.
- `identity-toolkit.ts` — password credentials via Google REST. The only user of the
  web API key. (The Admin SDK cannot verify passwords — that's why this exists.)
- `users.ts` — the only module that touches `users/`.
- `events.ts` — the only module that touches `users/{uid}/events/`. Calendar entries:
  create, range read by `localDate`, edit, soft delete. Never log a payload — health data.
- `firebase.ts` — Admin SDK singleton. Never initialize a second app.
- `config.ts` — required env vars, fail-fast.

## Rules

- Errors are always `{ error: { code, message } }`. Codes are a client contract:
  adding is fine, renaming is breaking. Current set: `VALIDATION`, `EMAIL_EXISTS`,
  `INVALID_CREDENTIALS`, `UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`,
  `BACKDATE_LIMIT_EXCEEDED`.
- Validate at the route edge (`normalizeEmail`, `parseProfile`), not deeper.
- Every behavior change gets a test in `test/`.
- Never log passwords, tokens, profile contents, or event payloads (health data).
- New env var → `config.ts` + `.env.example` (placeholder only).
- No refresh tokens in v1. Adding them is an architecture change, not a task.

## Style

Arrow-function consts, no semicolons, single quotes, 2-space indent, 100-col-ish.
`interface` for exported shapes, `type` for unions. Explicit return types on exported
functions. Match `src/users.ts` if unsure.

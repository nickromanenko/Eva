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
bun run retire:refdata  # apply the declared retirements (never deletes)
bun run purge:events    # delete events past their 30-day recovery window (--dry-run first)
```

Needs `api/.env` (copy `.env.example`) and Application Default Credentials
(`gcloud auth application-default login`).

## Module boundaries — enforced by review

```
index.ts ──► auth.ts · identity-toolkit.ts · rate-limit.ts · users.ts · events.ts · refdata.ts
         ──► email.ts · email-tokens.ts
         ──► firebase.ts · config.ts
```

- `index.ts` — routes, validation, HTTP mapping. **No Firestore, no outbound fetch.**
- `auth.ts` — JWT mint/verify + `requireAuth`. The only user of `JWT_SECRET`. It proves a
  token is ours and nothing more; whether the account still exists is `requireAccount` in
  `index.ts`, which is where it has to live because this file must not reach Firestore.
- `identity-toolkit.ts` — the Firebase Auth account: password credentials via Google REST
  (the only user of the web API key — the Admin SDK cannot verify passwords, which is why
  this exists), and `deleteAuthAccount` via the Admin SDK, which is the only place an Auth
  user is deleted. Two transports, one owner.
  Also classifies every upstream failure as `email-exists | rejected | unavailable`;
  routes branch on that kind and never on Google's reason string, which must not reach a
  body, a header, or a log line (#32).
- `rate-limit.ts` — attempt counters behind the `/auth/*` throttle. In-memory, so the
  limit is per Cloud Run instance — the guarantee, and what would have to change to make
  it real, are written out at the top of the file and in ARCHITECTURE §3. It never sees
  whether an account exists, and it never logs a key (they are addresses and IPs).
- `users.ts` — the only module that touches `users/`. `markUserDeleted` stamps the
  tombstone that starts an account delete (#8): while it is set `getUser` answers `null`
  and `ensureUser` refuses to revive the document, which is what stops a deleted account
  coming back through a sign-in or through a pre-delete token.
- `events.ts` — the only module that touches `users/{uid}/events/`. Calendar entries:
  create, range read by `localDate`, edit, soft delete. Never log a payload — health data.
  A soft delete is recoverable for `RETENTION_DAYS` (30) and then purged: `restoreEvent`
  is the Undo behind `POST /me/events/{id}/restore`, `purgeUserEvents` is the job behind
  the promise, driven by `scripts/purge-events.ts` (a script, not a route — ARCHITECTURE
  §4 "Retention" says why, and what a human still has to create for it to run).
  `deleteAllUserEvents` is the exception that proves the rule: account deletion takes
  soft-deleted entries too, because a recovery window inside a deleted account is a
  promise to nobody.
- `email-tokens.ts` — the only module that touches `authTokens/`. The tokens behind
  activation and password-reset links (#6): 32 random bytes handed out once, stored only
  as a SHA-256, single-use, spent in a transaction, each with its own TTL (24h / 60min).
  Issuing a reset token invalidates every unused one the account already has. Writes
  nothing to the console — a raw token or its hash in a log line is the link itself.
- `email.ts` — the only user of `POSTMARK_API_KEY`, and the only outbound mail. Postmark
  over REST with `fetch`, no SDK (GUARDRAILS 25). Two messages, no personalisation: a
  link, how long it lasts, and what to do if you did not ask for it. `EMAIL_TRANSPORT=log`
  prints the link instead of sending it — local only; `config.ts` refuses it under
  `NODE_ENV=production`.
- `refdata.ts` — the only module that touches `refdata/`. The client's option lists
  (symptom chips, sport activities, appointment types) with a content-hash `version`.
  Codes are permanent; options are retired, never deleted. Seed with
  `bun run seed:refdata` (see `scripts/seed-refdata.ts` for why a script, not a route);
  remove with `bun run retire:refdata`, which keeps the record of what went and why.
- `firebase.ts` — Admin SDK singleton. Never initialize a second app.
- `config.ts` — required env vars, fail-fast.

## Rules

- Errors are always `{ error: { code, message } }`. Codes are a client contract:
  adding is fine, renaming is breaking. Current set: `VALIDATION`, `EMAIL_EXISTS`,
  `INVALID_CREDENTIALS`, `UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`,
  `BACKDATE_LIMIT_EXCEEDED`, `UNKNOWN_SYMPTOM_CODE`, `WEAK_PASSWORD`, `RATE_LIMITED`,
  `SERVICE_UNAVAILABLE`, `DAY_ALREADY_LOGGED`, `NOT_ACTIVATED`, `INVALID_TOKEN`,
  `TOKEN_EXPIRED`, `INTERNAL`.
- Every authenticated route carries `requireAuth, requireAccount` — the second is what
  makes a deleted account's still-valid token useless. `DELETE /me` is the one exception,
  so an interrupted delete can be retried with the same token.
- `app.onError` is the floor: any throw no route answered for is `500 INTERNAL` with a
  fixed message and a `ref`. Never the thrown error's text, in the body or the log —
  ARCHITECTURE §3 says why that is the point of it.
- Validate at the route edge (`normalizeEmail`, `parseProfile`), not deeper.
- Every behavior change gets a test in `test/`.
- Never log passwords, tokens, profile contents, or event payloads (health data).
- New env var → `config.ts` + `.env.example` (placeholder only).
- No refresh tokens in v1. Adding them is an architecture change, not a task.
- `POST /auth/signup` hands out no session (#6): the account exists, the address is not
  proven, and `POST /auth/signin` answers `403 NOT_ACTIVATED` until it is. That gate sits
  **after** Identity Toolkit has verified the password, and must stay there — answering it
  earlier would tell any caller which addresses have Eva accounts. `/auth/activation/resend`
  and `/auth/password/forgot` answer `200 { sent: true }` for every well-formed address,
  registered or not, for the same reason.
- CORS is on exactly the two routes the website's link pages call (`/auth/activate`,
  `/auth/password/reset`), for exactly `config.publicWebOrigin`. Never `*`, never a third
  route: an allowed origin is a page that can spend a token it was handed.

## Style

Arrow-function consts, no semicolons, single quotes, 2-space indent, 100-col-ish.
`interface` for exported shapes, `type` for unions. Explicit return types on exported
functions. Match `src/users.ts` if unsure.

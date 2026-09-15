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
index.ts ──► auth.ts · identity-toolkit.ts · providers.ts · rate-limit.ts · users.ts
         ──► events.ts · refdata.ts · email.ts · email-tokens.ts
         ──► firebase.ts · config.ts
```

- `index.ts` — routes, validation, HTTP mapping. **No Firestore, no outbound fetch.**
- `auth.ts` — JWT mint/verify + `requireAuth`. The only user of `JWT_SECRET`. It proves a
  token is ours and nothing more; whether the account still exists is `requireAccount` in
  `index.ts`, which is where it has to live because this file must not reach Firestore.
- `identity-toolkit.ts` — the Firebase Auth account: password *and* provider credentials via
  Google REST (the only user of the web API key — the Admin SDK cannot verify either, which
  is why this exists), and `deleteAuthAccount` via the Admin SDK, which is the only place an
  Auth user is deleted. Two transports, one owner. `signInWithIdp` is the Apple/Google seam
  (#7): Firebase returns the uid it keyed to the provider's `sub`, which is what makes
  "identity is `sub`, and only `sub`" true by construction. Never add an email lookup to it.
  Also classifies every upstream failure as `email-exists | rejected | unavailable`;
  routes branch on that kind and never on Google's reason string, which must not reach a
  body, a header, or a log line (#32).
- `providers.ts` — the only two calls that go to Apple or Google *directly*, and the only
  user of `GOOGLE_IOS_CLIENT_ID` and the Apple keys (#7): Google's PKCE authorization-code
  exchange (public iOS client, no client secret) and Apple's token revocation for
  `DELETE /me` (an ES256 client secret signed with WebCrypto — no JWT library, and never
  `JWT_SECRET`). Every credential it needs is optional; unconfigured is a `503` on that one
  capability, never a boot failure, and never a failed delete. Writes no log line.
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
  Issuing a reset token invalidates every unused one the account already has. A token issued
  before its account exists carries `uid: null` (#120), so `deleteTokensForAccount` sweeps by
  **address as well as uid** — a uid query alone cannot see the tokens of anyone who signed
  up and never activated, and `DELETE /me` left them behind. Writes
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
  `TOKEN_EXPIRED`, `PROVIDER_ALREADY_LINKED`, `INTERNAL`.
- Every authenticated route carries `requireAuth, requireAccount` — the second is what
  makes a deleted account's still-valid token useless. `DELETE /me` is the one exception,
  so an interrupted delete can be retried with the same token.
- `app.onError` is the floor: any throw no route answered for is `500 INTERNAL` with a
  fixed message and a `ref`. Never the thrown error's text, in the body or the log —
  ARCHITECTURE §3 says why that is the point of it.
- Validate at the route edge (`normalizeEmail`, `parseProfile`), not deeper.
- Every behavior change gets a test in `test/`.
- **Every file that makes a live round trip sets `setDefaultTimeout(20_000)`** (#31). The
  suite runs against the real project, so a case that inherits Bun's 5000ms default is one
  cold connection away from a red run nobody can distinguish from a regression — which is
  how a suite that gates every merge teaches people to re-run instead of read. 20s is a
  ceiling, not a measurement: nothing honest reaches it, and a genuine hang still fails.
  Bun names the two failures differently, and that is worth knowing before reading a red
  run: an assertion prints `error: expect(received).toBe(expected)` with the two values, a
  timeout prints `^ this test timed out after 20000ms.` and no assertion at all.
- Never log passwords, tokens, profile contents, or event payloads (health data).
- New env var → `config.ts` + `.env.example` (placeholder only).
- No refresh tokens in v1. Adding them is an architecture change, not a task.
- **`POST /auth/signup` creates nothing (#120).** No Auth user, no document, no credential —
  it takes an address, issues an activation token and sends a link. `POST /auth/activate`
  takes that token **and a password** and creates the account, so the address is proven and
  the credential set in the same request. The invariant: *a password only works if the person
  who set it proved the address.* Sign-up used to create the Auth user with the caller's
  password, which reserved the address and put a working credential on it before anyone had
  proved it — the hole every defence below was written to live with.
  - It still answers `409 EMAIL_EXISTS` for an address whose owner is **activated**
    (ARCHITECTURE §3 says why sign-up discloses that deliberately). An unproven reservation is
    not ownership and does not block anyone.
  - A password in the body is **ignored, not refused**, so an un-updated client does not break
    outright.
- `POST /auth/signin` answers `403 NOT_ACTIVATED` for an unproven account, and that gate sits
  **after** Identity Toolkit has verified the password — answering earlier would tell any
  caller which addresses have Eva accounts. Since #120 the normal flow cannot reach it: there
  is no password before activation. It still guards accounts predating #120 and addresses
  reserved directly at Identity Toolkit. `/auth/activation/resend` and
  `/auth/password/forgot` answer `200 { sent: true }` for every well-formed address,
  registered or not, for the same reason.
- **A valid activation link on an already-activated account is a dead link (#120).** It used
  to answer `200` idempotently, which was right while activation only stamped a flag. The link
  sets a password now, so honouring a stale one would turn every activation email anybody ever
  saw into a password-reset primitive.
- **This code never matches on email; Firebase does (#7).** `POST /auth/idp` acts on the
  uid `signInWithIdp` returns and performs no lookup of its own — never add one. Whether a
  shared address resolves to one account or two is the console's
  *"Link accounts that use the same email"* setting, and it is set to link. A relay address
  from Hide My Email matches nothing and so still creates a new account; joining that one
  to an existing account is `POST /me/auth/providers`, deliberate and authenticated.
- **`/auth/idp` claims an unproven account before it mints a session (#7).** Sign-up
  creates the Auth user before the address is confirmed, and the Firebase web API key is
  public, so anyone can pre-register an address and attach their own provider identity to
  it directly at Identity Toolkit. `claimUnprovenAccount` overwrites the password, unlinks
  every *federated* provider except the one that just signed in, and revokes refresh
  tokens. `password` is overwritten rather than unlinked — an account with no password
  provider has nothing for forgot-password to reset, and the two cannot be asked for in
  one `updateUser` anyway. It asks
  `adminAuth.getUser`, never `users/{uid}`, because the mirror cannot see an Auth user
  whose document was never written. Gated on `activatedAt` being null alone.
- **Unlinking is half of it; the address test is the other half.** Stripping defends only
  the ordering where the victim signs in first, and the attacker can always choose to go
  first — nothing is stripped when `password` and their own provider are the only two, and
  activation then disarms the claim forever. So on an account whose address nobody has
  proved (`emailVerified` false), the provider signing in must carry that account's own
  address (the fact that made Firebase merge it). The trigger is `emailVerified` and never
  "has a password": a password entry is derived, client-mutable, and set by this function's
  own write, and an attacker can point a federated-only account at a victim's address
  without ever attaching one. Otherwise `claimUnprovenAccount` returns `refused` and the route
  answers 401 **without activating**. Fails closed on a missing provider address; a fresh
  provider account has no password and never reaches that branch, so Hide My Email is safe.
  Removing any part of this re-opens an account takeover; ARCHITECTURE §3 walks it through.
- **Some refusals from Identity Toolkit arrive as a 200 (#7).** `needConfirmation` (an
  account already holds this address and the credential has not proved it owns it),
  `emailRecycled` (the provider reassigned the address to a different `sub`), and an MFA
  challenge all answer 200 with the *other* account's `localId` and **no `idToken`**. Two
  were found in consecutive review rounds, so `requireSignedIn` names those and then
  requires `idToken` on any sign-in response for the shapes not met yet. Both halves are
  needed — `emailRecycled` *does* carry a token — and it runs in **both** transports,
  `call` and `signInWithIdp`. Never read `localId` before it.
- **Proving an address retracts what was attached while it was not (#7).** `/auth/activate`
  and `/auth/password/reset` call `retractUnprovenIdentities` on the transition to activated
  — only the transition, so a deliberately linked provider survives a later reset — and
  **before** stamping `activatedAt`, because the stamp is what disarms the claim gate.
  Without it the `/auth/idp` claim is simply outwaited: an attacker attaches a provider to a
  reserved address and signs in the moment the real owner activates.
- **`markCredentialsProven` runs last, after `markActivated` (#120).** `emailVerified` is
  what turns off `claimUnprovenAccount`'s address test; `activatedAt` is what turns off the
  claim itself. Any window in which the first is set and the second is not is the one
  combination that claims unconditionally, so the account is created *without*
  `emailVerified` (`createAccountWithPassword`) and the flag is set at the very end. Failing
  the other way leaves an activated account with the merge-wipe still armed, which costs its
  owner a password on a later provider sign-in and is recoverable through reset.
- **Both paths through `/auth/activate` share one set of guards.** The `email-exists` race
  and the ordinary "account already exists" branch both fall through the same
  `deleted` / `activated` refusals and the same tail. They were separate once, and the race
  branch skipped both — two unspent links for one address could overwrite each other's
  password.
- **`markCredentialsProven` is called from both the reset route and activation (#120).** It
  sets Firebase's `emailVerified`, which Identity Toolkit also uses to decide whether to wipe
  `passwordHash` on a merge. Activation withheld it under #7, deliberately, so that wipe
  stayed armed against a pre-registering attacker's password — the subtlest call in that
  issue. #120 removes the reason: the only credential an account can have at activation is
  the one supplied in that same request by whoever proved the address.
- **`/auth/idp` reads before it writes (#7).** `ensureUser` unions the provider into
  `authProviders`, so calling it before the claim gate left a refused credential's provider
  on a stranger's document — which is what the app reads to decide whether to offer
  "Connect Apple". Use `readUser` to decide, `ensureUser` only once the claim says
  `claimed`.
- A provider session comes back already activated, stores no display name, and adds no
  field to `users/{uid}`.
- CORS is on exactly the two routes the website's link pages call (`/auth/activate`,
  `/auth/password/reset`), for exactly `config.publicWebOrigin`. Never `*`, never a third
  route: an allowed origin is a page that can spend a token it was handed.
- **A link token never travels in a URL.** Both link routes are POST with the token in the
  body, and the emailed link carries it in the fragment (`#token=`), which browsers do not
  send. A query string would put a live credential into Cloud Run's and Hosting's request
  logs. Do not add a `GET` convenience route.

## Style

Arrow-function consts, no semicolons, single quotes, 2-space indent, 100-col-ish.
`interface` for exported shapes, `type` for unions. Explicit return types on exported
functions. Match `src/users.ts` if unsure.

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
| `auth.ts` | Minting and verifying the Eva JWT, `requireAuth` middleware | The only place `JWT_SECRET` is used |
| `identity-toolkit.ts` | The Firebase Auth account: password and provider credentials verified via Google REST, delete via the Admin SDK | The only place the web API key is used; the only place an Auth user is deleted |
| `providers.ts` | The two calls that go to Apple and Google *directly*: Google's PKCE code exchange, Apple's client secret and token revocation | The only place `GOOGLE_IOS_CLIENT_ID` and the Apple keys are used; writes no log line |
| `rate-limit.ts` | In-memory attempt counters for `/auth/*` | Holds no identity state; never logs its keys |
| `users.ts` | The `users/{uid}` document: read, create, update, mark deleted, delete, list IDs | The only module that touches `users/` |
| `events.ts` | The `users/{uid}/events/` subcollection: create, range read, edit, soft delete, restore, purge, delete-all | The only module that touches `events/` |
| `refdata.ts` | The `refdata/` collection: the option lists the client draws, and the version they are cached against | The only module that touches `refdata/` |
| `email-tokens.ts` | The `authTokens/` collection: activation and reset tokens — issue, spend, expire, revoke | The only module that touches `authTokens/`; stores hashes, never a token; logs nothing |
| `email.ts` | Sending the two transactional messages, over Postmark's REST API | The only place `POSTMARK_API_KEY` is used; no address, link or token in a log line |
| `firebase.ts` | Admin SDK singleton (Application Default Credentials) | Never construct a second app |
| `config.ts` | Required env vars, fail-fast at boot | Every new env var is declared here **and** in `.env.example` |

Layering: `index.ts` → (`auth`, `identity-toolkit`, `providers`, `rate-limit`, `users`,
`events`, `refdata`, `email-tokens`, `email`) → (`firebase`, `config`). Never call upward,
never sideways along the middle row.

### Contracts

Errors are always `{ "error": { "code": string, "message": string } }`. `code` is a
stable machine identifier (`VALIDATION`, `EMAIL_EXISTS`, `INVALID_CREDENTIALS`,
`UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`, `BACKDATE_LIMIT_EXCEEDED`,
`UNKNOWN_SYMPTOM_CODE`, `WEAK_PASSWORD`, `RATE_LIMITED`, `SERVICE_UNAVAILABLE`,
`DAY_ALREADY_LOGGED`, `NOT_ACTIVATED`, `INVALID_TOKEN`, `TOKEN_EXPIRED`,
`PROVIDER_ALREADY_LINKED`, `INTERNAL`);
`message` is human-facing and may be shown in the app. Changing a code is a breaking
change for the iOS client.

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
| `POST /me/auth/providers` | Bearer | `{ user }` — attaches a provider to *this* account; `409 PROVIDER_ALREADY_LINKED` when its `sub` belongs to another |
| `DELETE /me` | Bearer | `{ deleted: true }` — the account and all of its data, immediately; an optional `appleAuthorizationCode` also revokes the Apple token |
| `PUT /me/questionnaire` | Bearer | `{ user }` |
| `GET /me/events?from=&to=` | Bearer | `{ events }` — inclusive `localDate` range, soft-deleted excluded |
| `POST /me/events` | Bearer | `201 { event }` |
| `PATCH /me/events/{id}` | Bearer | `{ event }` — body must carry `type` and `localDate` |
| `DELETE /me/events/{id}` | Bearer | `{ deleted: true }` — soft delete |
| `POST /me/events/{id}/restore` | Bearer | `{ event }` — undo a soft delete, within 30 days |
| `PUT /me/body-signals/{date}` | Bearer | `{ event }` — upsert by day |
| `GET /refdata?version=` | Bearer | `{ version, catalogues }` — `304` when `version` (or `If-None-Match`) already matches |

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
| `POST /me/auth/providers` | the same two shapes, with a bearer token | `200 { user }`, with the provider added to `user.authProviders` |

Apple is native: the app already holds an `identityToken`, and it sends the **raw** nonce it
hashed into its `ASAuthorization` request. That nonce is forwarded to `signInWithIdp`, where
Firebase hashes it and compares — which is the whole of what stops a captured
`identityToken` being replayed at this route by somebody else. Google is PKCE against a
*public* iOS OAuth client: the app returns an authorization code, `providers.ts` exchanges it
at `https://oauth2.googleapis.com/token` with the code verifier and **no client secret**
(an iOS client has none), takes the `id_token` out, and that is what gets spent. Doing the
exchange server-side is what keeps the GoogleSignIn SDK and its transitive packages out of
the app (GUARDRAILS 25).

**Identity is the provider's `sub`, and only `sub`.** Firebase hands back the uid it keyed to
that `sub`, so `ensureUser` lands on the same `users/{uid}` document for a `sub` it has seen
and creates a new account for one it has not — *even when the address matches an account that
already exists*. There is no email lookup on this path and there must never be one: an
address is self-asserted at some other provider, joining accounts on one is an
account-takeover shape, and it could not work for Hide My Email users anyway, whose address
is a relay. The cost, stated plainly because users will meet it: someone with an
email/password account who taps Sign in with Apple gets a **second** account. Joining them is
`POST /me/auth/providers`, done deliberately while signed in to the account they want to
keep.

Half of that guarantee is not the code's to make. On Firebase's **default** account-linking
setting the console merges a provider sign-in into a password account with the same address,
underneath this code and whatever it says. Step 0 of
[PROVIDER-SIGNIN.md](PROVIDER-SIGNIN.md) is the setting that turns that off; it is a human's
errand and nothing here can assert it.

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

**Failures map by the same rule as everything else.** `providers.ts` reduces Apple's and
Google's answers to `unconfigured | rejected | unavailable`, `identity-toolkit.ts` gains a
fourth kind, `provider-linked`, and the routes branch on the kind and never on the reason:
a rejected credential is `401 INVALID_CREDENTIALS` in our own words, a 5xx or 429 or network
failure is `503 SERVICE_UNAVAILABLE` with the constant `Retry-After`. `unconfigured` — a
provider whose credentials this deploy was never given — is answered as `503` too, because
the capability genuinely is unavailable, and is logged as
`{"event":"provider_endpoint_unavailable","route","kind","upstreamStatus"}`, which
distinguishes "Google is down" from "page somebody, we never set `GOOGLE_IOS_CLIENT_ID`".
Every provider credential (`GOOGLE_IOS_CLIENT_ID`, `APPLE_SERVICES_ID`, `APPLE_TEAM_ID`,
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
Firestore, the activation stamp, `authProviders`, the 409, the validation, and that the raw
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

Two limits worth knowing. Hono hands `onError` only a thrown `Error`; anything else
(`throw "boom"`) is rethrown to the runtime and answers its own unshaped 500 — nothing in
the stack does that today. And an unmatched path is still Hono's plain-text `404`, because
it is a miss rather than a throw; both are filed, not fixed here.

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

**Every authenticated route is gated twice (#8).** `requireAuth` proves the token was ours;
`requireAccount`, right after it, proves the account it names still exists — one `getUser`
call, and a `401 UNAUTHORIZED` with the same message a bad token gets when it does not.
The gate exists because the token above is stateless and unrevocable: without it a token
minted before an account was deleted would keep working for up to 30 days, and at `GET /me`
— which used to fall back to `ensureUser` when no document was found — it would have
**recreated the deleted account** from its own claims. The user document is what does the
revoking, rather than a list of deleted uids: it stops answering the moment a delete starts
and is gone when the delete finishes, so nothing about a deleted account is retained in
order to keep refusing it. The cost is one Firestore read per authenticated request.

`DELETE /me` is the single exception, deliberately: the gate would reject the very token a
client needs to retry an interrupted delete with. All that token can do there is delete an
account that is already gone.

## 4. Data model

`users/{uid}` — document ID is the Firebase Auth uid, deliberately, so any future
provider resolving to the same Auth account lands on the same document.

```
email                  string
authProviders          string[]        // arrayUnion: "password", "apple.com", "google.com"
questionnaireCompleted boolean
profile                Profile | null  // see api/src/users.ts
activatedAt            Timestamp | null  // #6; null = unconfirmed, ABSENT = pre-#6 = confirmed
deletedAt              Timestamp       // absent until a delete starts; see below
createdAt, updatedAt   serverTimestamp
```

`deletedAt` on a *user* is not a soft delete and has no undo. It is the tombstone that
makes account deletion safe to interrupt: while it is set, `getUser` answers `null`, so the
account gate refuses every token, and `ensureUser` refuses to revive the document, so
signing in cannot bring the account back either.

`activatedAt` distinguishes three states with two values, which is the one subtle thing
about it: `null` means the address has not been confirmed, a timestamp means it has, and
**absent means confirmed too** — every document written before #6 lacks the field and those
accounts must keep signing in. A truthiness test would lock them out.

`Profile` is validated at the edge in `parseProfile` (`index.ts`) with hard ranges:
age 13–99, weight 30–200 kg, height 120–220 cm. Widening a range is a product
decision, not a bug fix.

`authTokens/{sha256(token)}` — the activation and password-reset links (#6). Top-level
rather than under `users/`, because the document is looked up by the token alone, before
anyone knows whose it is. Owned by `api/src/email-tokens.ts`.

```
uid        string            // the account the link opens
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
themselves are useless. `deleteTokensForUid` pages in batches for the same reason: an
unbounded collection needs an unbounded delete, and one 500-op batch would leave
`DELETE /me` unable to finish at all.

The document ID **is** the hash, so nothing here can be turned back into a link, and there
is no index from an account to a usable token. Account deletion takes them all — the
document carries the address.

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

**Retention — the 30 days are a clock, not a wish (#28).** `DELETE /me/events/{id}` is
soft: it stamps `deletedAt` and range reads skip the entry. For the next 30 days
(`RETENTION_DAYS` in `events.ts`, the one place the number lives) it can be brought back
by `POST /me/events/{id}/restore` — the Undo on the delete toast. After that a job
removes it for good. Restore's `deletedAt >= cutoff` and the purge's `deletedAt < cutoff`
are exact complements, so no entry is ever both restorable and purgeable. All of it is
instant arithmetic on the server-set `deletedAt`; none of it touches `localDate`, so no
time zone, DST change or client clock can move the boundary.

Restore answers `404` for an unknown id, for an entry that was never deleted, and for one
past its window. The interesting case is one-per-day: because `cycle` and `bodySignals`
live at a deterministic ID, re-logging that day **overwrites the very document** that held
the deleted entry, so there is nothing left to restore. Restore refuses with
`409 DAY_ALREADY_LOGGED` rather than creating a duplicate or relabelling the newer entry
as restored. One consequence is worth knowing before it surprises someone: a live document
at a one-per-day ID cannot distinguish "the day was retaken" from "this was never deleted"
— replacing keeps the ID and `createdAt` and leaves no trace of the delete — so both
answer `409`. That is the price of the deterministic ID, and it is paid here rather than
by keeping a second copy of every deleted day.

**Deleting an account is immediate and complete (#8).** `DELETE /me` removes the Firebase
Auth user, `users/{uid}`, and the whole `users/{uid}/events` subcollection — **including
soft-deleted entries still inside their 30-day window**. That is a deliberate difference
from event retention above, not a conflict with it: deleting one entry is an edit someone
may want to undo, deleting an account is a decision about all of it, and a recovery window
inside an account that no longer exists is a promise to nobody. Nothing else is keyed to a
uid except `authTokens/` (#6), which goes with it; `refdata/` is global, and the `/auth/*`
throttle's counters are in memory and keyed by address and IP rather than by account.

The order is the design, because a partial failure has to be safe *and* resumable:

1. mark `users/{uid}` deleted — from that instant the account is inert (every gated route
   `401`s, sign-in refuses to revive it);
2. delete the Firebase Auth user — the credentials open nothing and the address is free
   again;
3. delete every event, soft-deleted ones included, a batch at a time, and every
   activation and reset token — a token document carries the address;
4. delete `users/{uid}`, the tombstone step 1 wrote.

Data goes before the tombstone, and the tombstone goes last, so that **a missing user
document implies a missing Auth user**. There is therefore no state in which health data
outlives its owner unmarked, and none in which someone can sign in to an account whose
document has already gone — which is the state in which `ensureUser` would create a fresh
one. The failure mode that remains is the mild one: an interrupted delete can leave an Auth
user with nothing behind it, and the account is already unusable when it does. Every step
is idempotent, so a retry resumes rather than errors, and deleting twice is a `200`.

One residual race is worth knowing rather than discovering: a sign-in that passed Identity
Toolkit microseconds before step 2 can land its `ensureUser` after step 4 and recreate the
document. It needs the password and a window of milliseconds, and the account owner is the
one deleting; closing it would mean keeping a permanent record of every deleted uid, which
is a worse trade for a health app than the race is.

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
entrypoint overridden, triggered daily by Cloud Scheduler. **A human must create both —
this repo does not, and `Deploy API` does not either.** Until they exist, nothing purges
and deleted events accumulate; the code is inert, not wrong. What is needed:

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
| `Onboarding/` | `OnboardingModel` (flow state machine) + `Steps/` + `Components/` |
| `Profile/` | `ProfileView` and `DeleteAccountModal` — the account-deletion entry point |
| `Theme/` | Colors, gradients, `PrimaryButton`, progress style — see [DESIGN.md](DESIGN.md) |

`AppSession.State` (`loading → signedOut | needsQuestionnaire | ready | unreachable`)
drives the root view. **The server is the source of truth for `questionnaireCompleted`** — never
reintroduce a local `@AppStorage` flag for it.

### A dead credential signs the user out, wherever it lands (#55)

The JWT is stateless and lives 30 days, so the server's only way to say "this credential
is finished" is a `401 UNAUTHORIZED` — which `requireAccount` now returns for a deleted
account on every authenticated route (§3). The client has to hear that everywhere, not
just at launch.

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
| `scripts/verify-mobile.sh` | — | **nothing. A human, when they remember** | — |

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

All 196 tests pass under the emulators **unchanged** — no offline mode, no skips, no
second code path — in ~28s against ~210s for the real project. The error-mapping suites
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

**iOS is not verified by CI at all.** `scripts/verify-mobile.sh` needs a macOS runner and
a simulator, takes ~350s, and macOS runners bill at a premium multiplier; running it per
PR was considered and declined on cost (#67). So every claim about the iOS app in a PR is
something a person ran by hand on one machine, and nothing catches the PR where they did
not. Sign in with Apple could not be driven in CI regardless — it cannot be completed in
a simulator.

One consequence worth naming: **`docs/AUTONOMY.md`'s ratchet rule can now legitimately
advance for `api/` and `website/`, and still cannot for `mobile/`.** The rule requires a
surface's verify command to have caught a real regression a human would have missed, and
a command nobody runs automatically cannot do that.

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
  `Deploy Rules` is `workflow_dispatch`-only and run by a human.
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
control. The Keychain token is currently backup-restorable (#64); the store must not repeat
that.

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
- For the one-per-day types `cycle` and `bodySignals` the key is **ignored** — the
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
  and `/refdata`.
- Every created event carries a device-generated `idempotencyKey`; the API's lookup on it is
  a pinned test.
- The store is excluded from backups and wiped on log-out, account deletion and
  `EVA_UITEST_RESET`.
- The `events` composite index (#27) must be deployed before the first range read runs
  against production; the sync engine's first reconcile is that read.

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

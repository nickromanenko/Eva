# Eva — Sign in with Apple and Google: what a human must provision

Issue #7. Everything here is an **always-human gate** under
[AUTONOMY.md](AUTONOMY.md) — an Apple entitlement, a signing key, a sending domain and a
Firebase console setting are not things an agent can or should create. This document
exists so the blocker is visible now rather than discovered halfway through a PR.

Nothing in this file is a secret. The one secret it produces — Apple's `.p8` signing key —
goes to Secret Manager and never to the repo (GUARDRAILS 4).

Values this repo already fixes:

| | |
|---|---|
| Bundle ID | `com.evaapp.ios` |
| Firebase / GCP project | `eva-ai-made-for-women` |
| API | `https://eva-api-uwkxxorika-uc.a.run.app` |
| Website | `https://evatracker.com` |

---

## 0. The setting to leave alone

Firebase console → Authentication → Settings → **User account linking**, set to
**"Link accounts that use the same email"**. Decided 2026-09-03. Do not change it.

Firebase therefore merges a provider sign-in into an existing password account whenever
the addresses match, and returns that account's uid. `ensureUser` lands on the same
`users/{uid}` document and adds the provider. **That is deliberate**: it is what this
issue's PRD edge case always asked for — a Google sign-up for an existing email/password
account logs into it — and the alternative silently hands people a second, empty account
and the impression their cycle history is gone.

Two things follow, and both are load-bearing:

- **No code in this repo may match on email.** The rule lives in the console. A second
  copy in `identity-toolkit.ts` is how the two come to disagree, and the disagreement
  would be invisible.
- **Auto-linking is only safe because `POST /auth/idp` claims an unproven account.**
  Sign-up (#6) creates the Firebase Auth user *before* the address is confirmed, and the
  web API key is public, so someone can pre-register a victim's address and attach their
  own Apple identity to it at Identity Toolkit directly. `claimUnprovenAccount` takes the
  password, the other providers and the refresh tokens. See ARCHITECTURE §3.

Hide My Email is unaffected either way: Apple's relay address matches nothing, so those
users get a new account regardless, and the deliberate link from Profile
(`POST /me/auth/providers`) is their only route to an existing one.

---

## 1. Apple: the App ID capability — done 2026-09-08

Apple Developer → Certificates, Identifiers & Profiles → Identifiers → `com.evaapp.ios`,
with **Sign In with Apple** enabled.

The App ID did not exist when this document was written, so the step was "create it", not
"tick a box on it": Eva had never been signed for a device. Registered as an explicit App ID
under team **`266X9686VN`**, which is also `APPLE_TEAM_ID` in §6 and the Team ID Firebase
asks for in §5. The signing key in §3 must be created in that same team.

Verify rather than assume, because a missing capability does not fail the build; it fails at
runtime on a device, with an authorization error that reads like a code bug:

```sh
asc bundle-ids list --limit 200          # com.evaapp.ios → L9R4SZP2FW
asc bundle-ids capabilities list --bundle L9R4SZP2FW
```

`APPLE_ID_AUTH` must be listed. (`IN_APP_PURCHASE` appears beside it; Apple adds that to new
App IDs by default and it is unrelated.)

The matching entitlement is already in the repo — `com.apple.developer.applesignin:
[Default]` in `mobile/project.yml`, written out to `mobile/Eva/Eva.entitlements`. Do not add
it by hand; `Eva.xcodeproj` is generated.

**Provisioning profiles.** The instruction to regenerate any profile covering this App ID
does not apply to Eva: there were none, because the App ID is new. `CODE_SIGN_STYLE` is
`Automatic`, so Xcode creates the profile on the first device build and it picks the
capability up — *provided the capability exists first*. Enabling it after a device build
leaves a cached profile without it, and the re-sign that follows is confusing. `project.yml`
now carries `DEVELOPMENT_TEAM: 266X9686VN`; without it a generated project cannot sign for a
device at all, which is what the device testing under "What this does not cover" needs.

## 2. Apple: the Services ID — not needed, and the thing that is

**Skip the Services ID.** An earlier version of this document said to create one, on the
grounds that the Firebase console would not accept the Apple provider without it. That is
wrong for Eva. Firebase's own documentation is explicit: for an app on Apple platforms only,
the Service ID, Team ID, Key ID and private key fields may all be left empty — they exist to
support sign-in on **web and Android**, and Eva has neither. The Services ID identifies the
*web* OAuth flow; the app sends Apple's `identityToken` straight to our API and never
redirects anywhere.

Create one only if Eva ever adds Apple sign-in on the website or an Android app.

This does **not** make §3 optional. Eva revokes Apple tokens itself, in `providers.ts`,
with no involvement from Firebase — that is what satisfies App Review, and it needs the key.

### 2a. Sign in with Apple for Email Communication — done 2026-09-09

The step this document was missing, and the one that decides whether Hide My Email works.

Apple's private relay **bounces** mail to `@privaterelay.appleid.com` unless the sending
domain is registered here, and registered domains must publish SPF or DKIM. Eva sends its
own mail through Postmark (#6), so nothing about this is Firebase's to handle.

Where it bites today: a Hide My Email user who asks for a password reset gets
`200 { sent: true }` — non-enumeration, by design (GUARDRAILS 12b) — and the mail silently
disappears. There is no way for them to learn why, and no way for us to see it from the
route.

Apple Developer → Certificates, Identifiers & Profiles → **Services** → *Sign in with Apple
for Email Communication*. Registered:

| Source | Type |
|---|---|
| `evatracker.com` | Domain |
| `pm-bounces.evatracker.com` | Domain — Postmark's Return-Path; a separate bounce domain has to be registered too |
| `hello@evatracker.com` | Email address — this is `POSTMARK_FROM` |

`evatracker.com` had **no SPF record at all** before this; Postmark had set up DKIM and the
Return-Path but nothing else. Both domains now publish one:

```sh
dig +short TXT evatracker.com | grep spf
# v=spf1 include:spf.mtasv.net ~all
```

Neither the registration nor the relay behaviour is visible to the App Store Connect API, so
unlike §1 this cannot be verified from a terminal. The proof is a real send to a relay
address, which belongs with the device testing at the end of this document.

## 3. Apple: the signing key — done 2026-09-09, and why it is not optional

Keys → **+** → enable **Sign in with Apple**, configure it against `com.evaapp.ios`,
then Continue and Register.

**The `.p8` downloads exactly once.** There is no second chance; losing it means
revoking the key and issuing a new one. Note the **Key ID** and your 10-character
**Team ID** at the same time.

This key is what makes token *revocation* possible, and revocation is not a nicety:
Apple requires that an app offering Sign in with Apple **and** in-app account deletion
revoke the Apple token when the account is deleted. Eva has shipped `DELETE /me` since #8.
An App Review rejection on this is a common one, and it would land after the code is
otherwise finished.

So `DELETE /me` grows a step when #7 lands. That is in scope for #7 and is called out
here because the credential it needs is provisioned in this document, not in that code.

Store the key:

**Download it outside the repository**, and keep it outside. This instruction used to read
`--data-file=AuthKey_XXXXXXXXXX.p8`, which means the current directory; run from a checkout,
that is the repo root, and the first key provisioned this way was committed to `main` by a
blanket `git add -A` and had to be revoked. `*.p8` is now in `.gitignore`, but the habit is
the actual fix.

```sh
gcloud secrets create eva-apple-signin-key --data-file=~/Downloads/AuthKey_XXXXXXXXXX.p8 \
  --project eva-ai-made-for-women

gcloud secrets add-iam-policy-binding eva-apple-signin-key \
  --member "serviceAccount:976826401031-compute@developer.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor \
  --project eva-ai-made-for-women
```

Then delete the downloaded file. It is a signing key for your Apple team.

### Done 2026-09-09 — and verified, because this one fails quietly

Key ID `V6JDCDQQG7`, stored as `eva-apple-signin-key` version 1, `secretAccessor` granted
to the Cloud Run runtime service account. `APPLE_KEY_ID` is set, which completes the four
Apple repo variables.

A wrong key here does not fail loudly. Revocation is deliberately non-fatal, so
`DELETE /me` still answers `200 { deleted: true }` and the only trace is one log line —
which is exactly how the App Review requirement above would end up quietly unmet. So the
stored key was checked rather than assumed, without any of it reaching a terminal:

```sh
gcloud secrets versions list eva-apple-signin-key --project eva-ai-made-for-women
gcloud secrets get-iam-policy eva-apple-signin-key --project eva-ai-made-for-women
```

and, on the value itself: PKCS#8 header (`-----BEGIN PRIVATE KEY-----`, which is what
`crypto.subtle.importKey('pkcs8', …)` in `providers.ts` requires), real newlines rather than
the escaped `\n` that `config.ts` exists to restore, `openssl pkey` parses it, the curve is
`prime256v1` — P-256, as ES256 requires — and a WebCrypto import through the same call
`appleClientSecret` makes produces a 64-byte signature, the raw `r‖s` pair JWS defines.

What none of that proves is that **Apple** accepts it. That needs a real deletion on a
device, and is listed with the other device-testing items at the end.

## 4. Google: an OAuth client for iOS — done 2026-09-09

Google Cloud console → APIs & Services → Credentials → Create credentials → **OAuth
client ID** → Application type **iOS** → bundle ID `com.evaapp.ios`.

An iOS client is a *public* client: it has **no client secret**, which is what lets the app
run the OAuth dance itself with PKCE instead of pulling in the GoogleSignIn SDK and its two
transitive packages (#7's decision; GUARDRAILS 25). Nothing from this step is secret and
nothing goes to Secret Manager.

Copy the **client ID**. Its reversed form is the redirect scheme the app must register —
`com.googleusercontent.apps.<the-numeric-part>` — which becomes a second entry in
`mobile/project.yml`'s `CFBundleURLTypes`, alongside the `eva` scheme #6 added.

If Firebase's Google provider (step 5) has already created an iOS client for this bundle
ID, reuse it rather than making a second one.

### Done 2026-09-09

Client id `976826401031-jnmhrgu3gldhrph0b11rq66ndlbrt17f.apps.googleusercontent.com` — the
numeric prefix is the GCP project number, the same one in the Cloud Run runtime service
account, so it is demonstrably the right project.

`GOOGLE_IOS_CLIENT_ID` is set as a repo variable, completing all four. In
`mobile/project.yml` **both** settings are filled: the client id and the reversed redirect
scheme. Nothing at build time checks that those two agree —
`GoogleOAuthConfiguration.redirectScheme(forClientID:)` derives the scheme from the client
id and refuses at runtime when the bundle does not register the one it derived, because the
alternative is a flow that opens, completes at Google, and hands the callback to nobody.
They were checked against that derivation before being committed:

```
derived by the app: com.googleusercontent.apps.976826401031-jnmhrgu3gldhrph0b11rq66ndlbrt17f
in project.yml:     com.googleusercontent.apps.976826401031-jnmhrgu3gldhrph0b11rq66ndlbrt17f
```

## 5. Firebase: enable both providers

> **Do §6a and §6b first.** They are numbered after this step because they are repo and
> project configuration rather than console clicks, but both have to be in place before the
> providers are reachable: without §6b the API has no client id and answers `503` to every
> Google sign-in, and without §6a linking a provider from Profile is a `500`. Turning the
> providers on first means the first users to try them are the ones who find that out.

### 5a. Register the iOS app first — done 2026-09-09

**Firebase console → Project settings → Your apps → Add app → Apple.**

| Field | Value |
|---|---|
| Apple bundle ID | `com.evaapp.ios` (case-sensitive) |
| App nickname | `Eva iOS` |
| App Store ID | leave blank |

**Then stop.** Do not download `GoogleService-Info.plist`, do not add the SDK, do not add
initialization code, and ignore the "register with an AI coding agent" banner — it walks you
through exactly those steps. Eva's app never talks to Firebase (ARCHITECTURE §2) and has no
Firebase dependency; adding one would contradict that and GUARDRAILS 25. This registration
is **server-side only**: it tells Firebase that `com.evaapp.ios` is a client of this project.
Nothing ships in the app.

*This step was missing, and it cost a live debugging round.* Apple's `identityToken` carries
`aud: com.evaapp.ios`, and `signInWithIdp` validates that audience against the clients
Firebase knows for the project. With no app registered and the Services ID deliberately
empty (§2), there was no audience it would accept, so **every** Apple sign-in was refused —
and refused as a plain bad credential, indistinguishable from a wrong nonce or an expired
token. Two log lines, before and after registering, with nothing else changed:

```
20:49:59 POST 401 /auth/idp
21:14:40 POST 200 /auth/idp
```

Firebase's documentation does not state that `signInWithIdp` enforces this; its Apple
setup page says only that the bundle ID must be registered. So the mechanism above is
inference from the observed behaviour, and the evidence is those two lines.

Registering the app also creates an iOS API key in the project. Eva does not use it — the
API reads the **web** key (GUARDRAILS 4), which is unchanged.

### 5b. Enable the providers

Firebase console → Authentication → Sign-in method.

- **Apple** — enable, and **leave the OAuth code flow fields empty**: Services ID, Apple
  Team ID, Key ID, private key. Firebase's documentation says they may be blank for an app
  on Apple platforms only, and Eva is one.

  An earlier version of this document said to fill them anyway "because revocation uses
  them". That was wrong twice over. Revocation is **Eva's**, not Firebase's — `providers.ts`
  signs its own client secret from `config.providers.apple` and never asks Firebase to
  revoke anything. And the client id it signs with is the **App ID**, not a Services ID, so
  filling Firebase's form would not have supplied it either. What Firebase actually needs
  for a native iOS sign-in is the provider enabled and the bundle id registered — see §5a,
  which is the half that was missing and the half that actually broke it.
- **Google** — enable, and set the project support email.

## 6. Repo variables the code will need

Not needed until #7's code lands; listed here so provisioning and configuration are one
errand rather than two.

All four are set, as of 2026-09-09:

```sh
# The App ID / bundle identifier. Never a Services ID — §2 says why Eva has none, and
# what would break silently if one were used here.
gh variable set APPLE_CLIENT_ID      --body "com.evaapp.ios"
gh variable set APPLE_TEAM_ID        --body "266X9686VN"
gh variable set APPLE_KEY_ID         --body "V6JDCDQQG7"
gh variable set GOOGLE_IOS_CLIENT_ID --body "976826401031-jnmhrgu3gldhrph0b11rq66ndlbrt17f.apps.googleusercontent.com"
```

Setting them piecemeal was safe: `config.providers.apple` is all-four-or-nothing, so a
partial group reads as unconfigured and Apple revocation stays off rather than signing a
client secret Apple would reject.

They reach the running service only through §6b, which is still to do — until that line is
edited, the deploy forwards none of them and the API behaves exactly as it does today.

`APPLE_SIGNIN_KEY` arrives from Secret Manager as `eva-apple-signin-key:latest`, the same
shape as `eva-jwt-secret` and `eva-postmark-key`. All five are declared in
`api/src/config.ts` and `api/.env.example` when the code lands (GUARDRAILS 4).

### 6a. The Cloud Run service account must be able to sign for itself

`POST /me/auth/providers` mints a Firebase custom token for the signed-in uid
(`idTokenForUid`), and `createCustomToken` signs it with the runtime service account — which
requires that account to hold `serviceAccountTokenCreator` **on itself**. Nothing else in
Eva needs it, so it is easy to miss, and it fails only in production: every test mocks
`idTokenForUid`, so no verify command can catch it.

```sh
gcloud iam service-accounts add-iam-policy-binding \
  976826401031-compute@developer.gserviceaccount.com \
  --member "serviceAccount:976826401031-compute@developer.gserviceaccount.com" \
  --role roles/iam.serviceAccountTokenCreator \
  --project eva-ai-made-for-women
```

Without it, linking a provider from Profile is the one route that answers `500 INTERNAL` in
production while every other route works.

### 6b. The deploy workflow has to pass them on — done 2026-09-09

Setting the repo variables is not enough: `.github/workflows/deploy-api.yml` names every
env var it forwards, and `--set-env-vars` **replaces** the whole set rather than adding to
it, so the line has to be edited rather than appended to. Until it is, Google sign-in
answers `503` in production and Apple revocation returns `unconfigured` — which
`revokeApple` logs and swallows, so the app would ship Sign in with Apple *and* in-app
deletion with revocation silently disabled. That is the §3 rejection risk, arriving quietly.

Add to the existing `--set-env-vars` list:

```
GOOGLE_IOS_CLIENT_ID=${{ vars.GOOGLE_IOS_CLIENT_ID }},APPLE_CLIENT_ID=${{ vars.APPLE_CLIENT_ID }},APPLE_TEAM_ID=${{ vars.APPLE_TEAM_ID }},APPLE_KEY_ID=${{ vars.APPLE_KEY_ID }}
```

and to `--set-secrets`:

```
APPLE_SIGNIN_KEY=eva-apple-signin-key:latest
```

Done on Nick's explicit instruction, 2026-09-09. `docs/AUTONOMY.md` puts infra
implementation on the human side of the table; that instruction covered this file, and is
not a standing grant.

The four variables went into the step's `env:` block rather than inline, but **without** the
`test -n` guards `PUBLIC_WEB_URL` and `POSTMARK_FROM` carry: `config.ts` reads all of them
with `optionalString`, and an unprovisioned deploy is a supported state in which the
provider routes answer 503 instead of the API refusing to boot.

What it did gain is a check that the three Apple variables are **all set or all empty**.
`appleCredentials()` treats a partial group as unconfigured, which is right at runtime — a
half-signed client secret is one Apple rejects — but it means clearing a single variable
turns token revocation off *silently*, and revocation is non-fatal by design, so `DELETE /me`
would go on answering `200 { deleted: true }` with Apple's App Review requirement unmet and
nothing to see. A partial group is always a mistake, so the deploy says so where somebody is
watching. `APPLE_SIGNIN_KEY` is in Secret Manager and cannot be checked from that side.

---

## What this does not cover

- **Whether Apple's ID token keeps its `email` claim.** Apple documents that the address
  and name are returned on the *first* authorization only, and
  `ASAuthorizationAppleIDCredential.email` is certainly nil afterwards. Whether the **JWT
  claim** also drops out is a different question and cannot be answered from this repo or by
  any test in it. It matters because Identity Toolkit fills its response `email` from the
  incoming token and never from the account it resolved to, so a token without the claim
  yields a `localId` and no address. `identity-toolkit.ts` handles that by asking Firebase
  for the account's own address, which makes Eva independent of the answer — but confirm on
  a device that a *second* Apple sign-in still returns 200, because this is the ordinary
  returning-user path.
- **Testing.** Sign in with Apple needs a real device and a real Apple ID; the simulator
  cannot complete it. So the UI-test suite cannot drive the Apple path, the way #6 could
  not drive a mailbox. What stands in for it (#118): `AppleSignInNonceTests` pins which
  nonce goes to Apple and which to the API — the one part of the app's half that can be
  swapped and still compile — and `ProviderSignInUITests` covers the buttons, Profile's
  connected rows and the delete modal's Apple note without tapping through to Apple. For
  the Apple-connected half, the UI-test mailbox's `POST /link-apple` attaches a placeholder
  `apple.com` identity through the Admin SDK: real to `GET /me`, useless to Apple;
  `POST /link-google` does the same with `google.com` for the Google row (#330). The
  nonce pair's two strings are `private` (#330), so a caller cannot build the Apple
  credential from them itself. The sheet, the token and the server's nonce check remain
  device-only.
- **App Store policy.** Offering Google sign-in obliges the app to offer Sign in with
  Apple too. Both ship together in #7, so this is satisfied by construction — but it is
  the reason neither can ship alone.
- **Existing accounts.** A user with an email/password account who taps Sign in with Apple
  at the *same address* is merged onto their existing account by Firebase, per §0 — the
  setting decides this before Eva sees anything. This paragraph used to say they got a
  second, separate account, which was true of the earlier design and is now the opposite of
  what happens; it is left corrected rather than deleted because it is the sentence a reader
  reaches for when reasoning about `claimUnprovenAccount`. Linking from Profile is still how
  a *different* address is attached deliberately.

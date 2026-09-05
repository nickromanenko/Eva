# Eva — Sign in with Apple and Google: what a human must provision

Issue #7. Everything here is an **always-human gate** under
[AUTONOMY.md](AUTONOMY.md) — an Apple entitlement, a Services ID, a signing key and a
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

## 1. Apple: the App ID capability

Apple Developer → Certificates, Identifiers & Profiles → Identifiers → `com.evaapp.ios`.

Enable **Sign In with Apple**, save, and regenerate any provisioning profile that
covers this App ID — an existing profile does not pick the capability up on its own.

The matching entitlement lands in `mobile/project.yml` when implementation starts. Do not
add it by hand; `Eva.xcodeproj` is generated.

## 2. Apple: the Services ID

Identifiers → **+** → Services IDs. Description "Eva", identifier
`com.evaapp.ios.signin` (any unused reverse-DNS string; it must differ from the bundle ID).

Configure it against the primary App ID `com.evaapp.ios`, with:

- **Domain:** `eva-ai-made-for-women.firebaseapp.com`
- **Return URL:** `https://eva-ai-made-for-women.firebaseapp.com/__/auth/handler`

Eva's iOS app does not use this redirect — it sends Apple's `identityToken` straight to
our API. The Services ID is needed only so the Firebase console will accept the Apple
provider in step 5.

**It is not the client id our code uses, and an earlier version of this document said it
was.** Apple issues an authorization code to whichever client asked for it, and a native
`ASAuthorization` request asks as the **App ID** — the bundle identifier `com.evaapp.ios`.
The Services ID identifies the *web* flow. Exchanging a native code under the Services ID
is refused, and since revocation is deliberately non-fatal it would be refused **silently**,
leaving the App Review requirement in §3 quietly unmet. Hence `APPLE_CLIENT_ID` in §6,
which is the bundle identifier.

## 3. Apple: the signing key — and why it is not optional

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

```sh
gcloud secrets create eva-apple-signin-key --data-file=AuthKey_XXXXXXXXXX.p8 \
  --project eva-ai-made-for-women

gcloud secrets add-iam-policy-binding eva-apple-signin-key \
  --member "serviceAccount:<cloud-run-runtime-sa>" \
  --role roles/secretmanager.secretAccessor \
  --project eva-ai-made-for-women
```

Then delete the downloaded file. It is a signing key for your Apple team.

## 4. Google: an OAuth client for iOS

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

## 5. Firebase: enable both providers

> **Do §6a and §6b first.** They are numbered after this step because they are repo and
> project configuration rather than console clicks, but both have to be in place before the
> providers are reachable: without §6b the API has no client id and answers `503` to every
> Google sign-in, and without §6a linking a provider from Profile is a `500`. Turning the
> providers on first means the first users to try them are the ones who find that out.

Firebase console → Authentication → Sign-in method.

- **Apple** — enable. Fill Services ID, Apple Team ID, Key ID and the `.p8` contents from
  steps 2 and 3. The OAuth code flow fields read as optional for an iOS-only app; fill
  them regardless, because revocation uses them.
- **Google** — enable, and set the project support email.

## 6. Repo variables the code will need

Not needed until #7's code lands; listed here so provisioning and configuration are one
errand rather than two.

```sh
gh variable set GOOGLE_IOS_CLIENT_ID --body "<client id from step 4>"
# The App ID / bundle identifier, NOT the Services ID from step 2 — see the note there.
gh variable set APPLE_CLIENT_ID      --body "com.evaapp.ios"
gh variable set APPLE_TEAM_ID        --body "<10-char team id>"
gh variable set APPLE_KEY_ID         --body "<key id from step 3>"
```

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

### 6b. The deploy workflow has to pass them on — an infra change, so it is yours

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

Left undone in the #7 PR on purpose: `docs/AUTONOMY.md` puts infra implementation, and
anything touching Secret Manager, on the human side of the table.

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
  not drive a mailbox. #7 will say what stands in for it rather than pretend otherwise.
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

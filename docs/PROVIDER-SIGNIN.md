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

## 0. The setting to change before anyone signs in

Firebase console → Authentication → Settings → **User account linking**.

The default is *"Link accounts that use the same email address"*. Change it to
**"Create multiple accounts for each identity provider"**.

This is the most consequential step on the page and the easiest to skip, because nothing
visibly breaks either way. On the default, Firebase itself merges an Apple sign-in into an
existing password account whenever the addresses match — underneath our code, whatever our
code says. #7's decision rejects exactly that: identity is Apple's `sub` and only `sub`,
because an address is self-asserted at some other provider and auto-linking on one is an
account-takeover shape.

Change it **before** the first production Apple or Google sign-in. Afterwards it does not
retroactively split accounts that were already merged.

> Confirm the two option labels against your console — they are worded slightly
> differently across Firebase and Identity Platform, and I have not seen this project's
> console. The setting is the one under Authentication → Settings.

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
our API. The Services ID is required anyway, for the next step.

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
gh variable set APPLE_SERVICES_ID    --body "com.evaapp.ios.signin"
gh variable set APPLE_TEAM_ID        --body "<10-char team id>"
gh variable set APPLE_KEY_ID         --body "<key id from step 3>"
```

`APPLE_SIGNIN_KEY` arrives from Secret Manager as `eva-apple-signin-key:latest`, the same
shape as `eva-jwt-secret` and `eva-postmark-key`. All five are declared in
`api/src/config.ts` and `api/.env.example` when the code lands (GUARDRAILS 4).

---

## What this does not cover

- **Testing.** Sign in with Apple needs a real device and a real Apple ID; the simulator
  cannot complete it. So the UI-test suite cannot drive the Apple path, the way #6 could
  not drive a mailbox. #7 will say what stands in for it rather than pretend otherwise.
- **App Store policy.** Offering Google sign-in obliges the app to offer Sign in with
  Apple too. Both ship together in #7, so this is satisfied by construction — but it is
  the reason neither can ship alone.
- **Existing accounts.** Nobody's account changes. A user with an email/password account
  who taps Sign in with Apple gets a **second, separate account**, by decision, and joins
  them deliberately from Profile while signed in to the one they want to keep.

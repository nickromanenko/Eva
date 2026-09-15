import { adminAuth } from './firebase'
import { config } from './config'

/**
 * Owner of the Firebase Auth account itself — created, verified and destroyed here and
 * nowhere else.
 *
 * Two transports, for one reason: the Admin SDK cannot verify a password, so creating
 * and checking credentials goes through the Identity Toolkit REST API with the web API
 * key (GUARDRAILS 4, and the only place that key is read), while deleting an account has
 * no REST equivalent we hold a credential for and goes through the Admin SDK. Splitting
 * that across two modules would leave the Auth user with two owners, which is exactly
 * what GUARDRAILS 10 is about for Firestore collections.
 */

/**
 * Why a call failed, in *our* vocabulary rather than Google's (issue #32).
 *
 * The route has to answer differently for "this request will never work" and "ask again
 * in a minute", but it must not read `reason` to decide — a value derived from the
 * upstream answer is one refactor away from being interpolated into a message, which is
 * the enumeration leak #21 closed. So the mapping from Google's strings happens here,
 * where the upstream protocol already lives, and `index.ts` only ever sees these three.
 *
 * - `email-exists` — the address is taken. Signup says so deliberately (ARCHITECTURE §3).
 * - `rejected` — upstream refused the request itself. Our edge validation should have
 *   caught it; that it did not is a client mistake or a gap in our rule, never an outage.
 * - `unavailable` — upstream could not answer: 5xx, a throttle, a network failure, a
 *   response that is not JSON, or a project configuration that refuses the operation.
 *   Retrying is reasonable for all but the last, which retrying cannot fix but which an
 *   operator must be paged about rather than shown to the user as a bad email.
 * - `provider-linked` — the provider identity is already attached to a *different* Eva
 *   account (#7). Only `POST /me/auth/providers` can reach it, and only the holder of a
 *   valid session for one account and a provider credential for another, so answering it
 *   plainly tells that caller nothing they did not already have.
 */
export type IdentityToolkitFailure =
  | 'email-exists'
  | 'rejected'
  | 'unavailable'
  | 'provider-linked'

/**
 * Reasons Google returns with a 4xx that are nonetheless "not now", not "not ever":
 * the first two are load-shedding, the last two mean the project is misconfigured (the
 * password provider disabled, or sign-up locked to admins). None of them says anything
 * about the address that was submitted, which is what makes them safe to distinguish.
 */
const UNAVAILABLE_REASONS = new Set([
  'TOO_MANY_ATTEMPTS_TRY_LATER',
  'QUOTA_EXCEEDED',
  'OPERATION_NOT_ALLOWED',
  'ADMIN_ONLY_OPERATION',
])

/**
 * The status decides first, and only then the reason: a 5xx or a 429 is an outage whatever
 * the body claims, so a garbled or absent reason under one can never be read as a verdict
 * about the caller's address. A `null` status means the caller knows better than the reason
 * does and is expected to pass `kind` explicitly.
 */
const classify = (reason: string, upstreamStatus: number | null): IdentityToolkitFailure => {
  if (upstreamStatus !== null && (upstreamStatus >= 500 || upstreamStatus === 429)) {
    return 'unavailable'
  }
  if (reason === 'EMAIL_EXISTS') return 'email-exists'
  if (reason === 'FEDERATED_USER_ID_ALREADY_LINKED') return 'provider-linked'
  return UNAVAILABLE_REASONS.has(reason) ? 'unavailable' : 'rejected'
}

export class IdentityToolkitError extends Error {
  /**
   * `reason` is Google's own string and is for *nothing but* this class. It must never
   * reach a response body, a header, or a log line (GUARDRAILS 12) — route code branches
   * on `kind`. `upstreamStatus` is the HTTP status Google answered with, `null` when there
   * was no answer at all; it names no user and is the operator's signal.
   *
   * `kind` is derived rather than required so that every construction — including the
   * mocks in `test/` — classifies by the same rule the live call does. Pass it explicitly
   * only for a failure that has no upstream status to be judged by.
   */
  constructor(
    readonly reason: string,
    readonly upstreamStatus: number | null = null,
    readonly kind: IdentityToolkitFailure = classify(reason, upstreamStatus),
  ) {
    super(`Identity Toolkit: ${reason}`)
  }
}

interface TokenResponse {
  localId: string
  email: string
}

/** Every field of Identity Toolkit's answer this file reads, across all four endpoints. */
interface AccountsResponse {
  localId?: string
  email?: string
  /** A Firebase ID token for the account. Only `signInWithCustomToken` asks for it. */
  idToken?: string
  /**
   * `signInWithIdp` only, and it is a **refusal wearing a 200**: Identity Toolkit sets it
   * when the credential's `sub` is not linked to anything, an account already holds the
   * address the credential asserts, and the credential's own `email_verified` is falsy.
   * The body then carries that *other* account's `localId` and no `idToken` at all — the
   * Firebase JS SDK turns it into `auth/account-exists-with-different-credential`.
   *
   * It has to be a field here because the only other thing that distinguishes it from a
   * successful sign-in is a `localId` for an account the caller has never authenticated to.
   */
  needConfirmation?: boolean
  /**
   * `signInWithIdp` only, and the second refusal wearing a 200: the credential's address
   * matches an account that already holds an entry for **this same provider under a
   * different `sub`**. The provider has handed the address to somebody else — a workplace
   * mailbox reissued to a new employee is the ordinary way it happens. Firebase merges
   * anyway and returns the *old* account's `localId`.
   */
  emailRecycled?: boolean
  error?: { message?: string }
}

/**
 * Every sign-in response carries an ID token, because every request sets
 * `returnSecureToken: true`. Its absence is the one thing common to all of Identity
 * Toolkit's "200 that is not a sign-in" shapes — `needConfirmation`, `emailRecycled`'s
 * cousins, and an MFA challenge, which answers `mfaPendingCredential` and no token.
 *
 * So this is the backstop rather than the diagnosis: the named checks below say *why* and
 * classify accordingly, and this catches the shape we have not met yet. Written after the
 * fourth review of #7 found the second such shape immediately after the first was fixed —
 * enumerating them one at a time is losing to a list only Google can see.
 *
 * MFA is not enabled on the project today. It is one console switch away, and flipping it
 * would otherwise turn every second factor into a full session silently.
 *
 * Called from **both** transports — `call` (sign-up and password sign-in) and
 * `signInWithIdp`. The two named flags can only arise on the provider endpoint; the missing
 * `idToken` can arise on any of them, which is exactly why the backstop is not written into
 * one caller.
 */
const requireSignedIn = (json: AccountsResponse): void => {
  if (json.needConfirmation) {
    // "An account already holds this address and this credential has not proved it owns
    // it." Reading past it hands the caller a session on the account they collided with.
    throw new IdentityToolkitError('NEED_CONFIRMATION', null, 'rejected')
  }
  if (json.emailRecycled) {
    // The provider reassigned the address. The account behind it belongs to whoever had it
    // before, and their cycle and symptom history is the thing that would be handed over.
    throw new IdentityToolkitError('EMAIL_RECYCLED', null, 'rejected')
  }
  if (!json.idToken) {
    // Unrecognised, so not classified as the caller's fault: something answered 200 with a
    // shape this file does not know. `unavailable` pages an operator instead of telling a
    // user their Apple ID is bad.
    throw new IdentityToolkitError('NO_ID_TOKEN', null, 'unavailable')
  }
}

const post = async (
  endpoint: string,
  body: Record<string, unknown>,
): Promise<AccountsResponse> => {
  let response: Response
  try {
    response = await fetch(
      `${config.identityToolkitBaseUrl}/v1/accounts:${endpoint}?key=${config.firebaseWebApiKey}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ...body, returnSecureToken: true }),
      },
    )
  } catch {
    // The underlying error is dropped rather than attached as a `cause`: fetch puts the
    // request URL in its message, and that URL carries the web API key (GUARDRAILS 1).
    // A DNS failure, a refused connection, or a timeout are all the same fact here.
    throw new IdentityToolkitError('NETWORK_FAILURE', null, 'unavailable')
  }

  let json: AccountsResponse
  try {
    json = (await response.json()) as AccountsResponse
  } catch {
    // Not JSON means the answer did not come from Identity Toolkit at all — a proxy or
    // load balancer error page in front of it. Treat it as an outage, not as a verdict.
    throw new IdentityToolkitError('MALFORMED_RESPONSE', response.status, 'unavailable')
  }

  if (!response.ok) {
    // Google returns codes like EMAIL_EXISTS, INVALID_LOGIN_CREDENTIALS,
    // WEAK_PASSWORD : Password should be at least 6 characters
    const reason = json.error?.message?.split(' ')[0] ?? 'UNKNOWN'
    throw new IdentityToolkitError(reason, response.status)
  }
  return json
}

const call = async (endpoint: string, body: Record<string, unknown>): Promise<TokenResponse> => {
  const json = await post(endpoint, body)
  // Here as well as in `signInWithIdp`, and this is the point of it being a helper. It was
  // added for the provider route and called only from there, while ARCHITECTURE claimed it
  // guarded "any sign-in response" — so the password path, which has more users, was the
  // one left open. `signInWithPassword` answers `{ localId, email, mfaPendingCredential }`
  // and no `idToken` when MFA is enrolled, and reading `localId` out of that mints a full
  // Eva session for a second factor nobody supplied.
  requireSignedIn(json)
  return { localId: json.localId!, email: json.email! }
}

export const signUpWithPassword = (email: string, password: string) =>
  call('signUp', { email, password })

export const signInWithPassword = (email: string, password: string) =>
  call('signInWithPassword', { email, password })

// ── Provider identities (#7) ───────────────────────────────────────────────────

/** Firebase's own provider ids. They are what the Auth account is keyed to, so they are
 *  also what goes into `users/{uid}.authProviders` — the same string on both sides. */
export const PROVIDER_IDS = { apple: 'apple.com', google: 'google.com' } as const
export type ProviderName = keyof typeof PROVIDER_IDS

export interface IdpCredential {
  provider: ProviderName
  /** The provider's OIDC ID token: Apple's `identityToken`, or the `id_token` Google's
   *  token endpoint returned for the app's PKCE authorization code. */
  idToken: string
  /**
   * Apple only, and load-bearing: the **raw** nonce the app hashed into its
   * `ASAuthorizationAppleIDRequest`. Apple puts the SHA-256 of it in the token, Firebase
   * hashes this and compares — which is the whole of what stops a captured `identityToken`
   * being replayed at this route by somebody else.
   */
  rawNonce?: string
}

/**
 * Identity Toolkit wants a redirect URI even for a flow that has no redirect: ours is
 * native, the app already holds the credential, and nothing is ever sent here. The project's
 * own auth domain is used because it is a value the project owns and Google recognises,
 * rather than an invented one.
 */
const REQUEST_URI = `https://${config.firebaseProjectId}.firebaseapp.com`

/**
 * Spends a provider credential at Firebase and gets back the account it belongs to — the
 * one seam through which an Apple or Google identity becomes an Eva account (#7).
 *
 * **The uid is Firebase's, keyed to the provider's `sub`**, which is what makes the issue's
 * "identity is `sub`, and only `sub`" true by construction: a `sub` Firebase has seen
 * returns the uid it saw it with, so `ensureUser` lands on the same `users/{uid}` document,
 * and an unseen one gets a new uid and therefore a new account. This code has no email
 * lookup and must never grow one.
 *
 * Whether an address that already has a password account resolves to that same uid is
 * **Firebase's** decision, not ours: `Authentication → Settings → User account linking` is
 * set to *"Link accounts that use the same email"* (decided 2026-09-03), so it does. That
 * rule lives in the console and must not be copied into this code — two copies of a policy
 * is how the two come to disagree. What this file guarantees is narrower and still true:
 * it performs no email lookup of its own, and must never grow one.
 *
 * The linking setting is what makes `claimUnprovenAccount` below necessary; see there.
 *
 * `linkToIdToken` is the linking mode (`POST /me/auth/providers`): given a Firebase ID
 * token for an existing account, Identity Toolkit attaches the provider identity to *that*
 * account instead of resolving or creating one. A `sub` already attached elsewhere comes
 * back as `FEDERATED_USER_ID_ALREADY_LINKED`, which classifies as `provider-linked`.
 */
export const signInWithIdp = async (
  credential: IdpCredential,
  linkToIdToken?: string,
): Promise<TokenResponse> => {
  // Form-encoded inside a JSON field, which is Identity Toolkit's own shape for this
  // endpoint. `URLSearchParams` escapes each value, so nothing a caller sends can add a
  // parameter of its own.
  const postBody = new URLSearchParams({
    id_token: credential.idToken,
    providerId: PROVIDER_IDS[credential.provider],
  })
  if (credential.rawNonce) postBody.set('nonce', credential.rawNonce)

  const json = await post('signInWithIdp', {
    postBody: postBody.toString(),
    requestUri: REQUEST_URI,
    ...(linkToIdToken ? { idToken: linkToIdToken } : {}),
  })
  // Checked **before** `localId` is read, because on these responses `localId` names
  // somebody else. See `requireSignedIn`: a 200 from this endpoint is not always a sign-in,
  // and the refusals are classified `rejected`, which maps to the same
  // `401 INVALID_CREDENTIALS` as every other refusal on this route — so they add no way to
  // tell one from another (GUARDRAILS 12b).
  requireSignedIn(json)
  if (!json.localId) throw new IdentityToolkitError('MISSING_LOCAL_ID', null, 'unavailable')
  // *A response with no address is not always an error — and this is the returning Apple
  // user.* Identity Toolkit fills `email` from the **incoming token**, never from the
  // account it resolved to (`operations.js`: `response.email` is the parsed claim, and only
  // `emailVerified` is ever taken from the stored user). Apple is documented to send the
  // address on the *first* authorization; if a later one omits it, this response carries a
  // `localId` for a perfectly good account and no address at all.
  //
  // Refusing that would 503 every returning Apple user, which is what the issue's "a test
  // proves a second sign-in still resolves the account without them" is about. So ask the
  // account: it already exists, `ensureUser` is about to write its address onto the
  // document, and the authoritative copy is Firebase's.
  //
  // Whether Apple's *JWT claim* actually drops out — as distinct from the
  // `ASAuthorizationAppleIDCredential.email` property, which certainly does — cannot be
  // settled from here or by any test in this repo. `docs/PROVIDER-SIGNIN.md` lists it as a
  // device-testing item. This makes us independent of the answer either way.
  if (!json.email) {
    // A lookup that fails is the same answer as one that finds no address: there is nothing
    // to write on the document either way. Caught rather than propagated so the route
    // answers 503 rather than falling through to `app.onError` as a 500 — the caller's
    // recovery is identical, and an operator wants the `identity_toolkit_unavailable` line.
    const email = await adminAuth
      .getUser(json.localId)
      .then((account) => account.email)
      .catch(() => undefined)
    // Genuinely no address anywhere: inventing one is worse than refusing. `unavailable`
    // rather than `rejected` because it is a surprise about our project, not about the
    // caller — an operator is paged instead of a user being told their Apple ID is bad.
    if (!email) throw new IdentityToolkitError('MISSING_EMAIL', null, 'unavailable')
    return { localId: json.localId, email }
  }
  return { localId: json.localId, email: json.email }
}

/**
 * A Firebase ID token for `uid`, minted from our own Admin credentials — the first half of
 * linking (#7). Two hops rather than one because `signInWithIdp` links against an *ID*
 * token and the Admin SDK issues *custom* tokens; `signInWithCustomToken` is the exchange
 * between them.
 *
 * Chosen over `adminAuth.updateUser(uid, { providerToLink })`, which is one call, because
 * `providerToLink` takes a `sub` we would have had to verify ourselves — fetching Apple's
 * and Google's JWKS, checking `iss`, `aud`, `exp` and the nonce, and owning the rotation of
 * both. This way Firebase remains the only thing that validates a provider token, which is
 * what ARCHITECTURE §2 already says about the password path.
 *
 * The Admin credentials must be able to sign: on Cloud Run the runtime service account
 * needs `roles/iam.serviceAccountTokenCreator` **on itself**, or `createCustomToken` throws.
 * That is an infra gate (`docs/PROVIDER-SIGNIN.md`), and until it is done this route is the
 * only thing that fails.
 */
export const idTokenForUid = async (uid: string): Promise<string> => {
  const customToken = await adminAuth.createCustomToken(uid)
  const json = await post('signInWithCustomToken', { token: customToken })
  if (!json.idToken) throw new IdentityToolkitError('MISSING_ID_TOKEN', null, 'unavailable')
  return json.idToken
}

/** Firebase Admin's code for "no such user". */
const USER_NOT_FOUND = 'auth/user-not-found'

/**
 * Deletes the Firebase Auth user — step two of account deletion (#8), after the account
 * has been marked deleted in Firestore and before any of its data is swept. From here on
 * the address is free to sign up again and the old credentials open nothing.
 *
 * Idempotent: an already-deleted user is the state this is asking for, so it is success,
 * not a failure to report. That is what lets a `DELETE /me` retried after a partial
 * failure walk the same steps and finish rather than erroring on the first one that is
 * already done.
 *
 * Deliberately never told *which* address it removed, and it logs nothing: a uid is
 * enough to do the work, and an email in a log line is the thing GUARDRAILS 12 forbids.
 */
export const deleteAuthAccount = async (uid: string): Promise<void> => {
  try {
    await adminAuth.deleteUser(uid)
  } catch (err) {
    if ((err as { code?: string }).code !== USER_NOT_FOUND) throw err
  }
}

/**
 * The address a uid's Auth account actually holds, or `null` if there is no such account.
 *
 * For the `authTokens/` sweep in `DELETE /me` (#8). That sweep needs an address as well as a
 * uid, because a token issued before its account existed carries `uid: null` (#120) and a
 * uid query cannot see it — but it is a **delete key**, so which copy of the address it uses
 * decides whose documents go.
 *
 * Firebase Auth, never `users/{uid}.email`. The document's copy is written once at creation
 * and `ensureUser` never rewrites it, while an idToken holder can move their own Auth
 * address with `accounts:update` — the web API key is public. The routes that send links
 * already refuse to trust that mirror for the same reason (#121); trusting it here is worse
 * still, because it deletes rather than sends: an attacker who reserves an address, signs in
 * once to have the document written, then moves their Auth address away, leaves a document
 * permanently claiming a victim's address, and every `DELETE /me` on it would wipe the
 * victim's live activation and reset tokens.
 *
 * `null` on a resumed delete whose Auth user is already gone. The caller skips the address
 * half rather than guessing; the TTL policy on `expiresAt` is the backstop, and a stranded
 * token is a far smaller thing than someone else's deleted one. Logs nothing.
 *
 * **`proven` is the same question one step further on (#56).** The address above is the one
 * Auth holds *now*, which is not the same as one this account ever demonstrated control of:
 * `accounts:update` moves it, and Identity Toolkit clears `emailVerified` whenever it does.
 * **Measured, and not currently true of this project:** that call is refused —
 * `400 OPERATION_NOT_ALLOWED : Please verify the new email before changing email` — because
 * email-enumeration protection is on. It is a console setting, not a property of this code,
 * so the sentence above is what to assume if anyone turns it off; `account-deletion.test.ts`
 * asserts the refusal under `bun run verify` so that change cannot pass unnoticed. The
 * paragraph on `addressOfAuthAccount` above states the movability as fact and has the same
 * caveat.
 * So a caller that is about to act on *other people's* state keyed by this address — rather
 * than on this account's own rows — asks for `proven` and does nothing when it is false.
 * Fails closed: an unproven address is skipped, never guessed at.
 */
export interface AuthAddress {
  /** The address Auth holds now, or `null` if there is no such account. */
  address: string | null
  /** Whether Auth considers it proven. False for a moved address, and for no account. */
  proven: boolean
}

export const addressOfAuthAccount = async (uid: string): Promise<AuthAddress> => {
  try {
    const user = await adminAuth.getUser(uid)
    return { address: user.email ?? null, proven: user.emailVerified }
  } catch (err) {
    if ((err as { code?: string }).code === USER_NOT_FOUND) return { address: null, proven: false }
    throw err
  }
}

/**
 * The uid behind an address, or `null` when no Auth user holds it — the lookup behind
 * the two "send me a link" routes (#6). Those routes answer `200 { sent: true }` either
 * way, so the `null` never reaches a caller; it only decides whether there is anyone to
 * write to. Here rather than in `users.ts` because the Auth account, not the document, is
 * what a password reset acts on — and because `users/` is keyed by uid, never by email
 * (GUARDRAILS 9). Logs nothing.
 */
export const findAuthUidByEmail = async (email: string): Promise<string | null> => {
  try {
    return (await adminAuth.getUserByEmail(email)).uid
  } catch (err) {
    if ((err as { code?: string }).code === USER_NOT_FOUND) return null
    throw err
  }
}

/**
 * Creates the Firebase Auth account, with its password, for an address that has **just been
 * proven** (#120).
 *
 * *Why this exists at all.* Sign-up used to call `signUpWithPassword`, which created the
 * account and its password before anyone had proved the address. That reserved the address
 * for whoever asked first and put a working credential on it — so an attacker could sign up
 * as a victim, the victim could click the confirmation mail they never asked for, and the
 * attacker's password would open an activated account holding the victim's data. Every
 * defence #7 built was a way of living with that rather than removing it.
 *
 * The invariant this restores, and it is the whole point: **a password only works if the
 * person who set it proved the address.** Both halves happen in the same request now — the
 * link proves the address, the form supplies the password — so there is no window in which a
 * credential exists on an address nobody has confirmed.
 *
 * **`emailVerified` is deliberately not set here**, and the route calls
 * `markCredentialsProven` at the very end instead. Not because the flag is unearned — this
 * caller proved the address *and* chose the password, which is exactly the condition
 * `markCredentialsProven` documents as making it safe. Because of *when*. `emailVerified` is
 * what turns off `claimUnprovenAccount`'s address test, and `activatedAt` is what turns off
 * the claim itself; any gap in which the first is set and the second is not is the one
 * combination that claims unconditionally. Setting it at creation and stamping `activatedAt`
 * three calls later opened that gap on every single sign-up. See the ordering comment in the
 * route.
 *
 * Throws `email-exists` if the address was taken between the caller's sign-up and their
 * click — by someone calling Identity Toolkit directly, which the public web API key allows
 * and which Eva cannot prevent. The route turns that into a claim rather than a failure; see
 * there.
 */
export const createAccountWithPassword = async (
  email: string,
  password: string,
): Promise<string> => {
  try {
    const user = await adminAuth.createUser({ email, password })
    return user.uid
  } catch (err) {
    const code = (err as { code?: string }).code ?? ''
    if (code === 'auth/email-already-exists') {
      throw new IdentityToolkitError('EMAIL_EXISTS', null, 'email-exists')
    }
    // #32's guarantee, carried over to the Admin SDK. It was written for the Identity
    // Toolkit REST call sign-up used to make: an upstream problem must reach the caller as
    // a shaped `{ error: { code, message } }`, not as Hono's bare 500, which the iOS client
    // can only render as "Something went wrong (500)" and which makes every outage look
    // like a bug in our own server. Account creation moved to the Admin SDK (#120); the
    // guarantee moves with it.
    //
    // The two `invalid-*` codes are the caller's fault and nothing else is: a shape of
    // address our own edge validation let through, most likely. Everything else — an
    // internal error, a throttle, a network failure — is an outage the caller can retry,
    // and an operator should be told about rather than the user being told their address
    // is bad.
    if (code === 'auth/invalid-email' || code === 'auth/invalid-password') {
      throw new IdentityToolkitError(code, null, 'rejected')
    }
    throw new IdentityToolkitError(code || 'ADMIN_SDK_FAILURE', null, 'unavailable')
  }
}

/**
 * Sets a new password on the Auth account — the last step of a reset (#6), after the
 * token has been spent. The Admin SDK can set a password even though it cannot verify one,
 * so this is the one credential operation that needs no web API key. Never logs, and is
 * never told the old password; the new one passes through and is gone.
 */
export const setPassword = async (uid: string, password: string): Promise<void> => {
  await adminAuth.updateUser(uid, { password })
}

/**
 * Takes an unactivated account away from whoever set it up, keeping only the provider that
 * just signed in (#7). Overwrites the password, unlinks every other provider identity, and
 * revokes outstanding refresh tokens.
 *
 * *Why all three, and not just the password.* Firebase merges a provider sign-in into an
 * existing account when the addresses match, and `POST /auth/signup` (#6) creates the
 * Firebase Auth user **before** the address is confirmed. The web API key is public —
 * Firebase Hosting serves it at `/__/firebase/init.json` — so someone who pre-registers a
 * victim's address is a first-class Identity Toolkit client for that account and can,
 * without touching Eva:
 *
 *   1. `accounts:signInWithPassword` with their own password → a Firebase ID token;
 *   2. `accounts:signInWithIdp` with that token and *their own* Apple credential → their
 *      `sub` is now attached to the account, while `google.com` is left free;
 *   3. wait for the victim to sign in with Google, which merges onto the same uid;
 *   4. sign in at `/auth/idp` with their own Apple ID, forever.
 *
 * Overwriting the password alone defeats none of that — the attacker never uses it again.
 * Unlinking the other identities closes step 3, and revoking refresh tokens retracts the
 * session step 1 already handed them.
 *
 * But unlinking closes only the ordering above, in which the *victim* reaches `/auth/idp`
 * first. The attacker need not wait for step 3: they can sign in here themselves the moment
 * step 2 is done, and then nothing is stripped — `password` and their own `apple.com` are
 * both kept — while the call site marks the account activated, which disarms this function
 * for every later call including the victim's. Hence the address test in the body: on an
 * account someone pre-registered, the provider signing in must carry that account's own
 * address, which is the fact that made Firebase merge them in the first place.
 *
 * Safe for real users because **no legitimate flow puts a second provider on an
 * unactivated account**: Eva's own link route is behind `requireAuth`, and an unactivated
 * account cannot sign in to get a token. Anything else found here was attached out of band.
 *
 * Only ever called for an account whose address was never confirmed — a confirmed one has
 * already proven its credentials belong to its owner.
 *
 * The cost, stated: someone who genuinely signed up with a password, never clicked the
 * link, and then used Google has their own password invalidated. Nothing here can tell
 * those two people apart, and forgot-password is the flow they needed anyway.
 *
 * Returns `refused` rather than throwing, because it is a verdict about the credential and
 * not a failure: the caller answers 401, and must not activate the account.
 */
/**
 * Takes back the federated identities attached to an account before anyone proved its
 * address, and retracts the sessions that go with them (#7).
 *
 * *Why this exists, stated as the attack it closes.* `claimUnprovenAccount` defends
 * `/auth/idp`, and only `/auth/idp`. The gate in front of it is Eva's `activatedAt` — and
 * two other routes stamp that: the activation link and a password reset. Neither retracted
 * anything. So the takeover the claim was written for survived by simply waiting:
 *
 *   1. attacker signs up as the victim, which reserves the address (#6);
 *   2. attacker attaches their own Apple `sub` out of band at Identity Toolkit;
 *   3. attacker calls `/auth/idp` — refused, because the addresses differ. So far so good;
 *   4. the victim clicks the activation link they were sent, or recovers with
 *      forgot-password, which is the flow `claimUnprovenAccount` itself recommends to them;
 *   5. attacker calls `/auth/idp` again. The account is activated, so the claim is skipped
 *      **entirely**, and they are minted a 30-day session on the victim's account.
 *
 * The premise that was wrong: proving the address does not retroactively legitimise a
 * federated identity attached before it was proven. It proves the address. So the moment
 * the address *is* proven is the moment to take the rest away — the same argument
 * `claimUnprovenAccount` makes, applied at the other door.
 *
 * **The password is deliberately not touched here, and that is a cost, not an oversight.**
 * An earlier version of this comment said the password is safe because it is "the one they
 * chose at sign-up". On the reset route that is true — the caller chose it in that same
 * request. On the activation route it is exactly the assumption the attack above refutes:
 * the person who clicks the link and the person who chose the password are the same only in
 * the honest case. Rotating it would lock every legitimate signer-up out of the account they
 * had just confirmed, so what retracts an unproven password is `markCredentialsProven` being
 * withheld — see there.
 *
 * Called only on the transition to activated, never on a repeat: a user who linked Apple
 * deliberately from Profile and later resets their password must keep it. The routes decide
 * that from a read taken **before** they write anything, because anything keyed on the
 * stamp necessarily happens after it, and the stamp is what disarms the claim gate.
 *
 * A missing Auth user is not an error: a `DELETE /me` landing mid-activation leaves nothing
 * to retract, and `markActivated` answers the dead link a moment later.
 */
export const retractUnprovenIdentities = async (uid: string): Promise<void> => {
  const account = await adminAuth.getUser(uid).catch(() => null)
  if (!account) return

  // Federated only.
  const strip = account.providerData
    .map((p) => p.providerId)
    .filter((id) => id !== 'password')

  if (strip.length > 0) await adminAuth.updateUser(uid, { providersToUnlink: strip })
  // Anyone holding a session on this account got it before the address was proven, and the
  // web API key is public, so a refresh token can outlive the password that made it.
  await adminAuth.revokeRefreshTokens(uid)
}

/**
 * Tells Firebase the credentials on this account are proven — which it records as
 * `emailVerified`, though *that* is not the condition under which it is safe to call.
 *
 * **Read this before moving the call site.** Identity Toolkit uses `emailVerified` for one
 * thing beyond the obvious: when a verified provider address merges onto an account whose
 * own address is unverified, it clears `passwordHash` and unlinks every provider on it
 * (`handleIdpSigninEmailRequired`). That wipe is a nuisance — it is why a real user adding
 * Google could silently lose the password `users/{uid}.authProviders` still advertised —
 * and it is also the last thing standing between a pre-registering attacker and a victim's
 * account:
 *
 *   attacker signs up as `victim@x` with a password of their choosing; the victim clicks
 *   the confirmation mail they never asked for; the victim later signs in with Google. The
 *   wipe is what takes the attacker's password away at that moment. Nothing else does —
 *   Eva's own claim is already disarmed, because the account is activated.
 *
 * Under #7 this was therefore called from the **reset** route and deliberately *not* from
 * activation: a reset proved address control and set the password in the same request, so
 * the credentials really were the caller's, while activation proved only the address — the
 * password on the account could still be a pre-registering attacker's, and the wipe was the
 * only thing that would ever take it away. Withholding a fact that is true, for the sake of
 * a side effect, was unusual enough to be worth the paragraph.
 *
 * **#120 removed the premise, and both routes call this now.** Sign-up creates no account
 * and no credential; the only password an account can hold at activation is the one supplied
 * in the request that spent the link, by whoever proved the address. So activation is now
 * exactly as strong a claim as a reset, and the attack above has nowhere to start.
 *
 * What did *not* change is the ordering: this must run **after** `markActivated`, never
 * before. `emailVerified` is what turns off `claimUnprovenAccount`'s address test and
 * `activatedAt` is what turns off the claim itself, so an account carrying the first without
 * the second is the one state that claims unconditionally. See the tail of `activate` in
 * `index.ts`. **Both** call sites obey it since #127 — `/auth/password/reset` was the one
 * exception, and while its own `retractUnprovenIdentities` made the window unexploitable
 * there, a rule with a live counter-example is one the next person reads as advisory.
 */
export const markCredentialsProven = async (uid: string): Promise<void> => {
  await adminAuth.updateUser(uid, { emailVerified: true })
}

/**
 * What `claimUnprovenAccount` decided.
 *
 * - `claimed` — the account is now the caller's alone; the route may activate and mint.
 * - `refused` — the account's address belongs to someone who has not proven it, and the
 *   provider signing in is not them. The route must answer as it does for any bad
 *   credential and must **not** mark the account activated.
 *
 *   *Refused does not always mean untouched*, and the difference is worth knowing before
 *   relying on it. The address test refuses before any write, so that path leaves the
 *   account exactly as it found it — which is what the test beside it asserts. The
 *   **read-back** refusal happens after the password has been randomised and refresh tokens
 *   revoked, because it exists to catch a concurrent claim that stripped the provider this
 *   one kept. Reaching it means somebody's password was destroyed by a request that was then
 *   refused, with nothing sent to explain it. That is the safe direction — no session is
 *   minted either way — and forgot-password recovers it, but it is not "nothing changed".
 */
export type ClaimOutcome = 'claimed' | 'refused'

/** Same address, ignoring case and absence-vs-presence. Two missing addresses are equal;
 *  a missing one is never equal to a present one. */
const sameAddress = (a: string | undefined, b: string | undefined): boolean =>
  (a ?? '').toLowerCase() === (b ?? '').toLowerCase()

export const claimUnprovenAccount = async (
  uid: string,
  keepProviderId: string,
): Promise<ClaimOutcome> => {
  // Asked of Firebase, never of `users/{uid}`. Eva's `authProviders` is a mirror this
  // module does not write, and the two diverge in exactly the case that matters: sign-up
  // creates the Auth user before the document, so a failure between the two leaves an
  // account with the attacker's password and no document at all. A check against the
  // mirror reads that as a fresh account and does nothing.
  const account = await adminAuth.getUser(uid)

  // *Why `emailVerified`, and not "does it have a password".*
  //
  // The trigger has to be a fact the attacker cannot move. A password entry is not one:
  // Identity Toolkit derives it from `email && passwordHash`, an idToken holder can add or
  // drop credentials on their own account, and — decisively — **this function's own write
  // below sets a password**, so any account it has already claimed would take the branch on
  // a retry.
  //
  // It also missed a takeover outright. An attacker can create a federated-only account
  // with their own Apple `sub`, then call `accounts:update` with that account's idToken to
  // point its address at a victim who has not signed up yet. No password is ever attached,
  // so a password-shaped trigger skips the test, and the claim proceeds on an account whose
  // address its only provider does not own.
  //
  // `emailVerified` cannot be forged: `accounts:update` accepts it only from a privileged
  // caller, and changing an address forces it to false. It is exactly the question worth
  // asking — *has anyone proved this address belongs to this account* — and it answers
  // correctly in every case the password trigger got right, plus the two it got wrong:
  //
  //   fresh Apple/Google account (relay included) → true, from the provider; test skipped
  //   pre-registered password account             → false; test applies
  //   Firebase merge of a verified provider email → true, set as part of the merge
  //   federated-only account pointed at a victim  → false, forced by the address change
  //
  // The last row is the takeover above. The third matters for a different reason: a
  // returning user whose provider address changed is `true`, so they are never refused for
  // a mismatch that is legitimately theirs.
  const addressUnproven = !account.emailVerified

  // *Why the address has to match, and why checking the provider list is not enough.*
  //
  // Stripping the other identities defends the ordering where the victim reaches this
  // route first. It does nothing about the attacker reaching it first, which they can
  // always choose to do — they know when they signed up, and the victim does not know
  // anything happened. Pre-registering `victim@gmail.com`, attaching their *own* Apple
  // `sub` out of band, and then signing in here would otherwise strip nothing (both
  // `password` and `apple.com` are kept), mint them a session, and — one line later at the
  // call site — mark the account activated **permanently**, so the victim's real Google
  // sign-in merges onto it with the claim disarmed and never runs this code again.
  //
  // What separates the two orderings is the address. Firebase merged the victim's provider
  // into this account *because* the provider's own address equals the account's; an
  // attacker's identity attached out of band has no such equality and cannot manufacture
  // one without controlling the address, at which point they are the owner. So: an account
  // whose address nobody has proved may only be claimed by a provider that carries it.
  //
  // Fails **closed** on an absent provider address, deliberately. Identity Toolkit re-writes
  // a provider entry's `email` from the token on every sign-in, and Apple sends the address
  // only on the first authorization — so an absent one is ordinary, not corrupt, and
  // treating it as a match would make the whole test optional for any attacker willing to
  // re-authorize. A fresh provider account has `emailVerified` from the provider and never
  // reaches this branch, so Apple's Hide My Email relay is not locked out by it.
  if (addressUnproven) {
    const signingIn = account.providerData.find((p) => p.providerId === keepProviderId)
    if (!signingIn || !sameAddress(signingIn.email, account.email)) return 'refused'
  }

  // `password` is overwritten below, never unlinked — the two cannot be asked for in one
  // `updateUser`, and unlinking is the wrong half anyway: an account left with no password
  // provider has nothing for forgot-password to reset, so the real owner would be locked
  // out of recovering it. Only *federated* identities are stripped.
  const strip = account.providerData
    .map((p) => p.providerId)
    .filter((id) => id !== keepProviderId && id !== 'password')

  await adminAuth.updateUser(uid, {
    password: Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url'),
    ...(strip.length > 0 ? { providersToUnlink: strip } : {}),
  })

  // The attacker may already be holding a session: the web API key is public (Firebase
  // Hosting serves it at `/__/firebase/init.json`), so they can sign in at Identity
  // Toolkit directly and keep a refresh token alive indefinitely. Overwriting the password
  // does not retract one.
  await adminAuth.revokeRefreshTokens(uid)

  // Read back rather than trust the write. Two `/auth/idp` calls racing on the same
  // unactivated account each strip what the other kept, and both would otherwise be handed
  // a session for an account that no longer carries their identity. Cheap, and the only
  // thing between here and a token.
  const settled = await adminAuth.getUser(uid)
  if (!settled.providerData.some((p) => p.providerId === keepProviderId)) return 'refused'

  return 'claimed'
}

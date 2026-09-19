import {
  afterAll,
  afterEach,
  beforeEach,
  describe,
  expect,
  mock,
  setDefaultTimeout,
  spyOn,
  test,
} from 'bun:test'
import { mintToken } from '../src/auth'
import { config } from '../src/config'
import { adminAuth, firestore } from '../src/firebase'
import { resetAuthRateLimits } from '../src/rate-limit'
import { issueToken } from '../src/email-tokens'
import { getUser, markActivated, markUserDeleted } from '../src/users'
import { createUnactivatedAccount } from './support/session'
import type { IdpCredential } from '../src/identity-toolkit'

/**
 * Live round trips happen in this file, so the ceiling is chosen rather than inherited
 * (#31). 20s is what every other network-touching suite sets: high enough that no honest
 * round trip reaches it, low enough that a genuine hang still fails. It does not override
 * the per-test timeouts below, which stay where someone picked them deliberately.
 */
setDefaultTimeout(20_000)

/**
 * Sign in with Apple and Google, through the API (#7).
 *
 * ## What this suite can and cannot prove — read this before trusting it
 *
 * There is no way to obtain a real Apple `identityToken` or a real Google authorization
 * code from a test process: Apple needs a device and a human at an Apple ID, and Google's
 * code is minted by a consent screen. So the **provider boundary is faked** and everything
 * on our side of it is real — the same trade `signin-non-enumeration.test.ts` made, for the
 * same reason, and the mock is at the same seam (`mock.module` on
 * `../src/identity-toolkit`, the route driven in-process through `app.fetch`).
 *
 * Real, and therefore actually under test: the route's validation, `ensureUser`, the
 * `users/{uid}` documents themselves in the **live Firebase project**, the activation
 * stamp, `authProviders`, the account gate, and `DELETE /me`.
 *
 * Faked, and therefore *not* under test: that Apple's token is well-formed, that Firebase
 * rejects a replayed nonce, that Google's token endpoint accepts our PKCE exchange, and
 * that Apple's revocation endpoint accepts our client secret. The last describe below
 * closes the one piece of that which *is* ours — that the raw nonce reaches the wire — by
 * driving the real `signInWithIdp` against a stubbed `fetch`. Everything else in that list
 * needs a provisioned provider and a device, and `docs/PROVIDER-SIGNIN.md` says so.
 *
 * ## The `mock.module` caveat, as the other in-process suites state it
 *
 * Bun's module mocks are process-global and permanent, and `bun test` does not run files
 * alphabetically. So: the namespace is snapshotted on the way in and handed back in
 * `afterAll`; the rate-limit counters are shared with the other in-process files and are
 * reset around every test; and every account here is `e2e+<uuid>@e2e.evaapp.dev`
 * (GUARDRAILS 16) and is swept whether or not the test that made it got that far.
 */

// A copy, not the namespace object: `mock.module` replaces the bindings inside the live
// namespace, so a reference taken from it later would be this file's own mock.
const identityToolkit = { ...(await import('../src/identity-toolkit')) }
const { IdentityToolkitError, PROVIDER_IDS, claimUnprovenAccount } = identityToolkit

/** Captured before the mock replaces it, so the last describe can drive the real client
 *  against a stubbed `fetch` while every other test sees the fake. */
const realSignInWithIdp = identityToolkit.signInWithIdp

/** What the next `signInWithIdp` does. `null` is a bug in the test: a default that quietly
 *  succeeded would write a document for a fabricated uid into the live project. */
type IdpResult = { localId: string; email: string }
let idp: ((credential: IdpCredential, linkTo?: string) => IdpResult | Promise<IdpResult>) | null =
  null

/** The last credential the route handed the boundary — how the nonce is checked without
 *  reaching for the mock's internals. */
let lastIdp: { credential: IdpCredential; linkTo?: string } | null = null

const unset = (): never => {
  throw new Error('test/provider-signin.test.ts reached signInWithIdp without setting `idp`')
}

mock.module('../src/identity-toolkit', () => ({
  ...identityToolkit,
  signInWithIdp: async (credential: IdpCredential, linkTo?: string) => {
    lastIdp = { credential, linkTo }
    return (idp ?? unset)(credential, linkTo)
  },
  // The Admin-SDK half of linking. Faked because `createCustomToken` needs a signing
  // credential the test process is not guaranteed to hold (and on Cloud Run needs an IAM
  // role that is an infra gate) — what this suite is testing is what the route does with
  // the ID token, not how it got one.
  idTokenForUid: async (uid: string) => `firebase-id-token-for-${uid}`,
}))

// Imported after the mock, and never as a listening server.
const { default: server } = await import('../src/index')

const PASSWORD = 'correct-horse-8'

/** The nonce the "app" hashed into its ASAuthorization request. Distinctive so a leak of it
 *  into a body, a header or a log line is findable by substring. */
const RAW_NONCE = 'raw-nonce-a1b2c3d4e5'
const IDENTITY_TOKEN = 'apple-identity-token-f6g7h8'

const appleBody = () => ({
  provider: 'apple',
  identityToken: IDENTITY_TOKEN,
  rawNonce: RAW_NONCE,
})

const newEmail = () => `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`

const createdUids: string[] = []

/** An Auth user with no Eva document — what Firebase leaves behind when it creates an
 *  account for a provider `sub` it has not seen. */
const createAuthUser = async (email: string): Promise<string> => {
  const { uid } = await adminAuth.createUser({ email })
  createdUids.push(uid)
  return uid
}

const trackedUnactivatedAccount = async (email: string): Promise<string> => {
  const uid = await createUnactivatedAccount(email, PASSWORD)
  createdUids.push(uid)
  return uid
}

interface Answer {
  status: number
  /** The raw bytes, not a parse of them: a leak may be anywhere in the response. */
  text: string
  headers: string
  body: any
}

const send = async (
  method: string,
  path: string,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<Answer> => {
  const res = await server.fetch(
    new Request(`http://api.test${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify(body),
    }),
  )
  const text = await res.text()
  return {
    status: res.status,
    text,
    headers: JSON.stringify([...res.headers]),
    body: text === '' ? null : JSON.parse(text),
  }
}

const post = (path: string, body: unknown, headers?: Record<string, string>) =>
  send('POST', path, body, headers)

const bearer = (token: string) => ({ authorization: `Bearer ${token}` })

/** Every `users/{uid}` id holding this address. The whole point of the identity rule is
 *  what this returns, so it is asked directly of Firestore rather than of a route. */
const accountsForEmail = async (email: string): Promise<string[]> =>
  (await firestore.collection('users').where('email', '==', email).get()).docs
    .map((doc) => doc.id)
    .sort()

/**
 * Does this password still open this account? The question the takeover fix turns on.
 *
 * Asked of Google **directly**, with `fetch`, deliberately touching neither `POST
 * /auth/signin` nor `identity-toolkit.ts`. Both are unusable for it:
 *
 * - The route would answer `403 NOT_ACTIVATED` for exactly the accounts this cares about,
 *   hiding a live credential behind a gate.
 * - The module is replaced by `mock.module` in this file *and* in
 *   `signin-non-enumeration.test.ts`. Those mocks are process-global, permanent, and
 *   installed by whichever file Bun loads first — so even the snapshot taken at the top of
 *   this file can already be another suite's fake. An earlier version of this helper used
 *   that snapshot, passed when the file ran alone, and reported "the password was already
 *   dead" for every account in a full run.
 *
 * Not touching the module at all is the only version that answers about the credential
 * rather than about the test run.
 *
 * The origin comes from `config`, never a literal: `config.identityToolkitBaseUrl` (#67)
 * points at the Auth emulator when CI sets `FIREBASE_AUTH_EMULATOR_HOST` and at Google
 * otherwise. A hardcoded Google URL passed against the real project and failed every one
 * of these under `scripts/ci-api.sh`, because the account exists only in the emulator —
 * and Google is right to say that password opens nothing. `config` is not mocked, so this
 * keeps the immunity above while still following the emulator.
 */
const passwordStillWorks = async (email: string, password: string): Promise<boolean> => {
  const res = await fetch(
    `${config.identityToolkitBaseUrl}/v1/accounts:signInWithPassword?key=${config.firebaseWebApiKey}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    },
  )
  return res.ok
}

/**
 * Attaches a provider identity to the Auth record, the way Firebase does as part of a real
 * `signInWithIdp`. Never `catch`-swallowed: a link that fails silently is how the mock
 * drifted from production in the first place.
 */
const attachProvider = async (
  uid: string,
  providerId: string,
  providerEmail: string,
): Promise<void> => {
  await adminAuth.updateUser(uid, {
    providerToLink: {
      providerId,
      uid: `${providerId}-sub-${crypto.randomUUID()}`,
      email: providerEmail,
    },
  })
}

/**
 * The fake boundary resolving to an existing account — and **linking the identity while it
 * does**, because that is what Firebase does and `claimUnprovenAccount` reads the result.
 *
 * A mock that returned a uid without touching `providerData` described a world the route
 * never meets in production: the provider that just signed in was absent from the record,
 * so the `id !== keepProviderId` branch of the strip filter had nothing to keep and was
 * never executed by any test. Deleting that branch outright left the suite fully green
 * while every provider user's identity was unlinked a moment after they signed in.
 *
 * `providerEmail` defaults to the account's own address, which is the case Firebase's
 * "link accounts that use the same email" setting produces. Pass a different one to build
 * the identity an attacker attaches out of band.
 */
const resolveTo =
  (
    uid: string,
    email: string,
    { providerEmail = email, verifies = true }: { providerEmail?: string; verifies?: boolean } = {},
  ) =>
  async (credential: IdpCredential): Promise<IdpResult> => {
    const providerId = PROVIDER_IDS[credential.provider]
    // Already linked is the second-sign-in case, and Firebase does not duplicate it.
    // Tested for rather than caught, so a link that fails for any *other* reason throws.
    const linked = (await adminAuth.getUser(uid)).providerData.some(
      (p) => p.providerId === providerId,
    )
    if (!linked) await attachProvider(uid, providerId, providerEmail)
    // Apple and Google both assert `email_verified`, and Identity Toolkit copies it onto
    // the account — on a fresh sign-up from `handleIdpSignUp`, and on a merge, where it
    // sets `emailVerified: true` as part of the same write that strips the old
    // credentials. A fake that skipped this modelled a world in which no provider
    // sign-in ever verifies an address, which is exactly half of what
    // `claimUnprovenAccount`'s trigger reads. `verifies: false` builds the other half
    // deliberately.
    if (verifies) await adminAuth.updateUser(uid, { emailVerified: true })
    return { localId: uid, email }
  }

/** A real Firebase ID token for a password account, from Identity Toolkit directly — the
 *  session an attacker holds without ever touching Eva. Same reasoning as
 *  `passwordStillWorks` above for why it goes nowhere near the mocked module. */
const idTokenFromPassword = async (email: string, password: string): Promise<string | null> => {
  const res = await fetch(
    `${config.identityToolkitBaseUrl}/v1/accounts:signInWithPassword?key=${config.firebaseWebApiKey}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    },
  )
  if (!res.ok) return null
  return ((await res.json()) as { idToken?: string }).idToken ?? null
}

const activatedAt = async (uid: string): Promise<unknown> =>
  (await firestore.collection('users').doc(uid).get()).get('activatedAt')

/** Slow because each case is a chain of real round trips to Auth and Firestore. */
const SLOW = 20_000

beforeEach(() => {
  resetAuthRateLimits()
  idp = null
  lastIdp = null
})

/**
 * One case below borrows `config.rateLimit.trustedProxyHops`, and `config` is a mutable
 * singleton shared by every file in the run — `bun test` uses one process and one module
 * registry. A `try/finally` is not enough on its own: a timed-out test never reaches its
 * `finally`, and this file's cases are live round trips under a 20s ceiling, so leaving the
 * restore there would mean one slow run silently reconfiguring the throttle for every file
 * that follows. `afterEach` runs after a timeout, so the knob goes back either way.
 */
const DEPLOYED_HOPS = config.rateLimit.trustedProxyHops
afterEach(() => {
  config.rateLimit.trustedProxyHops = DEPLOYED_HOPS
})

afterAll(async () => {
  resetAuthRateLimits()
  idp = null
  for (const uid of createdUids) {
    await adminAuth.deleteUser(uid).catch(() => {})
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
  }
  // Hand the module back as it was found — Bun's mocks are permanent and process-global.
  mock.module('../src/identity-toolkit', () => identityToolkit)
}, 120_000)

describe("the provider ids are Firebase's strings, not ours", () => {
  /**
   * Pinned as literals, on purpose, and the only assertions in this file that do not go
   * through `PROVIDER_IDS`.
   *
   * Every other test dereferences the constant, so all of them agree with it whatever it
   * says — changing the source to `{ apple: "apple", google: "google" }` left the entire
   * suite green. That is not a hypothetical: the identical defect shipped in the iOS half
   * of this PR, where `EvaAuthProvider.rawValue` ("apple") was compared against Firebase's
   * `"apple.com"`, and two tests asserted the wrong value was right.
   *
   * What it would cost here: `signInWithIdp` sends `providerId` on the wire, so Firebase
   * would reject every provider sign-in in production, and `users/{uid}.authProviders`
   * would hold a string the app's `firebaseProviderID` never matches — which silently
   * disables Apple token revocation, an App Review requirement (`docs/PROVIDER-SIGNIN.md`).
   */
  test('apple is apple.com and google is google.com', () => {
    expect(PROVIDER_IDS.apple).toBe('apple.com')
    expect(PROVIDER_IDS.google).toBe('google.com')
    // The request-body word is deliberately not the Firebase id. Asserting they differ
    // keeps a "simplification" that collapses the two from passing.
    expect(PROVIDER_IDS.apple).not.toBe('apple')
    expect(PROVIDER_IDS.google).not.toBe('google')
  })
})

describe('claimUnprovenAccount reads back what it wrote', () => {
  test(
    'an account that does not carry the kept provider afterwards is refused, not claimed',
    async () => {
      // The concurrency case, reachable without concurrency. Two `/auth/idp` calls
      // racing on the same unactivated account each read `providerData` before either
      // write lands, so each strips what the other kept — and both would otherwise be
      // handed a session for an account that no longer carries their identity.
      //
      // Driven directly rather than through the route because a real race is not
      // deterministic; what is under test is that the function refuses to report
      // success for a state it can see is wrong. Here the provider was simply never
      // attached, which is the same end state the loser of the race observes.
      //
      // `emailVerified` is set so the address test above is skipped: otherwise this
      // is refused before any write and the read-back — the thing under test — never
      // runs. Deleting the read-back must fail this test, not be masked by the gate
      // in front of it.
      const uid = await createAuthUser(newEmail())
      await adminAuth.updateUser(uid, { emailVerified: true })

      expect(await claimUnprovenAccount(uid, PROVIDER_IDS.apple)).toBe('refused')
    },
    SLOW,
  )

  test(
    'the ordinary case still claims',
    async () => {
      const email = newEmail()
      const uid = await createAuthUser(email)
      await attachProvider(uid, PROVIDER_IDS.apple, email)

      expect(await claimUnprovenAccount(uid, PROVIDER_IDS.apple)).toBe('claimed')
    },
    SLOW,
  )
})

describe("POST /auth/idp — identity is the provider's sub, and only sub", () => {
  test(
    'a sub Firebase has seen lands on the same users/{uid}, with no second document',
    async () => {
      const email = newEmail()
      const uid = await createAuthUser(email)
      idp = resolveTo(uid, email)

      const first = await post('/auth/idp', appleBody())
      const second = await post('/auth/idp', appleBody())

      expect(first.status).toBe(200)
      expect(second.status).toBe(200)
      expect(first.body.user.id).toBe(uid)
      expect(second.body.user.id).toBe(uid)
      expect(first.body.token).toBeString()
      // One document, not two — the acceptance criterion, asked of Firestore.
      expect(await accountsForEmail(email)).toEqual([uid])
      expect(first.body.user.authProviders).toEqual([PROVIDER_IDS.apple])
      // A second sign-in adds no duplicate: `arrayUnion`, and the returned copy of it.
      expect(second.body.user.authProviders).toEqual([PROVIDER_IDS.apple])
    },
    SLOW,
  )

  test(
    'the account is whichever uid the boundary returns — this route never looks up an email',
    async () => {
      // Whether a shared address resolves to one account or two is **Firebase's**
      // decision (`Settings → User account linking`, set to "Link accounts that use
      // the same email" on 2026-09-03), and it is made before this route sees
      // anything. What is ours, and all this can prove, is that the route adds no
      // second opinion: it acts on the uid it was handed and performs no lookup of
      // its own. A regression that grew one would show up here as the pre-existing
      // account being touched.
      //
      // This is the real Hide My Email case: the relay address matches nothing, so
      // Firebase hands back a new uid and the user gets a new account while their
      // password account at the other address sits untouched beside it.
      //
      // An earlier version of this test had the boundary return the *password*
      // account's address against the Apple account's uid, to make the point sharply.
      // Firebase cannot produce that state — two Auth accounts cannot share an
      // address — and it is now refused by `claimUnprovenAccount`, correctly: an
      // unverified account whose provider's address is not its own is the shape of
      // the takeover in the test below. The property under test is unchanged.
      const email = newEmail()
      const relay = newEmail()
      const passwordUid = await trackedUnactivatedAccount(email)
      const appleUid = await createAuthUser(relay)
      idp = resolveTo(appleUid, relay)

      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(200)
      expect(res.body.user.id).toBe(appleUid)
      expect(res.body.user.id).not.toBe(passwordUid)
      expect(await accountsForEmail(relay)).toEqual([appleUid])
      expect(await accountsForEmail(email)).toEqual([passwordUid])

      // The account the route was NOT pointed at is untouched — no link, no
      // activation, and its password still its own.
      const original = (await getUser(passwordUid))!
      expect(original.authProviders).toEqual(['password'])
      expect(original.activated).toBe(false)
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)
    },
    SLOW,
  )

  test(
    'linking onto an unactivated account strips every credential but the one that signed in',
    async () => {
      // The takeover this closes: Firebase merges a provider sign-in into an existing
      // account when the addresses match, and `POST /auth/signup` (#6) creates that
      // account before anyone proves the address. So an attacker signs up as the
      // victim, waits for the victim to tap Sign in with Google, and inherits an
      // account this route then marks activated for them.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      idp = resolveTo(uid, email)

      // Asserted before as well as after, so the "false" below can only mean the
      // password changed — not that it was never right, or that some gate refused it.
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)

      const res = await post('/auth/idp', appleBody())
      expect(res.status).toBe(200)
      expect(res.body.user.id).toBe(uid)
      expect(await accountsForEmail(email)).toEqual([uid])
      expect(res.body.user.authProviders.sort()).toEqual(['password', PROVIDER_IDS.apple].sort())

      // The attacker's password is gone.
      expect(await passwordStillWorks(email, PASSWORD)).toBe(false)

      // The password *provider* survives, deliberately — only the password does not.
      // An account with no password provider has nothing for forgot-password to
      // reset, which would lock the real owner out of recovering it.
      //
      // Apple survives too, and must: it is the identity that just signed in, and
      // the filter keeps it by name. An earlier version of this assertion read
      // `["password"]` — true only because the fake boundary never linked anything,
      // which is what let the keep-branch go unexercised.
      const authRecord = await adminAuth.getUser(uid)
      expect(authRecord.providerData.map((p) => p.providerId).sort()).toEqual(
        ['password', PROVIDER_IDS.apple].sort(),
      )
    },
    SLOW,
  )

  test(
    'a provider identity attached before the account was proven does not survive the claim',
    async () => {
      // The attacker's foothold, built the way they would build it: a second provider
      // on an account whose address nobody confirmed. `google.com` here stands in for
      // the identity they attached; the victim then signs in with Apple.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      await adminAuth.updateUser(uid, {
        providerToLink: {
          providerId: PROVIDER_IDS.google,
          uid: `attacker-google-sub-${crypto.randomUUID()}`,
          email,
        },
      })
      expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId).sort()).toEqual(
        [PROVIDER_IDS.google, 'password'].sort(),
      )

      idp = resolveTo(uid, email)
      expect((await post('/auth/idp', appleBody())).status).toBe(200)

      // The attacker's Google identity is gone, and Apple — the one that signed in —
      // is still there. Both halves matter: stripping too little leaves the takeover
      // open, stripping too much unlinks the user who just arrived and hands them a
      // new uid on their next sign-in. `password` remains as a provider so the real
      // owner can reset it, but the password itself no longer opens the account.
      expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId).sort()).toEqual(
        ['password', PROVIDER_IDS.apple].sort(),
      )
      expect(await passwordStillWorks(email, PASSWORD)).toBe(false)
    },
    SLOW,
  )

  test(
    'the attacker cannot claim the account by reaching this route before the victim',
    async () => {
      // The ordering the strip alone does *not* close, and the reason the address
      // test exists. Everything above assumes the victim signs in first. Nothing
      // makes them: the attacker knows when they pre-registered, and the victim knows
      // nothing has happened at all.
      //
      //   1. attacker signs up as victim@…, which reserves the address (#6);
      //   2. attacker signs in at Identity Toolkit directly — the web API key is
      //      public — and links their *own* Apple sub to that account out of band;
      //   3. attacker signs in here. Nothing is stripped: `password` and `apple.com`
      //      are both kept. Without the address test they are handed a session and
      //      the account is marked activated, which disarms the claim forever, so the
      //      victim's real Google sign-in later merges onto an account the attacker
      //      holds.
      const victimEmail = newEmail()
      const attackerAppleEmail = newEmail()
      const uid = await trackedUnactivatedAccount(victimEmail)
      await attachProvider(uid, PROVIDER_IDS.apple, attackerAppleEmail)

      // The attacker's own Apple identity, whose address is not the account's.
      idp = () => ({ localId: uid, email: victimEmail })

      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(401)
      expect(res.body.error.code).toBe('INVALID_CREDENTIALS')
      expect(res.body.token).toBeUndefined()

      // Not activated — the half that would otherwise be permanent. If this stamp
      // lands, the victim's later sign-in skips the claim and inherits the attacker.
      expect(await activatedAt(uid)).toBeNull()

      // Refused means refused: nothing was changed on the way out, so a retry sees
      // the same account rather than a half-claimed one.
      expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId).sort()).toEqual(
        [PROVIDER_IDS.apple, 'password'].sort(),
      )
    },
    SLOW,
  )

  test(
    'a needConfirmation answer is a refusal, however much it looks like a success',
    async () => {
      // Identity Toolkit's third outcome, and the one that is not an error: when the
      // credential's `sub` is linked to nothing, an account already holds the address
      // the credential asserts, and the credential's own `email_verified` is falsy,
      // it answers **200** with `needConfirmation: true`, that other account's
      // `localId`, and no `idToken` — "this credential must not sign in". The
      // Firebase JS SDK raises `account-exists-with-different-credential` from it.
      //
      // Read past it and the caller is handed a 30-day session on an account they
      // have never authenticated to. This drives the *real* client against a stubbed
      // `fetch`, because the point is what the module does with that response shape.
      const victimEmail = newEmail()
      const victimUid = await createAuthUser(victimEmail)

      const realFetch = globalThis.fetch
      globalThis.fetch = (async (_input: any) =>
        new Response(
          JSON.stringify({
            needConfirmation: true,
            localId: victimUid,
            email: victimEmail,
            verifiedProvider: ['google.com'],
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        )) as typeof fetch

      let thrown: unknown
      try {
        await realSignInWithIdp({
          provider: 'apple',
          idToken: IDENTITY_TOKEN,
          rawNonce: RAW_NONCE,
        }).catch((err) => {
          thrown = err
        })
      } finally {
        globalThis.fetch = realFetch
      }

      // The classification, not merely that it threw. `rejected` is what maps this
      // to the same `401 INVALID_CREDENTIALS` as every other refusal on the route;
      // `unavailable` would answer `503` with a `Retry-After`, which tells the client
      // to retry something no retry can fix, pages an operator for a permanent
      // refusal, and — the reason it matters most — makes "an account already holds
      // this address" distinguishable from a plain bad credential (GUARDRAILS 12b).
      expect(thrown).toBeInstanceOf(IdentityToolkitError)
      expect((thrown as InstanceType<typeof IdentityToolkitError>).kind).toBe('rejected')
      // An earlier version of this test asserted `activatedAt(victimUid)` was
      // undefined. `createAuthUser` writes no Firestore document and this test never
      // drives the route, so that was true before the act as well: an assertion that
      // could not fail, standing in for "the victim's account is untouched".
      expect((await firestore.collection('users').doc(victimUid).get()).exists).toBe(false)
    },
    SLOW,
  )

  test(
    "an account pointed at a stranger's address is refused even with no password on it",
    async () => {
      // The takeover the password-shaped trigger missed entirely, and the reason the
      // trigger is `emailVerified`:
      //
      //   1. attacker signs in at Identity Toolkit directly with their own Apple
      //      credential — new account, their address, no Eva document;
      //   2. attacker calls `accounts:update` with that account's own idToken to
      //      point its address at a victim who has not signed up yet. Changing an
      //      address forces `emailVerified` to false, and no password is ever
      //      attached;
      //   3. attacker signs in here. A trigger that asks "does it have a password"
      //      finds none, skips the address test, and claims, activates and tokenises
      //      an account carrying the victim's address.
      const victimEmail = newEmail()
      const attackerAppleEmail = newEmail()
      const uid = await createAuthUser(attackerAppleEmail)
      await attachProvider(uid, PROVIDER_IDS.apple, attackerAppleEmail)
      // Step 2, with the same end state: the account's address is the victim's, its
      // only provider carries the attacker's, and nobody has proved either.
      await adminAuth.updateUser(uid, { email: victimEmail, emailVerified: false })
      expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId)).toEqual([
        PROVIDER_IDS.apple,
      ])

      idp = () => ({ localId: uid, email: victimEmail })

      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(401)
      expect(res.body.token).toBeUndefined()
      // No document at all — not merely an unactivated one. `ensureUser` writes, and
      // running it before the claim gate left a refused credential's provider unioned
      // permanently into `authProviders` on the account it collided with. `toBeNull`
      // here used to pass, and `null` rather than `undefined` was the evidence that
      // the write had already happened.
      expect((await firestore.collection('users').doc(uid).get()).exists).toBe(false)
    },
    SLOW,
  )

  test(
    'a refused credential leaves no trace on the account it collided with',
    async () => {
      // The victim's own account, already real and already activated — the state a
      // refusal must not touch. The damage is not the 401; it is that
      // `users/{uid}.authProviders` is what the app reads to decide whether to offer
      // "Connect Apple", so a provider mirrored there by a request that was refused
      // takes away the real owner's only way to link the identity that is theirs.
      const victimEmail = newEmail()
      const uid = await trackedUnactivatedAccount(victimEmail)
      await markActivated(uid)
      const before = (await getUser(uid))!.authProviders
      expect(before).toEqual(['password'])

      // An unverified account whose only provider carries a stranger's address.
      await adminAuth.updateUser(uid, { emailVerified: false })
      await attachProvider(uid, PROVIDER_IDS.apple, newEmail())
      // Unactivate it so the claim gate is reached at all.
      await firestore.collection('users').doc(uid).update({ activatedAt: null })

      idp = () => ({ localId: uid, email: victimEmail })
      expect((await post('/auth/idp', appleBody())).status).toBe(401)

      expect((await getUser(uid))!.authProviders).toEqual(before)
    },
    SLOW,
  )

  test(
    'a provider that carries no address at all cannot claim an unproven account',
    async () => {
      // Identity Toolkit rewrites a provider entry's `email` from the token on every
      // sign-in, and Apple sends the address only on the *first* authorization — so
      // an absent one is ordinary, not corrupt. Treating absent as a match would make
      // the address test optional for any attacker willing to re-authorize once.
      const victimEmail = newEmail()
      const uid = await trackedUnactivatedAccount(victimEmail)
      await adminAuth.updateUser(uid, {
        providerToLink: {
          providerId: PROVIDER_IDS.apple,
          uid: `attacker-apple-sub-${crypto.randomUUID()}`,
          // No email — the case `sameAddress` must not read as agreement.
        },
      })

      idp = () => ({ localId: uid, email: victimEmail })

      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(401)
      expect(res.body.token).toBeUndefined()
      expect(await activatedAt(uid)).toBeNull()
    },
    SLOW,
  )

  test(
    'an address that differs only in case is the same address',
    async () => {
      // The other direction, and the reason the comparison folds case: Firebase
      // canonicalises the account's address, a provider may not, and refusing on that
      // difference would give a real user a permanent 401 with no way to find out why.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      await attachProvider(uid, PROVIDER_IDS.apple, email.toUpperCase())

      idp = () => ({ localId: uid, email })

      expect((await post('/auth/idp', appleBody())).status).toBe(200)
    },
    SLOW,
  )

  test(
    'the claim revokes sessions the attacker already holds',
    async () => {
      // The third leg named in `claimUnprovenAccount`'s own docstring, and the one
      // with nothing else standing in for it. Overwriting the password does not
      // retract a refresh token: the web API key is public, so whoever set the
      // password can hold a live Identity Toolkit session indefinitely and keep
      // minting Firebase ID tokens for the account after the claim has run.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)

      // The attacker's live session, obtained the way they would obtain it: straight
      // at Identity Toolkit with the public web API key, never through Eva.
      const attackerToken = await idTokenFromPassword(email, PASSWORD)
      expect(attackerToken).toBeString()
      // It works right now. Asserted before the act so the rejection below cannot be
      // "the token was never valid".
      expect(await adminAuth.verifyIdToken(attackerToken!, true)).toBeTruthy()

      // `tokensValidAfterTime` has one-second resolution, so a claim in the same
      // second as the sign-in is indistinguishable from no revocation at all — by
      // Firebase's own comparison, not just by this assertion. Crossing the boundary
      // is what makes the check deterministic rather than a coin flip.
      await Bun.sleep(1_100)

      idp = resolveTo(uid, email)
      expect((await post('/auth/idp', appleBody())).status).toBe(200)

      // The property, not a proxy for it: Firebase now refuses the token when asked
      // to check revocation.
      await expect(adminAuth.verifyIdToken(attackerToken!, true)).rejects.toThrow()
    },
    SLOW,
  )

  test(
    'the revocation is asked for, not inherited from the password write',
    async () => {
      // Asserting the *call*, which is normally the wrong thing to assert — so the
      // reason, because it is not obvious.
      //
      // The test above proves the outcome: the attacker's Firebase ID token stops
      // verifying. But it cannot attribute that outcome. Identity Toolkit bumps
      // `validSince` on any update carrying a password, so overwriting the password
      // revokes tokens as a side effect, and deleting `revokeRefreshTokens` outright
      // leaves that test green. Verified by mutation, against the emulator, which is
      // also the only implementation of Firebase the CI suite has.
      //
      // Whether Google's production Identity Toolkit makes the same side effect is
      // not something this suite can find out, and the claim's docstring names
      // revocation as one of its three legs. So the call is pinned: not because
      // calling it is the requirement, but because nothing else here can tell the
      // difference between "revoked" and "revoked by accident".
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      const spy = spyOn(adminAuth, 'revokeRefreshTokens')

      try {
        idp = resolveTo(uid, email)
        expect((await post('/auth/idp', appleBody())).status).toBe(200)
        expect(spy).toHaveBeenCalledWith(uid)
      } finally {
        spy.mockRestore()
      }
    },
    SLOW,
  )

  test(
    'a refusal for a provider that is not on the account changes nothing either',
    async () => {
      // The `!signingIn` half of the guard, which the read-back would otherwise mask:
      // weaken it to `signingIn && !sameAddress(...)` and the outcome is still
      // `refused`, but only after the account has been overwritten — password gone,
      // federated identities stripped, sessions revoked — for a request that was
      // never entitled to touch it. Asked of the credential, which is the part a real
      // owner would notice.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)

      expect(await claimUnprovenAccount(uid, PROVIDER_IDS.apple)).toBe('refused')

      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)
      expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId)).toEqual([
        'password',
      ])
    },
    SLOW,
  )

  test(
    'a verified account is not refused when the provider stops sending an address',
    async () => {
      // The direction the address test must NOT be applied in, and the lockout the
      // `emailVerified` trigger exists to remove.
      //
      // Identity Toolkit rewrites a provider entry's `email` from the token on every
      // sign-in, and Apple sends the address only on the *first* authorization. So a
      // returning Apple user's entry can legitimately have no email at all. If the
      // address test ran on them, `sameAddress` would fail closed and they would get
      // `401` on every sign-in, for ever, with no recovery — activation needs an email
      // they may never see, and forgot-password on a relay address goes nowhere.
      //
      // What makes them safe is that their address is *verified*: Apple asserted it,
      // Identity Toolkit copied it onto the account, and nobody can set that field
      // without being Apple or being an admin.
      const email = newEmail()
      const uid = await createAuthUser(email)
      await adminAuth.updateUser(uid, {
        emailVerified: true,
        providerToLink: {
          providerId: PROVIDER_IDS.apple,
          uid: `apple-sub-${crypto.randomUUID()}`,
          // No email, exactly as a re-authorization leaves it.
        },
      })

      idp = resolveTo(uid, email)

      expect((await post('/auth/idp', appleBody())).status).toBe(200)
    },
    SLOW,
  )

  test(
    'an outage at Google is 503, not every user being told their credential is bad',
    async () => {
      // Where `classify` in providers.ts actually decides something. Collapsing it to
      // always-`rejected` was green, because the Apple path discards `kind` — it maps
      // every token-endpoint failure to `stage: "token"` regardless. Only the Google
      // route consumes it, and the wrong answer there is silent: `rejected` becomes a
      // 401 with **no log line**, so a Google outage presents as every user's
      // credential being bad and nothing points at the cause.
      //
      // Needs the client id set, since the unprovisioned path returns before the call.
      const clientId = config.providers.googleIosClientId
      ;(config.providers as { googleIosClientId: string | null }).googleIosClientId =
        '1234-abcd.apps.googleusercontent.com'
      const realFetch = globalThis.fetch
      // A **JSON** body, deliberately. A non-JSON one is thrown as `unavailable` by
      // the malformed-response branch before `classify` is ever consulted — so the
      // first version of this test passed with `classify` collapsed to always-
      // `rejected`, proving the wrong thing. Google answers errors in JSON.
      globalThis.fetch = (async (_input: any) =>
        new Response(JSON.stringify({ error: 'backend_error' }), {
          status: 503,
          headers: { 'content-type': 'application/json' },
        })) as typeof fetch

      let res: Answer
      try {
        res = await post('/auth/idp', {
          provider: 'google',
          code: 'auth-code',
          codeVerifier: 'code-verifier',
          redirectUri: 'com.googleusercontent.apps.1234:/oauth2redirect',
        })
      } finally {
        globalThis.fetch = realFetch
        ;(config.providers as { googleIosClientId: string | null }).googleIosClientId = clientId
      }

      expect(res.status).toBe(503)
      expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE')
      // And it says how long to wait, rather than leaving the client to guess.
      expect(
        JSON.parse(res.headers).some(([name]: [string, string]) => name === 'retry-after'),
      ).toBe(true)
    },
    SLOW,
  )

  test(
    "a recycled provider address does not hand one user another user's account",
    async () => {
      // Identity Toolkit's *second* refusal wearing a 200, and the one that arrives
      // without anybody doing anything wrong. `emailRecycled` is set when the
      // credential's address matches an account that already holds an entry for this
      // same provider under a **different** `sub` — the provider gave the address to
      // somebody else. A workplace mailbox reissued to a new employee is the ordinary
      // way it happens, and Firebase merges anyway, returning the *old* account's uid.
      //
      // The old account is activated, so the claim never runs. Without this check the
      // new employee is handed a 30-day session on their predecessor's cycle, flow and
      // symptom history.
      const realFetch = globalThis.fetch
      globalThis.fetch = (async (_input: any) =>
        new Response(
          JSON.stringify({
            emailRecycled: true,
            localId: 'the-previous-owners-uid',
            email: 'e2e+recycled@e2e.evaapp.dev',
            idToken: 'a-firebase-id-token',
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        )) as typeof fetch

      let thrown: unknown
      try {
        await realSignInWithIdp({
          provider: 'google',
          idToken: IDENTITY_TOKEN,
        }).catch((err) => {
          thrown = err
        })
      } finally {
        globalThis.fetch = realFetch
      }

      expect(thrown).toBeInstanceOf(IdentityToolkitError)
      // Same classification as every other refusal, so it is one 401 among many.
      expect((thrown as InstanceType<typeof IdentityToolkitError>).kind).toBe('rejected')
    },
    SLOW,
  )

  test(
    'a second sign-in resolves the account even when the provider sends no address',
    async () => {
      // The acceptance criterion for Apple's first-authorization behaviour, and the
      // half that was missing: the two-call route test returns an address on *both*
      // calls, so "resolves the account without them" was never built.
      //
      // Identity Toolkit fills `email` from the **incoming token** and never from the
      // account it resolved to — `operations.js` takes only `emailVerified` from the
      // stored user. So a token without the claim yields a response with a good
      // `localId` and no address, and refusing it would answer 503 to every returning
      // Apple user, on the ordinary path, with no client recovery.
      //
      // Driven through the real client rather than the route, because the fallback
      // lives inside `signInWithIdp` and the route sees this file's mock of it.
      const email = newEmail()
      const uid = await createAuthUser(email)

      const realFetch = globalThis.fetch
      // URL-aware so the intent is legible, though the fall-through is belt and
      // braces: `firebase-admin` does not route through `globalThis.fetch`, so the
      // fallback's `getUser` reaches the emulator regardless of this stub. Written
      // this way so the test does not quietly depend on that staying true.
      globalThis.fetch = (async (input: any, init?: any) => {
        const url = String(input?.url ?? input)
        if (url.includes('accounts:signInWithIdp')) {
          return new Response(JSON.stringify({ localId: uid, idToken: 'a-firebase-id-token' }), {
            status: 200,
            headers: { 'content-type': 'application/json' },
          })
        }
        return realFetch(input, init)
      }) as typeof fetch

      let result: { localId: string; email: string } | undefined
      try {
        result = await realSignInWithIdp({
          provider: 'apple',
          idToken: IDENTITY_TOKEN,
          rawNonce: RAW_NONCE,
        })
      } finally {
        globalThis.fetch = realFetch
      }

      expect(result?.localId).toBe(uid)
      // Answered from the account, not invented and not blank.
      expect(result?.email).toBe(email)
    },
    SLOW,
  )

  test(
    'a sign-in with no address is an outage, not a verdict about the caller',
    async () => {
      // There is nothing to write on a new document and inventing an address is worse
      // than refusing — but the classification is the point. `unavailable` pages an
      // operator about a surprise in our project's configuration; `rejected` would
      // tell the user their Apple ID is bad, which it is not, and give them nothing
      // to do about it. Deleting the check ships a `500 INTERNAL` instead, because
      // Firestore rejects `email: undefined`.
      //
      // `some-uid` is deliberately an account that does not exist, so this also covers
      // the branch where the fallback lookup finds nothing: no address on the wire and
      // none to be had from Firebase either is the one case that is still refused.
      const realFetch = globalThis.fetch
      globalThis.fetch = (async (_input: any) =>
        new Response(JSON.stringify({ localId: 'some-uid', idToken: 'a-firebase-id-token' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })) as typeof fetch

      let thrown: unknown
      try {
        await realSignInWithIdp({
          provider: 'google',
          idToken: IDENTITY_TOKEN,
        }).catch((err) => {
          thrown = err
        })
      } finally {
        globalThis.fetch = realFetch
      }

      expect(thrown).toBeInstanceOf(IdentityToolkitError)
      expect((thrown as InstanceType<typeof IdentityToolkitError>).kind).toBe('unavailable')
    },
    SLOW,
  )

  test(
    'a 200 with no ID token is not a sign-in, whatever else it says',
    async () => {
      // The backstop, and the reason it is not another named check: `needConfirmation`
      // and `emailRecycled` were found one at a time, in consecutive review rounds,
      // and the list is Google's rather than ours. An MFA challenge is the next one —
      // it answers `mfaPendingCredential` and no token, so reading `localId` past it
      // would turn every second factor into a full session. MFA is one console switch
      // away from being on.
      //
      // Every request sets `returnSecureToken: true`, so a real sign-in always carries
      // an ID token. Absence is the shape all three have in common.
      const realFetch = globalThis.fetch
      globalThis.fetch = (async (_input: any) =>
        new Response(
          JSON.stringify({
            localId: 'some-uid',
            email: 'e2e+mfa@e2e.evaapp.dev',
            mfaPendingCredential: 'a-pending-credential',
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        )) as typeof fetch

      let thrown: unknown
      try {
        await realSignInWithIdp({
          provider: 'google',
          idToken: IDENTITY_TOKEN,
        }).catch((err) => {
          thrown = err
        })
      } finally {
        globalThis.fetch = realFetch
      }

      expect(thrown).toBeInstanceOf(IdentityToolkitError)
      // `unavailable`, not `rejected`: an unrecognised shape is a surprise about our
      // project, not a verdict about the caller, so it pages rather than telling
      // someone their Apple ID is bad.
      expect((thrown as InstanceType<typeof IdentityToolkitError>).kind).toBe('unavailable')
    },
    SLOW,
  )

  test(
    'each refusal is one message to the caller and a distinct stage in the log',
    async () => {
      // Five branches answer `PROVIDER_REJECTED`, and that is deliberate — the
      // caller's recovery is the same for all of them and telling them apart would
      // say whether an address has an account. But none of them logged, so nobody
      // could tell them apart either: the first real Apple sign-in on a device failed
      // with that message and there was no way to learn whether Firebase had refused
      // the token or the claim had refused the account.
      const logged: string[] = []
      const spy = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
        logged.push(args.map(String).join(' '))
      })

      let credential: Answer
      let claim: Answer
      try {
        // Firebase refuses the credential.
        idp = () => {
          throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
        }
        credential = await post('/auth/idp', appleBody())

        // The claim refuses the account: a provider whose address is not the
        // account's, on one nobody has proved.
        const victimEmail = newEmail()
        const uid = await trackedUnactivatedAccount(victimEmail)
        await attachProvider(uid, PROVIDER_IDS.apple, newEmail())
        idp = () => ({ localId: uid, email: victimEmail })
        claim = await post('/auth/idp', appleBody())
      } finally {
        spy.mockRestore()
      }

      // Identical to the caller, byte for byte.
      expect(credential.status).toBe(401)
      expect(claim.status).toBe(401)
      expect(credential.text).toBe(claim.text)

      // Distinguishable to an operator, and carrying nothing else.
      const line = logged.join(' ')
      expect(line).toContain('"stage":"credential"')
      expect(line).toContain('"stage":"claim"')
      expect(line).not.toContain('INVALID_IDP_RESPONSE')
      expect(line).not.toContain(RAW_NONCE)
      expect(line).not.toContain(IDENTITY_TOKEN)
    },
    SLOW,
  )

  test(
    'the same refusal says nothing about whether the address is registered',
    async () => {
      // GUARDRAILS 12b. The 401 above must be indistinguishable from the 401 for a
      // credential the provider itself rejected, or it becomes an oracle for "this
      // address has an unactivated account", which is exactly what #6 emails about.
      const uid = await trackedUnactivatedAccount(newEmail())
      await attachProvider(uid, PROVIDER_IDS.apple, newEmail())
      idp = () => ({ localId: uid, email: newEmail() })
      const refused = await post('/auth/idp', appleBody())

      idp = () => {
        throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
      }
      const rejected = await post('/auth/idp', appleBody())

      expect(refused.status).toBe(rejected.status)
      expect(refused.text).toBe(rejected.text)
    },
    SLOW,
  )

  test(
    'a claim runs on an account Firebase has a password for but Firestore has no document for',
    async () => {
      // The divergence the `!user.activated` condition exists to survive, and which
      // no other test builds: `POST /auth/signup` writes the Auth user before the
      // `users/{uid}` document, so a failure between the two leaves a password
      // account with no document at all. `ensureUser` then creates a *fresh* document
      // whose `authProviders` is `["apple.com"]` — no "password" anywhere in it.
      //
      // A condition that consulted Eva's mirror (`user.authProviders.includes(
      // "password")`) would read that as a brand-new provider account and skip the
      // claim, leaving whoever set the password able to sign in with it. Firebase's
      // `providerData` is the authoritative record, and it says password.
      const email = newEmail()
      const uid = await createAuthUser(email)
      await adminAuth.updateUser(uid, { password: PASSWORD })
      await firestore
        .collection('users')
        .doc(uid)
        .delete()
        .catch(() => {})
      expect((await firestore.collection('users').doc(uid).get()).exists).toBe(false)
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)

      idp = resolveTo(uid, email)
      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(200)
      // The mirror on the fresh document never mentions the password, which is the
      // whole point — and the claim still ran.
      expect(res.body.user.authProviders).toEqual([PROVIDER_IDS.apple])
      expect(await passwordStillWorks(email, PASSWORD)).toBe(false)
    },
    SLOW,
  )

  test(
    'a provider sign-in cannot walk an account back out of its own deletion',
    async () => {
      // `account-deletion.test.ts` proves this for `POST /auth/signin`. The provider
      // route is a second door into the same account and needs its own lock: the
      // credential is real, and that is precisely why it must not mint.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      // A provider on the account first, so the refusal is observable in more than
      // the status: without the tombstone check the claim runs on an account that is
      // mid-delete and destroys its password on the way to the same 401.
      await attachProvider(uid, PROVIDER_IDS.apple, email)
      await markUserDeleted(uid)

      idp = resolveTo(uid, email)
      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(401)
      expect(res.body.error.code).toBe('INVALID_CREDENTIALS')
      expect(res.body.token).toBeUndefined()
      // Still a tombstone: not revived, not re-activated.
      expect((await firestore.collection('users').doc(uid).get()).get('deletedAt')).not.toBeNull()
      // And nothing was written on the way to the refusal. A delete that is retried
      // must find the account as it left it.
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)
    },
    SLOW,
  )

  test(
    'an already-activated account keeps its password and its other providers',
    async () => {
      // The other half, and the reason the check is on `activatedAt` rather than on
      // "has a password": someone who confirmed their address has proven the password
      // is theirs. Invalidating it here would log a real user out of their own
      // account for adding Apple to it.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      await markActivated(uid)
      idp = resolveTo(uid, email)

      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)
      expect((await post('/auth/idp', appleBody())).status).toBe(200)
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)
    },
    SLOW,
  )

  test(
    'the session comes back activated, so a provider user never meets the #6 gate',
    async () => {
      const email = newEmail()
      const uid = await createAuthUser(email)
      idp = resolveTo(uid, email)

      const res = await post('/auth/idp', appleBody())

      expect(res.status).toBe(200)
      expect(res.body.user.activated).toBe(true)
      // Stamped, not merely reported: `activatedAt` is a timestamp, not the `null` a
      // new document starts with.
      expect(await activatedAt(uid)).not.toBeNull()
    },
    SLOW,
  )

  test(
    'the raw nonce reaches the boundary',
    async () => {
      const email = newEmail()
      const uid = await createAuthUser(email)
      idp = resolveTo(uid, email)

      await post('/auth/idp', appleBody())

      expect(lastIdp?.credential).toEqual({
        provider: 'apple',
        idToken: IDENTITY_TOKEN,
        rawNonce: RAW_NONCE,
      })
      // A sign-in, not a link: nothing was passed to link against.
      expect(lastIdp?.linkTo).toBeUndefined()
    },
    SLOW,
  )

  test('a credential the provider refuses is one answer, carrying none of its reason', async () => {
    idp = () => {
      throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
    }

    const res = await post('/auth/idp', appleBody())

    expect(res.status).toBe(401)
    expect(res.body.error.code).toBe('INVALID_CREDENTIALS')
    const whole = `${res.text} ${res.headers}`.toLowerCase()
    for (const leak of ['INVALID_IDP_RESPONSE', 'Identity Toolkit', RAW_NONCE, IDENTITY_TOKEN]) {
      expect(whole).not.toContain(leak.toLowerCase())
    }
  })

  test('an upstream outage is 503 with the constant Retry-After, not a 500', async () => {
    idp = () => {
      throw new IdentityToolkitError('INTERNAL_ERROR', 500)
    }

    const res = await post('/auth/idp', appleBody())

    expect(res.status).toBe(503)
    expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE')
    expect(res.headers).toContain('retry-after')
  })

  test('the body is validated at the edge', async () => {
    for (const body of [
      {},
      { provider: 'facebook', identityToken: 't', rawNonce: 'n' },
      { provider: 'apple', identityToken: IDENTITY_TOKEN },
      { provider: 'apple', rawNonce: RAW_NONCE },
      { provider: 'apple', identityToken: '', rawNonce: RAW_NONCE },
      { provider: 'google', code: 'c', codeVerifier: 'v' },
      { provider: 'google', code: 'c', codeVerifier: 'v', redirectUri: 'not a uri' },
    ]) {
      const res = await post('/auth/idp', body)
      expect(res.status).toBe(400)
      expect(res.body.error.code).toBe('VALIDATION')
    }
    // Nothing reached the boundary: validation is the edge, not the module.
    expect(lastIdp).toBeNull()
  })

  /**
   * Both halves, chosen by config rather than skipped on it.
   *
   * This was `test.skipIf(config.providers.googleIosClientId !== null)`, which meant the
   * last remaining Google assertion in the file disappeared silently the moment anyone
   * followed `docs/PROVIDER-SIGNIN.md` §4 and set `GOOGLE_IOS_CLIENT_ID` in `api/.env`.
   * A test that deletes itself when the feature is turned on is worse than no test: it
   * reads as coverage.
   *
   * `fetch` is stubbed either way, so neither branch can reach Google's token endpoint
   * from `bun test` — the unprovisioned branch asserts it never tries.
   */
  test("Google's exchange answers for its configured state, and never leaves the process", async () => {
    const calls: string[] = []
    const realFetch = globalThis.fetch
    globalThis.fetch = (async (input: any, init?: any) => {
      calls.push(String(input?.url ?? input))
      return new Response(JSON.stringify({ error: 'invalid_grant' }), {
        status: 400,
        headers: { 'content-type': 'application/json' },
      })
    }) as typeof fetch

    let res: Answer
    try {
      res = await post('/auth/idp', {
        provider: 'google',
        code: 'auth-code',
        codeVerifier: 'code-verifier',
        redirectUri: 'com.googleusercontent.apps.1234:/oauth2redirect',
      })
    } finally {
      globalThis.fetch = realFetch
    }

    if (config.providers.googleIosClientId === null) {
      // Unprovisioned: a page for an operator, not a verdict about the credential —
      // and nothing was sent anywhere.
      expect(res.status).toBe(503)
      expect(res.body.error.code).toBe('SERVICE_UNAVAILABLE')
      expect(calls).toEqual([])
    } else {
      // Provisioned: Google refused the code, which is about the caller.
      expect(res.status).toBe(401)
      expect(res.body.error.code).toBe('INVALID_CREDENTIALS')
      expect(calls.some((url) => url.includes('oauth2.googleapis.com'))).toBe(true)
    }
    // Either way the boundary is never reached: there is no ID token to hand it.
    expect(lastIdp).toBeNull()
  })
})

describe('the declared maximums are the maximums', () => {
  /**
   * Three ceilings were declared by #7 — 4096 for a provider token, 512 for a redirect
   * URI, 2048 for an Apple authorization code — and none had a test at its edge. Deleting
   * `value.length <= max` from `isBounded` left every one of the 252 tests green, and that
   * function guards every route in the file, not only these.
   *
   * They exist because the fields are opaque credentials Eva forwards: nothing about their
   * *content* can be checked here, so the length is the only thing standing between a
   * caller and a body we carry to Apple or Google for free.
   */
  const times = (n: number) => 'x'.repeat(n)

  test(
    'a provider token at the ceiling is accepted and one past it is not',
    async () => {
      const email = newEmail()
      const uid = await createAuthUser(email)
      idp = resolveTo(uid, email)

      // 4096 exactly: refusing this would refuse a legitimate credential.
      const atLimit = await post('/auth/idp', {
        provider: 'apple',
        identityToken: times(4096),
        rawNonce: RAW_NONCE,
      })
      expect(atLimit.status).toBe(200)

      const overLimit = await post('/auth/idp', {
        provider: 'apple',
        identityToken: times(4097),
        rawNonce: RAW_NONCE,
      })
      expect(overLimit.status).toBe(400)
      expect(overLimit.body.error.code).toBe('VALIDATION')
    },
    SLOW,
  )

  test(
    'a redirect URI at the ceiling is accepted and one past it is not',
    async () => {
      // Pinned from below as well: silently lowering the ceiling would 400 a legitimate
      // reversed-client-id redirect with nothing objecting.
      const scheme = 'com.googleusercontent.apps.1234:/'
      const atLimit = await post('/auth/idp', {
        provider: 'google',
        code: 'a-code',
        codeVerifier: 'a-verifier',
        redirectUri: scheme + times(512 - scheme.length),
      })
      // Not a validation failure: it gets as far as the exchange, which is unconfigured
      // here and answers 503. What matters is that the edge did not refuse it.
      expect(atLimit.body.error?.code).not.toBe('VALIDATION')

      const res = await post('/auth/idp', {
        provider: 'google',
        code: 'a-code',
        codeVerifier: 'a-verifier',
        redirectUri: `com.googleusercontent.apps.1234:/${times(512)}`,
      })

      expect(res.status).toBe(400)
      expect(res.body.error.code).toBe('VALIDATION')
      // Refused at the edge: nothing reached the boundary or a provider.
      expect(lastIdp).toBeNull()
    },
    SLOW,
  )

  test(
    'an over-long Apple authorization code fails the delete rather than being dropped',
    async () => {
      // It used to be *silently* discarded: the account was deleted with no revocation,
      // no error and no log line, which is the one outcome Apple's entitlement forbids
      // and the caller could not detect.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      const token = await mintToken(uid, email, 0)

      // At the ceiling first: a real Apple code must not be refused by a limit someone
      // tightened without noticing.
      const atLimit = await send(
        'DELETE',
        '/me',
        { appleAuthorizationCode: times(2048) },
        bearer(token),
      )
      expect(atLimit.body.error?.code).not.toBe('VALIDATION')

      const secondEmail = newEmail()
      const secondUid = await trackedUnactivatedAccount(secondEmail)
      const secondToken = await mintToken(secondUid, secondEmail, 0)
      const res = await send(
        'DELETE',
        '/me',
        { appleAuthorizationCode: times(2049) },
        bearer(secondToken),
      )

      expect(res.status).toBe(400)
      expect(res.body.error.code).toBe('VALIDATION')
      // And the account is still there, because the request was refused rather than
      // half-performed.
      expect(await getUser(secondUid)).not.toBeNull()
    },
    SLOW,
  )
})

describe('activation retracts before it stamps', () => {
  /**
   * The ordering, pinned by its failure case — because the race it also closes is not
   * deterministic and this is.
   *
   * `/auth/activate` used to stamp `activatedAt` and *then* retract. That left a window,
   * three Admin SDK round trips wide, in which the document said activated while an
   * attacker's provider was still linked; `/auth/idp` reads exactly that flag to decide
   * whether to run its claim, so a request landing inside it skipped the claim and was
   * minted a 30-day Eva JWT that nothing can revoke.
   *
   * And it left something worse than a window: the transition is spent once. If the
   * retraction failed for any transient reason *after* the stamp had committed, no later
   * activation or reset would ever run it again — the account stayed activated with the
   * attacker's identity attached, permanently.
   *
   * So: if the retraction cannot complete, the account must not be activated. A user
   * clicking their link again is the acceptable outcome; a half-done activation is not.
   */
  // **Both doors, and that is the point of the loop.** The two routes were restructured
  // together for the same reason, and only the activation one had a test — while
  // `/auth/password/reset` is the *more* reachable of the two, because it is the recovery
  // `claimUnprovenAccount`'s own comment sends the victim to.
  for (const door of ['activate', 'reset'] as const) {
    test(
      `a retraction that fails leaves the account unactivated — /auth/${door === 'activate' ? 'activate' : 'password/reset'}`,
      async () => {
        const email = newEmail()
        const uid = await trackedUnactivatedAccount(email)
        await attachProvider(uid, PROVIDER_IDS.google, newEmail())

        // Failing **only the retraction's** write. Blanket-failing `updateUser` looks
        // equivalent and is not: on the reset door `setPassword` calls it first, so the
        // route would throw before it ever reached the retraction and this test would
        // pass without exercising the thing it is named for. Targeting
        // `providersToUnlink` is what makes the two doors actually comparable.
        const realUpdateUser = adminAuth.updateUser.bind(adminAuth)
        const spy = spyOn(adminAuth, 'updateUser').mockImplementation(
          async (target: string, props: Record<string, unknown>) => {
            if (props?.providersToUnlink) throw new Error('transient')
            return realUpdateUser(target, props)
          },
        )

        let res: Answer
        try {
          res =
            door === 'activate'
              ? await post('/auth/activate', {
                  token: await issueToken(uid, email, 'activation'),
                  password: 'a-password-they-chose-9',
                })
              : await post('/auth/password/reset', {
                  token: await issueToken(uid, email, 'reset'),
                  password: 'a-password-they-chose-9',
                })
        } finally {
          spy.mockRestore()
        }

        expect(res.status).toBe(500)
        // The account is untouched: not activated, and the claim gate in `/auth/idp` is
        // still armed for it. Stamping first would leave this a timestamp, and the
        // transition is spent once — no later link would ever retract again.
        expect(await activatedAt(uid)).toBeNull()
        // And the attacker's identity is still there to be retracted on the retry,
        // rather than stranded on an account nothing will ever clean again.
        expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId).sort()).toEqual(
          [PROVIDER_IDS.google, 'password'].sort(),
        )
      },
      SLOW,
    )
  }

  test(
    'a delete landing mid-activation is a dead link, not a 500',
    async () => {
      // `retractUnprovenIdentities` reads the Auth account before it writes. A `DELETE /me`
      // landing between the route's `readUser` and that read leaves nothing to retract —
      // and an uncaught `auth/user-not-found` would surface as `500 INTERNAL` with an
      // unhandled-error `ref`, where every other "the account went away" path in this
      // route answers a dead link. The guard is a `.catch` that returns; without it this
      // is a 500.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      const token = await issueToken(uid, email, 'activation')

      const realGetUser = adminAuth.getUser.bind(adminAuth)
      let first = true
      const spy = spyOn(adminAuth, 'getUser').mockImplementation(async (target: string) => {
        // Only the retraction's own read fails, so this cannot pass by breaking
        // something earlier in the route.
        if (first && target === uid) {
          first = false
          const err = new Error('no user record') as Error & { code: string }
          err.code = 'auth/user-not-found'
          throw err
        }
        return realGetUser(target)
      })

      let res: Answer
      try {
        res = await post('/auth/activate', { token })
      } finally {
        spy.mockRestore()
      }

      expect(res.status).not.toBe(500)
      expect(res.body.error?.code).not.toBe('INTERNAL')
    },
    SLOW,
  )

  test(
    'an activation link used on an already-activated account changes nothing',
    async () => {
      // The guard that keeps activation from being a second, unauthenticated unlink
      // button — and, since #120, from being a password-reset primitive. The link stays
      // valid for 24h, so this is an ordinary sequence: activate by reset, connect Apple
      // from Profile, then click the original mail still sitting in the inbox.
      //
      // It answers a dead link now rather than an inert 200. That changed with #120 and
      // had to: the link carries a password, so honouring a stale one against an activated
      // account would let anyone who ever saw an activation email set its password.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      await markActivated(uid)
      await attachProvider(uid, PROVIDER_IDS.apple, email)

      const res = await post('/auth/activate', {
        token: await issueToken(uid, email, 'activation'),
        password: 'a-password-they-chose-9',
      })

      expect(res.status).toBe(400)
      expect(res.body.error.code).toBe('INVALID_TOKEN')
      // Nothing retracted, and — the part that matters most — the password not replaced.
      expect((await adminAuth.getUser(uid)).providerData.map((p) => p.providerId).sort()).toEqual(
        [PROVIDER_IDS.apple, 'password'].sort(),
      )
      expect(await passwordStillWorks(email, PASSWORD)).toBe(true)
    },
    SLOW,
  )
})

describe('the fake boundary models what Identity Toolkit actually does', () => {
  /**
   * `resolveTo` verifies the address as part of linking, because Identity Toolkit does:
   * a provider sign-in that creates an account takes `emailVerified` from the provider,
   * and a merge sets it. Without that, every route-driven account in this file was
   * unverified — which made `addressUnproven` true everywhere and the whole address guard
   * unreachable in the one direction that matters.
   *
   * The default is pinned here because nothing else pins it: flipping `verifies` to false
   * left all 252 tests green, so the fix made in answer to that finding could have been
   * silently undone.
   */
  test(
    'resolving to an account verifies its address, as a real sign-in would',
    async () => {
      const email = newEmail()
      const uid = await createAuthUser(email)
      expect((await adminAuth.getUser(uid)).emailVerified).toBe(false)

      idp = resolveTo(uid, email)
      expect((await post('/auth/idp', appleBody())).status).toBe(200)

      expect((await adminAuth.getUser(uid)).emailVerified).toBe(true)
    },
    SLOW,
  )
})

describe('the provider routes are throttled, and separately', () => {
  /**
   * The 429 branch had no coverage at all: deleting the throttle from either route left
   * the whole suite green, and so did collapsing the two counters into one — which
   * `ProviderRoute`'s own docstring says must not happen.
   *
   * Nothing sent `x-forwarded-for`, so `consumeProviderAttempt` short-circuited on a null
   * IP in every test in the repo and the limiter was never once asked a real question.
   * That is what these send.
   */
  const IP = '203.0.113.7'
  const from = (ip: string) => ({ 'x-forwarded-for': ip })

  /** One more than the budget, so the last one must be refused. */
  const overBudget = config.rateLimit.idpPerIp + 1

  /**
   * Which `X-Forwarded-For` entry is the caller (#37).
   *
   * The per-IP limit is only a per-IP limit while the right entry is read. Cloud Run
   * appends the address it accepted the connection from; everything to its left is
   * whatever the caller chose to send, so reading from the left would let anyone spend a
   * fresh budget per request by inventing a prefix. `trustedProxyHops` says how far from
   * the right to count — `1` for the direct Cloud Run service `deploy-api.yml` deploys,
   * `2` once a load balancer appends one of its own.
   *
   * Driven through the route rather than by calling `clientIp`, which is not exported:
   * two requests that differ only in the *spoofed* prefix have to land in the same
   * bucket, and that is a property of the throttle, not of a string function.
   */
  test(
    'a spoofed prefix buys nothing — the caller is counted from the right',
    async () => {
      expect(config.rateLimit.trustedProxyHops).toBe(1)
      idp = () => {
        throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
      }
      const real = '198.51.100.77'

      let last: Answer | null = null
      for (let i = 0; i < overBudget; i++) {
        // A different invented client each time, all appended to the left of the
        // one entry Cloud Run actually wrote. Reading the leftmost would give every
        // one of these its own budget and none would ever be refused.
        last = await post('/auth/idp', appleBody(), {
          'x-forwarded-for': `10.0.0.${i % 200}, ${real}`,
        })
      }

      expect(last!.status).toBe(429)
      expect(last!.body.error.code).toBe('RATE_LIMITED')
    },
    SLOW,
  )

  test(
    'the route reads the configured hop count, and a shorter header skips the dimension',
    async () => {
      // The day a load balancer appears in front, `RATE_LIMIT_TRUSTED_PROXY_HOPS=2`
      // is the whole fix — so what has to be pinned is that the route reads the
      // knob at all. At the deployed value of `1` it cannot be: a hardcoded `1`
      // behaves identically, and no header is ever shorter than one entry. Both
      // become reachable at `2`, which is what this borrows the config for.
      // Restored by the file's `afterEach`, which survives a timeout where a
      // `finally` would not.
      expect(config.rateLimit.trustedProxyHops).toBe(1)
      idp = () => {
        throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
      }

      config.rateLimit.trustedProxyHops = 2
      const caller = '198.51.100.88'

      // Three entries: an invented prefix, the caller, and the entry a balancer
      // would append. Only the middle one is the same every time. Against a
      // hardcoded `1` each request keys on its own rightmost entry and none of them
      // is ever refused.
      let last: Answer | null = null
      for (let i = 0; i < overBudget; i++) {
        last = await post('/auth/idp', appleBody(), {
          'x-forwarded-for': `10.0.0.${i % 200}, ${caller}, 130.211.0.${i % 200}`,
        })
      }
      expect(last!.status).toBe(429)
      expect(last!.body.error.code).toBe('RATE_LIMITED')

      // And the fail-safe: a header with fewer entries than configured skips the
      // per-IP dimension rather than bucketing everyone together or picking an entry
      // the caller controls. `401` rather than "not 429" — the request is answered
      // normally, which is the claim.
      resetAuthRateLimits()
      let short: Answer | null = null
      for (let i = 0; i < overBudget; i++) {
        short = await post('/auth/idp', appleBody(), from('203.0.113.30'))
      }
      expect(short!.status).toBe(401)
    },
    SLOW,
  )

  test(
    'an address that keeps trying is refused, and told how long to wait',
    async () => {
      // The credential is nonsense on purpose: the throttle is counted after
      // validation and *before* either upstream call, so a refused request costs
      // nothing and can depend on nothing.
      idp = () => {
        throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
      }

      let last: Answer | null = null
      for (let i = 0; i < overBudget; i++) {
        last = await post('/auth/idp', appleBody(), from(IP))
      }

      expect(last!.status).toBe(429)
      expect(last!.body.error.code).toBe('RATE_LIMITED')
      expect(
        Number(
          JSON.parse(last!.headers).find(([name]: [string, string]) => name === 'retry-after')?.[1],
        ),
      ).toBeGreaterThan(0)
      // Nothing about the address, and nothing of the provider's own reason.
      expect(last!.text).not.toContain('INVALID_IDP_RESPONSE')
    },
    SLOW,
  )

  test(
    'a different address is unaffected by it',
    async () => {
      // Carrier NAT is why the per-IP budget is loose rather than sharp; it is also
      // why exhausting one address must not touch another.
      idp = () => {
        throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
      }
      for (let i = 0; i < overBudget; i++) {
        await post('/auth/idp', appleBody(), from('203.0.113.8'))
      }

      expect((await post('/auth/idp', appleBody(), from('203.0.113.9'))).status).toBe(401)
    },
    SLOW,
  )

  test(
    'exhausting sign-in does not spend linking, or the reverse',
    async () => {
      // Separate maps, deliberately. One budget shared between the two would let an
      // unauthenticated caller lock every signed-in user out of connecting a provider.
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      await markActivated(uid)
      const token = await mintToken(uid, email, 0)

      idp = () => {
        throw new IdentityToolkitError('INVALID_IDP_RESPONSE', 400)
      }
      for (let i = 0; i < overBudget; i++) {
        await post('/auth/idp', appleBody(), from(IP))
      }
      expect((await post('/auth/idp', appleBody(), from(IP))).status).toBe(429)

      // The link route, from the same address, still has its own budget.
      idp = resolveTo(uid, email)
      expect(
        (
          await post('/me/auth/providers', appleBody(), {
            ...bearer(token),
            ...from(IP),
          })
        ).status,
      ).toBe(200)
    },
    SLOW,
  )
})

describe('POST /me/auth/providers — linking is deliberate, and never a merge', () => {
  /** An activated password account and a session for it. */
  const signedIn = async (): Promise<{ uid: string; email: string; token: string }> => {
    const email = newEmail()
    const uid = await trackedUnactivatedAccount(email)
    await markActivated(uid)
    return { uid, email, token: await mintToken(uid, email, 0) }
  }

  test(
    'a provider attaches to the account the bearer token names',
    async () => {
      const { uid, email, token } = await signedIn()
      idp = resolveTo(uid, email)

      const res = await post('/me/auth/providers', appleBody(), bearer(token))

      expect(res.status).toBe(200)
      expect(res.body.user.id).toBe(uid)
      expect(res.body.user.authProviders).toEqual(['password', PROVIDER_IDS.apple])
      // Persisted, not just reported.
      expect((await getUser(uid))!.authProviders).toEqual(['password', PROVIDER_IDS.apple])
      // Linked against *this* account's Firebase ID token, which is what makes it a
      // link rather than a sign-in.
      expect(lastIdp?.linkTo).toBe(`firebase-id-token-for-${uid}`)
      expect(lastIdp?.credential.rawNonce).toBe(RAW_NONCE)
      // No second account was created for the address.
      expect(await accountsForEmail(email)).toEqual([uid])
    },
    SLOW,
  )

  test(
    'a sub already owned by another account is refused, and nothing is merged',
    async () => {
      const { uid, token } = await signedIn()
      idp = () => {
        throw new IdentityToolkitError('FEDERATED_USER_ID_ALREADY_LINKED', 400)
      }

      const res = await post('/me/auth/providers', appleBody(), bearer(token))

      expect(res.status).toBe(409)
      expect(res.body.error.code).toBe('PROVIDER_ALREADY_LINKED')
      // The account is exactly as it was: no provider added, no silent merge.
      expect((await getUser(uid))!.authProviders).toEqual(['password'])
    },
    SLOW,
  )

  test(
    'a link that landed on a different account is a bug, not a mirror update',
    async () => {
      // `signInWithIdp` in link mode attaches to the account the ID token names, so a
      // different uid coming back means Firebase merged instead of linking — the
      // thing this route exists to avoid. Deleting the guard was green: the mock
      // returns the caller's uid by construction and no test ever made it lie.
      //
      // Ships as `authProviders` claiming a provider the account does not hold, which
      // is what Profile reads to decide the Connect button and what the delete flow
      // reads to decide whether to revoke with Apple.
      const { token } = await signedIn()
      idp = () => ({ localId: 'a-different-uid', email: newEmail() })

      const res = await post('/me/auth/providers', appleBody(), bearer(token))

      expect(res.status).toBe(500)
      // Nothing of the other account reaches the caller.
      expect(res.text).not.toContain('a-different-uid')
    },
    SLOW,
  )

  test('it needs a session', async () => {
    const res = await post('/me/auth/providers', appleBody())
    expect(res.status).toBe(401)
    expect(res.body.error.code).toBe('UNAUTHORIZED')
    expect(lastIdp).toBeNull()
  })
})

describe('DELETE /me — Apple revocation never fails the delete', () => {
  test(
    'an unrevokable code still deletes the account, and logs no credential',
    async () => {
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      const token = await mintToken(uid, email, 0)
      const APPLE_CODE = 'apple-authorization-code-z9y8x7'
      const logged: string[] = []
      const spy = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
        logged.push(args.map(String).join(' '))
      })

      // Stubbed so this cannot become a live request to `appleid.apple.com` from
      // `bun test`. It is not hypothetical: with `APPLE_*` set in `api/.env` — which
      // `docs/PROVIDER-SIGNIN.md` §6 asks for — the unconfigured early return is gone
      // and the next line is an outbound call carrying a real signed client secret.
      const calls: string[] = []
      const realFetch = globalThis.fetch
      globalThis.fetch = (async (input: any) => {
        calls.push(String(input?.url ?? input))
        return new Response(JSON.stringify({ error: 'invalid_grant' }), {
          status: 400,
          headers: { 'content-type': 'application/json' },
        })
      }) as typeof fetch

      let res: Answer
      try {
        res = await send('DELETE', '/me', { appleAuthorizationCode: APPLE_CODE }, bearer(token))
      } finally {
        globalThis.fetch = realFetch
        spy.mockRestore()
      }

      // The revocation cannot succeed here, by either route: unprovisioned, or
      // provisioned and refused by the stub. Which one is config's business — what is
      // under test is that the delete goes through regardless, because Apple's
      // entitlement is not worth stranding a user who asked to be gone.
      expect(res.status).toBe(200)
      expect(res.body).toEqual({ deleted: true })
      expect(await getUser(uid)).toBeNull()
      expect((await firestore.collection('users').doc(uid).get()).exists).toBe(false)
      await expect(adminAuth.getUser(uid)).rejects.toThrow()

      // One line, and nothing in it that a credential could be recovered from. The
      // stage is asserted against config rather than pinned to "unconfigured", which
      // was a value this test could only ever see before the feature was turned on.
      const line = logged.join(' ')
      expect(line).toContain('apple_revocation_failed')
      expect(line).toContain(config.providers.apple.clientId === null ? 'unconfigured' : 'token')
      expect(line).not.toContain(APPLE_CODE)
      expect(line).not.toContain(email)
      expect(line).not.toContain(uid)
    },
    SLOW,
  )

  test(
    'a delete with no authorization code is exactly what it was',
    async () => {
      const email = newEmail()
      const uid = await trackedUnactivatedAccount(email)
      const token = await mintToken(uid, email, 0)

      // Two observations, because one of them does not work where this runs. The
      // `fetch` stub catches an outbound call — but only in an environment where
      // Apple is provisioned, and neither `ci-api.sh` nor `api/.env` sets `APPLE_*`,
      // so `revokeAppleToken` returns `unconfigured` before any request and the stub
      // stays empty. The log line is the config-independent half: an unconditional
      // revocation writes `apple_revocation_failed` on **every** deletion whether or
      // not Apple is configured, which is the "bury the real ones" outcome.
      const calls: string[] = []
      const realFetch = globalThis.fetch
      globalThis.fetch = (async (input: any) => {
        calls.push(String(input?.url ?? input))
        return new Response('{}', {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }) as typeof fetch
      const logged: string[] = []
      const spy = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
        logged.push(args.map(String).join(' '))
      })

      let res: Answer
      try {
        res = await send('DELETE', '/me', {}, bearer(token))
      } finally {
        globalThis.fetch = realFetch
        spy.mockRestore()
      }

      expect(res.status).toBe(200)
      expect(res.body).toEqual({ deleted: true })
      expect(await getUser(uid)).toBeNull()
      expect(calls.filter((url) => url.includes('appleid.apple.com'))).toEqual([])
      // Nothing was attempted, so nothing failed. This is the assertion that bites
      // on both verify paths.
      expect(logged.join(' ')).not.toContain('apple_revocation_failed')
    },
    SLOW,
  )
})

describe('identity-toolkit puts the nonce on the wire', () => {
  /**
   * The one part of the Apple flow that is ours rather than Firebase's: the raw nonce has
   * to arrive at `accounts:signInWithIdp` inside `postBody`, because Firebase hashing it
   * and comparing with the token's is the whole of what stops a captured `identityToken`
   * being replayed here by somebody else. The test above proves the route passes it along;
   * this proves the module sends it.
   *
   * The real client, against a stubbed `fetch`. The request URL is deliberately never
   * asserted on or printed — it carries the Firebase web API key (GUARDRAILS 1).
   */
  test('the Apple credential is sent as id_token + providerId + nonce', async () => {
    let sentBody: unknown = null
    const spy = spyOn(globalThis, 'fetch').mockImplementation((async (
      _url: unknown,
      init: { body?: string },
    ) => {
      sentBody = JSON.parse(init.body!)
      return new Response(
        // `idToken` is present because a real sign-in response always carries one —
        // every request sets `returnSecureToken: true`. Its absence is what
        // `requireSignedIn` treats as "a 200 that is not a sign-in".
        JSON.stringify({
          localId: 'wire-test-uid',
          email: 'e2e+wire@e2e.evaapp.dev',
          idToken: 'a-firebase-id-token',
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      )
    }) as never)

    try {
      const result = await realSignInWithIdp({
        provider: 'apple',
        idToken: IDENTITY_TOKEN,
        rawNonce: RAW_NONCE,
      })
      expect(result.localId).toBe('wire-test-uid')
    } finally {
      spy.mockRestore()
    }

    const postBody = new URLSearchParams((sentBody as { postBody: string }).postBody)
    expect(postBody.get('id_token')).toBe(IDENTITY_TOKEN)
    expect(postBody.get('providerId')).toBe(PROVIDER_IDS.apple)
    expect(postBody.get('nonce')).toBe(RAW_NONCE)
    // Not a link: no account ID token was attached.
    expect((sentBody as { idToken?: string }).idToken).toBeUndefined()
  })

  test("a Google credential carries no nonce, because Google's flow has none", async () => {
    let sentBody: unknown = null
    const spy = spyOn(globalThis, 'fetch').mockImplementation((async (
      _url: unknown,
      init: { body?: string },
    ) => {
      sentBody = JSON.parse(init.body!)
      return new Response(
        // `idToken` is present because a real sign-in response always carries one —
        // every request sets `returnSecureToken: true`. Its absence is what
        // `requireSignedIn` treats as "a 200 that is not a sign-in".
        JSON.stringify({
          localId: 'wire-test-uid',
          email: 'e2e+wire@e2e.evaapp.dev',
          idToken: 'a-firebase-id-token',
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      )
    }) as never)

    try {
      await realSignInWithIdp({ provider: 'google', idToken: 'google-id-token' })
    } finally {
      spy.mockRestore()
    }

    const postBody = new URLSearchParams((sentBody as { postBody: string }).postBody)
    expect(postBody.get('providerId')).toBe(PROVIDER_IDS.google)
    expect(postBody.has('nonce')).toBe(false)
  })
})

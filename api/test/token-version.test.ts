import { afterAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { sign } from 'hono/jwt'
import { config } from '../src/config'
import { issueToken } from '../src/email-tokens'
import { adminAuth, firestore } from '../src/firebase'
import { createUnactivatedAccount, signIn, signUpActivated } from './support/session'

/**
 * **A password reset invalidates every session** (#76) — the decision, and the only
 * property this file is about.
 *
 * The Eva JWT is stateless, lives 30 days and has no refresh (ARCHITECTURE §3), so before
 * this issue a woman could reset her password and the session held by whoever prompted her
 * to reset it kept working for a month. `users/{uid}.tokenVersion` is the generation her
 * tokens have to match; a reset bumps it and the account gate compares it.
 *
 * **What these cases are written to kill.** The field existing proves nothing, and neither
 * does a route answering 200. Each of the first block's cases fails if the bump is removed
 * from `/auth/password/reset`, *and* fails if the comparison is removed from
 * `requireAccount` — which is what makes them a test of the claim rather than of the
 * schema. The mutation table in the PR records both runs.
 *
 * Against the real Firebase project through the live server, the pattern every other
 * integration suite here uses: accounts are `e2e+<uuid>@e2e.evaapp.dev` and `afterAll`
 * sweeps them whether or not a case got that far.
 */

// Live round trips to the API, Auth and Firestore in every case — the 20s ceiling #31 sets
// for every file that makes one. A ceiling, not a measurement.
setDefaultTimeout(20_000)

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const PASSWORD = 'correct-horse-8'
const NEW_PASSWORD = 'correct-horse-9'

const createdUids: string[] = []
const createdEmails: string[] = []

const address = (): string => {
  const value = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
  createdEmails.push(value)
  return value
}

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token ? { authorization: `Bearer ${init.token}` } : {}),
    },
  })

const post = (path: string, body: unknown) =>
  api(path, { method: 'POST', body: JSON.stringify(body) })

interface ErrorBody {
  error: { code: string; message: string }
}

const userDoc = (uid: string) => firestore.collection('users').doc(uid)

const storedVersion = async (uid: string): Promise<unknown> =>
  (await userDoc(uid).get()).get('tokenVersion')

/** Sign up, activate, sign in — a real session on a real account, through the real routes.
 *  The activation takes the *create* path, which bumps nothing, so the account starts with
 *  no `tokenVersion` field at all. Several cases below depend on that. */
const account = async (): Promise<{ email: string; uid: string; token: string }> => {
  const email = address()
  const { token, uid } = await signUpActivated(BASE, email, PASSWORD)
  createdUids.push(uid)
  return { email, uid, token }
}

/**
 * A password reset carried out the way a user's browser carries one out: a real reset
 * token, spent at the real route. The link itself never reaches a test — it is mailed or
 * printed — so the token is issued here against the same Firestore the server reads, which
 * is what `test/support/session.ts` does for activation and for the same reason.
 *
 * Returns the session the route hands back: the one the resetting device keeps.
 */
const resetPassword = async (
  uid: string,
  email: string,
  password = NEW_PASSWORD,
): Promise<string> => {
  const token = await issueToken(uid, email, 'reset')
  const res = await post('/auth/password/reset', { token, password })
  expect(res.status).toBe(200)
  return ((await res.json()) as { token: string }).token
}

const tokenDocsByEmail = (value: string) =>
  firestore.collection('authTokens').where('email', '==', value).get()

afterAll(async () => {
  for (const value of createdEmails) {
    const rows = await tokenDocsByEmail(value).catch(() => null)
    if (rows) await Promise.all(rows.docs.map((d) => d.ref.delete().catch(() => {})))
  }
  for (const uid of createdUids) {
    await userDoc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
}, 180_000)

describe('a password reset ends every other session', () => {
  test('a session that was live before the reset is refused after it', async () => {
    const { uid, email, token } = await account()
    // Live first, so a failure below cannot be "the session never worked".
    expect((await api('/me', { token })).status).toBe(200)

    await resetPassword(uid, email)

    const after = await api('/me', { token })
    expect(after.status).toBe(401)
    expect(((await after.json()) as ErrorBody).error.code).toBe('UNAUTHORIZED')
  })

  test('it is refused on every authenticated route, not only GET /me', async () => {
    // The gate is one middleware, so this is not really three risks — but "signed out"
    // has to mean the whole authenticated surface, and a route wired without the gate
    // is exactly how it would stop meaning that (#8 made the same argument).
    const { uid, email, token } = await account()
    await resetPassword(uid, email)

    for (const path of ['/me', '/me/events?from=2026-01-01&to=2026-01-07', '/refdata']) {
      const res = await api(path, { token })
      expect([path, res.status]).toEqual([path, 401])
    }
  })

  test('the stale session is answered exactly as a token we never minted', async () => {
    // **No new error code** (#76, and changing one is always-human under AUTONOMY). A
    // superseded token has to answer whatever a dead one already answers, or the iOS
    // client's existing sign-out handling (#55) does not apply to it. Compared against a
    // real dead token rather than against a copied string, so the two cannot drift.
    const { uid, email, token } = await account()
    await resetPassword(uid, email)

    const stale = await api('/me', { token })
    const nonsense = await api('/me', { token: 'not-a-jwt' })

    expect(stale.status).toBe(nonsense.status)
    expect(await stale.json()).toEqual(await nonsense.json())
  })

  test('a second reset supersedes the session the first one handed out', async () => {
    // A counter, not a flag. A boolean "has ever reset" passes the first case in this
    // file and leaves every session after the first reset permanently unrevocable.
    const { uid, email } = await account()
    const first = await resetPassword(uid, email, NEW_PASSWORD)
    expect((await api('/me', { token: first })).status).toBe(200)

    const second = await resetPassword(uid, email, PASSWORD)

    expect((await api('/me', { token: first })).status).toBe(401)
    expect((await api('/me', { token: second })).status).toBe(200)
  })
})

describe('the device that performed the reset keeps its session', () => {
  test('the token the reset route answers with still works', async () => {
    // The other half of the decision, and the reason the bump has to happen before the
    // mint rather than after it. Minting at the old generation would sign her out of the
    // app she is holding at the moment she fixed her account.
    const { uid, email } = await account()
    const fresh = await resetPassword(uid, email)

    const res = await api('/me', { token: fresh })
    expect(res.status).toBe(200)
  })

  test('and signing in with the new password works too', async () => {
    const { uid, email } = await account()
    await resetPassword(uid, email)

    const token = await signIn(BASE, email, NEW_PASSWORD)
    expect((await api('/me', { token })).status).toBe(200)
  })

  test('signing in again does not disturb the session already out', async () => {
    // Minting is not bumping. If `/auth/signin` moved the generation, every second
    // device would sign the first one out and the app would be unusable on two phones.
    const { email, token } = await account()

    const second = await signIn(BASE, email, PASSWORD)

    expect((await api('/me', { token })).status).toBe(200)
    expect((await api('/me', { token: second })).status).toBe(200)
  })
})

describe('DELETE /me is inside the revocation, not outside it', () => {
  const deleteMe = (token: string) => api('/me', { method: 'DELETE', token })

  test('a superseded session cannot delete the account', async () => {
    // `DELETE /me` is the one authenticated route not behind `requireAccount`, so the
    // check is made by hand there. Without it a reset would lock the other session out
    // of every read while leaving it able to destroy everything — worse than no
    // revocation at all, because the reset is what would have provoked it.
    const { uid, email, token } = await account()
    await resetPassword(uid, email)

    const res = await deleteMe(token)
    expect(res.status).toBe(401)
    expect(((await res.json()) as ErrorBody).error.code).toBe('UNAUTHORIZED')
    // Still there: the refusal happened before the first write.
    expect((await userDoc(uid).get()).exists).toBe(true)
  })

  test('an interrupted delete can still be retried with its own token', async () => {
    // The exception the route's exemption exists for, pinned because the check above is
    // what could break it: after the tombstone there is no document to read a generation
    // out of, and the retry has to fall through exactly as it did before #76.
    const { uid, token } = await account()

    expect((await deleteMe(token)).status).toBe(200)
    expect((await deleteMe(token)).status).toBe(200)
    expect((await userDoc(uid).get()).exists).toBe(false)
  })
})

describe('what else bumps the version', () => {
  test('activation claiming an account somebody else reserved bumps it', async () => {
    // The claim path sets a password on an account this request did not create, and
    // `retractUnprovenIdentities` beside it already revokes Firebase's refresh tokens.
    // Nothing to strand today — the route refuses an activated account, and only an
    // activated account can hold a session — so this is asserted against the stored
    // field rather than against a refused request. The full rule lives on
    // `bumpTokenVersion`; this is the call site it names.
    const email = address()
    const uid = await createUnactivatedAccount(email, PASSWORD)
    createdUids.push(uid)
    expect(await storedVersion(uid)).toBeUndefined()

    const token = await issueToken(uid, email, 'activation')
    const res = await post('/auth/activate', { token, password: NEW_PASSWORD })
    expect(res.status).toBe(200)

    expect(await storedVersion(uid)).toBe(1)
  })

  test('the create path bumps nothing — there is no account to bump from', async () => {
    const { uid } = await account()
    expect(await storedVersion(uid)).toBeUndefined()
  })

  test('an ordinary authenticated write does not end the session', async () => {
    // Saving the questionnaire stamps `updatedAt` on the same document the generation
    // lives on. A bump written into any `users/` write rather than into the acts that
    // take a credential away would sign her out for filling in her profile.
    const { uid, token } = await account()

    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify({
        dateOfBirth: '1995-04-17',
        weightKg: 62,
        heightCm: 168,
        goals: ['energy'],
        conditions: ['noneOfThese'],
        medications: 'none',
        lifestyle: 'active',
        sports: [],
        timeZone: 'UTC',
      }),
    })
    expect(res.status).toBe(200)

    expect((await api('/me', { token })).status).toBe(200)
    expect(await storedVersion(uid)).toBeUndefined()
  })
})

describe('the deploy itself signs nobody out', () => {
  /**
   * A session exactly as it looked before #76: the claims `mintToken` used to sign, with
   * no `tv` at all. Signed here rather than minted, because `mintToken` cannot produce
   * this shape any more — which is the point of having it.
   *
   * Reading `JWT_SECRET` outside `auth.ts` is what GUARDRAILS 4 permits `api/test/` and
   * only `api/test/`: the rule is about `api/src/`, and a test that asked `auth.ts` for
   * this could only ask it for the shape it now mints.
   */
  const preIssueToken = (uid: string, email: string): Promise<string> => {
    const now = Math.floor(Date.now() / 1000)
    return sign({ sub: uid, email, iat: now, exp: now + config.jwtTtlSeconds }, config.jwtSecret)
  }

  test('a token minted before #76 still opens an account never bumped', async () => {
    // Both halves of the migration in one assertion: a claim that is absent and a field
    // that is absent are both read as generation 0, so they compare equal. Get this
    // wrong and shipping #76 signs out every user Eva has, at once.
    const { uid, email } = await account()
    expect(await storedVersion(uid)).toBeUndefined()

    const legacy = await preIssueToken(uid, email)

    expect((await api('/me', { token: legacy })).status).toBe(200)
  })

  test('and that same token is refused once the account has been reset', async () => {
    // The tolerance above is a starting point, not a bypass. A pre-#76 session is
    // exactly the session a reset is most likely to be aimed at — it is the oldest one.
    const { uid, email } = await account()
    const legacy = await preIssueToken(uid, email)
    expect((await api('/me', { token: legacy })).status).toBe(200)

    await resetPassword(uid, email)

    expect((await api('/me', { token: legacy })).status).toBe(401)
  })
})

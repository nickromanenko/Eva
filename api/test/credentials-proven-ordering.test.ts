import { afterAll, beforeAll, describe, expect, mock, setDefaultTimeout, test } from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'

/**
 * The ordering invariant `api/CLAUDE.md` states, pinned at the two call sites that have to
 * obey it (#127).
 *
 * > `emailVerified` is what turns off `claimUnprovenAccount`'s address test, and
 * > `activatedAt` is what turns off the claim itself. Any window in which the first is set
 * > and the second is not is the one combination that claims unconditionally.
 *
 * So `markActivated` must run **before** `markCredentialsProven`, in `/auth/activate` and
 * in `/auth/password/reset` alike. #120 restructured activation to obey it and left the
 * reset route calling them the other way round; #127 swapped them, and this file is what
 * stops either drifting back. Reversing the pair in either route fails a case here.
 *
 * **Why a call-order assertion and not a state assertion.** Both flags are set by the time
 * the route answers, so the finished account looks identical either way — the difference is
 * a window one dropped request wide, which has no observable outside the process. The order
 * the route calls them in *is* the property, so it is what gets asserted.
 *
 * **The seam** is the one `unhandled-errors.test.ts` uses, with the same caveat and the
 * same discipline: Bun's `mock.module` replaces the live bindings every already-imported
 * module sees, process-globally and permanently, so `afterAll` puts both modules back as
 * they were found. Unlike that file, every mock here **delegates to the real
 * implementation** — this is a recorder, not a fake. Firebase is the real project, the
 * account is a real `e2e+*` account, and the sweep deletes it.
 *
 * **Only the reset route is driven here, and that is a constraint rather than a choice.**
 * `/auth/activate` obeys the same invariant and #120 covers it, but it cannot be exercised
 * from a file that runs after `auth-upstream-failures.test.ts`: that suite replaces
 * `createAccountWithPassword` through `mock.module` and its `afterAll` restores `upstream`
 * without restoring the module, so the mock is still installed — and answering
 * `noUpstreamSet` — for every later file in the process. An activation case here passed
 * alone and failed in a full run for exactly that reason. Straightening that out is a
 * change to another suite's teardown and belongs to its own issue, not to #127.
 */

// Real Firebase, several round trips per case, and an account stood up and torn down:
// the same 20s ceiling the other live suites set (#31).
setDefaultTimeout(20_000)

const identityToolkit = { ...(await import('../src/identity-toolkit')) }
const users = { ...(await import('../src/users')) }
const emailTokens = { ...(await import('../src/email-tokens')) }
const email = { ...(await import('../src/email')) }

/** Every stamp call the routes make, in the order they were made. */
let calls: string[] = []
let resetMail: { to: string; token: string } | null = null

mock.module('../src/identity-toolkit', () => ({
  ...identityToolkit,
  markCredentialsProven: async (uid: string, expectedAddress: string) => {
    calls.push('markCredentialsProven')
    return identityToolkit.markCredentialsProven(uid, expectedAddress)
  },
}))

mock.module('../src/users', () => ({
  ...users,
  markActivated: async (uid: string) => {
    calls.push('markActivated')
    return users.markActivated(uid)
  },
}))

mock.module('../src/email', () => ({
  ...email,
  sendPasswordResetEmail: async (to: string, token: string) => {
    resetMail = { to, token }
  },
}))

// After the mocks, and never as a listening server: the route has to run in *this*
// process for the recorders above to be the bindings it calls.
const { default: server } = await import('../src/index')

const PASSWORD = 'correct-horse-8'
const NEW_PASSWORD = 'correct-horse-9'
const createdUids: string[] = []
const createdEmails: string[] = []

const address = () => {
  const value = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
  createdEmails.push(value)
  return value
}

const post = async (path: string, body: unknown) => {
  const res = await server.fetch(
    new Request(`http://api.test${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    }),
  )
  return { status: res.status, body: (await res.json()) as Record<string, unknown> }
}

/** An account in the shape sign-up leaves behind, written directly so this file spends no
 *  per-IP sign-up budget and sends no email (#5). */
const unactivatedAccount = async (email: string): Promise<string> => {
  const { uid } = await adminAuth.createUser({ email, password: PASSWORD })
  await firestore
    .collection('users')
    .doc(uid)
    .set({
      email,
      authProviders: ['password'],
      questionnaireCompleted: false,
      profile: null,
      activatedAt: null,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
  createdUids.push(uid)
  return uid
}

beforeAll(() => {
  calls = []
})

afterAll(async () => {
  // **Restores first, sweeps second**, and the order is the whole point. The sweep's
  // `.get()` is a live query and the only await here that can throw — every delete
  // around it is caught. A Firestore blip there would skip the restores and leave these
  // recorders installed process-globally for every later file, which is exactly the
  // failure this file's header criticises in another suite (#130). Handing the modules
  // back is not cleanup that can be deferred; it is the file's obligation to the rest of
  // the run, so it happens before anything that can fail.
  mock.module('../src/identity-toolkit', () => identityToolkit)
  mock.module('../src/users', () => users)
  mock.module('../src/email', () => email)

  for (const uid of createdUids) {
    await adminAuth.deleteUser(uid).catch(() => {})
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
  }
  // `authTokens/` is keyed by the token's hash and holds the address, so the rows this
  // file issues are swept by address the way auth.test.ts sweeps its own.
  for (const value of createdEmails) {
    const rows = await firestore
      .collection('authTokens')
      .where('email', '==', value)
      .get()
      .catch(() => null)
    for (const row of rows?.docs ?? []) await row.ref.delete().catch(() => {})
  }
})

describe('markCredentialsProven runs after markActivated', () => {
  test('the requested reset link is bound to the address it was mailed to', async () => {
    const original = address()
    const moved = address()
    const uid = await unactivatedAccount(original)
    await users.markActivated(uid)
    await identityToolkit.markCredentialsProven(uid, original)

    resetMail = null
    expect((await post('/auth/password/forgot', { email: original })).status).toBe(200)
    // The assignment happens through the mocked module while `post` runs; TypeScript cannot
    // see that side effect and otherwise keeps the variable narrowed to the null above.
    const sent = resetMail as { to: string; token: string } | null
    expect(sent?.to).toBe(original)
    if (sent === null) throw new Error('forgot-password sent no reset email')

    // The public accounts:update path is exercised in email-auth-routes.test.ts; Admin SDK
    // makes the same moved/unverified state deterministic in both Firebase environments.
    await adminAuth.updateUser(uid, { email: moved, emailVerified: false })
    const answer = await post('/auth/password/reset', {
      token: sent.token,
      password: NEW_PASSWORD,
    })

    expect(answer.status).toBe(400)
    expect((answer.body.error as { code: string }).code).toBe('INVALID_TOKEN')
    const account = await adminAuth.getUser(uid)
    expect(account.email).toBe(moved)
    expect(account.emailVerified).toBe(false)
  })

  test('on /auth/password/reset — the call site #127 corrected', async () => {
    const email = address()
    const uid = await unactivatedAccount(email)
    const token = await emailTokens.issueToken(uid, email, 'reset')

    calls = []
    const answer = await post('/auth/password/reset', { token, password: NEW_PASSWORD })

    expect(answer.status).toBe(200)
    // Reversing the two calls in the route makes this line fail and nothing else
    // change — which is the whole reason it is an array comparison and not two
    // `toHaveBeenCalled`s.
    expect(calls).toEqual(['markActivated', 'markCredentialsProven'])
  })

  test('the account ends with both set, whichever order they were called in', async () => {
    // The state assertion the ordering one cannot make: it is true either way, and
    // saying so is what stops the next reader thinking the order is about the outcome.
    const email = address()
    const uid = await unactivatedAccount(email)
    const token = await emailTokens.issueToken(uid, email, 'reset')

    await post('/auth/password/reset', { token, password: NEW_PASSWORD })

    const authUser = await adminAuth.getUser(uid)
    const doc = await firestore.collection('users').doc(uid).get()
    expect(authUser.emailVerified).toBe(true)
    expect(doc.get('activatedAt')).not.toBeNull()
  })
})

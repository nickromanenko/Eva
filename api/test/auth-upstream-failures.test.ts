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
import { config } from '../src/config'
import { issueToken } from '../src/email-tokens'
import { FieldValue } from 'firebase-admin/firestore'
import { adminAuth, firestore } from '../src/firebase'
import { resetAuthRateLimits } from '../src/rate-limit'
import { testEmail } from './support/test-email'

/**
 * Live round trips happen in this file, so the ceiling is chosen rather than inherited
 * (#31). 20s is what every other network-touching suite sets: high enough that no honest
 * round trip reaches it, low enough that a genuine hang still fails. It does not override
 * the per-test timeouts below, which stay where someone picked them deliberately.
 */
setDefaultTimeout(20_000)

/**
 * What both auth routes answer when Identity Toolkit fails for any reason other than
 * "that address is taken" (issue #32).
 *
 * Before this, `/auth/signup` handled `EMAIL_EXISTS` and rethrew the rest, so a Google-side
 * `INVALID_EMAIL`, a quota refusal, or an outage left Hono to answer — a bare 500 with no
 * `{ error: { code, message } }` at all, which the iOS client can only render as
 * "Something went wrong (500)". Every upstream problem looked exactly like a bug in our
 * own server, to the user and to whoever was on call.
 *
 * The seam is the one `signin-non-enumeration.test.ts` established: `mock.module` on
 * `../src/identity-toolkit`, and the route driven in-process through `app.fetch`. Faking
 * the boundary is the only way to reach these branches at all — the real project cannot be
 * made to return `INVALID_EMAIL` for an address our own edge validation accepted, and it
 * certainly cannot be made to have an outage on demand.
 *
 * **The `mock.module` caveat, stated because it constrains this file.** Bun's module mocks
 * are process-global and permanent: they replace the live bindings every already-imported
 * module sees, and they are not scoped to the file that installed them. `bun test` runs
 * test files sequentially, so this file dispatches through a mutable `upstream` that each
 * test sets rather than baking a fixed failure into the mock. It also uses addresses that
 * appear in no other suite, resets the shared throttle before every test and after the last,
 * and restores the module in `afterAll`. Restoring is this file's job: otherwise whichever
 * suite loads next inherits a fake whose cleared `upstream` can only throw.
 */

// A copy, not the namespace object: `mock.module` replaces the bindings inside the live
// namespace, so a reference captured here would become this file's own mock and restoring
// it in `afterAll` would change nothing.
const identityToolkit = { ...(await import('../src/identity-toolkit')) }
const { IdentityToolkitError } = identityToolkit

// Captured as a value *before* the mock below replaces the module's bindings, so the last
// describe in this file can exercise the real client against a stubbed `fetch` while the
// route tests see the mock. Reading it off the namespace later would get the mock instead.
const realSignUp = identityToolkit.signUpWithPassword
// Same reason, for the call that actually creates the account since #120. The route
// tests below replace this one wholesale, so without a value captured here nothing in
// the suite ever runs the real function.
const realCreateAccount = identityToolkit.createAccountWithPassword
// And again for the lookup, which the staged race below calls through. Reading it off the
// namespace at call time instead resolves to the mock — the function calls itself, and Bun
// reports the stack overflow as a `RangeError` 500 from whichever route was unlucky.
const realFindAuthUid = identityToolkit.findAuthUidByEmail

/** The failure the next call gets. Every test sets one; reaching the route without one
 *  set is a bug in the test, not a success path — this file never exercises one. */
let upstream: (() => never) | null = null

/** Makes the next `findAuthUidByEmail` answer `null` once, staging the create/lookup race.
 *  Reset in `beforeEach`, so a test that sets it and returns early cannot leak it. */
let hideAccountOnce = false

/** Makes every `findAuthUidByEmail` throw until cleared, staging the sign-up lookup's
 *  outage (#346). Reset in `beforeEach`. */
let failFindAuthUid: (() => never) | null = null

const noUpstreamSet = (): never => {
  throw new Error('test reached Identity Toolkit without setting `upstream`')
}

mock.module('../src/identity-toolkit', () => ({
  ...identityToolkit,
  signInWithPassword: () => (upstream ?? noUpstreamSet)(),
  signUpWithPassword: () => (upstream ?? noUpstreamSet)(),
  // Where an account is created now (#120). Sign-up creates nothing and never reaches
  // Identity Toolkit at all, so #32's guarantee — an upstream failure is a shaped answer,
  // never Hono's bare 500 — has to be pinned here instead. It is the same guarantee about
  // a different call.
  createAccountWithPassword: () => (upstream ?? noUpstreamSet)(),
  // Left real: activation looks the address up before creating, and a fake that failed
  // would send every case down the claim branch instead of the create branch.
  //
  // Except for one shot, which is the only way to reach the race at all. `/auth/activate`
  // asks this twice — once to decide whether to create, and once more after the create
  // comes back `EMAIL_EXISTS` — and the branch under test is entered exactly when the
  // first answers `null` and the second does not. That gap is real (another request
  // creating the account in between) and cannot be produced on demand, so it is staged
  // here, one call deep, with the second answer left genuine.
  findAuthUidByEmail: async (value: string): Promise<string | null> => {
    if (failFindAuthUid) return failFindAuthUid()
    if (hideAccountOnce) {
      hideAccountOnce = false
      return null
    }
    return realFindAuthUid(value)
  },
}))

// Imported after the mock, and never as a listening server.
const { default: server } = await import('../src/index')

// The failures are built the way `identity-toolkit.ts` builds them — a reason and the
// upstream status — and left to classify themselves, so these fakes cannot drift into
// asserting a classification the live call would not have made.

/** Google refuses the request itself: a 400 carrying one of its reason strings. */
const rejects = (reason: string) => () => {
  throw new IdentityToolkitError(reason, 400)
}

/** Google could not answer: its own 500. The reason string is whatever came back. */
const isDown = () => {
  throw new IdentityToolkitError('INTERNAL_ERROR', 500)
}

/** The request never landed — DNS, refused connection, timeout. No upstream status. */
const unreachable = () => {
  throw new IdentityToolkitError('NETWORK_FAILURE', null, 'unavailable')
}

/** Load-shedding: a 4xx that means "not now" rather than "not ever". */
const shedsLoad = () => {
  throw new IdentityToolkitError('TOO_MANY_ATTEMPTS_TRY_LATER', 400)
}

// Distinctive local parts, so a leak of the address into a body, a header, or a log line
// is findable by substring. Under the e2e sweep pattern (GUARDRAILS 16) out of habit only
// — the upstream is mocked, so no account is ever created.
const REGISTERED = 'e2e+upstream-registered@e2e.evaapp.dev'
const UNKNOWN = 'e2e+upstream-unknown@e2e.evaapp.dev'
const PASSWORD = 'correct-horse-8'
/** The password the *link holder* chooses, distinct from the squatter's above. */
const CHOSEN = 'chosen-at-activation-9'

interface Answer {
  status: number
  /** The raw bytes, not a parse of them: a leak may be anywhere in the response. */
  text: string
  headers: string
  retryAfter: string | undefined
  body: unknown
}

const post = async (path: string, body: unknown): Promise<Answer> => {
  const res = await server.fetch(
    new Request(`http://api.test${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    }),
  )
  const text = await res.text()
  return {
    status: res.status,
    text,
    headers: JSON.stringify([...res.headers]),
    retryAfter: res.headers.get('retry-after') ?? undefined,
    body: JSON.parse(text),
  }
}

const signup = (email = REGISTERED) => post('/auth/signup', { email })

/**
 * A whole sign-up, then the link spent — which is where the account is created (#120) and
 * therefore where `upstream` fires. The token is issued directly, the way every live suite
 * does it, because the link itself never reaches a test.
 */
const activate = async (email = REGISTERED, password = PASSWORD): Promise<Answer> => {
  await signup(email)
  const token = await issueToken(null, email, 'activation')
  return post('/auth/activate', { token, password })
}

/**
 * Whether a password actually opens an account, asked of Identity Toolkit directly.
 *
 * Not through `POST /auth/signin`, which would answer `403 NOT_ACTIVATED` for exactly the
 * accounts worth asking about, and not through `../src/identity-toolkit` — `mock.module`
 * has replaced that module's bindings for this whole process, so a helper reading it would
 * be asking the fake. `config` is not mocked, and `identityToolkitBaseUrl` follows the
 * emulator when `FIREBASE_AUTH_EMULATOR_HOST` is set (#67); a hardcoded Google URL would
 * report "that password is dead" for every account that exists only in the emulator.
 */
const passwordOpens = async (email: string, password: string): Promise<boolean> => {
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
const signin = (email = REGISTERED) => post('/auth/signin', { email, password: PASSWORD })

/** `{ error: { code, message } }` and nothing else (GUARDRAILS 11). */
const expectStandardShape = (answer: Answer, code: string) => {
  const body = answer.body as { error: { code: string; message: string } }
  expect(Object.keys(body)).toEqual(['error'])
  expect(Object.keys(body.error).sort()).toEqual(['code', 'message'])
  expect(body.error.code).toBe(code)
  expect(body.error.message).toBeTypeOf('string')
  expect(body.error.message.length).toBeGreaterThan(0)
}

/**
 * Anything that must never appear in a response or a log line: Google's reason strings,
 * the exception's own message prefix, the submitted address, the submitted password.
 */
const LEAKS = [
  'INVALID_EMAIL',
  'INTERNAL_ERROR',
  'NETWORK_FAILURE',
  'TOO_MANY_ATTEMPTS_TRY_LATER',
  'MALFORMED_RESPONSE',
  'WEAK_PASSWORD : Password',
  'Identity Toolkit',
  'upstream-registered',
  'upstream-unknown',
  'evaapp.dev',
  'correct-horse',
]

const expectNoLeak = (haystack: string) => {
  const whole = haystack.toLowerCase()
  for (const leak of LEAKS) expect(whole).not.toContain(leak.toLowerCase())
}

/** The few cases here that need a real account, swept at the end (GUARDRAILS 16). */
const strays: string[] = []

beforeEach(() => {
  resetAuthRateLimits()
  upstream = null
  hideAccountOnce = false
  failFindAuthUid = null
})
afterAll(async () => {
  // Hand the module back exactly as it was found before any live cleanup can fail or time
  // out. Bun's mocks are permanent and process-global, so this must not wait behind I/O.
  mock.module('../src/identity-toolkit', () => identityToolkit)
  resetAuthRateLimits()
  upstream = null
  for (const uid of strays) {
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
})

describe('creating the account: an upstream failure that is not EMAIL_EXISTS', () => {
  // Sign-up used to make this call and now creates nothing (#120); the account comes into
  // existence when the activation link is spent. These are the same assertions about the
  // same guarantee, moved to the route that now carries it.
  test('a refused request is a shaped 400, not a bare 500', async () => {
    upstream = rejects('INVALID_EMAIL')
    const answer = await activate()

    expect(answer.status).toBe(400)
    expectStandardShape(answer, 'VALIDATION')
    expectNoLeak(`${answer.text} ${answer.headers}`)
  })

  test('an outage is a shaped 503 that says retrying is reasonable', async () => {
    upstream = isDown
    const answer = await activate()

    expect(answer.status).toBe(503)
    expectStandardShape(answer, 'SERVICE_UNAVAILABLE')
    expect(answer.retryAfter).toBe('30')
    expectNoLeak(`${answer.text} ${answer.headers}`)
  })

  test('a transient failure and a malformed-input one are told apart', async () => {
    upstream = isDown
    const outage = await activate()
    upstream = rejects('INVALID_EMAIL')
    const malformed = await activate()

    // The distinction the issue asks for: 503-shaped for "Google is unavailable",
    // 400-shaped for "this email is malformed" — different status, different code,
    // and only one of them carries Retry-After.
    expect(outage.status).toBe(503)
    expect(malformed.status).toBe(400)
    expect(outage.text).not.toBe(malformed.text)
    expect(outage.retryAfter).toBe('30')
    expect(malformed.retryAfter).toBeUndefined()
  })

  test('the request never landing is an outage too, not a 400', async () => {
    upstream = unreachable
    const answer = await activate()

    expect(answer.status).toBe(503)
    expectStandardShape(answer, 'SERVICE_UNAVAILABLE')
  })

  test("upstream load-shedding on a 4xx is an outage, not the caller's fault", async () => {
    upstream = shedsLoad
    const answer = await activate()

    expect(answer.status).toBe(503)
    expectStandardShape(answer, 'SERVICE_UNAVAILABLE')
  })

  test('EMAIL_EXISTS is no longer a refusal here — the link takes the account', async () => {
    // The one case whose *meaning* changed with #120, rather than moving.
    //
    // A taken address used to end sign-up with `409`. At activation it cannot: the
    // holder of a valid link has proved the address, and whoever reserved it in the
    // meantime — by calling Identity Toolkit directly, which the public web API key
    // allows — has proved nothing. Refusing here would let anyone permanently lock a
    // person out of their own address by racing their sign-up.
    //
    // `409` still exists, at sign-up, for an address whose owner is *activated*. That is
    // tested in `auth.test.ts`.
    // A real account for the address, because the race this models is real: somebody
    // reserved it by calling Identity Toolkit directly while this caller was reading
    // their email. Without one the route has nothing to claim and rightly rethrows.
    const squatted = testEmail()
    const { uid } = await adminAuth.createUser({ email: squatted, password: PASSWORD })
    strays.push(uid)

    // **Staged, because pre-creating the squatter is not enough to reach this branch.**
    // With the account already there, the route's *first* `findAuthUidByEmail` finds it
    // and takes the ordinary path — `createAccountWithPassword` is never called and the
    // `upstream` stub below sits inert. This test carried its name and its comment for a
    // while while exercising a different code path; `hideAccountOnce` is what makes the
    // first lookup miss and the create collide, which is the race itself.
    await signup(squatted)
    const token = await issueToken(null, squatted, 'activation')
    hideAccountOnce = true
    upstream = rejects('EMAIL_EXISTS')
    const answer = await post('/auth/activate', { token, password: CHOSEN })

    expect(answer.status).toBe(200)
    expect(answer.body).toEqual({ activated: true })
    // **Claimed, not inherited — asked of the credential, not of a flag.** This asserted
    // `emailVerified === true` alone, which `markCredentialsProven` satisfies on its own:
    // replacing the whole `claimForActivation` call with that one line left the suite
    // green, while the branch quietly started handing the squatter's password an
    // activated account. That is the #120 takeover surviving in its residual race, so the
    // question has to be the one the comment claims: which password opens this account.
    expect((await adminAuth.getUser(uid)).emailVerified).toBe(true)
    expect(await passwordOpens(squatted, PASSWORD)).toBe(false)
    expect(await passwordOpens(squatted, CHOSEN)).toBe(true)
    // Kept explicitly, though the file default is now the same 20s (#31). This is the
    // case that earned the number: four real round trips (create, look up, claim, read
    // back), and it blew Bun's 5s default against the real project while passing
    // against the emulator — `bun test` green, `bun run verify` red, for a test that
    // was working. Leaving it here keeps that story where the next reader meets it.
    //
    // The file used to justify keeping the 5s default on the grounds that "every other
    // case is in-process against a mocked upstream and finishes in milliseconds". That
    // was not true: `describe("createAccountWithPassword classifies the Admin SDK's own
    // failures")` calls `realCreateAccount` — the real Admin SDK, deliberately
    // un-mocked — with no timeout of its own, and the `afterAll` sweeps Auth and
    // Firestore.
  }, 20_000)
})

/**
 * The one auth route whose lookup was unguarded (#346): `POST /auth/signup` asks
 * `findAuthUidByEmail` to learn whether an address is already taken, and before this
 * rethrew the raw Admin SDK error — an Identity Toolkit outage surfaced as a bare 500
 * `unhandled_error` rather than the shaped 503 every other auth route gives it.
 */
describe('signup: an outage during the address lookup', () => {
  test('is a shaped 503, not a bare 500', async () => {
    failFindAuthUid = isDown
    const answer = await signup(UNKNOWN)

    expect(answer.status).toBe(503)
    expectStandardShape(answer, 'SERVICE_UNAVAILABLE')
    expect(answer.retryAfter).toBe('30')
    expectNoLeak(`${answer.text} ${answer.headers}`)
  })

  test('the request never landing is the same 503', async () => {
    failFindAuthUid = unreachable
    const answer = await signup(UNKNOWN)

    expect(answer.status).toBe(503)
    expectStandardShape(answer, 'SERVICE_UNAVAILABLE')
  })
})

/**
 * What the request leaves behind when it **fails after the claim**, which is the only thing
 * the `markCredentialsProven`-last ordering is for.
 *
 * On the happy path both orderings produce the same account, so nothing observable separates
 * them and two mutations — setting `emailVerified` at creation, and moving
 * `markCredentialsProven` back inside `claimForActivation` — each left the suite fully green.
 * The difference only shows when the route stops between the claim and the stamp, so this
 * makes it stop there.
 *
 * The fault is the real one, not an invented one: a `DELETE /me` landing mid-activation.
 * `readUser` runs several awaits before `ensureUser` does, and the tombstone written in that
 * gap is what `ensureUser` refuses — the case the `existing.deleted` guard three lines above
 * explicitly does **not** cover, because it covers the settled one.
 */
describe('a request that dies after the claim leaves nothing armed', () => {
  test('the address is not marked proven unless the account was activated', async () => {
    const email = testEmail('midflight')
    const { uid } = await adminAuth.createUser({ email, password: PASSWORD })
    strays.push(uid)
    await firestore
      .collection('users')
      .doc(uid)
      .set({
        email,
        authProviders: ['password'],
        questionnaireCompleted: false,
        profile: null,
        activatedAt: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      })

    await signup(email)
    const token = await issueToken(null, email, 'activation')

    // Tombstoned **during** `claimForActivation`'s first write, so the route is already
    // past its `deleted` guard and has not yet reached `ensureUser`. Hung off
    // `setPassword`'s call rather than fired beforehand, because fired beforehand the
    // guard catches it and the route never enters the window at all.
    const realUpdateUser = adminAuth.updateUser.bind(adminAuth)
    const spy = spyOn(adminAuth, 'updateUser').mockImplementation(
      async (target: string, props: Record<string, unknown>) => {
        const result = await realUpdateUser(target, props)
        if (props?.password) {
          await firestore.collection('users').doc(uid).update({
            deletedAt: FieldValue.serverTimestamp(),
          })
        }
        return result
      },
    )

    let answer: Answer
    try {
      answer = await post('/auth/activate', { token, password: CHOSEN })
    } finally {
      spy.mockRestore()
    }

    // A dead link, because `ensureUser` refuses to revive a tombstone.
    //
    // The two tail refusals — `!user` and `markActivated` returning false — are
    // **jointly** pinned by this and individually redundant: with either one deleted the
    // other still answers `INVALID_TOKEN` for the same account, so neither mutation is
    // visible alone and deleting both is (1 failure, here). That is a true fact about the
    // route rather than a gap to paper over, and it is the reason to state it: the pair
    // is load-bearing, and a test that pinned each separately would only be pinning that
    // the redundancy exists.
    expect(answer.status).toBe(400)
    expectStandardShape(answer, 'INVALID_TOKEN')

    const account = await adminAuth.getUser(uid)
    // **The assertion the ordering exists for.** `activatedAt` was never stamped, so
    // `emailVerified` must not be set either: that pair is what disarms
    // `claimUnprovenAccount`'s address test while leaving its gate armed, which is the
    // one combination that claims unconditionally.
    expect(account.emailVerified).toBe(false)
    expect((await firestore.collection('users').doc(uid).get()).data()!.activatedAt).toBeNull()
  }, 20_000)
})

describe('the email-exists race obeys the same guards as every other path', () => {
  test('the race does not reopen the dead-link rule on an activated account', async () => {
    // **The one path where that rule was not enforced.** `/auth/activate` reaches an
    // account that already exists two ways: the ordinary lookup, and this one — the
    // create failing with `EMAIL_EXISTS` and the uid being found on a second look. The
    // second had its own copy of the tail and skipped both refusals the first makes, so
    // a link for an address whose owner is already activated claimed the account and
    // overwrote their password. Two unspent links for one address — a sign-up and a
    // Resend, opened on two devices — is enough to produce it without an attacker.
    //
    // An *activated* account, built the way an activated account looks: Auth user plus a
    // document with `activatedAt` set. Without both, the guard reads `user: null` and the
    // branch is never entered in either direction.
    const owned = testEmail()
    const { uid } = await adminAuth.createUser({ email: owned, password: PASSWORD })
    strays.push(uid)
    await firestore
      .collection('users')
      .doc(uid)
      .set({
        email: owned,
        authProviders: ['password'],
        questionnaireCompleted: false,
        profile: null,
        activatedAt: FieldValue.serverTimestamp(),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      })

    // Signed up *before* the race is staged: sign-up asks the same question, and it
    // would otherwise spend the one-shot below on the wrong call.
    await signup(owned)
    const token = await issueToken(null, owned, 'activation')

    hideAccountOnce = true
    upstream = rejects('EMAIL_EXISTS')
    const answer = await post('/auth/activate', { token, password: CHOSEN })

    expect(answer.status).toBe(400)
    expectStandardShape(answer, 'INVALID_TOKEN')
    // The owner's credential is the thing at stake, so it is the thing asserted.
    expect(await passwordOpens(owned, PASSWORD)).toBe(true)
    expect(await passwordOpens(owned, CHOSEN)).toBe(false)
  }, 20_000)
})

describe('signin: an upstream failure that is not a wrong password', () => {
  test('an outage is a shaped 503, distinct from the 401 for bad credentials', async () => {
    upstream = isDown
    const outage = await signin()
    upstream = rejects('INVALID_LOGIN_CREDENTIALS')
    const wrong = await signin()

    expect(outage.status).toBe(503)
    expectStandardShape(outage, 'SERVICE_UNAVAILABLE')
    expect(outage.retryAfter).toBe('30')

    expect(wrong.status).toBe(401)
    expectStandardShape(wrong, 'INVALID_CREDENTIALS')
  })

  test('and it waits out the signin floor, like every other branch (#34)', async () => {
    // The floor wraps the **whole** `/auth/signin` handler rather than only the two
    // `INVALID_CREDENTIALS` returns, so a branch added later cannot forget to opt in.
    // This is the case that can see the difference: an outage is the one non-401 answer
    // that costs nothing to produce — the upstream is stubbed and fails immediately —
    // so without the floor it returns in single-digit milliseconds. Every other branch
    // (403, 200, the deleted-account 401) does real upstream and Firestore work and
    // already exceeds the floor, which is why wrapping them is free and also why they
    // cannot pin the wrapper's width.
    //
    // Restated rather than imported, so lowering the route's constant fails here
    // instead of dragging the assertion down with it.
    const SIGNIN_FLOOR_MS = 350
    upstream = isDown

    const started = performance.now()
    const answer = await signin()
    const elapsed = performance.now() - started

    expect(answer.status).toBe(503)
    expect(elapsed).toBeGreaterThanOrEqual(SIGNIN_FLOOR_MS - 1)
  })

  test('a reason signin has no answer for still collapses to 401, never a 500', async () => {
    // Signin deliberately has no 400 branch: "that address is malformed" would answer
    // the question the 401 refuses to answer. An upstream rejection our route has no
    // specific handling for must land on the same 401 as a wrong password.
    upstream = rejects('INVALID_EMAIL')
    const answer = await signin()

    expect(answer.status).toBe(401)
    expectStandardShape(answer, 'INVALID_CREDENTIALS')
    expectNoLeak(`${answer.text} ${answer.headers}`)
  })
})

describe('the new 503 branch does not reintroduce the enumeration leak', () => {
  test('an outage answers a registered and an unknown address byte-identically', async () => {
    // The property #21 closed, re-checked against the branch #32 adds. The 503 is
    // chosen from the upstream *status*, which does not vary with the address — but
    // "does not vary" is the kind of claim that stops being true quietly, so it is
    // compared the same way the 401s are: whole bytes, headers included.
    upstream = isDown
    const registered = await signin(REGISTERED)
    const unknown = await signin(UNKNOWN)

    expect(registered.status).toBe(503)
    expect(unknown.status).toBe(503)
    expect(registered.text).toBe(unknown.text)
    expect(registered.headers).toBe(unknown.headers)
  })

  test('Retry-After is the same constant for every caller and every failure', async () => {
    // A per-caller value here — a backoff that grows with an address's failures, say —
    // would answer through the header what the body refuses to. Constant, per #5.
    upstream = isDown
    const first = await signin(REGISTERED)
    const second = await signin(UNKNOWN)
    upstream = unreachable
    const third = await signin(REGISTERED)
    upstream = shedsLoad
    const fourth = await activate(UNKNOWN)

    expect(new Set([first, second, third, fourth].map((a) => a.retryAfter)).size).toBe(1)
    expect(first.retryAfter).toBe('30')
  })

  test('the 400 branch reveals nothing about which address it was', async () => {
    // Sign-up is allowed to say EMAIL_EXISTS (ARCHITECTURE §3), but the 400 that
    // account creation can answer must not become a second channel: a rejection reads
    // the same whichever address it is.
    upstream = rejects('INVALID_EMAIL')
    const registered = await activate(REGISTERED)
    const unknown = await activate(UNKNOWN)

    expect(registered.text).toBe(unknown.text)
    expect(registered.headers).toBe(unknown.headers)
  })
})

describe("the operator's signal", () => {
  let logged: string[] = []
  let spy: ReturnType<typeof spyOn> | null = null

  beforeEach(() => {
    logged = []
    spy = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
      logged.push(args.map((a) => String(a)).join(' '))
    })
  })
  afterEach(() => spy?.mockRestore())

  test('an outage is logged with the route and the upstream status, and nothing else', async () => {
    upstream = isDown
    await signin()

    // Without this line a 503 is a silent number on a dashboard; with it, an outage is
    // greppable and alertable. It is the whole answer to "is Google down, or did we
    // ship a bug" — a bug from these routes is still a bare 500 and logs a stack.
    expect(logged).toHaveLength(1)
    const line = JSON.parse(logged[0]!) as Record<string, unknown>
    expect(line.event).toBe('identity_toolkit_unavailable')
    expect(line.route).toBe('signin')
    expect(line.upstreamStatus).toBe(500)
  })

  test('the log line carries no reason, no address, no password, no API key', async () => {
    upstream = unreachable
    await activate()
    upstream = rejects('INVALID_EMAIL')
    await activate()
    upstream = isDown
    await signin()

    const whole = logged.join('\n')
    expectNoLeak(whole)
    // `includes`, not `not.toContain`: on failure Bun prints the expected substring,
    // which here would write the live web API key into a CI log. Also removes a
    // stray NUL byte that made this whole file unsearchable by grep.
    expect(whole.includes(config.firebaseWebApiKey)).toBe(false)
    // `unavailable` is what an operator needs to see; a wrong password is not an
    // incident, and logging one per attempt would be a log full of nothing.
    expect(logged).toHaveLength(2)
  })
})

/**
 * The boundary itself: what `identity-toolkit.ts` makes of an upstream that misbehaves.
 *
 * Everything above builds `IdentityToolkitError`s by hand, which proves the routes map
 * a kind correctly but not that the client ever produces those kinds. This drives the
 * real `signUpWithPassword` against a stubbed `fetch` — the only way to reach a refused
 * connection or an HTML error page from a load balancer, neither of which the live
 * project can be asked for.
 */
describe("the Identity Toolkit client's own classification", () => {
  let fetchSpy: ReturnType<typeof spyOn> | null = null

  const answering = (make: () => Response | never) => {
    // The cast is only about `fetch`'s extra `preconnect` property, which the client
    // does not use; the stub still has to be a function returning a Response.
    fetchSpy = spyOn(globalThis, 'fetch').mockImplementation((async () =>
      make()) as unknown as typeof fetch)
  }
  const jsonResponse = (status: number, reason: string) =>
    new Response(JSON.stringify({ error: { message: reason } }), { status })

  afterEach(() => fetchSpy?.mockRestore())

  /** Runs the real client and hands back the failure it threw. */
  const failure = async (): Promise<InstanceType<typeof IdentityToolkitError>> => {
    try {
      await realSignUp('e2e+boundary@e2e.evaapp.dev', PASSWORD)
    } catch (err) {
      return err as InstanceType<typeof IdentityToolkitError>
    }
    throw new Error('expected the call to fail')
  }

  test('a refused connection is unavailable, with no status and no leaked URL', async () => {
    answering(() => {
      // What Bun throws when the host cannot be reached — its message names the
      // request URL, and that URL carries the web API key.
      throw new Error(
        'Unable to connect: https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=SECRET',
      )
    })
    const err = await failure()

    expect(err.kind).toBe('unavailable')
    expect(err.upstreamStatus).toBeNull()
    // The cause is dropped rather than attached, so the key cannot travel with the
    // error into a log line or a stack trace (GUARDRAILS 1).
    expect(`${err.message} ${err.reason} ${err.stack ?? ''}`).not.toContain('SECRET')
    expect(err.cause).toBeUndefined()
  })

  test('a body that is not JSON is an outage, not a verdict', async () => {
    answering(() => new Response('<html>502 Bad Gateway</html>', { status: 502 }))
    const err = await failure()

    expect(err.kind).toBe('unavailable')
    expect(err.upstreamStatus).toBe(502)
  })

  test('a 5xx is unavailable whatever its body claims about the address', async () => {
    // The status is read before the reason, so a 500 carrying EMAIL_EXISTS cannot be
    // turned into a statement about whether that address is registered.
    answering(() => jsonResponse(500, 'EMAIL_EXISTS'))
    const err = await failure()

    expect(err.kind).toBe('unavailable')
    expect(err.upstreamStatus).toBe(500)
  })

  test('a 429 is unavailable', async () => {
    answering(() => jsonResponse(429, 'RESOURCE_EXHAUSTED'))
    expect((await failure()).kind).toBe('unavailable')
  })

  test('a 400 EMAIL_EXISTS is still email-exists', async () => {
    answering(() => jsonResponse(400, 'EMAIL_EXISTS'))
    const err = await failure()

    expect(err.kind).toBe('email-exists')
    expect(err.upstreamStatus).toBe(400)
  })

  test('a 400 the caller could fix is rejected', async () => {
    answering(() => jsonResponse(400, 'INVALID_EMAIL'))
    expect((await failure()).kind).toBe('rejected')
  })

  test('load-shedding and a disabled provider are unavailable despite their 400', async () => {
    for (const reason of [
      'TOO_MANY_ATTEMPTS_TRY_LATER',
      'QUOTA_EXCEEDED',
      'OPERATION_NOT_ALLOWED',
      'ADMIN_ONLY_OPERATION',
    ]) {
      answering(() => jsonResponse(400, reason))
      expect((await failure()).kind).toBe('unavailable')
      fetchSpy?.mockRestore()
    }
  })

  test("Google's multi-word reasons keep only the code", async () => {
    answering(() => jsonResponse(400, 'WEAK_PASSWORD : Password should be at least 6 characters'))
    const err = await failure()

    expect(err.reason).toBe('WEAK_PASSWORD')
    expect(err.kind).toBe('rejected')
  })
})

/**
 * The classifier **inside** `createAccountWithPassword`, driven for real.
 *
 * The route tests above replace the whole function through `mock.module` and throw
 * `IdentityToolkitError`s they built themselves, so they prove what `index.ts` does with a
 * classification and never that the classification is the one the Admin SDK would produce.
 * Two independent mutations confirmed the gap: collapsing every `unavailable` into
 * `rejected`, and deleting the `auth/email-already-exists` mapping, each left the suite
 * fully green. What that costs is precisely #32's guarantee — the one this file exists for:
 * a Firebase outage during activation answering `400 VALIDATION` ("that email or password
 * can't be used") instead of a `503` with `Retry-After`, and a real race answering `503` and
 * leaving the user with a spent link and no account.
 *
 * `realCreateAccount`, never the namespace: the mock above is installed for this whole
 * process and reading `identityToolkit.createAccountWithPassword` here would ask the fake.
 */
describe("createAccountWithPassword classifies the Admin SDK's own failures", () => {
  test('an address that already exists is email-exists, which the route claims', async () => {
    const email = testEmail('create')
    const uid = await realCreateAccount(email, PASSWORD)
    strays.push(uid)
    // **Created unproven, and the route proves it at the end.** `emailVerified` turns off
    // `claimUnprovenAccount`'s address test while `activatedAt` turns off the claim
    // itself, so an account carrying the first without the second is the one state that
    // claims unconditionally — and setting it here, three calls before `markActivated`,
    // opened exactly that window on every sign-up. Nothing asserted the one-word change
    // that closed it; putting `emailVerified: true` back left the whole suite green.
    expect((await adminAuth.getUser(uid)).emailVerified).toBe(false)

    // Not a fake and not a stubbed fetch: the second create genuinely collides.
    const err = (await realCreateAccount(email, PASSWORD).then(
      () => null,
      (e: unknown) => e,
    )) as InstanceType<typeof IdentityToolkitError> | null

    expect(err).toBeInstanceOf(IdentityToolkitError)
    expect(err!.kind).toBe('email-exists')
  })

  test("a password the SDK refuses is the caller's fault, not an outage", async () => {
    // Seven characters: under Firebase's own six-character floor is not enough to get a
    // refusal, so this uses the length Eva's edge would have caught — reaching here at
    // all means the edge changed, and the answer must still be a 400 rather than a 503.
    const email = testEmail('create')
    const err = (await realCreateAccount(email, '12345').then(
      () => null,
      (e: unknown) => e,
    )) as InstanceType<typeof IdentityToolkitError> | null

    expect(err).toBeInstanceOf(IdentityToolkitError)
    expect(err!.kind).toBe('rejected')
  })

  test('anything else is an outage the caller can retry', async () => {
    // The one case that cannot be produced honestly — the real project will not have an
    // internal error on demand — so the SDK call itself is stubbed, one level below the
    // classifier, which is the thing under test.
    const spy = spyOn(adminAuth, 'createUser').mockImplementation(() => {
      throw Object.assign(new Error('backend unavailable'), {
        code: 'auth/internal-error',
      })
    })
    try {
      const err = (await realCreateAccount(
        testEmail('create'),
        PASSWORD,
      ).then(
        () => null,
        (e: unknown) => e,
      )) as InstanceType<typeof IdentityToolkitError> | null

      expect(err).toBeInstanceOf(IdentityToolkitError)
      // The distinction the whole file is about: retryable, not the caller's fault.
      expect(err!.kind).toBe('unavailable')
    } finally {
      spy.mockRestore()
    }
  })
})

/**
 * The same classifier, for the lookup the sign-up route performs (#346).
 *
 * `createAccountWithPassword` classified the Admin SDK's failures since #120; the address
 * lookup it runs *first* did not, so an outage there escaped as a raw error and a bare 500.
 * Driven for real against a stubbed `getUserByEmail`, so this pins the classification and
 * not just the route's mapping of a hand-built `IdentityToolkitError`.
 */
describe("findAuthUidByEmail classifies the Admin SDK's own failures", () => {
  test('a lookup outage is unavailable', async () => {
    const spy = spyOn(adminAuth, 'getUserByEmail').mockImplementation(() => {
      throw Object.assign(new Error('backend unavailable'), {
        code: 'auth/internal-error',
      })
    })
    try {
      const err = (await realFindAuthUid('e2e+lookup@e2e.evaapp.dev').then(
        () => null,
        (e: unknown) => e,
      )) as InstanceType<typeof IdentityToolkitError> | null

      expect(err).toBeInstanceOf(IdentityToolkitError)
      expect(err!.kind).toBe('unavailable')
    } finally {
      spy.mockRestore()
    }
  })

  test('a missing address is still null, not an error', async () => {
    // The lookup's whole job at sign-up is telling "taken" from "free"; a miss is the
    // normal free-address answer and must stay `null`, not become an outage.
    const spy = spyOn(adminAuth, 'getUserByEmail').mockImplementation(() => {
      throw Object.assign(new Error('no such user'), { code: 'auth/user-not-found' })
    })
    try {
      const answer = await realFindAuthUid('e2e+lookup@e2e.evaapp.dev').then(
        (v) => v,
        (e: unknown) => e,
      )
      expect(answer).toBeNull()
    } finally {
      spy.mockRestore()
    }
  })
})

import { afterAll, afterEach, beforeEach, describe, expect, mock, spyOn, test } from 'bun:test'
import { mintToken } from '../src/auth'
import { config } from '../src/config'
import type { TokenKind } from '../src/email-tokens'
import { resetAuthRateLimits } from '../src/rate-limit'

/**
 * What the API answers when something throws that no route handles (issue #48).
 *
 * #32 mapped every Identity Toolkit failure, so "no bare 500s" became true of upstream
 * auth failures and of nothing else. `ensureUser` sits inside the same `try` as the
 * Identity Toolkit call in both auth routes, so a **Firestore** outage fell past it to
 * Hono's default handler: an unshaped 500, which the iOS client can only render as
 * "Something went wrong (500)", and the thrown error's own text written to the log.
 *
 * The second half is what this file spends most of its assertions on. A Firestore error's
 * message names the document it failed on — which is a uid, and for an event an id that
 * encodes a day someone logged health data on — and a failed `fetch`'s message names the
 * request URL, which for Identity Toolkit carries the web API key (#32). So the fakes
 * below throw errors whose messages carry exactly those things, marked with strings that
 * appear nowhere else, and every response and every log line is checked for them as raw
 * text rather than as a parse.
 *
 * **The seam** is #21's: `mock.module` on the modules that would touch Firestore, and the
 * route driven in-process through `app.fetch`. The real project cannot be asked for an
 * outage on demand, and it must not be asked for one.
 *
 * **The `mock.module` caveat that constrains this file**, as `auth-upstream-failures.test.ts`
 * states it: Bun's module mocks are process-global and permanent — they replace the live
 * bindings every already-imported module sees, they are not scoped to the file that
 * installed them, and the last file loaded leaves its mocks in place for the rest of the
 * process. Three consequences are handled here:
 *
 * 1. This file installs its own `identity-toolkit` mock rather than relying on another
 *    file's: sign-in must succeed upstream to reach the user-store seam, while sign-up's
 *    Auth address lookup is answered locally. Whichever mock is installed when this file
 *    loads otherwise decides both paths for the whole process.
 * 2. `afterAll` puts all five modules back, by re-mocking each to the namespace this
 *    file captured. Without it the run order decides whether another suite passes:
 *    `bun test` does **not** run files alphabetically — this one currently runs first,
 *    and `auth-upstream-failures.test.ts` captures `signUpWithPassword` as a value at
 *    load to drive the real client, so a mock of ours still installed by then is the
 *    "real" client it captures. Restoring is this file's job; the other suites are
 *    unchanged.
 * 3. The rate-limit counters are shared with the other in-process files, so the throttle
 *    is reset before every test and after the last one.
 *
 * While this file's own tests run, no mock ever delegates to the real module and every
 * default throws instead: delegating would write a document for a fabricated uid into the
 * live project, and a test that forgot to say what Firestore does is a bug in the test.
 */

// Copies, not the namespace objects: `mock.module` replaces the bindings *inside* the
// live namespace, so a reference captured here would quietly become this file's own mock
// and `afterAll` would restore nothing. These snapshots are what the modules were on the
// way in, which is what has to go back.
const identityToolkit = { ...(await import('../src/identity-toolkit')) }
const users = { ...(await import('../src/users')) }
const events = { ...(await import('../src/events')) }
const emailTokens = { ...(await import('../src/email-tokens')) }
const email = { ...(await import('../src/email')) }

/** The uid every credential call hands back. Fabricated, and never written anywhere. */
const UID = 'unhandled-errors-test-uid'

/** Deliberately shaped like a real one-per-day id: the type and the date are in it. */
const EVENT_ID = 'cycle_2026-08-27'

const EMAIL = 'e2e+unhandled-errors@e2e.evaapp.dev'
const PASSWORD = 'correct-horse-8'

/** What the next credential call does. `null` is a bug in the test, never a success. */
let credential: (() => { localId: string; email: string }) | null = null
/** What the Auth address lookup does next. The ordinary sign-up fixture answers absent. */
let authLookup: ((email: string) => string | null) | null = null
/** What `email-tokens.issueToken` does next: throw, or write to the in-memory fake. */
let tokenStore: null | (() => void) = null

type FakeToken = {
  uid: string | null
  email: string
  kind: TokenKind
  used: boolean
}

let tokenSequence = 0
const fakeTokens = new Map<string, FakeToken>()

const issueFakeToken = async (
  uid: string | null,
  email: string,
  kind: TokenKind,
): Promise<string> => {
  if (tokenStore) tokenStore()
  tokenSequence += 1
  const raw = tokenSequence.toString(36).padStart(emailTokens.TOKEN_LENGTH, 'a')
  fakeTokens.set(raw, { uid, email, kind, used: false })
  return raw
}

/** What `users.ensureUser` / `users.getUser` do next: throw, or answer with an account.
 *  Every authenticated route now reads the user document before its handler runs (#8's
 *  account gate), so a test that wants to reach a handler at all has to say the account
 *  exists — otherwise the gate is what throws, and the route never gets its turn. */
let userStore: (() => unknown) | null = null
/** What `events.softDeleteEvent` does next — a throw, or an ordinary answer. */
let deleteEvent: (() => boolean) | null = null

const unset = (what: string) => (): never => {
  throw new Error(`test/unhandled-errors.test.ts reached ${what} without setting it`)
}

mock.module('../src/identity-toolkit', () => ({
  ...identityToolkit,
  signInWithPassword: async () => (credential ?? unset('Identity Toolkit'))(),
  signUpWithPassword: async () => (credential ?? unset('Identity Toolkit'))(),
  findAuthUidByEmail: async (email: string) =>
    (authLookup ?? unset('Identity Toolkit address lookup'))(email),
}))

// Sign-up's only Firestore write is the activation token (#120) — it no longer creates an
// account — so this is the seam that makes "Firestore is down inside sign-up" reachable.
mock.module('../src/email-tokens', () => ({
  ...emailTokens,
  issueToken: issueFakeToken,
  consumeToken: async (raw: string, kind: TokenKind) => {
    const token = fakeTokens.get(raw)
    if (!token || token.kind !== kind || token.used) {
      return { ok: false as const, reason: 'invalid' as const }
    }
    token.used = true
    return { ok: true as const, uid: token.uid, email: token.email }
  },
  deleteTokensForAccount: async (uid: string, address: string | null) => {
    for (const [raw, token] of fakeTokens) {
      if (
        token.uid === uid ||
        (token.uid === null && address !== null && token.email === address)
      ) {
        fakeTokens.delete(raw)
      }
    }
  },
}))

// Delivery is outside this file's subject. Keep sign-up in-process even when the local
// environment is configured for Postmark rather than the log transport.
mock.module('../src/email', () => ({
  ...email,
  sendActivationEmail: async () => {},
  sendPasswordResetEmail: async () => {},
}))

mock.module('../src/users', () => ({
  ...users,
  ensureUser: async () => (userStore ?? unset('users.ensureUser'))(),
  getUser: async () => (userStore ?? unset('users.getUser'))(),
  // The account gate reads `getAccount` since #76 — the same seam, one function further
  // along. Without it here the gate calls the real Firestore and the mocked outage below
  // never reaches the handler it is supposed to be testing.
  getAccount: async () => (userStore ?? unset('users.getAccount'))(),
  // `/auth/signin` reads before it writes since #119, through the same seam: the account
  // `userStore` names, or its throw.
  readUser: async () => ({
    deleted: false,
    user: ((userStore ?? unset('users.readUser'))() as { user: unknown }).user,
  }),
}))

mock.module('../src/events', () => ({
  ...events,
  softDeleteEvent: async () => (deleteEvent ?? unset('events.softDeleteEvent'))(),
}))

// Imported after the mocks, and never as a listening server.
const { default: server } = await import('../src/index')

const succeeds = () => ({ localId: UID, email: EMAIL })

/**
 * A live account for the gate to find. Never written anywhere — `users` is mocked.
 *
 * The `Account` shape `getAccount` and `ensureUser` answer with since #76: the user, and
 * the session generation her token has to match. `0` is the generation of an account that
 * has never had a password reset, which is what every `mintToken(…, 0)` below mints at.
 */
const liveAccount = () => ({
  user: {
    id: UID,
    email: EMAIL,
    questionnaireCompleted: false,
    profile: null,
  },
  tokenVersion: 0,
})

/**
 * A Firestore outage as `firebase-admin` reports one: a gRPC status in the message, and —
 * the part that matters — the credential-refresh URL it failed on.
 */
const firestoreUnavailable = (): never => {
  const err = new Error(
    '14 UNAVAILABLE: Getting metadata from plugin failed with error: ' +
      'Could not refresh access token: https://oauth2.googleapis.com/token?key=LEAKED-KEY-48',
  )
  err.name = 'FirebaseAppError'
  throw err
}

/** The other half of the risk: a message that names the document it failed on. */
const firestoreNamesTheDocument = (): never => {
  const err = new Error(
    `5 NOT_FOUND: no entity to update: path { users "${UID}" events "${EVENT_ID}" }`,
  )
  err.name = 'FirebaseFirestoreError'
  throw err
}

interface Answer {
  status: number
  /** The raw bytes, not a parse of them: a leak may be anywhere in the response. */
  text: string
  headers: string
  body: { error: { code: string; message: string } }
}

const send = async (
  method: string,
  path: string,
  init: { body?: unknown; token?: string } = {},
): Promise<Answer> => {
  const res = await server.fetch(
    new Request(`http://api.test${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(init.token ? { authorization: `Bearer ${init.token}` } : {}),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    }),
  )
  const text = await res.text()
  return {
    status: res.status,
    text,
    headers: JSON.stringify([...res.headers]),
    body: JSON.parse(text) as Answer['body'],
  }
}

const signup = (email = EMAIL) => send('POST', '/auth/signup', { body: { email } })

const signin = (email = EMAIL) =>
  send('POST', '/auth/signin', { body: { email, password: PASSWORD } })

/**
 * Every distinctive fragment of the two thrown messages, plus the address, the password
 * and the uid. Any of these in a body or a log line is exactly what #32 removed.
 */
const LEAKS = [
  'LEAKED-KEY-48',
  'oauth2.googleapis.com',
  'UNAVAILABLE',
  'NOT_FOUND',
  'no entity to update',
  'Getting metadata',
  'access token',
  EVENT_ID,
  UID,
  'unhandled-errors@',
  'correct-horse',
]

const expectNoLeak = (haystack: string) => {
  const whole = haystack.toLowerCase()
  for (const leak of LEAKS) expect(whole).not.toContain(leak.toLowerCase())
}

/**
 * The whole user-facing message, as a template with one hole. Asserting the *shape* of the
 * message, rather than a list of things absent from it, is what makes "carries no part of
 * the thrown error's text" checkable: the only part that varies is eight hex characters
 * this handler generated itself.
 */
const INTERNAL_MESSAGE =
  /^Something went wrong on our end\. Please try again\. \(ref: [0-9a-f]{8}\)$/

const expectShapedInternalError = (answer: Answer) => {
  expect(answer.status).toBe(500)
  // `{ error: { code, message } }` and nothing else (GUARDRAILS 11).
  expect(Object.keys(answer.body)).toEqual(['error'])
  expect(Object.keys(answer.body.error).sort()).toEqual(['code', 'message'])
  expect(answer.body.error.code).toBe('INTERNAL')
  expect(answer.body.error.message).toMatch(INTERNAL_MESSAGE)
  expectNoLeak(`${answer.text} ${answer.headers}`)
}

const refOf = (answer: Answer): string =>
  answer.body.error.message.match(/\(ref: ([0-9a-f]{8})\)$/)![1]!

/** In-process and fully mocked: nothing in this file waits on a network. */
const FAST = 5_000

/** console.error is captured for the whole file: several tests provoke a 500 on purpose,
 *  and their log lines are the subject of one describe rather than noise in the run. */
let logged: string[] = []
let spy: ReturnType<typeof spyOn> | null = null
const line = (index = 0) => JSON.parse(logged[index]!) as Record<string, unknown>

beforeEach(() => {
  resetAuthRateLimits()
  credential = null
  authLookup = () => null
  userStore = null
  deleteEvent = null
  tokenStore = null
  tokenSequence = 0
  fakeTokens.clear()
  logged = []
  spy = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
    logged.push(args.map((a) => String(a)).join(' '))
  })
})
afterEach(() => spy?.mockRestore())
afterAll(() => {
  resetAuthRateLimits()
  credential = null
  authLookup = null
  userStore = null
  deleteEvent = null
  tokenStore = null
  fakeTokens.clear()
  // Hand the modules back exactly as they were found. Bun's module mocks are permanent
  // and process-global, so this is the only thing that keeps this file's fixtures from
  // becoming the next file's idea of the real implementation.
  mock.module('../src/identity-toolkit', () => identityToolkit)
  mock.module('../src/users', () => users)
  mock.module('../src/events', () => events)
  mock.module('../src/email-tokens', () => emailTokens)
  mock.module('../src/email', () => email)
})

describe('a Firestore outage inside an auth route', () => {
  test(
    "signup answers a shaped 500 instead of Hono's bare one",
    async () => {
      // Sign-up no longer creates an account (#120), so `users.ensureUser` is not the
      // seam any more. Its one Firestore write is the activation token, and that is
      // what fails here.
      tokenStore = firestoreUnavailable

      expectShapedInternalError(await signup())
    },
    FAST,
  )

  test(
    'signin answers the same shaped 500',
    async () => {
      credential = succeeds
      userStore = firestoreUnavailable

      expectShapedInternalError(await signin())
    },
    FAST,
  )

  test(
    'the body is the same whatever the thrown error said',
    async () => {
      // The two failures carry very different text — a credential URL in one, a
      // document path in the other. If any of it reached the caller, these two
      // answers could not be identical once the ref is masked.
      tokenStore = firestoreUnavailable
      const outage = await signup()
      tokenStore = firestoreNamesTheDocument
      const missing = await signup()

      const masked = (a: Answer) => a.text.replace(/[0-9a-f]{8}\)/, 'REF)')
      expect(masked(outage)).toBe(masked(missing))
      expect(masked(outage)).toBe(
        '{"error":{"code":"INTERNAL","message":"Something went wrong on our end. ' +
          'Please try again. (ref: REF)"}}',
      )
      expect(refOf(outage)).not.toBe(refOf(missing))
    },
    FAST,
  )
})

describe('what the operator gets, and what they deliberately do not', () => {
  test(
    "one line: the route, the method, the error's class and a ref — and nothing else",
    async () => {
      tokenStore = firestoreUnavailable
      const answer = await signup()

      expect(logged).toHaveLength(1)
      expect(Object.keys(line()).sort()).toEqual(['errorName', 'event', 'method', 'ref', 'route'])
      expect(line().event).toBe('unhandled_error')
      expect(line().method).toBe('POST')
      expect(line().route).toBe('/auth/signup')
      // A class name, chosen where the class is declared — not text assembled from
      // whatever the failure happened to involve.
      expect(line().errorName).toBe('FirebaseAppError')
      // The one field the caller is also given, which is the whole point of having
      // it: a user can quote the ref and it names exactly one line.
      expect(line().ref).toBe(refOf(answer))
    },
    FAST,
  )

  test(
    "the thrown error's own text reaches the log in no form at all",
    async () => {
      tokenStore = firestoreUnavailable
      await signup()
      userStore = firestoreNamesTheDocument
      await signin()

      const whole = logged.join('\n')
      expect(logged).toHaveLength(2)
      expectNoLeak(whole)
      // Not the message, and therefore not the stack either — a stack's first line
      // *is* the message, which is how the web API key would travel into a log with
      // a "just for debugging" stack (#32).
      expect(whole).not.toContain('Could not refresh')
      expect(whole).not.toContain('    at ')
      // Compared as a boolean so that a failure prints `true !== false` rather than
      // printing the key it is looking for.
      expect(whole.includes(config.firebaseWebApiKey)).toBe(false)
    },
    FAST,
  )

  test(
    'the logged route is the registered path, so no id or date is written down',
    async () => {
      // `/me/events/cycle_2026-08-27` in a log line says a named user logged a cycle
      // entry on a named day. That is the payload by another route (GUARDRAILS 12),
      // which is why the handler logs the matched route and never `c.req.path`.
      userStore = liveAccount // past the account gate, so the *route* is what throws
      deleteEvent = firestoreNamesTheDocument
      const answer = await send('DELETE', `/me/events/${EVENT_ID}?timeZone=Europe/Berlin`, {
        token: await mintToken(UID, EMAIL, 0),
      })

      expectShapedInternalError(answer)
      expect(line().route).toBe('/me/events/:id')
      expect(line().method).toBe('DELETE')
      expectNoLeak(logged.join('\n'))
    },
    FAST,
  )
})

describe('onError is the floor, not a replacement', () => {
  // Firestore throws in every case below, so if a route stopped answering for itself the
  // answer would be a shaped 500 — which is what each of these refuses to accept.
  beforeEach(() => {
    credential = succeeds
    userStore = firestoreUnavailable
    deleteEvent = firestoreNamesTheDocument
    tokenStore = null
  })

  test(
    'edge validation still answers first',
    async () => {
      const answer = await send('POST', '/auth/signup', {
        body: { email: 'not-an-address', password: PASSWORD },
      })

      expect(answer.status).toBe(400)
      expect(answer.body.error.code).toBe('VALIDATION')
    },
    FAST,
  )

  test(
    'the weak-password rule still answers first',
    async () => {
      // On activation now, not sign-up: sign-up takes no password (#120). Firestore
      // is throwing throughout this describe, so a rule that stopped answering for
      // itself would surface as a shaped 500 instead of this 400.
      await signup()
      const token = await issueFakeToken(null, EMAIL, 'activation')
      const answer = await send('POST', '/auth/activate', {
        body: { token, password: 'short' },
      })

      expect(answer.status).toBe(400)
      expect(answer.body.error.code).toBe('WEAK_PASSWORD')
    },
    FAST,
  )

  test(
    "#32's Identity Toolkit mapping still wins, with its Retry-After",
    async () => {
      // On the route that creates the account now (#120). Sign-up makes no upstream
      // call at all, so there is no mapping left for it to get wrong.
      tokenStore = null
      credential = () => {
        throw new identityToolkit.IdentityToolkitError('INTERNAL_ERROR', 500)
      }
      const answer = await signin()

      expect(answer.status).toBe(503)
      expect(answer.body.error.code).toBe('SERVICE_UNAVAILABLE')
      expect(answer.headers).toContain('retry-after')
      // #32's line, not this one — the two signals stay distinguishable.
      expect(line().event).toBe('identity_toolkit_unavailable')
      expect(logged).toHaveLength(1)
    },
    FAST,
  )

  test(
    'EMAIL_EXISTS is still 409 and a wrong password still 401',
    async () => {
      // Sign-up's 409 is now decided by reading the account rather than by an upstream
      // refusal (#120), and `users.getUser` is throwing throughout this describe — so
      // this half of the pair moved to `auth.test.ts`, where a real activated account
      // exists to be refused. What is still true here is the other half.
      tokenStore = null
      credential = () => {
        throw new identityToolkit.IdentityToolkitError('INVALID_LOGIN_CREDENTIALS', 400)
      }
      const wrong = await signin()
      expect(wrong.status).toBe(401)
      expect(wrong.body.error.code).toBe('INVALID_CREDENTIALS')
    },
    FAST,
  )

  test(
    "#5's throttle still refuses before anything can throw",
    async () => {
      const perEmail = config.rateLimit.signupPerEmail
      expect(perEmail).toBeGreaterThan(0)
      // Firestore is down for the token write, so each attempt is a shaped 500 — the
      // point being that the throttle answers before the route can throw at all.
      tokenStore = firestoreUnavailable
      for (let i = 0; i < perEmail; i++) expect((await signup()).status).toBe(500)

      const throttled = await signup()
      expect(throttled.status).toBe(429)
      expect(throttled.body.error.code).toBe('RATE_LIMITED')
    },
    FAST,
  )

  test(
    "a route's own 404 is not turned into a 500",
    async () => {
      // "No such event" is an ordinary negative answer, not a failure, and it keeps
      // its own code even though the same route can now answer INTERNAL.
      userStore = liveAccount // the gate's own throw would answer before the route
      deleteEvent = () => false
      const answer = await send('DELETE', `/me/events/${EVENT_ID}`, {
        token: await mintToken(UID, EMAIL, 0),
      })

      expect(answer.status).toBe(404)
      expect(answer.body.error.code).toBe('NOT_FOUND')
      expect(logged).toHaveLength(0)
    },
    FAST,
  )

  test(
    'a missing token is still 401',
    async () => {
      const answer = await send('DELETE', `/me/events/${EVENT_ID}`)

      expect(answer.status).toBe(401)
      expect(answer.body.error.code).toBe('UNAUTHORIZED')
    },
    FAST,
  )
})

/**
 * The two gaps #48 left, both of them a response that does not match the contract
 * ARCHITECTURE §3 states and `APIClient` decodes (#53).
 *
 * Hono calls `onError` only for `err instanceof Error` and rethrows anything else at the
 * runtime; and an unmatched path is a *miss*, not a throw, so `onError` never sees it at
 * all. Nothing in the stack throws a non-Error today, which is why the first half is a
 * guard rather than a bug fix — and why the tests below have to throw one on purpose.
 */
describe('a throw that is not an Error, and a path that is not a route', () => {
  /** Throws `value` itself — not an Error carrying it. `never` because the call site
   *  needs the same signature the Error-throwing fixtures have. */
  const throwsExactly = (value: unknown) => (): never => {
    throw value
  }

  /**
   * The reason the log line records a type and not a value. A thrown object can be
   * anything the throwing code had to hand, and in this codebase the things to hand are
   * a uid, an address, and a day somebody logged a symptom on (GUARDRAILS 12).
   *
   * **`expectNoLeak` is the weaker assertion on this object, not the stronger** — worth
   * saying, because the opposite is the natural assumption. `String({…})` is
   * `"[object Object]"`, which leaks nothing, so a stringifying implementation slips past
   * it; what it catches here is a `JSON.stringify`. The assertion carrying the claim is
   * `errorName` being exactly `NonErrorObject`, together with the exact-field-set check
   * in the first case: `ERROR_NAME` collapses anything not identifier-shaped to
   * `"unknown"`, so an implementation that put part of the value in that field fails, and
   * one that added a field to carry it fails the other.
   */
  const payloadObject = {
    uid: UID,
    email: EMAIL,
    event: EVENT_ID,
    password: PASSWORD,
    note: 'no entity to update',
  }

  test(
    'a thrown string answers exactly as a thrown Error does',
    async () => {
      tokenStore = throwsExactly('boom')

      // The same assertion the Error cases use, unchanged: same status, same two
      // keys, same message template, nothing of the throw in the bytes.
      expectShapedInternalError(await signup())
      expect(logged).toHaveLength(1)
      expect(Object.keys(line()).sort()).toEqual(['errorName', 'event', 'method', 'ref', 'route'])
      expect(line().event).toBe('unhandled_error')
      expect(line().route).toBe('/auth/signup')
    },
    FAST,
  )

  test(
    "the log line names the thrown value's type, and never the value",
    async () => {
      // A string whose content is a leak, so "records something useful about it
      // without stringifying the value" is checkable rather than asserted.
      tokenStore = throwsExactly(`14 UNAVAILABLE ${UID} ${EVENT_ID} LEAKED-KEY-48`)
      const answer = await signup()

      expect(line().errorName).toBe('NonErrorString')
      expectNoLeak(`${logged.join('\n')} ${answer.text} ${answer.headers}`)
    },
    FAST,
  )

  test(
    'a thrown object never has a property read off it',
    async () => {
      tokenStore = throwsExactly(payloadObject)
      const answer = await signup()

      expectShapedInternalError(answer)
      expect(line().errorName).toBe('NonErrorObject')
      expectNoLeak(`${logged.join('\n')} ${answer.text} ${answer.headers}`)
    },
    FAST,
  )

  test(
    'null is distinguishable from an object, which is the only reason to special-case it',
    async () => {
      // `typeof null === "object"`, so without the branch this line would be
      // indistinguishable from the one above — and "something was thrown that was
      // not an error, and it was nothing" is the most useful of these to read.
      tokenStore = throwsExactly(null)

      expectShapedInternalError(await signup())
      expect(line().errorName).toBe('NonErrorNull')
    },
    FAST,
  )

  test(
    'a refusal carries Retry-After and writes no unhandled-error line',
    async () => {
      // **Not a regression guard for the wildcard middleware**, despite sitting in
      // this describe — and the honest name matters, because the obvious name for it
      // would be a claim the next reader acts on. A 429 is a *returned* response and
      // the wrapper only has a `catch`, so there is no path by which removing the
      // middleware could fail this: it stays green with either new line deleted.
      //
      // It was written to discharge the issue's "check that it does not disturb #5's
      // throttle" criterion, and what it actually established is that the criterion's
      // premise was wrong — the throttle is not middleware, it is a call at the top of
      // each handler. Kept for the `Retry-After` assertion, which nothing else makes.
      //
      // Firestore stays down throughout, so the spending requests write nothing to the
      // real project. Asserted rather than assumed: if the mocked `issueToken` stopped
      // throwing they would be real sign-ups sending real mail, and this test would
      // still have been green.
      tokenStore = firestoreUnavailable
      const email = 'e2e+unhandled-errors-throttle@e2e.evaapp.dev'
      // From config, the way the throttle test above this one reads it. The limit is
      // env-overridable (`RATE_LIMIT_SIGNUP_PER_EMAIL`), and a hardcoded 5 would stop
      // testing the boundary the moment anyone changed it — silently, and green.
      const limit = config.rateLimit.signupPerEmail
      for (let i = 0; i < limit; i += 1) {
        expect((await signup(email)).status).toBe(500)
      }
      const spent = logged.length
      expect(spent).toBe(limit)
      const refused = await signup(email)

      expect(refused.status).toBe(429)
      expect(refused.body.error.code).toBe('RATE_LIMITED')
      expect(refused.headers.toLowerCase()).toContain('retry-after')
      // The refusal is a returned response, not a throw, so it never reached the
      // wrapper's `catch` and added no line of its own.
      expect(logged).toHaveLength(spent)
    },
    FAST,
  )

  test(
    'an unmatched path is JSON with the shape every other error has',
    async () => {
      const answer = await send('GET', '/no-such-route')

      expect(answer.status).toBe(404)
      expect(Object.keys(answer.body)).toEqual(['error'])
      expect(Object.keys(answer.body.error).sort()).toEqual(['code', 'message'])
      expect(answer.body.error.code).toBe('NOT_FOUND')
      // Hono's default is `content-type: text/plain` with a bare "404 Not Found"
      // body, which `APIClient` can only render as a status number.
      expect(answer.headers).toContain('application/json')
      expect(answer.text).not.toBe('404 Not Found')
    },
    FAST,
  )

  test(
    'an unmatched path logs nothing — it is a bad request, not a fault of ours',
    async () => {
      // And `c.req.path` is the field that would make a line useful, which is the
      // field that carries ids and dates (GUARDRAILS 12).
      await send('POST', `/me/events/${EVENT_ID}/no-such-action`, {
        token: await mintToken(UID, EMAIL, 0),
      })

      expect(logged).toHaveLength(0)
    },
    FAST,
  )

  test(
    'a wrong method on a real path is a 404 of the same shape, not a bare one',
    async () => {
      const answer = await send('GET', '/auth/signup')

      expect(answer.status).toBe(404)
      expect(answer.body.error.code).toBe('NOT_FOUND')
    },
    FAST,
  )
})

/**
 * A JSON body that is not an object (#119). `null` used to reach `body.provider` — or
 * `body.email`, or `body.appleAuthorizationCode` — and throw a `TypeError`, which this file's
 * floor answered as a 500 *and a line*: on the unauthenticated `/auth/idp`, a free way to
 * fill the one signal that is meant to mean "we shipped a bug". An array, a number or a
 * string was refused only by whichever field check a route happened to make first, and
 * `DELETE /me` made none — it read `[]` as "no Apple code" and deleted.
 *
 * Fixed once, in the shared body parse, so the list below is every route that reads a body
 * and it is asserted of all of them: a route added later that parses its own body is the
 * thing this is here to catch.
 */
describe('a JSON body that is not an object is a 400, never a 500 (#119)', () => {
  /** A live account that has also consented, so the consent-gated routes reach their
   *  handlers — the gate would otherwise answer first and prove nothing. */
  const consentingAccount = () => ({
    user: {
      ...liveAccount().user,
      consent: {
        collect: { version: 'test', at: '2026-01-01T00:00:00.000Z', withdrawnAt: null },
        share: null,
      },
    },
    tokenVersion: 0,
  })

  const ROUTES: [method: string, path: string, authenticated: boolean][] = [
    ['POST', '/auth/signup', false],
    ['POST', '/auth/signin', false],
    ['POST', '/auth/activate', false],
    ['POST', '/auth/activation/resend', false],
    ['POST', '/auth/password/forgot', false],
    ['POST', '/auth/password/reset', false],
    ['POST', '/auth/idp', false],
    ['POST', '/me/auth/providers', true],
    ['DELETE', '/me', true],
    ['PUT', '/me/consent/collect', true],
    ['PUT', '/me/questionnaire', true],
    ['PUT', '/me/nutrition-settings', true],
    ['PATCH', '/me/nutrition/profile', true],
    ['POST', '/me/events', true],
    ['PATCH', `/me/events/${EVENT_ID}`, true],
    ['PUT', '/me/body-signals/2026-08-27', true],
  ]

  const NOT_OBJECTS: unknown[] = [null, [], [{ email: EMAIL }], 5, 'x', true]

  for (const [method, path, authenticated] of ROUTES) {
    test(
      `${method} ${path}`,
      async () => {
        // Anything that got past the parse would reach one of these and throw, or — for
        // `DELETE /me` — carry on deleting; either way not the answer asserted below.
        userStore = consentingAccount
        credential = succeeds
        const token = authenticated ? await mintToken(UID, EMAIL, 0) : undefined

        for (const body of NOT_OBJECTS) {
          const answer = await send(method, path, { body, token })

          expect({ body, status: answer.status }).toEqual({ body, status: 400 })
          expect(answer.body.error.code).toBe('VALIDATION')
          expect(Object.keys(answer.body.error).sort()).toEqual(['code', 'message'])
        }
        // Not one line: no `unhandled_error`, and nothing else either.
        expect(logged).toEqual([])
      },
      FAST,
    )
  }
})

describe('a body that is absent or not JSON is still `{}` to the route (#119)', () => {
  test(
    "each route's own validation answers, in its own words",
    async () => {
      // The other half of `readBody`: only *valid* JSON that is not an object is the
      // non-object refusal. Missing and unparseable bodies reach the route as `{}`, so the
      // message is the route's, not the shared one.
      for (const body of [undefined, '{not json']) {
        const res = await server.fetch(
          new Request('http://api.test/auth/idp', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body,
          }),
        )
        const answer = (await res.json()) as Answer['body']
        expect(res.status).toBe(400)
        expect(answer.error).toEqual({
          code: 'VALIDATION',
          message: "provider must be 'apple' or 'google'",
        })
      }
      expect(logged).toEqual([])
    },
    FAST,
  )
})

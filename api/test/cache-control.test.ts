import { afterAll, afterEach, beforeEach, describe, expect, mock, spyOn, test } from 'bun:test'
import { mintToken } from '../src/auth'
import { TOKEN_LENGTH } from '../src/email-tokens'
import { IdentityToolkitError } from '../src/identity-toolkit'
import { resetAuthRateLimits } from '../src/rate-limit'

/**
 * Every response is `cache-control: no-store` unless its route says otherwise (#280).
 *
 * Three things are pinned, each by the criterion or the Risk on the issue that names it:
 *
 * 1. **The default** — on the routes that carry a session or health data, on a refusal, on
 *    an unmatched path's `404`, and on a shaped `500`. None of these routes sets the header
 *    itself, so each assertion fails the moment the app-wide middleware is gone.
 * 2. **A route's own header stands.** `/content` and `/refdata` send `private, no-cache`
 *    and an `ETag`, and answer `304` to a matching `If-None-Match`. A default that
 *    overwrote the header would pass (1) and silently break their revalidation.
 * 3. **The error path.** A non-`Error` thrown inside either link route used to answer its
 *    500 without the header, because the old per-route `noStore` set it after `await next()`
 *    and a throw skipped that line. And a response `app.onError` built is `no-store` even
 *    when the route had already set a cacheable `Cache-Control` before it threw.
 *
 * **In-process and fully mocked**, the seam `unhandled-errors.test.ts` uses: `mock.module`
 * on every module a route here would reach Firestore or Google through, and `app.fetch`
 * driven directly, never as a listening server — so this file takes no port and needs no
 * emulator, and `/content` and `/refdata` answer from a fake rather than seeded content.
 * The seeded `304` round trip is still `content.test.ts`' and `refdata.test.ts`' (the former
 * only on emulators); what this file adds is the header, which neither of them could lose
 * to this middleware without the assertions below failing first.
 *
 * Bun's module mocks are process-global and permanent, so `afterAll` hands every module
 * back exactly as it was found — see `unhandled-errors.test.ts` for why that is the file's
 * job. No default delegates to the real module: a test that forgot to say what a seam does
 * throws instead of touching the live project.
 */

// Copies, not the namespaces — see `unhandled-errors.test.ts`.
const identityToolkit = { ...(await import('../src/identity-toolkit')) }
const users = { ...(await import('../src/users')) }
const events = { ...(await import('../src/events')) }
const emailTokens = { ...(await import('../src/email-tokens')) }
const today = { ...(await import('../src/today')) }
const content = { ...(await import('../src/content')) }
const refdata = { ...(await import('../src/refdata')) }

/** Fabricated, and never written anywhere. */
const UID = 'cache-control-test-uid'
const EMAIL = 'e2e+cache-control@e2e.evaapp.dev'
const PASSWORD = 'correct-horse-8'
const VERSION = 'cachecontroltestversion'

const unset = (what: string) => (): never => {
  throw new Error(`test/cache-control.test.ts reached ${what} without setting it`)
}

/** What each seam does next. `null` is a bug in the test, never a success. */
let signIn: (() => { localId: string; email: string }) | null = null
let listed: (() => unknown[]) | null = null
let spendToken: (() => unknown) | null = null
let contentBody: (() => unknown) | null = null

const record = () => ({
  id: UID,
  email: EMAIL,
  questionnaireCompleted: false,
  profile: null,
  consent: { collect: null, marketing: null },
  passwordChosen: true,
  activated: true,
  nutritionQualitativeOnly: false,
  profileNudgeDismissed: false,
})
const account = () => ({ user: record(), tokenVersion: 0 })

mock.module('../src/identity-toolkit', () => ({
  ...identityToolkit,
  signInWithPassword: async () => (signIn ?? unset('Identity Toolkit'))(),
  federatedProvidersOf: async () => [],
}))

mock.module('../src/users', () => ({
  ...users,
  getAccount: async () => account(),
  readUser: async () => ({ deleted: false, user: record() }),
  ensureUser: async () => account(),
}))

mock.module('../src/events', () => ({
  ...events,
  listEvents: async () => (listed ?? unset('events.listEvents'))(),
}))

mock.module('../src/email-tokens', () => ({
  ...emailTokens,
  consumeToken: async () => (spendToken ?? unset('email-tokens.consumeToken'))(),
}))

mock.module('../src/today', () => ({
  ...today,
  getToday: async () => ({ date: '2026-09-25', card: null }),
}))

mock.module('../src/content', () => ({
  ...content,
  getContent: async () => (contentBody ?? unset('content.getContent'))(),
}))

mock.module('../src/refdata', () => ({
  ...refdata,
  getRefData: async () => ({ version: VERSION, catalogues: {} }),
}))

// Imported after the mocks, and never as a listening server.
const { default: server } = await import('../src/index')

const token = await mintToken(UID, EMAIL, 0)

const send = (
  method: string,
  path: string,
  init: { body?: unknown; auth?: boolean; headers?: Record<string, string> } = {},
): Promise<Response> =>
  server.fetch(
    new Request(`http://api.test${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(init.auth ? { authorization: `Bearer ${token}` } : {}),
        ...init.headers,
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    }),
  )

const expectNoStore = (res: Response) => {
  expect(res.headers.get('cache-control')).toBe('no-store')
}

/** In-process and fully mocked; the sign-in floor (350ms) is the slowest thing here. */
const FAST = 5_000

/** A well-formed link token, so the route gets as far as spending it. */
const LINK_TOKEN = 'a'.repeat(TOKEN_LENGTH)

let spy: ReturnType<typeof spyOn> | null = null

beforeEach(() => {
  resetAuthRateLimits()
  signIn = null
  listed = null
  spendToken = null
  contentBody = () => ({ version: VERSION, templates: [], banners: [], nudges: [] })
  // Several cases provoke a 500 on purpose; their `unhandled_error` line is
  // `unhandled-errors.test.ts`' subject, not noise in this run.
  spy = spyOn(console, 'error').mockImplementation(() => {})
})
afterEach(() => spy?.mockRestore())
afterAll(() => {
  resetAuthRateLimits()
  mock.module('../src/identity-toolkit', () => identityToolkit)
  mock.module('../src/users', () => users)
  mock.module('../src/events', () => events)
  mock.module('../src/email-tokens', () => emailTokens)
  mock.module('../src/today', () => today)
  mock.module('../src/content', () => content)
  mock.module('../src/refdata', () => refdata)
})

describe('no-store is the default', () => {
  test(
    'GET /me',
    async () => {
      const res = await send('GET', '/me', { auth: true })
      expect(res.status).toBe(200)
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'GET /me/events',
    async () => {
      listed = () => []
      const res = await send('GET', '/me/events?from=2026-09-01&to=2026-09-25', { auth: true })
      expect(res.status).toBe(200)
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'GET /me/today',
    async () => {
      const res = await send('GET', '/me/today?timeZone=UTC', { auth: true })
      expect(res.status).toBe(200)
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'POST /auth/signin, answering a session token',
    async () => {
      signIn = () => ({ localId: UID, email: EMAIL })
      const res = await send('POST', '/auth/signin', { body: { email: EMAIL, password: PASSWORD } })
      expect(res.status).toBe(200)
      expect(((await res.json()) as { token?: unknown }).token).toBeString()
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'POST /auth/signin, refusing',
    async () => {
      signIn = () => {
        throw new IdentityToolkitError('INVALID_LOGIN_CREDENTIALS', 400)
      }
      const res = await send('POST', '/auth/signin', { body: { email: EMAIL, password: PASSWORD } })
      expect(res.status).toBe(401)
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'a gated route refusing a missing token',
    async () => {
      const res = await send('GET', '/me')
      expect(res.status).toBe(401)
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'a path no route matches',
    async () => {
      const res = await send('GET', '/no/such/route')
      expect(res.status).toBe(404)
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe('NOT_FOUND')
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'a shaped 500',
    async () => {
      listed = () => {
        throw new Error('Firestore is down')
      }
      const res = await send('GET', '/me/events?from=2026-09-01&to=2026-09-25', { auth: true })
      expect(res.status).toBe(500)
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe('INTERNAL')
      expectNoStore(res)
    },
    FAST,
  )
})

describe("a route's own Cache-Control stands", () => {
  for (const path of ['/content', '/refdata']) {
    test(
      `${path} sends private, no-cache and its ETag`,
      async () => {
        const res = await send('GET', path, { auth: true })
        expect(res.status).toBe(200)
        expect(res.headers.get('cache-control')).toBe('private, no-cache')
        expect(res.headers.get('etag')).toBe(`"${VERSION}"`)
      },
      FAST,
    )

    test(
      `${path} still answers 304 to a matching If-None-Match, with the same headers`,
      async () => {
        const res = await send('GET', path, {
          auth: true,
          headers: { 'if-none-match': `"${VERSION}"` },
        })
        expect(res.status).toBe(304)
        expect(await res.text()).toBe('')
        expect(res.headers.get('cache-control')).toBe('private, no-cache')
        expect(res.headers.get('etag')).toBe(`"${VERSION}"`)
      },
      FAST,
    )
  }
})

describe('the error path carries no-store too', () => {
  // The gap #53 wrote down and left to this issue: a non-`Error` passed *through* the old
  // per-route `noStore` as a throw and skipped the line after its `await next()`.
  for (const path of ['/auth/activate', '/auth/password/reset']) {
    test(
      `a non-Error thrown inside ${path}`,
      async () => {
        spendToken = () => {
          throw 'boom'
        }
        const res = await send('POST', path, { body: { token: LINK_TOKEN, password: PASSWORD } })
        expect(res.status).toBe(500)
        expect(((await res.json()) as { error: { code: string } }).error.code).toBe('INTERNAL')
        expectNoStore(res)
      },
      FAST,
    )
  }

  test(
    'a non-Error thrown inside an ordinary route',
    async () => {
      listed = () => {
        throw { uid: UID }
      }
      const res = await send('GET', '/me/events?from=2026-09-01&to=2026-09-25', { auth: true })
      expect(res.status).toBe(500)
      expectNoStore(res)
    },
    FAST,
  )

  test(
    'a throw after the route set a cacheable Cache-Control still answers no-store',
    async () => {
      // `/content` sets `private, no-cache` and the `ETag` before it serialises the body, so
      // a body that cannot be serialised throws *after* the headers are on the context —
      // and `onError`'s 500 inherits them. A BigInt is the least contrived way to get there.
      contentBody = () => ({ version: VERSION, templates: [], banners: [], nudges: [], n: 1n })
      const res = await send('GET', '/content', { auth: true })
      expect(res.status).toBe(500)
      expectNoStore(res)
    },
    FAST,
  )
})

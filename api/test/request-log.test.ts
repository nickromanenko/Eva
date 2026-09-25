import { afterEach, describe, expect, spyOn, test } from 'bun:test'
import { Hono } from 'hono'
import { recordRoute, routeOf, withRequestLog } from '../src/request-log'
import { withRequestTimeout } from '../src/request-timeout'
import { isRequestLine } from './support/request-line'

/**
 * The per-request completion line (#263) and the route both request-level lines carry.
 *
 * Mostly pure — a throwaway Hono app with the same `recordRoute` registration `index.ts`
 * uses, and no Firestore and no network. The last `describe` drives the real `server.fetch`
 * on two requests that are refused before any module is reached; `nutrition-profile.test.ts`
 * and `delete-race.test.ts` also drive it and admit the line only in the exact shape pinned
 * here.
 *
 * GUARDRAILS 12 is the point of most of these cases: the line must never carry a path the
 * caller sent, because a path can hold an event id, a logged day, an address or a token.
 */

const DAY = '2026-09-25'
const EVENT_ID = 'evt-7f3a9c'
const ADDRESS = 'e2e+request-log@e2e.evaapp.dev'
const TOKEN = 'Zm9vYmFyLXRva2VuLW5vdC1hLXJlYWwtb25lLXJlYWxseQ'

const buildApp = () => {
  const app = new Hono()
  app.use('*', recordRoute)
  app.use('/auth/activate', async (c, next) => {
    // Stands in for `webCors`: literal-path middleware that answers a preflight itself.
    if (c.req.method === 'OPTIONS') return c.body(null, 204)
    await next()
  })
  app.get('/', (c) => c.text('Eva API'))
  app.post('/auth/activate', (c) => c.json({ ok: true }))
  app.put('/me/body-signals/:date', (c) => c.json({ ok: true }, 201))
  app.patch('/me/events/:id', (c) => c.json({ error: { code: 'NOT_FOUND', message: 'x' } }, 404))
  app.get('/boom', () => {
    throw new Error('boom')
  })
  app.onError((_err, c) => c.json({ error: { code: 'INTERNAL', message: 'x' } }, 500))
  return app
}

let lines: string[] = []
let spy: ReturnType<typeof spyOn> | null = null
const capture = () => {
  lines = []
  spy = spyOn(console, 'log').mockImplementation((...args: unknown[]) => {
    lines.push(args.map(String).join(' '))
  })
}
afterEach(() => {
  spy?.mockRestore()
  spy = null
})

/** A clock that advances 12.4ms between the two reads `withRequestLog` makes. */
const steppingClock = () => {
  let t = 1000
  return () => {
    const now = t
    t += 12.4
    return now
  }
}

const drive = async (method: string, path: string) => {
  const fetch = withRequestLog(buildApp().fetch, steppingClock())
  capture()
  const res = await fetch(new Request(`http://localhost${path}`, { method }))
  spy?.mockRestore()
  spy = null
  expect(lines).toHaveLength(1)
  return { res, line: JSON.parse(lines[0]!) as Record<string, unknown>, raw: lines[0]! }
}

describe('withRequestLog', () => {
  test('writes exactly { event, method, route, status, ms } for a finished request', async () => {
    const { res, line, raw } = await drive('GET', '/')
    expect(res.status).toBe(200)
    expect(line).toEqual({ event: 'request', method: 'GET', route: '/', status: 200, ms: 12 })
    // The shape the other suites admit — if this and `isRequestLine` drift, they fail here.
    expect(isRequestLine(raw)).toBe(true)
  })

  test('logs the matched pattern, never the day in the path', async () => {
    const { line, raw } = await drive('PUT', `/me/body-signals/${DAY}`)
    expect(line.route).toBe('/me/body-signals/:date')
    expect(line.status).toBe(201)
    expect(raw).not.toContain(DAY)
  })

  test('logs the matched pattern, never the event id in the path', async () => {
    const { line, raw } = await drive('PATCH', `/me/events/${EVENT_ID}`)
    expect(line).toMatchObject({ route: '/me/events/:id', status: 404 })
    expect(raw).not.toContain(EVENT_ID)
  })

  test('an unmatched path is route null — whatever the caller put in it stays out', async () => {
    const { line, raw } = await drive('GET', `/x/${encodeURIComponent(ADDRESS)}/${TOKEN}?token=${TOKEN}`)
    expect(line).toMatchObject({ route: null, status: 404 })
    expect(raw).not.toContain('e2e')
    expect(raw).not.toContain(TOKEN)
  })

  test('the query string never reaches the line', async () => {
    const { line, raw } = await drive('POST', `/auth/activate?token=${TOKEN}`)
    expect(line).toMatchObject({ route: '/auth/activate', status: 200 })
    expect(raw).not.toContain(TOKEN)
  })

  test('a preflight answered by literal-path middleware names that path', async () => {
    const { line } = await drive('OPTIONS', '/auth/activate')
    expect(line).toMatchObject({ method: 'OPTIONS', route: '/auth/activate', status: 204 })
  })

  test("app.onError's shaped 500 is the status logged", async () => {
    const { line } = await drive('GET', '/boom')
    expect(line).toMatchObject({ route: '/boom', status: 500 })
  })

  test('a handler that throws past Hono logs 500 and still throws', async () => {
    capture()
    const failing = withRequestLog(() => Promise.reject(new Error('onError itself threw')))
    await expect(failing(new Request('http://localhost/anything'))).rejects.toThrow()
    expect(lines).toHaveLength(1)
    expect(JSON.parse(lines[0]!)).toMatchObject({ event: 'request', route: null, status: 500 })
  })
})

describe('routeOf', () => {
  test('is null for a request Hono never matched', () => {
    expect(routeOf(new Request(`http://localhost/me/body-signals/${DAY}`))).toBeNull()
  })
})

describe('request_timeout carries the same route', () => {
  test('a hung request is named by its pattern, not its path', async () => {
    const app = new Hono()
    app.use('*', recordRoute)
    app.put('/me/body-signals/:date', () => new Promise<Response>(() => {}))
    const errors: string[] = []
    const errSpy = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
      errors.push(String(args[0]))
    })
    try {
      const hung = withRequestTimeout(app.fetch, 5)
      void hung(new Request(`http://localhost/me/body-signals/${DAY}`, { method: 'PUT' }))
      await Bun.sleep(30)
    } finally {
      errSpy.mockRestore()
    }
    expect(errors).toHaveLength(1)
    expect(JSON.parse(errors[0]!)).toEqual({
      event: 'request_timeout',
      method: 'PUT',
      route: '/me/body-signals/:date',
    })
    expect(errors[0]).not.toContain(DAY)
  })
})

/**
 * The real wiring in `index.ts`: `recordRoute` registered, `withRequestLog` outermost on the
 * default export. Both requests are refused before any module is reached — no bearer token,
 * and no matching route — so this touches no Firestore and needs no emulator, only the
 * configuration every suite that imports the server already needs.
 */
describe('server.fetch', () => {
  test('writes the line with the pattern for a refused request, and null for a miss', async () => {
    const { default: server } = await import('../src/index')
    capture()
    const refused = await server.fetch(
      new Request(`http://localhost/me/body-signals/${DAY}`, { method: 'PUT' }),
    )
    const missed = await server.fetch(new Request(`http://localhost/x/${TOKEN}`))
    spy?.mockRestore()
    spy = null
    expect(refused.status).toBe(401)
    expect(missed.status).toBe(404)
    expect(lines).toHaveLength(2)
    expect(lines.every(isRequestLine)).toBe(true)
    expect(JSON.parse(lines[0]!)).toMatchObject({
      method: 'PUT',
      route: '/me/body-signals/:date',
      status: 401,
    })
    expect(JSON.parse(lines[1]!)).toMatchObject({ method: 'GET', route: null, status: 404 })
    expect(lines.join('\n')).not.toContain(DAY)
    expect(lines.join('\n')).not.toContain(TOKEN)
  })
})

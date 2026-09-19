import { describe, expect, test } from 'bun:test'
import { REQUEST_TIMEOUT_MS, withRequestTimeout } from '../src/request-timeout'

/**
 * The per-request timeout that makes a hung request name itself (#225).
 *
 * Pure — the module reads no clock and touches no network, so this runs in every
 * environment. The production route races `REQUEST_TIMEOUT_MS` (10s); these cases pass a
 * short value so the timer fires in milliseconds rather than ten seconds.
 */
describe('withRequestTimeout', () => {
  const captureErrors = () => {
    const logged: string[] = []
    const original = console.error
    console.error = ((...args: unknown[]) => {
      logged.push(String(args[0]))
    }) as typeof console.error
    return { logged, restore: () => (console.error = original) }
  }

  test('a hung request names its route in the log before the kill', async () => {
    const { logged, restore } = captureErrors()
    try {
      const hung = withRequestTimeout(() => new Promise<Response>(() => {}), 5)
      void hung(new Request('http://localhost/auth/signup', { method: 'POST' }))
      await Bun.sleep(30)
    } finally {
      restore()
    }
    expect(logged).toHaveLength(1)
    expect(JSON.parse(logged[0]!)).toEqual({
      event: 'request_timeout',
      method: 'POST',
      route: '/auth/signup',
    })
  })

  test('a request that answers in time logs nothing', async () => {
    const { logged, restore } = captureErrors()
    try {
      const quick = withRequestTimeout(() => Promise.resolve(new Response('ok')), 50)
      await quick(new Request('http://localhost/health'))
    } finally {
      restore()
    }
    expect(logged).toEqual([])
  })

  test('the production timeout is not raised', () => {
    // #225: raising the timeout alone is not a fix — it turns a killed request into a slow
    // one and leaves the hang. Pin the default to Bun's own 10s so a future "just raise it"
    // fails here.
    expect(REQUEST_TIMEOUT_MS).toBe(10_000)
  })
})

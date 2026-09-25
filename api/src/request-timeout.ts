/**
 * The per-request timeout that makes a hung request name itself before it dies (#225).
 *
 * A request that has not answered this long is hung — the exact shape #225 was about: a
 * wedged Firestore call that never returned, so every route that touched the database hung
 * and the runtime's socket `idleTimeout` killed the connection with a line naming no route.
 * That made the whole thing read as an app defect. This timer logs the route just before
 * the kill, so an operator can tell which request hung from the API's log alone.
 *
 * The route is the matched *pattern* (`routeOf`, `request-log.ts`), never the path the
 * caller sent (GUARDRAILS 12): it is the one fact that says which request hung, and a
 * pattern holds no payload, address, token or id. Until #263 this logged the raw pathname,
 * which for `/me/body-signals/:date` is the day a user logged body signals.
 *
 * The value is deliberately **not** raised: a longer timeout converts a killed request into
 * a slow one and leaves the underlying hang in place. This is a diagnostic, not a fix.
 */
import { routeOf } from './request-log'

export const REQUEST_TIMEOUT_MS = 10_000

/**
 * Wraps `handler` so a request still in flight past `timeoutMs` is named in the log before
 * Bun's `idleTimeout` closes the connection. `timeoutMs` is a parameter only so a test can
 * race a short timeout rather than wait ten seconds; the route uses the default.
 */
export const withRequestTimeout = (
  handler: (request: Request) => Response | Promise<Response>,
  timeoutMs: number = REQUEST_TIMEOUT_MS,
): ((request: Request) => Promise<Response>) => {
  return async (request) => {
    const method = request.method
    // Read when the timer fires, not now: the pattern is recorded once Hono's router has
    // matched, which is after this wrapper hands the request on.
    const timer = setTimeout(() => {
      console.error(JSON.stringify({ event: 'request_timeout', method, route: routeOf(request) }))
    }, timeoutMs)
    try {
      return await handler(request)
    } finally {
      clearTimeout(timer)
    }
  }
}

import { createMiddleware } from 'hono/factory'
import { matchedRoutes } from 'hono/route'

/**
 * One line per finished request (#263): `{ event: 'request', method, route, status, ms }`.
 *
 * `request_timeout` (#225) names a request that hung; this names the fate of every other
 * one, so a failed UI suite's API log says which request answered what, and how slowly,
 * without inference. The two lines share `method` and `route`, and `route` means the same
 * thing in both — see `routeOf`.
 *
 * **`route` is the matched pattern, never the path the caller sent** (GUARDRAILS 12). The
 * raw path of `PUT /me/body-signals/2026-09-25` carries the day a user logged body signals,
 * `PATCH /me/events/:id` an event id, and an unmatched path whatever the caller typed — an
 * address, a token. The pattern is a string from this repository's source, so it can carry
 * none of those. An unmatched path is `null`, not its path. `status` and `ms` are the only
 * other fields: no payload, no header, no query string, no uid.
 *
 * **Written at the server edge, not as Hono middleware.** The middleware below only
 * *records* the pattern; `withRequestLog` wraps `app.fetch` in the default export, beside
 * `withRequestTimeout`, and writes the line. So the suites that drive `app.fetch` in-process
 * and assert that a route logs *nothing* (`nutrition-profile.test.ts`, `delete-race.test.ts`)
 * keep asserting exactly that about the route, and the status logged is the one the client
 * got — including `app.onError`'s shaped 500s, which are built inside Hono.
 *
 * `ms` is time to the `Response`, not to the last byte: `GET /me/export` streams its body
 * after headers, so its `ms` is the first page, not the whole export.
 */

/** Hono's name for `app.use` registrations — method-agnostic middleware, not a route. */
const METHOD_ALL = 'ALL'

const isWildcard = (path: string) => path === '*' || path === '/*'

/** The pattern each in-flight request matched, keyed by the `Request` Bun handed us. A
 *  `WeakMap` so an entry dies with its request and nothing here grows across requests. */
const patterns = new WeakMap<Request, string | null>()

/**
 * The matched route pattern for `request`, or `null` when no route matched (or the request
 * never reached Hono's router). Shared with `request-timeout.ts` so both lines say the same.
 */
export const routeOf = (request: Request): string | null => patterns.get(request) ?? null

/**
 * Records which route pattern the request matched. Registered first in `index.ts`, so it
 * runs before any other handler and before anything can `await` — the timeout timer can
 * therefore always read it. Matching is complete before the first handler runs, so this
 * reads the router's answer rather than inferring one; it logs nothing and holds no state
 * beyond the `WeakMap` entry, so it adds no surface on an unauthenticated, unthrottled path.
 *
 * The first matching method route is the one Hono dispatches to; `app.use` middleware with
 * a literal path (`webCors` on the link routes) is the fallback, which is what names an
 * `OPTIONS` preflight.
 */
export const recordRoute = createMiddleware(async (c, next) => {
  const matched = matchedRoutes(c).filter((r) => !isWildcard(r.path))
  const route = matched.find((r) => r.method !== METHOD_ALL) ?? matched[0]
  patterns.set(c.req.raw, route?.path ?? null)
  await next()
})

/**
 * Wraps `handler` so every request that finishes writes one `request` line to stdout.
 * `now` is a parameter only so a test can pin `ms`; the server uses `performance.now`.
 */
export const withRequestLog = (
  handler: (request: Request) => Response | Promise<Response>,
  now: () => number = () => performance.now(),
): ((request: Request) => Promise<Response>) => {
  return async (request) => {
    const started = now()
    const line = (status: number) =>
      console.log(
        JSON.stringify({
          event: 'request',
          method: request.method,
          route: routeOf(request),
          status,
          ms: Math.round(now() - started),
        }),
      )
    let response: Response
    try {
      response = await handler(request)
    } catch (err) {
      // Only `app.onError` itself throwing reaches here (see `noStoreByDefault` in
      // index.ts); Bun answers that with its own 500, which is what the client got.
      line(500)
      throw err
    }
    line(response.status)
    return response
  }
}

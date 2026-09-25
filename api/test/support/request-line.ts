/**
 * Recognises the server edge's per-request line (`request-log.ts`, #263), so a suite that
 * asserts a route logs *nothing* can keep asserting that about the route.
 *
 * Deliberately strict: a line counts only if it is exactly the five fields
 * `{ event: 'request', method, route, status, ms }` with those types — so a payload, an id
 * or an address added to the line later fails the suites that filter it here, rather than
 * slipping past them. `request-log.test.ts` pins the line itself.
 *
 * Not a test file: Bun only picks up `*.test.ts`.
 */
export const isRequestLine = (line: string): boolean => {
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    return false
  }
  if (typeof parsed !== 'object' || parsed === null) return false
  const o = parsed as Record<string, unknown>
  return (
    Object.keys(o).sort().join(',') === 'event,method,ms,route,status' &&
    o.event === 'request' &&
    typeof o.method === 'string' &&
    (o.route === null || (typeof o.route === 'string' && !o.route.includes('@'))) &&
    typeof o.status === 'number' &&
    typeof o.ms === 'number'
  )
}

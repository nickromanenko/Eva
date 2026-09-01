import { config } from './config'

/**
 * Throttling for the two unauthenticated auth routes (issue #5).
 *
 * ## The guarantee this actually gives — read this before trusting it
 *
 * Counters live in *this process's* memory. Cloud Run runs N instances, so the effective
 * limit is `limit × instances`, and every deploy, scale-up, or cold start starts the
 * windows again from zero. This raises the cost of credential stuffing and caps the
 * Identity Toolkit bill per instance; it does not bound either.
 *
 * That was chosen over a shared store deliberately: the accurate version needs Firestore
 * (a read+write on the path of every sign-in, with its own latency, cost, and failure
 * mode) or a new Redis dependency (GUARDRAILS 25). Neither is worth it for a limiter whose
 * job is to make bulk guessing expensive. To make it exact, replace `createRateLimiter`
 * with a shared-store implementation behind the same two-function surface below — nothing
 * outside this file knows where the counters live. See docs/ARCHITECTURE.md §3.
 *
 * ## Why nothing here can leak whether an account exists
 *
 * Budget is consumed **on arrival**, before the route has asked Identity Toolkit anything.
 * No function in this file receives, reads, or can read whether an address is registered,
 * so a throttled registered address and a throttled unknown one are the same code path,
 * the same counters, and the same response. `test/signin-non-enumeration.test.ts` pins it.
 *
 * The residual side channel, named rather than hidden: a *real* user signing in spends
 * their own address's budget, so an address in active use can reach the limit sooner than
 * an unused one. Reading that requires racing a live session and it moves with the
 * victim's behaviour, not with existence — it is a much weaker signal than a response that
 * simply says so, and it is inherent to per-identifier limiting rather than to this code.
 *
 * ## Never logs
 *
 * The keys are an email address and a client IP. Nothing in this file writes to the
 * console, and nothing should start (GUARDRAILS 12).
 */

export interface RateLimiter {
  /** Counts one attempt against `key`, and says whether that attempt is allowed. */
  consume(key: string): boolean
  /** Drops every counter. Test support — nothing in `src/` calls it. */
  reset(): void
}

interface Bucket {
  count: number
  /** Epoch ms at which this bucket stops counting and a fresh window begins. */
  resetAt: number
}

/**
 * Above this many live keys, new keys stop being tracked instead of old ones being
 * evicted. Eviction is precisely what a flood of invented addresses would be buying, so
 * the cap fails open for the attacker's new keys and keeps the counters that already
 * matter. Expired buckets are swept first, so reaching the cap takes genuine load.
 */
const MAX_KEYS = 50_000

/**
 * Fixed window, not sliding: a sliding window needs the timestamps of every attempt, which
 * is a longer-lived record of who tried to sign in as whom than a counter is. The cost is
 * the usual one — up to `2 × limit` attempts can land across a window boundary.
 *
 * `limit <= 0` disables the limiter entirely (`RATE_LIMIT_*=0`), which is the documented
 * escape hatch for local work.
 */
export const createRateLimiter = (
  limit: number,
  windowSeconds: number,
  now: () => number = Date.now,
): RateLimiter => {
  const windowMs = windowSeconds * 1000
  const buckets = new Map<string, Bucket>()

  const sweepExpired = (at: number): void => {
    for (const [key, bucket] of buckets) if (bucket.resetAt <= at) buckets.delete(key)
  }

  return {
    consume: (key) => {
      if (limit <= 0 || windowMs <= 0) return true

      const at = now()
      const bucket = buckets.get(key)
      if (bucket && bucket.resetAt > at) {
        bucket.count += 1
        return bucket.count <= limit
      }

      // No bucket, or the window it belonged to has passed: start a new one.
      if (!bucket && buckets.size >= MAX_KEYS) {
        sweepExpired(at)
        if (buckets.size >= MAX_KEYS) return true
      }
      buckets.set(key, { count: 1, resetAt: at + windowMs })
      return true
    },
    reset: () => buckets.clear(),
  }
}

export type AuthRoute = 'signin' | 'signup' | 'resend' | 'forgot'

/**
 * Two dimensions per route, in separate maps so an address can never collide with an IP.
 *
 * The per-IP limits are the loose backstop and the per-address limits the sharp one: iOS
 * traffic arrives through carrier NAT, where one address fronts a great many unrelated
 * users, so a tight per-IP limit would lock out bystanders.
 *
 * `resend` and `forgot` (#6) are the two routes that send an email. Their per-address
 * counter is one attempt per `resendPerEmailSeconds` — the canvas' once-per-minute Resend
 * — and their per-IP counter runs over the ordinary window. Same knobs, separate counters:
 * asking for a reset must not spend the activation Resend, and the reverse.
 */
const sendLinkLimiters = () => ({
  byIp: createRateLimiter(config.rateLimit.resendPerIp, config.rateLimit.windowSeconds),
  byEmail: createRateLimiter(1, config.rateLimit.resendPerEmailSeconds),
})

const limiters: Record<AuthRoute, { byIp: RateLimiter; byEmail: RateLimiter }> = {
  signin: {
    byIp: createRateLimiter(config.rateLimit.signinPerIp, config.rateLimit.windowSeconds),
    byEmail: createRateLimiter(config.rateLimit.signinPerEmail, config.rateLimit.windowSeconds),
  },
  signup: {
    byIp: createRateLimiter(config.rateLimit.signupPerIp, config.rateLimit.windowSeconds),
    byEmail: createRateLimiter(config.rateLimit.signupPerEmail, config.rateLimit.windowSeconds),
  },
  resend: sendLinkLimiters(),
  forgot: sendLinkLimiters(),
}

/**
 * Counts one attempt on `route` and says whether to serve it. `ip` is `null` when the
 * caller's address is unknown, which skips the per-IP dimension.
 *
 * The two routes hold separate budgets: exhausting sign-in for an address leaves sign-up
 * for it untouched, and the reverse. They defend different things — guessing a password
 * versus creating accounts — and one shared budget would let the cheaper abuse deny the
 * other route to the same person.
 *
 * IP is checked first and short-circuits, so an already-throttled IP cannot go on spending
 * a victim's per-address budget on their behalf.
 */
export const consumeAuthAttempt = (
  route: AuthRoute,
  ip: string | null,
  email: string,
): boolean => {
  const { byIp, byEmail } = limiters[route]
  if (ip !== null && !byIp.consume(ip)) return false
  return byEmail.consume(email)
}

/**
 * The `Retry-After` a throttled auth request carries: the whole window, deliberately a
 * constant rather than the time actually left on the bucket.
 *
 * A remaining-time value would differ between two throttled addresses by however many
 * milliseconds apart the caller's own requests happened to land, which would make the
 * "two branches answer with the same bytes" property depend on clock rounding instead of
 * on design. The constant over-states the wait and never under-states it.
 *
 * Per route, not per caller: the send-a-link routes answer with their per-address window,
 * which is what the canvas' toast counts down. (When it is their per-IP backstop that
 * fired, this under-states — the caller retries in a minute and is refused again. That is
 * the one exception to "never under-states", and it costs a refused request, not a leak:
 * the value still does not vary with the address.) A per-address window of `0` disables
 * that dimension, so the ordinary window is quoted instead of a zero.
 */
export const authRetryAfterSeconds = (route: AuthRoute): number =>
  route === 'resend' || route === 'forgot'
    ? config.rateLimit.resendPerEmailSeconds || config.rateLimit.windowSeconds
    : config.rateLimit.windowSeconds

/** Drops every auth counter. Test support — nothing in `src/` calls it. */
export const resetAuthRateLimits = (): void => {
  for (const route of Object.values(limiters)) {
    route.byIp.reset()
    route.byEmail.reset()
  }
}

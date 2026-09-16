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
 * #37 changed its character without removing it. Under the backoff a blocked address gives
 * back one attempt per cycle rather than `free`, so sampling "was this address used
 * recently" costs one request instead of eleven, and the answer is a yes/no rather than a
 * count. Cheaper to ask, less to learn, and still about *activity* rather than existence.
 *
 * ## Never logs
 *
 * The keys are an email address and a client IP. Nothing in this file writes to the
 * console, and nothing should start (GUARDRAILS 12).
 */

/**
 * Which `X-Forwarded-For` entry is the caller, counting from the **right** (#37).
 *
 * Exported and pure so the shape that does not exist yet can be tested before it does.
 * `hops` is `config.rateLimit.trustedProxyHops`: how many rightmost entries were appended
 * by infrastructure rather than sent by the caller.
 *
 *     hops = 1   "1.2.3.4, 35.191.0.7"              → 35.191.0.7   direct Cloud Run
 *     hops = 2   "1.2.3.4, 35.191.0.7, 130.211.0.1" → 35.191.0.7   behind a balancer
 *
 * Never the leftmost. Everything left of the infrastructure entries is whatever the caller
 * chose to send, so reading from the left would hand anyone a fresh per-IP budget per
 * request for the price of a header.
 *
 * `null` for an absent, empty or too-short header. All three skip the per-IP dimension
 * rather than bucketing every caller together: collapsing the world into one counter is an
 * outage, the per-address limit still applies, and a header shorter than configured is
 * exactly the case where choosing an entry would mean choosing one the caller controls.
 */
export const callerFromForwarded = (
  forwarded: string | undefined,
  hops: number,
): string | null => {
  if (!forwarded || hops < 1) return null
  const entries = forwarded.split(',')
  const caller = entries[entries.length - hops]?.trim() ?? ''
  return caller === '' ? null : caller
}

/**
 * What a limiter is, as data: which penalty shape it applies and the numbers it was built
 * with.
 *
 * Reported rather than inferred because the difference is invisible from `consume` alone
 * without advancing a clock, and the *wiring* is the part worth pinning. The two
 * implementations are interchangeable at the call site, so pointing sign-in's per-address
 * counter back at a fixed window is a one-line change — and `kind` alone is only a name:
 * `createBackoffLimiter(free, 1, 1, 1)` is still a backoff, and still removes the defence.
 * The settings are here so a test can pin both halves against `config.rateLimit`.
 */
export interface LimiterShape {
  readonly kind: 'window' | 'backoff'
  readonly settings: Readonly<Record<string, number>>
}

export interface RateLimiter extends LimiterShape {
  /** Counts one attempt against `key`, and says whether that attempt is allowed. */
  consume(key: string): boolean
  /** Drops `key`'s counter, if it has one. Used when the identity a key names stops
   *  existing — see `forgetEmail`. */
  forget(key: string): void
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
    kind: 'window',
    settings: { limit, windowSeconds },
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
    forget: (key) => {
      buckets.delete(key)
    },
    reset: () => buckets.clear(),
  }
}

/**
 * The per-address limiter for sign-in and sign-up (#37, decided 2026-08-29).
 *
 * ## What it replaces, and why
 *
 * A fixed window makes a lockout something an attacker **buys once**: spend
 * `signinPerEmail` requests on an address you know, and its owner is refused for the rest
 * of the window whatever they do. That is the whole cost. The per-address dimension exists
 * to stop a distributed attack on one account — every IP staying under its own limit — so
 * dropping it was rejected; what was wrong was the shape of the penalty, not the dimension.
 *
 * Here the penalty is **earned per cycle and decays on its own**:
 *
 * - The first `free` attempts are as cheap as they are today.
 * - The next one starts a block of `baseMs`. Each block that follows doubles, capped at
 *   `maxMs`.
 * - **A refused attempt changes nothing.** It does not raise the tier, does not extend the
 *   block, and does not keep the record alive. Otherwise refusing would be free lockout
 *   extension, which is the defect being fixed wearing different clothes.
 * - When a block expires the key gets **one** attempt back, not `free`. That is the number
 *   that makes both halves work: a legitimate user who was locked out by somebody else
 *   types their password once and is in, while someone guessing gets one guess per
 *   exponentially growing interval, which is what makes guessing pointless.
 * - After `decayMs` with no *served* attempt the record is forgotten entirely and the key
 *   is back to `free`. Quiet costs the owner nothing.
 *
 * ## What it costs, measured rather than asserted
 *
 * This is a trade, and the sentence "at the cap it is no worse than the window it
 * replaced" — which this comment used to make — is true of the *block length* and false of
 * everything that matters. Simulated against this code at the defaults (`free = 10`,
 * `base = 30`, cap = window = 900), an attacker holding one address out:
 *
 *     6h of denial     backoff  65 requests   fixed window  240    3.7× cheaper
 *     24h of denial    backoff 209 requests   fixed window  960    4.6× cheaper
 *
 * and with `signinPerIp = 60`, one attacker IP that could hold ~6 addresses out under the
 * window can hold ~30 under this. The lockout got cheaper. What was bought with it is on
 * the other side of the ledger: sustained guessing gets 6-9× fewer attempts (37 vs 240 over
 * six hours, 109 vs 960 over a day), and a drive-by burst costs its victim 30 seconds
 * rather than 15 minutes. In the *first* window the ramp is slightly more permissive than
 * the limiter it replaced — 14 attempts against 10 — so the guessing win is asymptotic
 * rather than immediate. The dimension itself was never the thing to remove: a distributed
 * attack on one account is what it exists to stop.
 *
 * ## The residual, stated rather than discovered later
 *
 * - **Holding an address out is a rent, not a purchase.** One served request per cycle,
 *   forever, and each one also spends the attacker's per-IP budget. Cheaper than it was,
 *   as above, but it stops the moment they do.
 * - **The victim's own retries pay it, and roughly halve it.** After a block lapses the
 *   cycle gives back one attempt, and nothing says whose. An attacker who takes it leaves
 *   the owner's next keystroke to be the request that arms the next block — so under active
 *   attack she races for one slot per cycle where the window gave her ten. The six-hour
 *   figure above falls from 65 attacker requests to 38: the per-cycle rent halves, two
 *   requests to one, while the opening burst of eleven is paid either way.
 * - **The tier is shed all at once, not gradually.** It survives until the whole record
 *   decays, so someone whose address was attacked and left alone gets *one* attempt back
 *   per cycle for as long as the residue lasts. The second attempt inside a cycle is
 *   refused whatever it carries — a typo, the right password on another device, the app
 *   retrying after a dropped connection — and it arms the *next* block, twice the last one
 *   up to the cap. A successful sign-in does not clear the record either; every served
 *   attempt pushes `forgetAt` out, so someone signing in more often than once per window
 *   never sheds the tier. "Types their password once and is in" holds for the first
 *   attempt and no further.
 * - The block always expires, and `/auth/password/forgot` is not backed off, so the reset
 *   path stays open throughout.
 *
 * Per-instance like everything else in this file, and weakened by horizontal scaling in
 * exactly the way ARCHITECTURE §3 records. A better limiter, not a guarantee.
 */
interface Penalty {
  /** Attempts served since the current allowance began. */
  used: number
  /** Blocks this key has earned. 0 means it has never been blocked. */
  tier: number
  /** Epoch ms until which attempts are refused. */
  blockedUntil: number
  /** Epoch ms at which the record is dropped, taking the tier with it. */
  forgetAt: number
}

export const createBackoffLimiter = (
  free: number,
  baseSeconds: number,
  maxSeconds: number,
  decaySeconds: number,
  now: () => number = Date.now,
): RateLimiter => {
  const baseMs = baseSeconds * 1000
  const maxMs = maxSeconds * 1000
  const decayMs = decaySeconds * 1000
  const penalties = new Map<string, Penalty>()

  const sweepForgotten = (at: number): void => {
    for (const [key, penalty] of penalties) if (penalty.forgetAt <= at) penalties.delete(key)
  }

  /** `baseMs × 2^(tier-1)`, capped. Computed rather than accumulated so a tier that somehow
   *  ran away cannot produce a block longer than the cap. */
  const blockFor = (tier: number): number =>
    Math.min(maxMs, baseMs * 2 ** Math.min(tier - 1, 30))

  return {
    kind: 'backoff',
    settings: { free, baseSeconds, maxSeconds, decaySeconds },
    consume: (key) => {
      // The disable switch, and every value that would silently amount to one. `maxMs <= 0`
      // makes every block zero-length and `decayMs <= 0` forgets each record before it can
      // be read again — both are `RATE_LIMIT_WINDOW_SECONDS=0`, the documented escape hatch
      // for local work, arriving here. Stated rather than emergent, so "the backoff is off"
      // is one condition to read instead of three behaviours to derive.
      if (free <= 0 || baseMs <= 0 || maxMs <= 0 || decayMs <= 0) return true

      const at = now()
      let penalty = penalties.get(key)
      if (penalty && penalty.forgetAt <= at) {
        penalties.delete(key)
        penalty = undefined
      }

      if (!penalty) {
        // Same fail-open-for-new-keys rule as `createRateLimiter`, and for the same reason:
        // evicting a live counter is what a flood of invented addresses would be buying.
        if (penalties.size >= MAX_KEYS) {
          sweepForgotten(at)
          if (penalties.size >= MAX_KEYS) return true
        }
        penalty = { used: 0, tier: 0, blockedUntil: 0, forgetAt: at + decayMs }
        penalties.set(key, penalty)
      }

      // Refused, and deliberately inert: no tier, no extension, no `forgetAt` refresh.
      if (penalty.blockedUntil > at) return false

      penalty.used += 1
      penalty.forgetAt = at + decayMs
      // `free` before the first block; one attempt per cycle after it.
      if (penalty.used <= (penalty.tier === 0 ? free : 1)) return true

      penalty.tier += 1
      penalty.blockedUntil = at + blockFor(penalty.tier)
      penalty.used = 0
      // Outlive the block, then decay from its end rather than from now.
      penalty.forgetAt = penalty.blockedUntil + decayMs
      return false
    },
    forget: (key) => {
      penalties.delete(key)
    },
    reset: () => penalties.clear(),
  }
}

export type AuthRoute = 'signin' | 'signup' | 'resend' | 'forgot'

/**
 * The two routes an emailed link lands on (#6). They are counted separately from
 * `AuthRoute` because they have only one dimension: a link carries a token, not an
 * address, so there is nothing per-account to count. Guessing a 256-bit token is
 * infeasible — this exists so an unauthenticated route that runs a Firestore transaction
 * per call cannot be used as a free amplifier.
 */
export type TokenRoute = 'activate' | 'reset'

/**
 * The two provider routes (#7), counted per IP and only per IP.
 *
 * There is no address to count against: the only address in the request is inside a
 * provider token we have not verified yet, so counting against it would let anyone spend
 * any user's budget by asserting their address — a lockout primitive handed out for free,
 * which is the thing the per-address counters above are careful to keep bounded. And
 * counting *after* verification would put the throttle behind the upstream call it exists
 * to protect us from paying for.
 *
 * `link` is separate from `idp` for the reason sign-in and sign-up are separate: they
 * defend different things, and exhausting one must not deny the other to the same person.
 */
export type ProviderRoute = 'idp' | 'link'

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

/** The per-address limiter for the two routes a credential attack aims at (#37). The
 *  send-link routes keep their fixed one-per-60s: that is a *cooldown* the canvas counts
 *  down, not a defence against guessing, and backing it off would make the Resend button's
 *  wait vary with how often the address had been asked for. */
const backoffByEmail = (free: number) =>
  createBackoffLimiter(
    free,
    config.rateLimit.backoffBaseSeconds,
    config.rateLimit.windowSeconds,
    config.rateLimit.windowSeconds,
  )

const limiters: Record<AuthRoute, { byIp: RateLimiter; byEmail: RateLimiter }> = {
  signin: {
    byIp: createRateLimiter(config.rateLimit.signinPerIp, config.rateLimit.windowSeconds),
    byEmail: backoffByEmail(config.rateLimit.signinPerEmail),
  },
  signup: {
    byIp: createRateLimiter(config.rateLimit.signupPerIp, config.rateLimit.windowSeconds),
    byEmail: backoffByEmail(config.rateLimit.signupPerEmail),
  },
  resend: sendLinkLimiters(),
  forgot: sendLinkLimiters(),
}

const tokenLimiters: Record<TokenRoute, RateLimiter> = {
  activate: createRateLimiter(config.rateLimit.tokenPerIp, config.rateLimit.windowSeconds),
  reset: createRateLimiter(config.rateLimit.tokenPerIp, config.rateLimit.windowSeconds),
}

const providerLimiters: Record<ProviderRoute, RateLimiter> = {
  idp: createRateLimiter(config.rateLimit.idpPerIp, config.rateLimit.windowSeconds),
  link: createRateLimiter(config.rateLimit.idpPerIp, config.rateLimit.windowSeconds),
}

/** Counts one attempt on a provider route. Per IP only — see `ProviderRoute`. */
export const consumeProviderAttempt = (route: ProviderRoute, ip: string | null): boolean =>
  ip === null || providerLimiters[route].consume(ip)

/** Counts one attempt on a link route. Per IP only — see `TokenRoute`. An unknown address
 *  (no `x-forwarded-for`) is served: the alternative is refusing every caller behind a
 *  proxy that strips it. */
export const consumeTokenAttempt = (route: TokenRoute, ip: string | null): boolean =>
  ip === null || tokenLimiters[route].consume(ip)

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
 *
 * It is also deliberately **not** the backoff's real block (#37). A tier-1 block is 30s
 * and this still says 900, because the real length is a function of how many times *this
 * address* has been blocked — quoting it would turn the header into a per-address attack
 * history readable by anyone who can send one request. The cost is real and is charged to
 * the user rather than the attacker: #38 holds the app's CTA for exactly what this says,
 * so the gentler wait the backoff gives a person locked out by someone else does not
 * reach the app until a bucketed or padded value replaces this one.
 */
export const authRetryAfterSeconds = (route: AuthRoute): number =>
  route === 'resend' || route === 'forgot'
    ? config.rateLimit.resendPerEmailSeconds || config.rateLimit.windowSeconds
    : config.rateLimit.windowSeconds

/**
 * Drops every **per-address** counter for one address, across all four auth routes (#56).
 *
 * Called when an account is deleted. Its address's attempts are counted for the length of
 * the window whether or not the account still exists, so someone who deletes and
 * immediately registers again could be refused by their own deleted account's attempts —
 * confusing in a flow people reach at an emotional moment, and protecting nothing, because
 * there is no longer an account behind that address to guess a password for.
 *
 * **Per-address only. The per-IP counters are untouched**, and that is the whole safety
 * argument: those are the backstop against someone creating and destroying accounts to
 * clear their own budget. Deleting an account gives back exactly the dimension that named
 * the account, and nothing that names the caller.
 *
 * Takes the address already normalised, as the routes' counters were keyed
 * (`normalizeEmail` at the edge). A `null` address — an Auth user with none — has nothing
 * to forget, and the caller passes it through rather than branching.
 */
export const forgetEmail = (email: string | null): void => {
  if (email === null) return
  for (const route of Object.values(limiters)) route.byEmail.forget(email)
}

/**
 * How each auth route's two dimensions are wired — the shape and the numbers. Test
 * support; nothing in `src/` calls it. See `LimiterShape` for why it reports both.
 */
export const authLimiterShapes = (): Record<
  AuthRoute,
  { byIp: LimiterShape; byEmail: LimiterShape }
> =>
  Object.fromEntries(
    Object.entries(limiters).map(([route, { byIp, byEmail }]) => [
      route,
      {
        byIp: { kind: byIp.kind, settings: byIp.settings },
        byEmail: { kind: byEmail.kind, settings: byEmail.settings },
      },
    ]),
  ) as Record<AuthRoute, { byIp: LimiterShape; byEmail: LimiterShape }>

/** Drops every auth counter, link routes included. Test support — nothing in `src/`
 *  calls it. */
export const resetAuthRateLimits = (): void => {
  for (const route of Object.values(limiters)) {
    route.byIp.reset()
    route.byEmail.reset()
  }
  for (const limiter of Object.values(tokenLimiters)) limiter.reset()
  for (const limiter of Object.values(providerLimiters)) limiter.reset()
}

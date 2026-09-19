import { afterEach, describe, expect, test } from 'bun:test'
import { config } from '../src/config'
import {
  authLimiterShapes,
  callerFromForwarded,
  consumeAuthAttempt,
  createBackoffLimiter,
  createRateLimiter,
  forgetEmail,
  resetAuthRateLimits,
} from '../src/rate-limit'

/**
 * The counter underneath the `/auth/*` throttle (issue #5), tested directly.
 *
 * The clock is injected rather than slept through: a limiter tested with real waits makes
 * the suite slower and flakier for no extra confidence, and the suite is already
 * intermittently flaky on its first cold network call (#31). Nothing in this file touches
 * the network, Firestore, or the route — `signin-non-enumeration.test.ts` covers the
 * route's half, which is where the property that actually matters lives.
 *
 * **One exception, added by #56 and worth naming because the paragraph above would
 * otherwise be wrong.** The "forgetting one address" block below uses the module's *real*
 * `limiters` — the process-global singleton — rather than a hand-cranked one, because what
 * it tests is which counters `forgetEmail` reaches, which is a property of that wiring and
 * not of `createRateLimiter`. It still touches no network and no Firestore, and it calls
 * `resetAuthRateLimits()` at the top of every case and again in `afterEach`, so it leaves
 * the shared counters empty rather than spent for whatever runs next.
 */

/** A hand-cranked clock. `advance` moves it; the limiter reads it through `now`. */
const clock = (start = 1_000_000) => {
  let ms = start
  return { now: () => ms, advance: (seconds: number) => void (ms += seconds * 1000) }
}

const WINDOW = 900

describe('the limit boundary', () => {
  test('the attempt at the limit is allowed and the next one is not', () => {
    const limiter = createRateLimiter(3, WINDOW, clock().now)

    expect(limiter.consume('key')).toBe(true) // 1
    expect(limiter.consume('key')).toBe(true) // 2
    expect(limiter.consume('key')).toBe(true) // 3 — at the limit, still served
    expect(limiter.consume('key')).toBe(false) // 4 — over
  })

  test('once over, it stays over for the rest of the window', () => {
    const time = clock()
    const limiter = createRateLimiter(1, WINDOW, time.now)

    expect(limiter.consume('key')).toBe(true)
    expect(limiter.consume('key')).toBe(false)

    time.advance(WINDOW - 1)
    expect(limiter.consume('key')).toBe(false)
  })
})

describe('the window', () => {
  test('expiring lets the caller through again', () => {
    const time = clock()
    const limiter = createRateLimiter(2, WINDOW, time.now)

    expect(limiter.consume('key')).toBe(true)
    expect(limiter.consume('key')).toBe(true)
    expect(limiter.consume('key')).toBe(false)

    time.advance(WINDOW)
    expect(limiter.consume('key')).toBe(true)
    expect(limiter.consume('key')).toBe(true)
    expect(limiter.consume('key')).toBe(false)
  })

  test('a fresh window starts at the attempt that opens it, not at the old boundary', () => {
    // Fixed window, so the second window is measured from the request that started
    // it. Pinning this stops a "sliding window" rewrite landing silently.
    const time = clock()
    const limiter = createRateLimiter(1, WINDOW, time.now)

    expect(limiter.consume('key')).toBe(true)
    time.advance(WINDOW) // window 1 over; this attempt opens window 2
    expect(limiter.consume('key')).toBe(true)

    time.advance(WINDOW - 1) // still inside window 2
    expect(limiter.consume('key')).toBe(false)
    time.advance(1)
    expect(limiter.consume('key')).toBe(true)
  })
})

describe('keys are independent', () => {
  test('exhausting one key leaves another untouched', () => {
    const limiter = createRateLimiter(1, WINDOW, clock().now)

    expect(limiter.consume('a')).toBe(true)
    expect(limiter.consume('a')).toBe(false)
    expect(limiter.consume('b')).toBe(true)
    expect(limiter.consume('b')).toBe(false)
    expect(limiter.consume('c')).toBe(true)
  })
})

describe('the disable switch', () => {
  test('a limit of 0 never throttles', () => {
    // The documented escape hatch in .env.example: RATE_LIMIT_*=0.
    const limiter = createRateLimiter(0, WINDOW, clock().now)
    for (let i = 0; i < 50; i++) expect(limiter.consume('key')).toBe(true)
  })

  test('a window of 0 never throttles either', () => {
    const limiter = createRateLimiter(5, 0, clock().now)
    for (let i = 0; i < 50; i++) expect(limiter.consume('key')).toBe(true)
  })
})

describe('reset', () => {
  test('drops every counter', () => {
    const limiter = createRateLimiter(1, WINDOW, clock().now)

    expect(limiter.consume('a')).toBe(true)
    expect(limiter.consume('a')).toBe(false)
    limiter.reset()
    expect(limiter.consume('a')).toBe(true)
  })
})

/**
 * Forgetting one address's counters when its account is deleted (#56).
 *
 * The oddity being removed: counters are keyed by address and survive the account, so
 * someone who deleted their account and registered again inside the same window could be
 * refused by their own deleted account's attempts. It resolves itself when the window
 * expires, which is up to fifteen minutes of a flow people reach at an emotional moment.
 *
 * These use the module's *real* limiters rather than a hand-cranked one, because what is
 * being tested is which counters `forgetEmail` reaches — a property of the wiring in
 * `limiters`, not of `createRateLimiter`. The shared counters are reset around each case.
 */
describe('forgetting one address', () => {
  afterEach(() => resetAuthRateLimits())

  /** Spends `count` attempts on `route` for this address, from an address-less caller so
   *  the per-IP dimension is not touched. */
  const spend = (route: 'signin' | 'signup', email: string, count: number): boolean[] =>
    Array.from({ length: count }, () => consumeAuthAttempt(route, null, email))

  test('an exhausted address is served again once it is forgotten', () => {
    resetAuthRateLimits()
    const email = 'forgotten@example.test'
    // `signinPerEmail` is 10; the eleventh is refused.
    expect(spend('signin', email, 10).every(Boolean)).toBe(true)
    expect(consumeAuthAttempt('signin', null, email)).toBe(false)

    forgetEmail(email)

    expect(consumeAuthAttempt('signin', null, email)).toBe(true)
  })

  test('it reaches every auth route, not only the one that was exhausted', () => {
    resetAuthRateLimits()
    const email = 'forgotten-everywhere@example.test'
    // Sign-up and sign-in hold separate budgets, so an account deleted after being
    // throttled on both has both to give back.
    spend('signin', email, 11)
    spend('signup', email, 6)
    expect(consumeAuthAttempt('signin', null, email)).toBe(false)
    expect(consumeAuthAttempt('signup', null, email)).toBe(false)

    forgetEmail(email)

    expect(consumeAuthAttempt('signin', null, email)).toBe(true)
    expect(consumeAuthAttempt('signup', null, email)).toBe(true)
  })

  test("another address's counters are untouched", () => {
    resetAuthRateLimits()
    const deleted = 'deleted@example.test'
    const bystander = 'bystander@example.test'
    spend('signin', deleted, 11)
    spend('signin', bystander, 11)
    expect(consumeAuthAttempt('signin', null, bystander)).toBe(false)

    forgetEmail(deleted)

    expect(consumeAuthAttempt('signin', null, bystander)).toBe(false)
  })

  test('the per-IP backstop is deliberately NOT cleared', () => {
    // The whole safety argument for this feature. If deleting an account gave back the
    // per-IP budget, creating and destroying accounts would be a way to clear one's own
    // — which is exactly the abuse that dimension exists to bound.
    resetAuthRateLimits()
    const ip = '203.0.113.7'
    const email = 'ip-holder@example.test'
    // `signupPerIp` is 30, and IP is checked first and short-circuits.
    for (let i = 0; i < 30; i += 1) consumeAuthAttempt('signup', ip, `filler-${i}@example.test`)
    expect(consumeAuthAttempt('signup', ip, email)).toBe(false)

    forgetEmail(email)

    expect(consumeAuthAttempt('signup', ip, email)).toBe(false)
  })

  test('a null address is a no-op rather than a branch at the call site', () => {
    resetAuthRateLimits()
    const email = 'still-throttled@example.test'
    spend('signin', email, 11)

    // `addressOfAuthAccount` answers null for an Auth user with no address, and
    // `DELETE /me` passes that straight through.
    expect(() => forgetEmail(null)).not.toThrow()

    expect(consumeAuthAttempt('signin', null, email)).toBe(false)
  })
})

/**
 * The per-address limiter for sign-in and sign-up (#37).
 *
 * What is being pinned is not "it refuses after N" — the fixed-window limiter above already
 * did that. It is the shape of the penalty: earned per cycle, inert while refusing, one
 * attempt back after each block, and gone after a quiet spell. Each of those is a property
 * the fixed window did not have, and each is what makes a lockout a rent rather than a
 * purchase.
 */
describe('per-address backoff', () => {
  const FREE = 3
  const BASE = 30
  const MAX = 900
  const DECAY = 900
  const limiter = (time: ReturnType<typeof clock>) =>
    createBackoffLimiter(FREE, BASE, MAX, DECAY, time.now)

  /** Spends the free allowance and the attempt that blocks. Returns the limiter. */
  const intoFirstBlock = (time: ReturnType<typeof clock>) => {
    const l = limiter(time)
    for (let i = 0; i < FREE; i += 1) expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)
    return l
  }

  test('the free attempts are as cheap as they were, and the next one blocks', () => {
    intoFirstBlock(clock())
  })

  test('a block expires on its own, and gives back exactly one attempt', () => {
    // The number that makes both halves work: a legitimate user locked out by somebody
    // else types their password once and is in; someone guessing gets one guess per
    // interval.
    const time = clock()
    const l = intoFirstBlock(time)

    time.advance(BASE - 1)
    expect(l.consume('her@example.test')).toBe(false)

    time.advance(2)
    expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)
  })

  test('each block doubles', () => {
    const time = clock()
    const l = intoFirstBlock(time)

    time.advance(BASE + 1)
    expect(l.consume('her@example.test')).toBe(true) // the one attempt back
    expect(l.consume('her@example.test')).toBe(false) // blocks again, now 2 × BASE

    time.advance(BASE + 1) // would have been enough for the first block
    expect(l.consume('her@example.test')).toBe(false)
    time.advance(BASE + 1)
    expect(l.consume('her@example.test')).toBe(true)
  })

  test('a refused attempt is inert — it does not extend the block', () => {
    // The defect being fixed, wearing different clothes: if refusing raised the tier,
    // an attacker would extend a lockout for free by being refused.
    const time = clock()
    const l = intoFirstBlock(time)

    // Hammer it throughout the block. Every one of these is refused, and none of them
    // is allowed to push the end of the block further out.
    for (let i = 0; i < BASE - 5; i += 1) {
      time.advance(1)
      expect(l.consume('her@example.test')).toBe(false)
    }

    // The block ends exactly when it was always going to, 25 refusals later.
    time.advance(6)
    expect(l.consume('her@example.test')).toBe(true)
  })

  test('and refusals do not raise the tier — the next block is the next one, not a later one', () => {
    // The other half of "inert", and the half the block-length test above cannot see:
    // a refusal that raised the tier without re-arming would leave *this* block ending
    // on time and make the *next* one exponentially longer. An attacker who can climb
    // the ladder with refused requests reaches the 15-minute cap for free, which is
    // the whole cost model inverted.
    const time = clock()
    const l = intoFirstBlock(time)

    for (let i = 0; i < BASE - 1; i += 1) {
      time.advance(1)
      expect(l.consume('her@example.test')).toBe(false)
    }

    // Out of the first block, into the second: it is tier 2, so 60s — the doubling of
    // 30, not of whatever 25 free refusals could have bought.
    time.advance(2)
    expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)

    time.advance(2 * BASE - 1)
    expect(l.consume('her@example.test')).toBe(false)
    time.advance(2)
    expect(l.consume('her@example.test')).toBe(true)
  })

  test('and refusals do not move the forget clock — at the cap that would hand back the lot', () => {
    // The clause `Penalty.forgetAt` documents, and the one a first reading gets
    // backwards. A refusal that set `forgetAt = at + decay` would move it *earlier*
    // than the `blockedUntil + decay` the block armed — and earlier is worse, not
    // harmless: the record is then dropped as the block lapses, taking the tier with
    // it, and the key is back to its full free allowance instead of the one attempt a
    // cycle is supposed to give. Measured on the shipped defaults: 10 attempts instead
    // of 1. Only visible at the cap, where `decay` is no longer longer than the block.
    const time = clock()
    const l = limiter(time)
    for (let i = 0; i < FREE; i += 1) expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)

    // Climb to the cap: 30, 60, 120, 240, 480, then 900.
    for (let block = BASE; block < MAX; block *= 2) {
      time.advance(block + 1)
      expect(l.consume('her@example.test')).toBe(true)
      expect(l.consume('her@example.test')).toBe(false)
    }

    // One refusal early in the capped block, then out the other side.
    time.advance(1)
    expect(l.consume('her@example.test')).toBe(false)
    time.advance(MAX)

    expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)
  })

  test('a served attempt pushes the decay out, so frequent use never sheds the tier', () => {
    // The other half of the record's lifetime, and the residual ARCHITECTURE §3 now
    // states: a tier is shed only by `decayMs` of silence, and every *served* attempt
    // restarts that clock. Someone signing in more often than once per window keeps
    // their tier indefinitely — which is why "the owner types their password once and
    // is in" holds for the first attempt and no further.
    const time = clock()
    const l = intoFirstBlock(time)

    // Out of the block, and take the one attempt the cycle gives back. That attempt is
    // what restarts the decay: without it the record would expire `decayMs` after the
    // block armed, one second before the assertion below.
    time.advance(BASE + 1)
    expect(l.consume('her@example.test')).toBe(true)

    // A whole decay later, minus a second. The record is still alive and still tiered,
    // so this is the second attempt of the cycle and it is refused. If the served
    // branch did not refresh `forgetAt`, the record would have just been dropped and
    // this would be the first of a fresh free allowance.
    time.advance(DECAY - 1)
    expect(l.consume('her@example.test')).toBe(false)
  })

  test('the block is capped, so at worst it is the fixed window it replaced', () => {
    const time = clock()
    const l = intoFirstBlock(time)

    // Climb far past the point where doubling would exceed the cap.
    for (let i = 0; i < 12; i += 1) {
      time.advance(MAX + 1)
      expect(l.consume('her@example.test')).toBe(true)
      expect(l.consume('her@example.test')).toBe(false)
    }
    time.advance(MAX + 1)
    expect(l.consume('her@example.test')).toBe(true)
  })

  test('quiet costs the owner nothing — the record decays and the allowance returns', () => {
    const time = clock()
    const l = intoFirstBlock(time)

    // Long enough for the block to end and the decay to run from its end.
    time.advance(BASE + DECAY + 1)

    for (let i = 0; i < FREE; i += 1) expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)
  })

  test("one address's penalty is not another's", () => {
    const time = clock()
    const l = intoFirstBlock(time)

    for (let i = 0; i < FREE; i += 1) expect(l.consume('him@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)
  })

  test('forget clears a penalty, so deleting an account still returns the budget', () => {
    // #56 calls `forget` through `forgetEmail`; the backoff limiter has to honour it
    // the same way the fixed-window one does, or a deleted address stays blocked.
    const time = clock()
    const l = intoFirstBlock(time)

    l.forget('her@example.test')

    expect(l.consume('her@example.test')).toBe(true)
  })

  test('and so does a cap of 0, the shape `RATE_LIMIT_WINDOW_SECONDS=0` reaches it as', () => {
    // `RATE_LIMIT_WINDOW_SECONDS=0` reaches this limiter as both `maxSeconds` and
    // `decaySeconds`. Only the `maxSeconds` half is falsifiable, and it is the pair
    // below that carries this test: a cap of 0 with a live decay would, without the
    // guard, count attempts, block for zero seconds, and climb a tier ladder nobody can
    // observe. The `decaySeconds = 0` rows are documentation — a record whose
    // `forgetAt` equals its creation instant is dropped by the next `consume` whether
    // the guard is there or not, so nothing about them can fail.
    for (const [maxSeconds, decaySeconds] of [
      [0, 900],
      [900, 0],
      [0, 0],
    ]) {
      const time = clock()
      const l = createBackoffLimiter(FREE, BASE, maxSeconds!, decaySeconds!, time.now)

      for (let i = 0; i < 100; i += 1) {
        time.advance(1)
        expect(l.consume('her@example.test')).toBe(true)
      }
    }
  })

  test('a free allowance of 0 disables the dimension', () => {
    const l = createBackoffLimiter(0, BASE, MAX, DECAY, clock().now)
    for (let i = 0; i < 100; i += 1) expect(l.consume('her@example.test')).toBe(true)
  })
})

/**
 * Each dimension has its own key budget (#37's third criterion).
 *
 * **The issue's premise was already false when it was filed.** It says the failure is "in
 * today's single shared map" — there has never been one: `createRateLimiter` allocates its
 * `Map` per instance, and `byIp` and `byEmail` are separate instances. Checked against the
 * original commit that introduced the file, not just against today's.
 *
 * So there is nothing to fix and something to pin. A future refactor that hoisted the map
 * to module scope to "save memory" would hand an attacker exactly the eviction tool the
 * issue was worried about, and nothing would have failed.
 */
describe('one dimension cannot starve another', () => {
  test("filling one limiter's key space leaves another's counting", () => {
    const time = clock()
    const byEmail = createRateLimiter(5, WINDOW, time.now)
    const byIp = createRateLimiter(60, WINDOW, time.now)

    // Past MAX_KEYS (50_000), where new keys stop being tracked.
    for (let i = 0; i < 50_100; i += 1) byEmail.consume(`invented-${i}@example.test`)

    for (let i = 0; i < 60; i += 1) expect(byIp.consume('203.0.113.9')).toBe(true)
    expect(byIp.consume('203.0.113.9')).toBe(false)
  })

  test('and the backoff limiter has its own budget too', () => {
    const time = clock()
    const byEmail = createBackoffLimiter(3, 30, 900, 900, time.now)
    const byIp = createRateLimiter(60, WINDOW, time.now)

    for (let i = 0; i < 50_100; i += 1) byEmail.consume(`invented-${i}@example.test`)

    for (let i = 0; i < 60; i += 1) expect(byIp.consume('203.0.113.9')).toBe(true)
    expect(byIp.consume('203.0.113.9')).toBe(false)
  })

  test('at the cap new keys stop being tracked — old ones are not evicted', () => {
    // #37 considered evicting oldest-first and rejected it, because eviction is
    // precisely what a flood of invented addresses would be buying: the attacker would
    // pay 50,000 cheap requests to clear the counter that was actually holding them.
    // The two tests above pass under either policy, so this is the one that pins it.
    const time = clock()
    const limiter = createRateLimiter(5, WINDOW, time.now)

    for (let i = 0; i < 5; i += 1) expect(limiter.consume('her@example.test')).toBe(true)

    // A flood far past MAX_KEYS, every key different, all within the same window so
    // nothing is swept.
    for (let i = 0; i < 50_100; i += 1) limiter.consume(`invented-${i}@example.test`)

    // The counter that mattered is still there. Under eviction it would be gone and
    // this would be `true`.
    expect(limiter.consume('her@example.test')).toBe(false)
  })

  test("and the backoff's map holds the same line", () => {
    // The map a flood of invented sign-in addresses actually lands in, since #37 moved
    // the two credential routes' per-address dimension onto this limiter. The case
    // above pins `createRateLimiter`, which those addresses no longer reach.
    const time = clock()
    const l = createBackoffLimiter(3, 30, 900, 900, time.now)

    for (let i = 0; i < 3; i += 1) expect(l.consume('her@example.test')).toBe(true)
    expect(l.consume('her@example.test')).toBe(false)

    for (let i = 0; i < 50_100; i += 1) l.consume(`invented-${i}@example.test`)

    // Still blocked. Under eviction her penalty would have been the price of the flood.
    expect(l.consume('her@example.test')).toBe(false)
  })
})

/**
 * Which `X-Forwarded-For` entry is counted as the caller (#37's first criterion).
 *
 * The **two-hop shape does not exist yet** — `deploy-api.yml` deploys a direct Cloud Run
 * service and the deployed API answers on its `run.app` URL with nothing in front. It is
 * tested anyway, because the criterion is about the day someone puts a load balancer there:
 * on that day the fix should be a config value whose behaviour is already proven, not a
 * guess made under pressure about which entry moved.
 *
 * Nothing here can *detect* that day. No header distinguishes "the rightmost entry is Cloud
 * Run" from "the rightmost entry is a balancer", which is exactly why the assumption is a
 * value now rather than a sentence in a comment.
 */
describe('which forwarded entry is the caller', () => {
  test('one trusted hop takes the rightmost — a direct Cloud Run service', () => {
    expect(callerFromForwarded('203.0.113.9', 1)).toBe('203.0.113.9')
    expect(callerFromForwarded('1.2.3.4, 35.191.0.7', 1)).toBe('35.191.0.7')
  })

  test('two trusted hops take the one before it — behind a load balancer', () => {
    // The balancer appends its own, so the caller sits one further left. Getting this
    // wrong collapses every caller into one bucket, which is a per-IP limit that is
    // really a global one.
    expect(callerFromForwarded('1.2.3.4, 35.191.0.7, 130.211.0.1', 2)).toBe('35.191.0.7')
  })

  test('a spoofed prefix cannot move the answer', () => {
    // Everything left of the trusted entries is whatever the caller sent. If any of it
    // could be selected, a per-IP budget would cost one header to reset.
    const spoofed = '10.0.0.1, 10.0.0.2, 10.0.0.3, 35.191.0.7'
    expect(callerFromForwarded(spoofed, 1)).toBe('35.191.0.7')
    expect(callerFromForwarded(spoofed, 2)).toBe('10.0.0.3')
  })

  test('absent, empty, or shorter than configured is null, never a guess', () => {
    expect(callerFromForwarded(undefined, 1)).toBeNull()
    expect(callerFromForwarded('', 1)).toBeNull()
    expect(callerFromForwarded('   ', 1)).toBeNull()
    // Two hops configured, one entry present: the entry that *is* there is the
    // caller's own and therefore the one thing that must not be trusted.
    expect(callerFromForwarded('1.2.3.4', 2)).toBeNull()
    expect(callerFromForwarded('1.2.3.4, 35.191.0.7', 3)).toBeNull()
  })

  test('the deployed topology is one hop, and the default says so', () => {
    // `deploy-api.yml` runs `gcloud run deploy --allow-unauthenticated` with no
    // balancer, and the app's base URL is the `run.app` host. If that changes, this is
    // the line that should change with it.
    expect(config.rateLimit.trustedProxyHops).toBe(1)
  })
})

/**
 * Which routes actually got the backoff (#37).
 *
 * The behavioural tests above drive `createBackoffLimiter` directly, and a mutation check
 * showed that is not enough: pointing sign-in's per-address counter back at
 * `createRateLimiter` left every one of them green, because the two satisfy the same
 * interface and the difference only shows when a clock moves. These are the tests that
 * fail — the name *and* the numbers, because `createBackoffLimiter(free, 1, 1, 1)` is
 * still a backoff by name and no longer a defence.
 */
/**
 * The one `RATE_LIMIT_*` value that is not a limit, and the one `0` that is not a quieter
 * setting (#37).
 *
 * `callerFromForwarded` returns `null` below one hop, `clientIp` returns `null` for every
 * request, and `consumeProviderAttempt`/`consumeTokenAttempt` both skip a null IP — so a
 * zero here does not disable "the per-IP dimension for this route", it removes per-IP
 * throttling from `/auth/idp`, `/me/auth/providers`, `/auth/activate` and
 * `/auth/password/reset`, where it is the only dimension there is. Every other knob in
 * this block documents `0` as a deliberate disable switch, which is exactly what makes it
 * a plausible thing for someone to type here meaning "no proxies in front of me".
 *
 * A subprocess, because `config.ts` reads the environment once at import and this process
 * has already imported it — the shape `config-emulators.test.ts` established.
 */
describe('a hop count below one refuses the boot', () => {
  const BASE_ENV = {
    FIREBASE_PROJECT_ID: 'demo-eva-config-test',
    FIREBASE_WEB_API_KEY: 'not-a-real-key',
    JWT_SECRET: 'not-a-real-secret',
    EMAIL_TRANSPORT: 'log',
    POSTMARK_FROM: 'config-test@example.test',
    PUBLIC_WEB_URL: 'http://localhost:4321',
  }

  const boot = async (hops: string) => {
    const proc = Bun.spawn(['bun', 'run', 'src/config.ts'], {
      cwd: `${import.meta.dir}/..`,
      env: {
        PATH: process.env.PATH ?? '',
        ...BASE_ENV,
        NODE_ENV: 'test',
        RATE_LIMIT_TRUSTED_PROXY_HOPS: hops,
      },
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
    return { code, stderr }
  }

  test('0 is refused, and says what it expected', async () => {
    const { code, stderr } = await boot('0')

    expect(code).not.toBe(0)
    expect(stderr).toContain('RATE_LIMIT_TRUSTED_PROXY_HOPS')
    expect(stderr).toContain('at least 1')
  }, 15_000)

  test('1 and 2 boot', async () => {
    for (const hops of ['1', '2']) expect((await boot(hops)).code).toBe(0)
  }, 15_000)
})

describe('the routes a credential attack aims at got the backoff', () => {
  test('sign-in and sign-up count addresses with backoff, and callers with a window', () => {
    const shapes = authLimiterShapes()

    expect(shapes.signin.byEmail.kind).toBe('backoff')
    expect(shapes.signup.byEmail.kind).toBe('backoff')
    // Per-IP stays a fixed window on purpose: carrier NAT puts many unrelated users
    // behind one address, so an escalating penalty there punishes bystanders for each
    // other's attempts. It is the loose backstop, and it should stay loose.
    expect(shapes.signin.byIp.kind).toBe('window')
    expect(shapes.signup.byIp.kind).toBe('window')
  })

  test('and with the numbers config declares, not ones that would disable it', () => {
    // A backoff built with one-second blocks passes every test above and removes the
    // defence. The arguments are the wiring too.
    const shapes = authLimiterShapes()

    expect(shapes.signin.byEmail.settings).toEqual({
      free: config.rateLimit.signinPerEmail,
      baseSeconds: config.rateLimit.backoffBaseSeconds,
      maxSeconds: config.rateLimit.windowSeconds,
      decaySeconds: config.rateLimit.windowSeconds,
    })
    expect(shapes.signup.byEmail.settings).toEqual({
      free: config.rateLimit.signupPerEmail,
      baseSeconds: config.rateLimit.backoffBaseSeconds,
      maxSeconds: config.rateLimit.windowSeconds,
      decaySeconds: config.rateLimit.windowSeconds,
    })
    expect(shapes.signin.byIp.settings).toEqual({
      limit: config.rateLimit.signinPerIp,
      windowSeconds: config.rateLimit.windowSeconds,
    })
  })

  test('the send-link routes keep their fixed cooldown', () => {
    // `resend` and `forgot` are a *cooldown* the canvas counts down — the once-per-60s
    // Resend button — not a defence against guessing. Backing it off would make the
    // button's wait vary with how often the address had been asked for, and
    // `authRetryAfterSeconds` quotes that window as a constant precisely so it cannot.
    const shapes = authLimiterShapes()

    expect(shapes.resend.byEmail.kind).toBe('window')
    expect(shapes.forgot.byEmail.kind).toBe('window')
    for (const route of ['resend', 'forgot'] as const) {
      expect(shapes[route].byEmail.settings).toEqual({
        limit: 1,
        windowSeconds: config.rateLimit.resendPerEmailSeconds,
      })
      expect(shapes[route].byIp.settings).toEqual({
        limit: config.rateLimit.resendPerIp,
        windowSeconds: config.rateLimit.windowSeconds,
      })
    }
  })
})

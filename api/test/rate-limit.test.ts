import { afterEach, describe, expect, test } from "bun:test";
import { config } from "../src/config";
import {
    authLimiterKinds,
    callerFromForwarded,
    consumeAuthAttempt,
    createBackoffLimiter,
    createRateLimiter,
    forgetEmail,
    resetAuthRateLimits,
} from "../src/rate-limit";

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
    let ms = start;
    return { now: () => ms, advance: (seconds: number) => void (ms += seconds * 1000) };
};

const WINDOW = 900;

describe("the limit boundary", () => {
    test("the attempt at the limit is allowed and the next one is not", () => {
        const limiter = createRateLimiter(3, WINDOW, clock().now);

        expect(limiter.consume("key")).toBe(true); // 1
        expect(limiter.consume("key")).toBe(true); // 2
        expect(limiter.consume("key")).toBe(true); // 3 — at the limit, still served
        expect(limiter.consume("key")).toBe(false); // 4 — over
    });

    test("once over, it stays over for the rest of the window", () => {
        const time = clock();
        const limiter = createRateLimiter(1, WINDOW, time.now);

        expect(limiter.consume("key")).toBe(true);
        expect(limiter.consume("key")).toBe(false);

        time.advance(WINDOW - 1);
        expect(limiter.consume("key")).toBe(false);
    });
});

describe("the window", () => {
    test("expiring lets the caller through again", () => {
        const time = clock();
        const limiter = createRateLimiter(2, WINDOW, time.now);

        expect(limiter.consume("key")).toBe(true);
        expect(limiter.consume("key")).toBe(true);
        expect(limiter.consume("key")).toBe(false);

        time.advance(WINDOW);
        expect(limiter.consume("key")).toBe(true);
        expect(limiter.consume("key")).toBe(true);
        expect(limiter.consume("key")).toBe(false);
    });

    test("a fresh window starts at the attempt that opens it, not at the old boundary", () => {
        // Fixed window, so the second window is measured from the request that started
        // it. Pinning this stops a "sliding window" rewrite landing silently.
        const time = clock();
        const limiter = createRateLimiter(1, WINDOW, time.now);

        expect(limiter.consume("key")).toBe(true);
        time.advance(WINDOW); // window 1 over; this attempt opens window 2
        expect(limiter.consume("key")).toBe(true);

        time.advance(WINDOW - 1); // still inside window 2
        expect(limiter.consume("key")).toBe(false);
        time.advance(1);
        expect(limiter.consume("key")).toBe(true);
    });
});

describe("keys are independent", () => {
    test("exhausting one key leaves another untouched", () => {
        const limiter = createRateLimiter(1, WINDOW, clock().now);

        expect(limiter.consume("a")).toBe(true);
        expect(limiter.consume("a")).toBe(false);
        expect(limiter.consume("b")).toBe(true);
        expect(limiter.consume("b")).toBe(false);
        expect(limiter.consume("c")).toBe(true);
    });
});

describe("the disable switch", () => {
    test("a limit of 0 never throttles", () => {
        // The documented escape hatch in .env.example: RATE_LIMIT_*=0.
        const limiter = createRateLimiter(0, WINDOW, clock().now);
        for (let i = 0; i < 50; i++) expect(limiter.consume("key")).toBe(true);
    });

    test("a window of 0 never throttles either", () => {
        const limiter = createRateLimiter(5, 0, clock().now);
        for (let i = 0; i < 50; i++) expect(limiter.consume("key")).toBe(true);
    });
});

describe("reset", () => {
    test("drops every counter", () => {
        const limiter = createRateLimiter(1, WINDOW, clock().now);

        expect(limiter.consume("a")).toBe(true);
        expect(limiter.consume("a")).toBe(false);
        limiter.reset();
        expect(limiter.consume("a")).toBe(true);
    });
});

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
describe("forgetting one address", () => {
    afterEach(() => resetAuthRateLimits());

    /** Spends `count` attempts on `route` for this address, from an address-less caller so
     *  the per-IP dimension is not touched. */
    const spend = (route: "signin" | "signup", email: string, count: number): boolean[] =>
        Array.from({ length: count }, () => consumeAuthAttempt(route, null, email));

    test("an exhausted address is served again once it is forgotten", () => {
        resetAuthRateLimits();
        const email = "forgotten@example.test";
        // `signinPerEmail` is 10; the eleventh is refused.
        expect(spend("signin", email, 10).every(Boolean)).toBe(true);
        expect(consumeAuthAttempt("signin", null, email)).toBe(false);

        forgetEmail(email);

        expect(consumeAuthAttempt("signin", null, email)).toBe(true);
    });

    test("it reaches every auth route, not only the one that was exhausted", () => {
        resetAuthRateLimits();
        const email = "forgotten-everywhere@example.test";
        // Sign-up and sign-in hold separate budgets, so an account deleted after being
        // throttled on both has both to give back.
        spend("signin", email, 11);
        spend("signup", email, 6);
        expect(consumeAuthAttempt("signin", null, email)).toBe(false);
        expect(consumeAuthAttempt("signup", null, email)).toBe(false);

        forgetEmail(email);

        expect(consumeAuthAttempt("signin", null, email)).toBe(true);
        expect(consumeAuthAttempt("signup", null, email)).toBe(true);
    });

    test("another address's counters are untouched", () => {
        resetAuthRateLimits();
        const deleted = "deleted@example.test";
        const bystander = "bystander@example.test";
        spend("signin", deleted, 11);
        spend("signin", bystander, 11);
        expect(consumeAuthAttempt("signin", null, bystander)).toBe(false);

        forgetEmail(deleted);

        expect(consumeAuthAttempt("signin", null, bystander)).toBe(false);
    });

    test("the per-IP backstop is deliberately NOT cleared", () => {
        // The whole safety argument for this feature. If deleting an account gave back the
        // per-IP budget, creating and destroying accounts would be a way to clear one's own
        // — which is exactly the abuse that dimension exists to bound.
        resetAuthRateLimits();
        const ip = "203.0.113.7";
        const email = "ip-holder@example.test";
        // `signupPerIp` is 30, and IP is checked first and short-circuits.
        for (let i = 0; i < 30; i += 1) consumeAuthAttempt("signup", ip, `filler-${i}@example.test`);
        expect(consumeAuthAttempt("signup", ip, email)).toBe(false);

        forgetEmail(email);

        expect(consumeAuthAttempt("signup", ip, email)).toBe(false);
    });

    test("a null address is a no-op rather than a branch at the call site", () => {
        resetAuthRateLimits();
        const email = "still-throttled@example.test";
        spend("signin", email, 11);

        // `addressOfAuthAccount` answers null for an Auth user with no address, and
        // `DELETE /me` passes that straight through.
        expect(() => forgetEmail(null)).not.toThrow();

        expect(consumeAuthAttempt("signin", null, email)).toBe(false);
    });
});

/**
 * The per-address limiter for sign-in and sign-up (#37).
 *
 * What is being pinned is not "it refuses after N" — the fixed-window limiter above already
 * did that. It is the shape of the penalty: earned per cycle, inert while refusing, one
 * attempt back after each block, and gone after a quiet spell. Each of those is a property
 * the fixed window did not have, and each is what makes a lockout a rent rather than a
 * purchase.
 */
describe("per-address backoff", () => {
    const FREE = 3;
    const BASE = 30;
    const MAX = 900;
    const DECAY = 900;
    const limiter = (time: ReturnType<typeof clock>) =>
        createBackoffLimiter(FREE, BASE, MAX, DECAY, time.now);

    /** Spends the free allowance and the attempt that blocks. Returns the limiter. */
    const intoFirstBlock = (time: ReturnType<typeof clock>) => {
        const l = limiter(time);
        for (let i = 0; i < FREE; i += 1) expect(l.consume("her@example.test")).toBe(true);
        expect(l.consume("her@example.test")).toBe(false);
        return l;
    };

    test("the free attempts are as cheap as they were, and the next one blocks", () => {
        intoFirstBlock(clock());
    });

    test("a block expires on its own, and gives back exactly one attempt", () => {
        // The number that makes both halves work: a legitimate user locked out by somebody
        // else types their password once and is in; someone guessing gets one guess per
        // interval.
        const time = clock();
        const l = intoFirstBlock(time);

        time.advance(BASE - 1);
        expect(l.consume("her@example.test")).toBe(false);

        time.advance(2);
        expect(l.consume("her@example.test")).toBe(true);
        expect(l.consume("her@example.test")).toBe(false);
    });

    test("each block doubles", () => {
        const time = clock();
        const l = intoFirstBlock(time);

        time.advance(BASE + 1);
        expect(l.consume("her@example.test")).toBe(true); // the one attempt back
        expect(l.consume("her@example.test")).toBe(false); // blocks again, now 2 × BASE

        time.advance(BASE + 1); // would have been enough for the first block
        expect(l.consume("her@example.test")).toBe(false);
        time.advance(BASE + 1);
        expect(l.consume("her@example.test")).toBe(true);
    });

    test("a refused attempt is inert — it does not extend the block", () => {
        // The defect being fixed, wearing different clothes: if refusing raised the tier,
        // an attacker would extend a lockout for free by being refused.
        const time = clock();
        const l = intoFirstBlock(time);

        // Hammer it throughout the block. Every one of these is refused, and none of them
        // is allowed to push the end of the block further out.
        for (let i = 0; i < BASE - 5; i += 1) {
            time.advance(1);
            expect(l.consume("her@example.test")).toBe(false);
        }

        // The block ends exactly when it was always going to, 25 refusals later.
        time.advance(6);
        expect(l.consume("her@example.test")).toBe(true);
    });

    test("the block is capped, so at worst it is the fixed window it replaced", () => {
        const time = clock();
        const l = intoFirstBlock(time);

        // Climb far past the point where doubling would exceed the cap.
        for (let i = 0; i < 12; i += 1) {
            time.advance(MAX + 1);
            expect(l.consume("her@example.test")).toBe(true);
            expect(l.consume("her@example.test")).toBe(false);
        }
        time.advance(MAX + 1);
        expect(l.consume("her@example.test")).toBe(true);
    });

    test("quiet costs the owner nothing — the record decays and the allowance returns", () => {
        const time = clock();
        const l = intoFirstBlock(time);

        // Long enough for the block to end and the decay to run from its end.
        time.advance(BASE + DECAY + 1);

        for (let i = 0; i < FREE; i += 1) expect(l.consume("her@example.test")).toBe(true);
        expect(l.consume("her@example.test")).toBe(false);
    });

    test("one address's penalty is not another's", () => {
        const time = clock();
        const l = intoFirstBlock(time);

        for (let i = 0; i < FREE; i += 1) expect(l.consume("him@example.test")).toBe(true);
        expect(l.consume("her@example.test")).toBe(false);
    });

    test("forget clears a penalty, so deleting an account still returns the budget", () => {
        // #56 calls `forget` through `forgetEmail`; the backoff limiter has to honour it
        // the same way the fixed-window one does, or a deleted address stays blocked.
        const time = clock();
        const l = intoFirstBlock(time);

        l.forget("her@example.test");

        expect(l.consume("her@example.test")).toBe(true);
    });

    test("a free allowance of 0 disables the dimension", () => {
        const l = createBackoffLimiter(0, BASE, MAX, DECAY, clock().now);
        for (let i = 0; i < 100; i += 1) expect(l.consume("her@example.test")).toBe(true);
    });
});

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
describe("one dimension cannot starve another", () => {
    test("filling one limiter's key space leaves another's counting", () => {
        const time = clock();
        const byEmail = createRateLimiter(5, WINDOW, time.now);
        const byIp = createRateLimiter(60, WINDOW, time.now);

        // Past MAX_KEYS (50_000), where new keys stop being tracked.
        for (let i = 0; i < 50_100; i += 1) byEmail.consume(`invented-${i}@example.test`);

        for (let i = 0; i < 60; i += 1) expect(byIp.consume("203.0.113.9")).toBe(true);
        expect(byIp.consume("203.0.113.9")).toBe(false);
    });

    test("and the backoff limiter has its own budget too", () => {
        const time = clock();
        const byEmail = createBackoffLimiter(3, 30, 900, 900, time.now);
        const byIp = createRateLimiter(60, WINDOW, time.now);

        for (let i = 0; i < 50_100; i += 1) byEmail.consume(`invented-${i}@example.test`);

        for (let i = 0; i < 60; i += 1) expect(byIp.consume("203.0.113.9")).toBe(true);
        expect(byIp.consume("203.0.113.9")).toBe(false);
    });
});

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
describe("which forwarded entry is the caller", () => {
    test("one trusted hop takes the rightmost — a direct Cloud Run service", () => {
        expect(callerFromForwarded("203.0.113.9", 1)).toBe("203.0.113.9");
        expect(callerFromForwarded("1.2.3.4, 35.191.0.7", 1)).toBe("35.191.0.7");
    });

    test("two trusted hops take the one before it — behind a load balancer", () => {
        // The balancer appends its own, so the caller sits one further left. Getting this
        // wrong collapses every caller into one bucket, which is a per-IP limit that is
        // really a global one.
        expect(callerFromForwarded("1.2.3.4, 35.191.0.7, 130.211.0.1", 2)).toBe("35.191.0.7");
    });

    test("a spoofed prefix cannot move the answer", () => {
        // Everything left of the trusted entries is whatever the caller sent. If any of it
        // could be selected, a per-IP budget would cost one header to reset.
        const spoofed = "10.0.0.1, 10.0.0.2, 10.0.0.3, 35.191.0.7";
        expect(callerFromForwarded(spoofed, 1)).toBe("35.191.0.7");
        expect(callerFromForwarded(spoofed, 2)).toBe("10.0.0.3");
    });

    test("absent, empty, or shorter than configured is null, never a guess", () => {
        expect(callerFromForwarded(undefined, 1)).toBeNull();
        expect(callerFromForwarded("", 1)).toBeNull();
        expect(callerFromForwarded("   ", 1)).toBeNull();
        // Two hops configured, one entry present: the entry that *is* there is the
        // caller's own and therefore the one thing that must not be trusted.
        expect(callerFromForwarded("1.2.3.4", 2)).toBeNull();
        expect(callerFromForwarded("1.2.3.4, 35.191.0.7", 3)).toBeNull();
    });

    test("the deployed topology is one hop, and the default says so", () => {
        // `deploy-api.yml` runs `gcloud run deploy --allow-unauthenticated` with no
        // balancer, and the app's base URL is the `run.app` host. If that changes, this is
        // the line that should change with it.
        expect(config.rateLimit.trustedProxyHops).toBe(1);
    });
});

/**
 * Which routes actually got the backoff (#37).
 *
 * The behavioural tests above drive `createBackoffLimiter` directly, and a mutation check
 * showed that is not enough: pointing sign-in's per-address counter back at
 * `createRateLimiter` left every one of them green, because the two satisfy the same
 * interface and the difference only shows when a clock moves. This is the test that fails.
 */
describe("the routes a credential attack aims at got the backoff", () => {
    test("sign-in and sign-up count addresses with backoff, and callers with a window", () => {
        const kinds = authLimiterKinds();

        expect(kinds.signin.byEmail).toBe("backoff");
        expect(kinds.signup.byEmail).toBe("backoff");
        // Per-IP stays a fixed window on purpose: carrier NAT puts many unrelated users
        // behind one address, so an escalating penalty there punishes bystanders for each
        // other's attempts. It is the loose backstop, and it should stay loose.
        expect(kinds.signin.byIp).toBe("window");
        expect(kinds.signup.byIp).toBe("window");
    });

    test("the send-link routes keep their fixed cooldown", () => {
        // `resend` and `forgot` are a *cooldown* the canvas counts down — the once-per-60s
        // Resend button — not a defence against guessing. Backing it off would make the
        // button's wait vary with how often the address had been asked for, and
        // `authRetryAfterSeconds` quotes that window as a constant precisely so it cannot.
        const kinds = authLimiterKinds();

        expect(kinds.resend.byEmail).toBe("window");
        expect(kinds.forgot.byEmail).toBe("window");
    });
});

import { afterEach, describe, expect, test } from "bun:test";
import {
    consumeAuthAttempt,
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

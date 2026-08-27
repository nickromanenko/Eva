import { describe, expect, test } from "bun:test";
import { createRateLimiter } from "../src/rate-limit";

/**
 * The counter underneath the `/auth/*` throttle (issue #5), tested directly.
 *
 * The clock is injected rather than slept through: a limiter tested with real waits makes
 * the suite slower and flakier for no extra confidence, and the suite is already
 * intermittently flaky on its first cold network call (#31). Nothing in this file touches
 * the network, Firestore, or the route — `signin-non-enumeration.test.ts` covers the
 * route's half, which is where the property that actually matters lives.
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

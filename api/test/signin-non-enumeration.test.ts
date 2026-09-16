import {
    afterAll,
    beforeAll,
    beforeEach,
    describe,
    expect,
    mock,
    setDefaultTimeout,
    test,
} from "bun:test";
import { FieldValue } from "firebase-admin/firestore";
import { adminAuth, firestore } from "../src/firebase";
import { config } from "../src/config";
import { resetAuthRateLimits } from "../src/rate-limit";
import { createUnactivatedAccount } from "./support/session";

/**
 * Live round trips happen in this file, so the ceiling is chosen rather than inherited
 * (#31). 20s is what every other network-touching suite sets: high enough that no honest
 * round trip reaches it, low enough that a genuine hang still fails. Every case here takes
 * it; none of them had a timeout of its own to keep.
 */
setDefaultTimeout(20_000);


/**
 * The non-enumeration property on `POST /auth/signin` (issue #21).
 *
 * A wrong password on a real account and an address that was never registered must be
 * indistinguishable from outside: same status, same code, same message, same bytes.
 * Knowing that an address has an Eva account is itself sensitive health information.
 *
 * Why this suite does not drive the real API, unlike every other file in test/:
 * Identity Toolkit currently collapses both cases into one `INVALID_LOGIN_CREDENTIALS`
 * upstream, so two live sign-in attempts prove nothing about *our* half of the property —
 * a route that interpolated `err.reason` into the message would still answer identically
 * and stay green (that is exactly what happened to the UI test in #3). The property rests
 * on two layers, upstream and ours, and only a controlled upstream can test ours.
 *
 * So `identity-toolkit.ts` is mocked to hand the route two *different* reasons for the two
 * branches — the distinct codes Google used to return before it collapsed them — and the
 * route is driven in-process through `app.fetch`. The mock is the seam rather than an
 * injected client because the route needs no injection to be correct, only to be
 * observed; `index.ts` reads better importing the module directly, as the module map
 * (ARCHITECTURE.md §3) describes it.
 *
 * The live half of the property — the upstream layer, which this file deliberately does
 * not exercise — is pinned in auth.test.ts.
 */

const identityToolkit = await import("../src/identity-toolkit");

/** The upstream failure the next signin gets, chosen from the address it was given. */
const upstreamSigninReason = (email: string): string =>
    email.includes("registered-account") ? "INVALID_PASSWORD" : "EMAIL_NOT_FOUND";

mock.module("../src/identity-toolkit", () => ({
    ...identityToolkit,
    signInWithPassword: (email: string) => {
        throw new identityToolkit.IdentityToolkitError(upstreamSigninReason(email));
    },
    signUpWithPassword: () => {
        throw new identityToolkit.IdentityToolkitError("EMAIL_EXISTS");
    },
}));

// Imported after the mock, and never as a listening server: `export default { port,
// fetch }` only serves when it is the entrypoint, so this is the route and nothing else.
const { default: server } = await import("../src/index");

// Both addresses follow the e2e+*@e2e.evaapp.dev sweep pattern (GUARDRAILS 16) out of
// habit only — the upstream is mocked, so neither account is ever created. The local
// parts are distinctive so a leak of the address is findable by substring.
/**
 * `SIGNIN_FLOOR_MS` in `src/index.ts`, restated here rather than exported.
 *
 * Exporting it would let the route and its test drift together — the constant could be
 * lowered to nothing and the assertion would follow it down. A second copy is the thing
 * that has to be changed deliberately, in the same commit, by somebody who then has to
 * say why.
 */
const SIGNIN_FLOOR_MS = 350;

const REGISTERED = "e2e+registered-account@e2e.evaapp.dev";
const UNKNOWN = "e2e+never-registered@e2e.evaapp.dev";
const PASSWORD = "correct-horse-8";

interface Answer {
    status: number;
    /** The raw bytes, not a parse of them: a leak may be anywhere in the response. */
    text: string;
    headers: string;
    error: { code: string; message: string };
}

const post = async (
    path: string,
    body: unknown,
    /** Extra request headers — `x-forwarded-for`, for the per-IP half of the throttle. */
    headers: Record<string, string> = {},
): Promise<Answer> => {
    const res = await server.fetch(
        new Request(`http://api.test${path}`, {
            method: "POST",
            headers: { "content-type": "application/json", ...headers },
            body: JSON.stringify(body),
        }),
    );
    const text = await res.text();
    return {
        status: res.status,
        text,
        headers: JSON.stringify([...res.headers]),
        error: (JSON.parse(text) as { error: { code: string; message: string } }).error,
    };
};

describe("signin does not reveal whether an address is registered", () => {
    test("a wrong password and an unknown address get the same answer", async () => {
        const wrongPassword = await post("/auth/signin", {
            email: REGISTERED,
            password: "wrong-password-1",
        });
        const unknownAddress = await post("/auth/signin", {
            email: UNKNOWN,
            password: PASSWORD,
        });

        // The upstream told the route two different things, which is the whole point.
        expect(upstreamSigninReason(REGISTERED)).not.toBe(upstreamSigninReason(UNKNOWN));

        expect(wrongPassword.status).toBe(unknownAddress.status);
        expect(wrongPassword.status).toBe(401);
        expect(wrongPassword.error.code).toBe(unknownAddress.error.code);
        expect(wrongPassword.error.code).toBe("INVALID_CREDENTIALS");
        expect(wrongPassword.error.message).toBe(unknownAddress.error.message);

        // Byte-identical, so anything the route learned upstream and passed on — in a
        // field this test does not know to look at — shows up as a difference here.
        expect(wrongPassword.text).toBe(unknownAddress.text);
        expect(wrongPassword.headers).toBe(unknownAddress.headers);
    });

    test("and both answers take at least as long as the floor (#34)", async () => {
        // Byte-identical was never time-identical: Identity Toolkit refuses an address it
        // has no record of without verifying a password hash, which measured 21.3ms faster
        // (median 29.6ms, z = 3.01) across 40 fresh addresses per branch against the real
        // project. `SIGNIN_FLOOR_MS` holds both above that difference.
        //
        // Asserted as a floor on each branch rather than as a difference between them,
        // because a difference is a measurement and would flake: what the route promises is
        // that neither branch can answer sooner than the floor, and that is what makes them
        // indistinguishable below it. `timed` returns the wall clock around one request.
        const timed = async (email: string, password: string): Promise<number> => {
            const started = Date.now();
            expect((await post("/auth/signin", { email, password })).status).toBe(401);
            return Date.now() - started;
        };

        const wrongPassword = await timed(REGISTERED, "wrong-password-2");
        const unknownAddress = await timed(UNKNOWN, PASSWORD);

        // The number is one below the constant, not the constant: `Date.now()` is measured
        // around the call and `setTimeout` is allowed to fire a millisecond early.
        for (const elapsed of [wrongPassword, unknownAddress]) {
            expect(elapsed).toBeGreaterThanOrEqual(SIGNIN_FLOOR_MS - 1);
        }
    });

    test("neither answer carries the upstream reason, the address, or the password", async () => {
        // Equality alone would not catch a leak that is identical in both branches, e.g.
        // a message that always appends "(INVALID_LOGIN_CREDENTIALS)".
        const leaks = [
            "INVALID_PASSWORD",
            "EMAIL_NOT_FOUND",
            "INVALID_LOGIN_CREDENTIALS",
            "Identity Toolkit", // the IdentityToolkitError message prefix
            "registered-account",
            "never-registered",
            "evaapp.dev",
            "correct-horse",
            "wrong-password",
        ];

        for (const [email, password] of [
            [REGISTERED, "wrong-password-1"],
            [UNKNOWN, PASSWORD],
        ] as const) {
            const answer = await post("/auth/signin", { email, password });
            const whole = `${answer.text} ${answer.headers}`.toLowerCase();
            for (const leak of leaks) {
                expect(whole).not.toContain(leak.toLowerCase());
            }
        }
    });
});

/**
 * The mirror image, deliberately: `POST /auth/signup` *does* tell you the address is
 * taken, and must keep doing so.
 *
 * The two routes are inconsistent on purpose. Signup already reveals nothing new — the
 * person is holding the address and asking to register it — while the canvas' account-
 * linking banner ("this email is already registered, sign in instead") depends on being
 * able to say so. Signin has no such excuse: there, the caller may be anybody.
 *
 * If you are here to make the two routes agree, this is the note saying don't.
 */
/**
 * A real, **activated** account, because that is now what sign-up's 409 means (#120).
 * It used to come from Identity Toolkit refusing `accounts:signUp`, which this file's
 * mock could fabricate. Sign-up creates nothing now, so the refusal is decided by
 * reading the account — and an address with no activated owner is one anybody may still
 * claim, which is the denial-of-service half #120 closes.
 */
let takenUid: string | null = null;

beforeAll(async () => {
    // **Delete-first, because the address is fixed rather than a fresh uuid.** An
    // interrupted run — a killed `bun run verify`, a failure before `afterAll` — leaves this
    // account behind against the real project, and the next run's `createUser` then throws
    // `email-already-exists` and takes the whole file red for a reason that has nothing to
    // do with what it tests. A stale account is exactly as good as no account here, so it is
    // cleared rather than worked around.
    const stale = await adminAuth.getUserByEmail(REGISTERED).catch(() => null);
    if (stale) {
        await firestore.collection("users").doc(stale.uid).delete().catch(() => {});
        await adminAuth.deleteUser(stale.uid).catch(() => {});
    }
    const { uid } = await adminAuth.createUser({
        email: REGISTERED,
        password: PASSWORD,
        emailVerified: true,
    });
    takenUid = uid;
    await firestore.collection("users").doc(uid).set({
        email: REGISTERED,
        authProviders: ["password"],
        questionnaireCompleted: false,
        profile: null,
        activatedAt: FieldValue.serverTimestamp(),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
    });
});

afterAll(async () => {
    if (!takenUid) return;
    await firestore.collection("users").doc(takenUid).delete().catch(() => {});
    await adminAuth.deleteUser(takenUid).catch(() => {});
});


describe("signup deliberately does distinguish a taken address", () => {
    test("a registered address is 409 EMAIL_EXISTS, not the combined message", async () => {
        const res = await post("/auth/signup", { email: REGISTERED });
        expect(res.status).toBe(409);
        expect(res.error.code).toBe("EMAIL_EXISTS");
        expect(res.error.code).not.toBe("INVALID_CREDENTIALS");
    });

    test("an address whose only account is unproven is not taken", async () => {
        // The other side, and the reason the 409 now reads the account rather than trusting
        // that one exists: a reservation nobody has proved is not ownership, so the person
        // whose address it actually is can still sign up.
        //
        // **An Auth user with no document, which is not the shape that matters.** Anything
        // created outside the API looks like this, and `readUser` answers `{ user: null }`
        // for it — so the gate's condition is never evaluated in either direction, and
        // widening it from `existing.user?.activated` to `existing.user` left this test
        // green. The case below is the one with teeth.
        const unproven = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
        const { uid } = await adminAuth.createUser({ email: unproven, password: PASSWORD });
        try {
            const res = await post("/auth/signup", { email: unproven });
            expect(res.status).toBe(201);
        } finally {
            await adminAuth.deleteUser(uid).catch(() => {});
        }
    });

    test("a pre-#120 account that never activated can still ask for a link", async () => {
        // The population this actually protects, and the only one where the gate's condition
        // is reached: an account made by `POST /auth/signup` *before* #120 — a document, a
        // password, and `activatedAt: null` — whose owner never clicked the link. Sign-up is
        // the route that re-issues it, so a `409` here strands them with no way back in.
        const stranded = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
        const uid = await createUnactivatedAccount(stranded, PASSWORD);
        try {
            const res = await post("/auth/signup", { email: stranded });
            expect(res.status).toBe(201);
        } finally {
            await firestore.collection("users").doc(uid).delete().catch(() => {});
            await adminAuth.deleteUser(uid).catch(() => {});
        }
    });
});

/**
 * The `/auth/*` throttle (issue #5), and the trap it sets for the property above.
 *
 * A per-address limiter is exactly the shape of thing that re-opens the enumeration hole
 * #21 closed. If a registered address were throttled on a different schedule from an
 * unregistered one — a different count, a different status, a different `Retry-After` —
 * then the limiter would answer the question that the response body no longer does, and
 * the answer would be just as usable. So the throttled answers are compared the same way
 * the 401s are: byte for byte, headers included.
 *
 * The counts come from `config`, not from literals, so the tests describe the boundary
 * wherever it is set rather than pinning today's default a second time.
 */

const SIGNIN_PER_EMAIL = config.rateLimit.signinPerEmail;
const SIGNIN_PER_IP = config.rateLimit.signinPerIp;
const SIGNUP_PER_EMAIL = config.rateLimit.signupPerEmail;

/** Signs in `times` times and hands back every answer, in order. */
const signinRepeatedly = async (
    email: string,
    times: number,
    headers: Record<string, string> = {},
): Promise<Answer[]> => {
    const answers: Answer[] = [];
    for (let i = 0; i < times; i++) {
        answers.push(await post("/auth/signin", { email, password: PASSWORD }, headers));
    }
    return answers;
};

describe("throttling does not reintroduce the enumeration leak", () => {
    beforeEach(() => resetAuthRateLimits());
    afterAll(() => resetAuthRateLimits());

    test("a throttled registered address and a throttled unknown one answer identically", async () => {
        // A limit of 0 disables the throttle, which would make everything below pass
        // without testing anything. Fail loudly instead.
        expect(SIGNIN_PER_EMAIL).toBeGreaterThan(0);

        const registered = await signinRepeatedly(REGISTERED, SIGNIN_PER_EMAIL + 1);
        const unknown = await signinRepeatedly(UNKNOWN, SIGNIN_PER_EMAIL + 1);

        // The upstream is still telling the route two different things throughout.
        expect(upstreamSigninReason(REGISTERED)).not.toBe(upstreamSigninReason(UNKNOWN));

        // Both cross the boundary at the same attempt: the first SIGNIN_PER_EMAIL are
        // served and answered 401, and only the one after that is refused.
        for (let i = 0; i < SIGNIN_PER_EMAIL; i++) {
            expect(registered[i]!.status).toBe(401);
            expect(unknown[i]!.status).toBe(401);
        }

        const throttledRegistered = registered[SIGNIN_PER_EMAIL]!;
        const throttledUnknown = unknown[SIGNIN_PER_EMAIL]!;
        expect(throttledRegistered.status).toBe(429);
        expect(throttledUnknown.status).toBe(429);

        // The same comparison the 401 branch gets: same bytes, same headers. A
        // `Retry-After` computed from what is left on the bucket would land here.
        expect(throttledRegistered.text).toBe(throttledUnknown.text);
        expect(throttledRegistered.headers).toBe(throttledUnknown.headers);
    });

    test("the throttled answer carries no address and no upstream reason", async () => {
        // Equality alone would miss a leak that is present in both branches — a message
        // that helpfully names the address being throttled, say.
        const leaks = [
            "INVALID_PASSWORD",
            "EMAIL_NOT_FOUND",
            "INVALID_LOGIN_CREDENTIALS",
            "Identity Toolkit",
            "registered-account",
            "never-registered",
            "evaapp.dev",
            "correct-horse",
        ];

        for (const email of [REGISTERED, UNKNOWN]) {
            const answers = await signinRepeatedly(email, SIGNIN_PER_EMAIL + 1);
            const throttled = answers[SIGNIN_PER_EMAIL]!;
            expect(throttled.status).toBe(429);

            const whole = `${throttled.text} ${throttled.headers}`.toLowerCase();
            for (const leak of leaks) expect(whole).not.toContain(leak.toLowerCase());
        }
    });
});

describe("the /auth/* throttle", () => {
    beforeEach(() => resetAuthRateLimits());
    afterAll(() => resetAuthRateLimits());

    test("the refusal is 429 in the standard error shape, with the additive code", async () => {
        const answers = await signinRepeatedly(REGISTERED, SIGNIN_PER_EMAIL + 1);
        const throttled = answers[SIGNIN_PER_EMAIL]!;

        expect(throttled.status).toBe(429);
        expect(throttled.error.code).toBe("RATE_LIMITED");
        expect(throttled.error.message).toBeTypeOf("string");
        expect(throttled.error.message.length).toBeGreaterThan(0);
        // The shape is `{ error: { code, message } }` and nothing else (GUARDRAILS 11).
        expect(Object.keys(JSON.parse(throttled.text))).toEqual(["error"]);
        expect(Object.keys(throttled.error).sort()).toEqual(["code", "message"]);
    });

    test("Retry-After is the whole window, so it is a constant across callers", async () => {
        const registered = await signinRepeatedly(REGISTERED, SIGNIN_PER_EMAIL + 1);
        const unknown = await signinRepeatedly(UNKNOWN, SIGNIN_PER_EMAIL + 1);

        const retryAfter = (answer: Answer) =>
            (JSON.parse(answer.headers) as [string, string][]).find(
                ([name]) => name.toLowerCase() === "retry-after",
            )?.[1];

        expect(retryAfter(registered[SIGNIN_PER_EMAIL]!)).toBe(
            String(config.rateLimit.windowSeconds),
        );
        expect(retryAfter(registered[SIGNIN_PER_EMAIL]!)).toBe(
            retryAfter(unknown[SIGNIN_PER_EMAIL]!),
        );
    });

    test("throttling one address does not throttle another", async () => {
        const exhausted = await signinRepeatedly(REGISTERED, SIGNIN_PER_EMAIL + 1);
        expect(exhausted[SIGNIN_PER_EMAIL]!.status).toBe(429);

        const bystander = await post("/auth/signin", { email: UNKNOWN, password: PASSWORD });
        expect(bystander.status).toBe(401);
    });

    test("signup and signin hold separate budgets for the same address", async () => {
        // Pinning the choice, not discovering it: the two routes defend different things,
        // so exhausting one must leave the other alone. See src/rate-limit.ts.
        const signins = await signinRepeatedly(REGISTERED, SIGNIN_PER_EMAIL + 1);
        expect(signins[SIGNIN_PER_EMAIL]!.status).toBe(429);

        // 409, because the address has an activated owner (#120) — the point is that it
        // was served at all rather than refused by sign-in's exhausted counter.
        const signup = await post("/auth/signup", { email: REGISTERED });
        expect(signup.status).toBe(409);
        expect(signup.error.code).toBe("EMAIL_EXISTS");

        // And the reverse direction, on its own budget.
        expect(SIGNUP_PER_EMAIL).toBeGreaterThan(0);
        for (let i = 1; i < SIGNUP_PER_EMAIL; i++) {
            expect((await post("/auth/signup", { email: REGISTERED })).status)
                .toBe(409);
        }
        const overSignup = await post("/auth/signup", { email: REGISTERED });
        expect(overSignup.status).toBe(429);
        expect(overSignup.error.code).toBe("RATE_LIMITED");
    });

    test("the per-IP limit catches one caller sweeping many addresses", async () => {
        expect(SIGNIN_PER_IP).toBeGreaterThan(0);
        const ip = { "x-forwarded-for": "203.0.113.7" };

        // A different address every time, so the per-address counters never fire and the
        // only thing that can refuse this is the per-IP one.
        for (let i = 0; i < SIGNIN_PER_IP; i++) {
            const answer = await post(
                "/auth/signin",
                { email: `e2e+sweep-${i}@e2e.evaapp.dev`, password: PASSWORD },
                ip,
            );
            expect(answer.status).toBe(401);
        }

        const over = await post(
            "/auth/signin",
            { email: "e2e+sweep-last@e2e.evaapp.dev", password: PASSWORD },
            ip,
        );
        expect(over.status).toBe(429);
        expect(over.error.code).toBe("RATE_LIMITED");

        // A different caller is unaffected.
        const elsewhere = await post(
            "/auth/signin",
            { email: "e2e+sweep-last@e2e.evaapp.dev", password: PASSWORD },
            { "x-forwarded-for": "198.51.100.4" },
        );
        expect(elsewhere.status).toBe(401);
        // 60 sequential sign-ins, each held to `SIGNIN_FLOOR_MS` by the route (#34), so
        // this case cannot finish inside the file's 20s default any more. The cost is the
        // floor's, not this test's: it is the same 60 requests it always made.
    }, 60_000);

    test("a forged X-Forwarded-For prefix does not buy a fresh per-IP budget", async () => {
        // Cloud Run appends the address it accepted the connection from, so the rightmost
        // entry is the one the caller could not choose. Reading the leftmost instead would
        // make the per-IP limit bypassable with a request header, which is the whole
        // reason src/index.ts reads from the right.
        const ip = { "x-forwarded-for": "203.0.113.7" };
        for (let i = 0; i < SIGNIN_PER_IP + 1; i++) {
            await post(
                "/auth/signin",
                { email: `e2e+forge-${i}@e2e.evaapp.dev`, password: PASSWORD },
                ip,
            );
        }

        const forged = await post(
            "/auth/signin",
            { email: "e2e+forge-last@e2e.evaapp.dev", password: PASSWORD },
            { "x-forwarded-for": "10.0.0.1, 203.0.113.7" },
        );
        expect(forged.status).toBe(429);
        // Same 61 sequential requests, same reason for the raised ceiling as above.
    }, 60_000);
});

import { afterAll, afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { issueToken } from "../src/email-tokens";
import { adminAuth, firestore } from "../src/firebase";
import { resetAuthRateLimits } from "../src/rate-limit";

/**
 * What both auth routes answer when Identity Toolkit fails for any reason other than
 * "that address is taken" (issue #32).
 *
 * Before this, `/auth/signup` handled `EMAIL_EXISTS` and rethrew the rest, so a Google-side
 * `INVALID_EMAIL`, a quota refusal, or an outage left Hono to answer — a bare 500 with no
 * `{ error: { code, message } }` at all, which the iOS client can only render as
 * "Something went wrong (500)". Every upstream problem looked exactly like a bug in our
 * own server, to the user and to whoever was on call.
 *
 * The seam is the one `signin-non-enumeration.test.ts` established: `mock.module` on
 * `../src/identity-toolkit`, and the route driven in-process through `app.fetch`. Faking
 * the boundary is the only way to reach these branches at all — the real project cannot be
 * made to return `INVALID_EMAIL` for an address our own edge validation accepted, and it
 * certainly cannot be made to have an outage on demand.
 *
 * **The `mock.module` caveat, stated because it constrains this file.** Bun's module mocks
 * are process-global and permanent: they replace the live bindings every already-imported
 * module sees, and they are not scoped to the file that installed them. `bun test` runs
 * test files sequentially, so this file and `signin-non-enumeration.test.ts` each hold the
 * mock only while their own tests run — but the last one loaded leaves its mock installed
 * for the rest of the process, and both files share one cached `src/index` and therefore
 * one set of rate-limit counters. Hence: this file dispatches through a mutable `upstream`
 * that each test sets, rather than baking a fixed failure into the mock; it uses addresses
 * that appear in no other suite; and it resets the throttle before every test and after the
 * last, so whichever order the two files run in, neither spends the other's budget.
 */

const identityToolkit = await import("../src/identity-toolkit");
const { IdentityToolkitError } = identityToolkit;

// Captured as a value *before* the mock below replaces the module's bindings, so the last
// describe in this file can exercise the real client against a stubbed `fetch` while the
// route tests see the mock. Reading it off the namespace later would get the mock instead.
const realSignUp = identityToolkit.signUpWithPassword;

/** The failure the next call gets. Every test sets one; reaching the route without one
 *  set is a bug in the test, not a success path — this file never exercises one. */
let upstream: (() => never) | null = null;

const noUpstreamSet = (): never => {
    throw new Error("test reached Identity Toolkit without setting `upstream`");
};

mock.module("../src/identity-toolkit", () => ({
    ...identityToolkit,
    signInWithPassword: () => (upstream ?? noUpstreamSet)(),
    signUpWithPassword: () => (upstream ?? noUpstreamSet)(),
    // Where an account is created now (#120). Sign-up creates nothing and never reaches
    // Identity Toolkit at all, so #32's guarantee — an upstream failure is a shaped answer,
    // never Hono's bare 500 — has to be pinned here instead. It is the same guarantee about
    // a different call.
    createProvenAccount: () => (upstream ?? noUpstreamSet)(),
    // Left real: activation looks the address up before creating, and a fake that failed
    // would send every case down the claim branch instead of the create branch.
    findAuthUidByEmail: identityToolkit.findAuthUidByEmail,
}));

// Imported after the mock, and never as a listening server.
const { default: server } = await import("../src/index");

// The failures are built the way `identity-toolkit.ts` builds them — a reason and the
// upstream status — and left to classify themselves, so these fakes cannot drift into
// asserting a classification the live call would not have made.

/** Google refuses the request itself: a 400 carrying one of its reason strings. */
const rejects = (reason: string) => () => {
    throw new IdentityToolkitError(reason, 400);
};

/** Google could not answer: its own 500. The reason string is whatever came back. */
const isDown = () => {
    throw new IdentityToolkitError("INTERNAL_ERROR", 500);
};

/** The request never landed — DNS, refused connection, timeout. No upstream status. */
const unreachable = () => {
    throw new IdentityToolkitError("NETWORK_FAILURE", null, "unavailable");
};

/** Load-shedding: a 4xx that means "not now" rather than "not ever". */
const shedsLoad = () => {
    throw new IdentityToolkitError("TOO_MANY_ATTEMPTS_TRY_LATER", 400);
};

// Distinctive local parts, so a leak of the address into a body, a header, or a log line
// is findable by substring. Under the e2e sweep pattern (GUARDRAILS 16) out of habit only
// — the upstream is mocked, so no account is ever created.
const REGISTERED = "e2e+upstream-registered@e2e.evaapp.dev";
const UNKNOWN = "e2e+upstream-unknown@e2e.evaapp.dev";
const PASSWORD = "correct-horse-8";

interface Answer {
    status: number;
    /** The raw bytes, not a parse of them: a leak may be anywhere in the response. */
    text: string;
    headers: string;
    retryAfter: string | undefined;
    body: unknown;
}

const post = async (path: string, body: unknown): Promise<Answer> => {
    const res = await server.fetch(
        new Request(`http://api.test${path}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
        }),
    );
    const text = await res.text();
    return {
        status: res.status,
        text,
        headers: JSON.stringify([...res.headers]),
        retryAfter: res.headers.get("retry-after") ?? undefined,
        body: JSON.parse(text),
    };
};

const signup = (email = REGISTERED) => post("/auth/signup", { email });

/**
 * A whole sign-up, then the link spent — which is where the account is created (#120) and
 * therefore where `upstream` fires. The token is issued directly, the way every live suite
 * does it, because the link itself never reaches a test.
 */
const activate = async (email = REGISTERED): Promise<Answer> => {
    await signup(email);
    const token = await issueToken(null, email, "activation");
    return post("/auth/activate", { token, password: PASSWORD });
};
const signin = (email = REGISTERED) => post("/auth/signin", { email, password: PASSWORD });

/** `{ error: { code, message } }` and nothing else (GUARDRAILS 11). */
const expectStandardShape = (answer: Answer, code: string) => {
    const body = answer.body as { error: { code: string; message: string } };
    expect(Object.keys(body)).toEqual(["error"]);
    expect(Object.keys(body.error).sort()).toEqual(["code", "message"]);
    expect(body.error.code).toBe(code);
    expect(body.error.message).toBeTypeOf("string");
    expect(body.error.message.length).toBeGreaterThan(0);
};

/**
 * Anything that must never appear in a response or a log line: Google's reason strings,
 * the exception's own message prefix, the submitted address, the submitted password.
 */
const LEAKS = [
    "INVALID_EMAIL",
    "INTERNAL_ERROR",
    "NETWORK_FAILURE",
    "TOO_MANY_ATTEMPTS_TRY_LATER",
    "MALFORMED_RESPONSE",
    "WEAK_PASSWORD : Password",
    "Identity Toolkit",
    "upstream-registered",
    "upstream-unknown",
    "evaapp.dev",
    "correct-horse",
];

const expectNoLeak = (haystack: string) => {
    const whole = haystack.toLowerCase();
    for (const leak of LEAKS) expect(whole).not.toContain(leak.toLowerCase());
};

/** The few cases here that need a real account, swept at the end (GUARDRAILS 16). */
const strays: string[] = [];

beforeEach(() => {
    resetAuthRateLimits();
    upstream = null;
});
afterAll(async () => {
    resetAuthRateLimits();
    upstream = null;
    for (const uid of strays) {
        await firestore.collection("users").doc(uid).delete().catch(() => {});
        await adminAuth.deleteUser(uid).catch(() => {});
    }
});

describe("creating the account: an upstream failure that is not EMAIL_EXISTS", () => {
    // Sign-up used to make this call and now creates nothing (#120); the account comes into
    // existence when the activation link is spent. These are the same assertions about the
    // same guarantee, moved to the route that now carries it.
    test("a refused request is a shaped 400, not a bare 500", async () => {
        upstream = rejects("INVALID_EMAIL");
        const answer = await activate();

        expect(answer.status).toBe(400);
        expectStandardShape(answer, "VALIDATION");
        expectNoLeak(`${answer.text} ${answer.headers}`);
    });

    test("an outage is a shaped 503 that says retrying is reasonable", async () => {
        upstream = isDown;
        const answer = await activate();

        expect(answer.status).toBe(503);
        expectStandardShape(answer, "SERVICE_UNAVAILABLE");
        expect(answer.retryAfter).toBe("30");
        expectNoLeak(`${answer.text} ${answer.headers}`);
    });

    test("a transient failure and a malformed-input one are told apart", async () => {
        upstream = isDown;
        const outage = await activate();
        upstream = rejects("INVALID_EMAIL");
        const malformed = await activate();

        // The distinction the issue asks for: 503-shaped for "Google is unavailable",
        // 400-shaped for "this email is malformed" — different status, different code,
        // and only one of them carries Retry-After.
        expect(outage.status).toBe(503);
        expect(malformed.status).toBe(400);
        expect(outage.text).not.toBe(malformed.text);
        expect(outage.retryAfter).toBe("30");
        expect(malformed.retryAfter).toBeUndefined();
    });

    test("the request never landing is an outage too, not a 400", async () => {
        upstream = unreachable;
        const answer = await activate();

        expect(answer.status).toBe(503);
        expectStandardShape(answer, "SERVICE_UNAVAILABLE");
    });

    test("upstream load-shedding on a 4xx is an outage, not the caller's fault", async () => {
        upstream = shedsLoad;
        const answer = await activate();

        expect(answer.status).toBe(503);
        expectStandardShape(answer, "SERVICE_UNAVAILABLE");
    });

    test("EMAIL_EXISTS is no longer a refusal here — the link takes the account", async () => {
        // The one case whose *meaning* changed with #120, rather than moving.
        //
        // A taken address used to end sign-up with `409`. At activation it cannot: the
        // holder of a valid link has proved the address, and whoever reserved it in the
        // meantime — by calling Identity Toolkit directly, which the public web API key
        // allows — has proved nothing. Refusing here would let anyone permanently lock a
        // person out of their own address by racing their sign-up.
        //
        // `409` still exists, at sign-up, for an address whose owner is *activated*. That is
        // tested in `auth.test.ts`.
        // A real account for the address, because the race this models is real: somebody
        // reserved it by calling Identity Toolkit directly while this caller was reading
        // their email. Without one the route has nothing to claim and rightly rethrows.
        const squatted = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
        const { uid } = await adminAuth.createUser({ email: squatted, password: PASSWORD });
        strays.push(uid);

        upstream = rejects("EMAIL_EXISTS");
        const answer = await activate(squatted);

        expect(answer.status).toBe(200);
        expect(answer.body).toEqual({ activated: true });
        // Claimed, not inherited: the reserver's password no longer opens it.
        expect((await adminAuth.getUser(uid)).emailVerified).toBe(true);
        // Its own budget. Every other case in this file is in-process against a mocked
        // upstream and finishes in milliseconds, so the file keeps Bun's 5s default; this
        // one makes four real round trips (create, look up, claim, read back) and blew that
        // default against the real project while passing against the emulator — `bun test`
        // green, `bun run verify` red, for a test that was working. 20s is the ceiling the
        // live suites use (#31).
    }, 20_000);
});

describe("signin: an upstream failure that is not a wrong password", () => {
    test("an outage is a shaped 503, distinct from the 401 for bad credentials", async () => {
        upstream = isDown;
        const outage = await signin();
        upstream = rejects("INVALID_LOGIN_CREDENTIALS");
        const wrong = await signin();

        expect(outage.status).toBe(503);
        expectStandardShape(outage, "SERVICE_UNAVAILABLE");
        expect(outage.retryAfter).toBe("30");

        expect(wrong.status).toBe(401);
        expectStandardShape(wrong, "INVALID_CREDENTIALS");
    });

    test("a reason signin has no answer for still collapses to 401, never a 500", async () => {
        // Signin deliberately has no 400 branch: "that address is malformed" would answer
        // the question the 401 refuses to answer. An upstream rejection our route has no
        // specific handling for must land on the same 401 as a wrong password.
        upstream = rejects("INVALID_EMAIL");
        const answer = await signin();

        expect(answer.status).toBe(401);
        expectStandardShape(answer, "INVALID_CREDENTIALS");
        expectNoLeak(`${answer.text} ${answer.headers}`);
    });
});

describe("the new 503 branch does not reintroduce the enumeration leak", () => {
    test("an outage answers a registered and an unknown address byte-identically", async () => {
        // The property #21 closed, re-checked against the branch #32 adds. The 503 is
        // chosen from the upstream *status*, which does not vary with the address — but
        // "does not vary" is the kind of claim that stops being true quietly, so it is
        // compared the same way the 401s are: whole bytes, headers included.
        upstream = isDown;
        const registered = await signin(REGISTERED);
        const unknown = await signin(UNKNOWN);

        expect(registered.status).toBe(503);
        expect(unknown.status).toBe(503);
        expect(registered.text).toBe(unknown.text);
        expect(registered.headers).toBe(unknown.headers);
    });

    test("Retry-After is the same constant for every caller and every failure", async () => {
        // A per-caller value here — a backoff that grows with an address's failures, say —
        // would answer through the header what the body refuses to. Constant, per #5.
        upstream = isDown;
        const first = await signin(REGISTERED);
        const second = await signin(UNKNOWN);
        upstream = unreachable;
        const third = await signin(REGISTERED);
        upstream = shedsLoad;
        const fourth = await activate(UNKNOWN);

        expect(new Set([first, second, third, fourth].map((a) => a.retryAfter)).size).toBe(1);
        expect(first.retryAfter).toBe("30");
    });

    test("the 400 branch reveals nothing about which address it was", async () => {
        // Sign-up is allowed to say EMAIL_EXISTS (ARCHITECTURE §3), but the 400 that
        // account creation can answer must not become a second channel: a rejection reads
        // the same whichever address it is.
        upstream = rejects("INVALID_EMAIL");
        const registered = await activate(REGISTERED);
        const unknown = await activate(UNKNOWN);

        expect(registered.text).toBe(unknown.text);
        expect(registered.headers).toBe(unknown.headers);
    });
});

describe("the operator's signal", () => {
    let logged: string[] = [];
    let spy: ReturnType<typeof spyOn> | null = null;

    beforeEach(() => {
        logged = [];
        spy = spyOn(console, "error").mockImplementation((...args: unknown[]) => {
            logged.push(args.map((a) => String(a)).join(" "));
        });
    });
    afterEach(() => spy?.mockRestore());

    test("an outage is logged with the route and the upstream status, and nothing else", async () => {
        upstream = isDown;
        await signin();

        // Without this line a 503 is a silent number on a dashboard; with it, an outage is
        // greppable and alertable. It is the whole answer to "is Google down, or did we
        // ship a bug" — a bug from these routes is still a bare 500 and logs a stack.
        expect(logged).toHaveLength(1);
        const line = JSON.parse(logged[0]!) as Record<string, unknown>;
        expect(line.event).toBe("identity_toolkit_unavailable");
        expect(line.route).toBe("signin");
        expect(line.upstreamStatus).toBe(500);
    });

    test("the log line carries no reason, no address, no password, no API key", async () => {
        upstream = unreachable;
        await activate();
        upstream = rejects("INVALID_EMAIL");
        await activate();
        upstream = isDown;
        await signin();

        const whole = logged.join("\n");
        expectNoLeak(whole);
        // `includes`, not `not.toContain`: on failure Bun prints the expected substring,
        // which here would write the live web API key into a CI log. Also removes a
        // stray NUL byte that made this whole file unsearchable by grep.
        expect(whole.includes(config.firebaseWebApiKey)).toBe(false);
        // `unavailable` is what an operator needs to see; a wrong password is not an
        // incident, and logging one per attempt would be a log full of nothing.
        expect(logged).toHaveLength(2);
    });
});

/**
 * The boundary itself: what `identity-toolkit.ts` makes of an upstream that misbehaves.
 *
 * Everything above builds `IdentityToolkitError`s by hand, which proves the routes map
 * a kind correctly but not that the client ever produces those kinds. This drives the
 * real `signUpWithPassword` against a stubbed `fetch` — the only way to reach a refused
 * connection or an HTML error page from a load balancer, neither of which the live
 * project can be asked for.
 */
describe("the Identity Toolkit client's own classification", () => {
    let fetchSpy: ReturnType<typeof spyOn> | null = null;

    const answering = (make: () => Response | never) => {
        // The cast is only about `fetch`'s extra `preconnect` property, which the client
        // does not use; the stub still has to be a function returning a Response.
        fetchSpy = spyOn(globalThis, "fetch").mockImplementation((async () =>
            make()) as unknown as typeof fetch);
    };
    const jsonResponse = (status: number, reason: string) =>
        new Response(JSON.stringify({ error: { message: reason } }), { status });

    afterEach(() => fetchSpy?.mockRestore());

    /** Runs the real client and hands back the failure it threw. */
    const failure = async (): Promise<InstanceType<typeof IdentityToolkitError>> => {
        try {
            await realSignUp("e2e+boundary@e2e.evaapp.dev", PASSWORD);
        } catch (err) {
            return err as InstanceType<typeof IdentityToolkitError>;
        }
        throw new Error("expected the call to fail");
    };

    test("a refused connection is unavailable, with no status and no leaked URL", async () => {
        answering(() => {
            // What Bun throws when the host cannot be reached — its message names the
            // request URL, and that URL carries the web API key.
            throw new Error(
                "Unable to connect: https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=SECRET",
            );
        });
        const err = await failure();

        expect(err.kind).toBe("unavailable");
        expect(err.upstreamStatus).toBeNull();
        // The cause is dropped rather than attached, so the key cannot travel with the
        // error into a log line or a stack trace (GUARDRAILS 1).
        expect(`${err.message} ${err.reason} ${err.stack ?? ""}`).not.toContain("SECRET");
        expect(err.cause).toBeUndefined();
    });

    test("a body that is not JSON is an outage, not a verdict", async () => {
        answering(() => new Response("<html>502 Bad Gateway</html>", { status: 502 }));
        const err = await failure();

        expect(err.kind).toBe("unavailable");
        expect(err.upstreamStatus).toBe(502);
    });

    test("a 5xx is unavailable whatever its body claims about the address", async () => {
        // The status is read before the reason, so a 500 carrying EMAIL_EXISTS cannot be
        // turned into a statement about whether that address is registered.
        answering(() => jsonResponse(500, "EMAIL_EXISTS"));
        const err = await failure();

        expect(err.kind).toBe("unavailable");
        expect(err.upstreamStatus).toBe(500);
    });

    test("a 429 is unavailable", async () => {
        answering(() => jsonResponse(429, "RESOURCE_EXHAUSTED"));
        expect((await failure()).kind).toBe("unavailable");
    });

    test("a 400 EMAIL_EXISTS is still email-exists", async () => {
        answering(() => jsonResponse(400, "EMAIL_EXISTS"));
        const err = await failure();

        expect(err.kind).toBe("email-exists");
        expect(err.upstreamStatus).toBe(400);
    });

    test("a 400 the caller could fix is rejected", async () => {
        answering(() => jsonResponse(400, "INVALID_EMAIL"));
        expect((await failure()).kind).toBe("rejected");
    });

    test("load-shedding and a disabled provider are unavailable despite their 400", async () => {
        for (const reason of [
            "TOO_MANY_ATTEMPTS_TRY_LATER",
            "QUOTA_EXCEEDED",
            "OPERATION_NOT_ALLOWED",
            "ADMIN_ONLY_OPERATION",
        ]) {
            answering(() => jsonResponse(400, reason));
            expect((await failure()).kind).toBe("unavailable");
            fetchSpy?.mockRestore();
        }
    });

    test("Google's multi-word reasons keep only the code", async () => {
        answering(() =>
            jsonResponse(400, "WEAK_PASSWORD : Password should be at least 6 characters"),
        );
        const err = await failure();

        expect(err.reason).toBe("WEAK_PASSWORD");
        expect(err.kind).toBe("rejected");
    });
});
import { config } from "../src/config";

import { describe, expect, mock, test } from "bun:test";

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
describe("signup deliberately does distinguish a taken address", () => {
    test("a registered address is 409 EMAIL_EXISTS, not the combined message", async () => {
        const res = await post("/auth/signup", { email: REGISTERED, password: PASSWORD });
        expect(res.status).toBe(409);
        expect(res.error.code).toBe("EMAIL_EXISTS");
        expect(res.error.code).not.toBe("INVALID_CREDENTIALS");
    });
});

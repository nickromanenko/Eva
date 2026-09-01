import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { config } from "../src/config";
import { ACTIVATION_TTL_SECONDS, RESET_TTL_SECONDS, issueToken } from "../src/email-tokens";
import { adminAuth, firestore } from "../src/firebase";
import { createUnactivatedAccount, signIn } from "./support/session";

/**
 * The four routes that activation and password reset are made of (#6), driven live:
 * `GET|POST /auth/activate`, `/auth/activation/resend`, `/auth/password/forgot`,
 * `/auth/password/reset`.
 *
 * `email-tokens.test.ts` tests the tokens and `email.test.ts` the sending; this file is
 * about what the API answers, which is the part the app and the website are written
 * against. Real Firebase, same sweep pattern as the other live suites (GUARDRAILS 16).
 *
 * Accounts are stood up with the Admin SDK rather than `POST /auth/signup`, deliberately:
 * the per-IP sign-up counter is shared by the whole `test/` directory (#5), and none of
 * the properties below are about sign-up. The one thing that pattern cannot produce — an
 * account that has never been activated but *was* made by the API — is exactly what
 * `createUnactivatedAccount` writes.
 *
 * The two "send me a link" routes are throttled to one attempt per address per
 * `resendPerEmailSeconds`, and a live test cannot reset an in-process counter, so every
 * case that calls them uses an address of its own.
 */

// Every case here stands up an account and makes several live round trips, and the sweep
// at the end deletes them all; 20s is the same ceiling events.test.ts uses (#31).
setDefaultTimeout(20_000);

const BASE = process.env.EVA_API_URL ?? "http://localhost:3003";
const PASSWORD = "correct-horse-8";
const createdUids: string[] = [];

const address = () => `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;

/** An API-made account that has never confirmed its address. */
const unactivated = async (): Promise<{ email: string; uid: string }> => {
    const email = address();
    const uid = await createUnactivatedAccount(email, PASSWORD);
    createdUids.push(uid);
    return { email, uid };
};

interface Answer {
    status: number;
    /** The raw bytes, not a parse of them — the comparison two branches have to survive. */
    text: string;
    headers: string;
    body: Record<string, unknown>;
    error?: { code: string; message: string };
}

const answer = async (res: Response): Promise<Answer> => {
    const text = await res.text();
    const body = JSON.parse(text) as Record<string, unknown>;
    return {
        status: res.status,
        text,
        headers: JSON.stringify([...res.headers]),
        body,
        error: body.error as { code: string; message: string } | undefined,
    };
};

const post = async (path: string, body: unknown): Promise<Answer> =>
    answer(
        await fetch(`${BASE}${path}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
        }),
    );

const get = async (path: string): Promise<Answer> => answer(await fetch(`${BASE}${path}`));

/** A token whose expiry is already in the past, issued against the same Firestore the
 *  server reads. Cheaper than waiting a day, and it exercises the real expiry branch. */
const expiredToken = (uid: string, email: string, kind: "activation" | "reset") =>
    issueToken(uid, email, kind, () => Date.now() - (kind === "activation" ? ACTIVATION_TTL_SECONDS : RESET_TTL_SECONDS) * 1000 - 1000);

const userDoc = (uid: string) => firestore.collection("users").doc(uid);

const tokenDocs = (uid: string) =>
    firestore.collection("authTokens").where("uid", "==", uid).get();

afterAll(async () => {
    for (const uid of createdUids) {
        const tokens = await tokenDocs(uid).catch(() => null);
        if (tokens) await Promise.all(tokens.docs.map((doc) => doc.ref.delete().catch(() => {})));
        await userDoc(uid).delete().catch(() => {});
        await adminAuth.deleteUser(uid).catch(() => {});
    }
});

describe("GET /auth/activate", () => {
    test("a good link activates the account and says so", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");

        const res = await get(`/auth/activate?token=${token}`);
        expect(res.status).toBe(200);
        expect(res.body).toEqual({ activated: true });
        expect((await userDoc(uid).get()).data()!.activatedAt).not.toBeNull();
    });

    test("the same link twice is a dead link, not a second activation", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");

        expect((await get(`/auth/activate?token=${token}`)).status).toBe(200);
        const replay = await get(`/auth/activate?token=${token}`);
        expect(replay.status).toBe(400);
        expect(replay.error!.code).toBe("INVALID_TOKEN");
    });

    test("a token that never existed and one that was spent answer identically", async () => {
        // Folded together on purpose: telling them apart would let whoever holds a link
        // learn whether somebody else has already clicked it.
        const { email, uid } = await unactivated();
        const spent = await issueToken(uid, email, "activation");
        await get(`/auth/activate?token=${spent}`);

        // Well-formed and never issued: same shape, so it gets as far as the lookup.
        const neverIssued = Buffer.from(crypto.getRandomValues(new Uint8Array(32)))
            .toString("base64url");
        const unknownRes = await get(`/auth/activate?token=${neverIssued}`);
        const spentRes = await get(`/auth/activate?token=${spent}`);

        expect(unknownRes.status).toBe(spentRes.status);
        expect(unknownRes.text).toBe(spentRes.text);
    });

    test("an expired link is told apart, because the user can act on it", async () => {
        const { email, uid } = await unactivated();
        const token = await expiredToken(uid, email, "activation");

        const res = await get(`/auth/activate?token=${token}`);
        expect(res.status).toBe(400);
        expect(res.error!.code).toBe("TOKEN_EXPIRED");
        expect((await userDoc(uid).get()).data()!.activatedAt).toBeNull();
    });

    test("a malformed token is a dead link; no token at all is a client mistake", async () => {
        expect((await get("/auth/activate?token=nonsense")).error!.code).toBe("INVALID_TOKEN");
        expect((await get("/auth/activate")).error!.code).toBe("VALIDATION");
    });

    test("a reset token does not open the activation route", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");
        expect((await get(`/auth/activate?token=${token}`)).error!.code).toBe("INVALID_TOKEN");
    });

    test("POST /auth/activate takes the token in the body and answers the same", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");
        const res = await post("/auth/activate", { token });
        expect(res.status).toBe(200);
        expect(res.body).toEqual({ activated: true });
    });
});

describe("the two send-a-link routes", () => {
    test("a registered address and an unknown one get the same answer, byte for byte", async () => {
        // The property `/auth/signin` has, extended to the routes that would otherwise
        // give it away for free: whether an address has an Eva account is not the
        // caller's to learn. Separate addresses because the throttle is per address.
        const { email } = await unactivated();
        const registered = await post("/auth/activation/resend", { email });
        const unknown = await post("/auth/activation/resend", { email: address() });

        expect(registered.status).toBe(200);
        expect(registered.body).toEqual({ sent: true });
        expect(registered.text).toBe(unknown.text);
        expect(registered.headers).toBe(unknown.headers);
    });

    test("forgot answers the same for both, and for an unactivated account too", async () => {
        const { email } = await unactivated();
        const registered = await post("/auth/password/forgot", { email });
        const unknown = await post("/auth/password/forgot", { email: address() });

        expect(registered.status).toBe(200);
        expect(registered.text).toBe(unknown.text);
        expect(registered.headers).toBe(unknown.headers);
    });

    test("neither answer carries the address", async () => {
        const { email } = await unactivated();
        for (const res of [
            await post("/auth/activation/resend", { email }),
            await post("/auth/password/forgot", { email: address() }),
        ]) {
            const whole = `${res.text} ${res.headers}`.toLowerCase();
            expect(whole).not.toContain("evaapp.dev");
            expect(whole).not.toContain(email.toLowerCase());
        }
    });

    test("an address that is not one is a 400, before anything is looked up", async () => {
        expect((await post("/auth/activation/resend", { email: "not-an-email" })).error!.code)
            .toBe("VALIDATION");
        expect((await post("/auth/password/forgot", {})).error!.code).toBe("VALIDATION");
    });

    test("resend issues a fresh activation token for an unactivated account", async () => {
        const { email, uid } = await unactivated();
        expect((await tokenDocs(uid)).size).toBe(0);
        expect((await post("/auth/activation/resend", { email })).status).toBe(200);

        const tokens = await tokenDocs(uid);
        expect(tokens.size).toBe(1);
        expect(tokens.docs[0]!.data().kind).toBe("activation");
        // The document is keyed by the hash and holds no copy of the token itself.
        expect(Object.keys(tokens.docs[0]!.data()).sort()).toEqual([
            "createdAt",
            "email",
            "expiresAt",
            "kind",
            "uid",
            "usedAt",
        ]);
    });

    test("resend on an already-activated account sends nothing", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");
        await get(`/auth/activate?token=${token}`);

        expect((await post("/auth/activation/resend", { email })).status).toBe(200);
        // Only the one that was spent above; the route had nothing to confirm.
        const tokens = await tokenDocs(uid);
        expect(tokens.size).toBe(1);
        expect(tokens.docs[0]!.data().usedAt).not.toBeNull();
    });

    test("a second request inside the window is refused, and says how long to wait", async () => {
        expect(config.rateLimit.resendPerEmailSeconds).toBeGreaterThan(0);
        const { email } = await unactivated();
        expect((await post("/auth/password/forgot", { email })).status).toBe(200);

        const again = await post("/auth/password/forgot", { email });
        expect(again.status).toBe(429);
        expect(again.error!.code).toBe("RATE_LIMITED");
        expect(JSON.parse(again.headers) as [string, string][]).toContainEqual([
            "retry-after",
            String(config.rateLimit.resendPerEmailSeconds),
        ]);
    });

    test("resend and forgot hold separate budgets for the same address", async () => {
        const { email } = await unactivated();
        expect((await post("/auth/activation/resend", { email })).status).toBe(200);
        // Asking for a reset must not have been spent by the activation Resend.
        expect((await post("/auth/password/forgot", { email })).status).toBe(200);
    });
});

describe("POST /auth/password/reset", () => {
    const NEW_PASSWORD = "brand-new-42";

    test("a good token sets the password and hands back a session", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");

        const res = await post("/auth/password/reset", { token, password: NEW_PASSWORD });
        expect(res.status).toBe(200);
        expect(typeof res.body.token).toBe("string");
        expect(res.body.user).toMatchObject({ id: uid, email, activated: true });

        // The new password works and the old one does not.
        expect(typeof (await signIn(BASE, email, NEW_PASSWORD))).toBe("string");
        expect((await post("/auth/signin", { email, password: PASSWORD })).status).toBe(401);
    });

    test("a reset proves the address, so it activates an account that never confirmed", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");
        expect((await post("/auth/password/reset", { token, password: NEW_PASSWORD })).status)
            .toBe(200);
        expect((await userDoc(uid).get()).data()!.activatedAt).not.toBeNull();
    });

    test("a weak password costs a retry, not the link", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");

        const weak = await post("/auth/password/reset", { token, password: "short" });
        expect(weak.status).toBe(400);
        expect(weak.error!.code).toBe("WEAK_PASSWORD");

        // The token was never spent, so the same link still works.
        expect((await post("/auth/password/reset", { token, password: NEW_PASSWORD })).status)
            .toBe(200);
    });

    test("the link is single-use and expires", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");
        expect((await post("/auth/password/reset", { token, password: NEW_PASSWORD })).status)
            .toBe(200);
        expect((await post("/auth/password/reset", { token, password: NEW_PASSWORD })).error!.code)
            .toBe("INVALID_TOKEN");

        const stale = await expiredToken(uid, email, "reset");
        expect((await post("/auth/password/reset", { token: stale, password: NEW_PASSWORD })).error!.code)
            .toBe("TOKEN_EXPIRED");
    });

    test("asking for a new link kills the one already in the inbox", async () => {
        const { email, uid } = await unactivated();
        const first = await issueToken(uid, email, "reset");
        expect((await post("/auth/password/forgot", { email })).status).toBe(200);

        const dead = await post("/auth/password/reset", { token: first, password: NEW_PASSWORD });
        expect(dead.status).toBe(400);
        expect(dead.error!.code).toBe("INVALID_TOKEN");
    });

    test("an activation token does not open the reset route", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");
        expect((await post("/auth/password/reset", { token, password: NEW_PASSWORD })).error!.code)
            .toBe("INVALID_TOKEN");
    });
});

describe("CORS on the two routes the website calls", () => {
    const preflight = (path: string, origin: string) =>
        fetch(`${BASE}${path}`, {
            method: "OPTIONS",
            headers: {
                origin,
                "access-control-request-method": "POST",
                "access-control-request-headers": "content-type",
            },
        });

    test("the site's own origin is allowed", async () => {
        const res = await preflight("/auth/password/reset", config.publicWebOrigin);
        expect(res.headers.get("access-control-allow-origin")).toBe(config.publicWebOrigin);
    });

    test("any other origin is not — and never `*`", async () => {
        const res = await preflight("/auth/activate", "https://not-eva.example");
        expect(res.headers.get("access-control-allow-origin")).not.toBe("*");
        expect(res.headers.get("access-control-allow-origin")).not.toBe("https://not-eva.example");
    });

    test("routes the website does not call carry no CORS header at all", async () => {
        const res = await preflight("/auth/signin", config.publicWebOrigin);
        expect(res.headers.get("access-control-allow-origin")).toBeNull();
    });
});

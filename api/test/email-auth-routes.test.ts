import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { config } from "../src/config";
import { ACTIVATION_TTL_SECONDS, RESET_TTL_SECONDS, issueToken } from "../src/email-tokens";
import { adminAuth, firestore } from "../src/firebase";
import { markUserDeleted } from "../src/users";
import { createUnactivatedAccount, signIn } from "./support/session";

/**
 * The four routes that activation and password reset are made of (#6), driven live:
 * `POST /auth/activate`, `/auth/activation/resend`, `/auth/password/forgot`,
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

/** Spends an activation token. POST, with the token in the body: the route takes it no
 *  other way, so that a token cannot reach a request log (#6). */
const activate = (token: string): Promise<Answer> => post("/auth/activate", { token });

/** The response headers minus `date`, which ticks between two requests and would make a
 *  byte-for-byte comparison depend on which second each landed in. */
const headersWithoutClock = (a: Answer): string =>
    JSON.stringify((JSON.parse(a.headers) as [string, string][]).filter(([k]) => k !== "date"));

/** A token whose expiry is already in the past, issued against the same Firestore the
 *  server reads. Cheaper than waiting a day, and it exercises the real expiry branch. */
const expiredToken = (uid: string, email: string, kind: "activation" | "reset") =>
    issueToken(uid, email, kind, () => Date.now() - (kind === "activation" ? ACTIVATION_TTL_SECONDS : RESET_TTL_SECONDS) * 1000 - 1000);

const userDoc = (uid: string) => firestore.collection("users").doc(uid);

const tokenDocs = (uid: string) =>
    firestore.collection("authTokens").where("uid", "==", uid).get();

// Its own budget: this suite stands up an account per case and the sweep is one Firestore
// query and three deletes each, well past the 20s the cases get.
afterAll(async () => {
    for (const uid of createdUids) {
        const tokens = await tokenDocs(uid).catch(() => null);
        if (tokens) await Promise.all(tokens.docs.map((doc) => doc.ref.delete().catch(() => {})));
        await userDoc(uid).delete().catch(() => {});
        await adminAuth.deleteUser(uid).catch(() => {});
    }
}, 180_000);

describe("POST /auth/activate", () => {
    test("a good link activates the account and says so", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");

        const res = await activate(token);
        expect(res.status).toBe(200);
        expect(res.body).toEqual({ activated: true });
        expect((await userDoc(uid).get()).data()!.activatedAt).not.toBeNull();
    });

    test("the same link twice is a dead link, not a second activation", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");

        expect((await activate(token)).status).toBe(200);
        const replay = await activate(token);
        expect(replay.status).toBe(400);
        expect(replay.error!.code).toBe("INVALID_TOKEN");
    });

    test("a token that never existed and one that was spent answer identically", async () => {
        // Folded together on purpose: telling them apart would let whoever holds a link
        // learn whether somebody else has already clicked it.
        const { email, uid } = await unactivated();
        const spent = await issueToken(uid, email, "activation");
        await activate(spent);

        // Well-formed and never issued: same shape, so it gets as far as the lookup.
        const neverIssued = Buffer.from(crypto.getRandomValues(new Uint8Array(32)))
            .toString("base64url");
        const unknownRes = await activate(neverIssued);
        const spentRes = await activate(spent);

        expect(unknownRes.status).toBe(spentRes.status);
        expect(unknownRes.text).toBe(spentRes.text);
    });

    test("an expired link is told apart, because the user can act on it", async () => {
        const { email, uid } = await unactivated();
        const token = await expiredToken(uid, email, "activation");

        const res = await activate(token);
        expect(res.status).toBe(400);
        expect(res.error!.code).toBe("TOKEN_EXPIRED");
        expect((await userDoc(uid).get()).data()!.activatedAt).toBeNull();
    });

    test("a malformed token is a dead link; no token at all is a client mistake", async () => {
        expect((await activate("nonsense")).error!.code).toBe("INVALID_TOKEN");
        expect((await post("/auth/activate", {})).error!.code).toBe("VALIDATION");
    });

    test("a reset token does not open the activation route", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");
        expect((await activate(token)).error!.code).toBe("INVALID_TOKEN");
    });

    test("a token in the query string is not a way in", async () => {
        // The route is POST-only on purpose: `GET /auth/activate?token=…` would write the
        // raw token into Cloud Run's request log. A GET must not quietly start working.
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "activation");
        // A raw fetch: an unmatched route answers plain text, not the error shape.
        const viaQuery = await fetch(`${BASE}/auth/activate?token=${token}`);
        expect(viaQuery.status).toBe(404);
        // And the token is untouched, so the real route still takes it.
        expect((await activate(token)).status).toBe(200);
    });

    test("the answer is never cached", async () => {
        const { email, uid } = await unactivated();
        const res = await activate(await issueToken(uid, email, "activation"));
        expect(JSON.parse(res.headers) as [string, string][]).toContainEqual([
            "cache-control",
            "no-store",
        ]);
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
        expect(headersWithoutClock(registered)).toBe(headersWithoutClock(unknown));
    });

    test("forgot answers the same for both, and for an unactivated account too", async () => {
        const { email } = await unactivated();
        const registered = await post("/auth/password/forgot", { email });
        const unknown = await post("/auth/password/forgot", { email: address() });

        expect(registered.status).toBe(200);
        expect(registered.text).toBe(unknown.text);
        expect(headersWithoutClock(registered)).toBe(headersWithoutClock(unknown));
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

    test("a registered address and an unknown one take the same time to answer", async () => {
        // The bytes matching is half the property. The registered branch does a Firestore
        // write and a POST to Postmark and the unknown branch does neither, so without a
        // floor the two are hundreds of milliseconds apart — an oracle readable from one
        // request, no statistics needed. This is the assertion that the floor is there.
        const { email } = await unactivated();
        const time = async (address: string): Promise<number> => {
            const started = Date.now();
            expect((await post("/auth/password/forgot", { email: address })).status).toBe(200);
            return Date.now() - started;
        };

        const registered = await time(email);
        const unknown = await time(address());

        // Both above the floor, and within a fraction of it of each other. The bound is
        // loose on purpose — it fails on "one branch skips the work", which is the leak,
        // and not on ordinary network jitter.
        expect(registered).toBeGreaterThanOrEqual(750);
        expect(unknown).toBeGreaterThanOrEqual(750);
        expect(Math.abs(registered - unknown)).toBeLessThan(400);
    });

    test("an address that is not one is a 400, before anything is looked up", async () => {
        expect((await post("/auth/activation/resend", { email: "not-an-email" })).error!.code)
            .toBe("VALIDATION");
        expect((await post("/auth/password/forgot", {})).error!.code).toBe("VALIDATION");
        // Long enough to be a throttle key nobody wants to keep: refused at the edge.
        const huge = `e2e+${"a".repeat(300)}@e2e.evaapp.dev`;
        expect((await post("/auth/password/forgot", { email: huge })).error!.code)
            .toBe("VALIDATION");
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
        await activate(token);

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

    test("the refused answer is the same for both, too — the throttle runs before the lookup", async () => {
        // The 200s above only close the leak for the first request. GUARDRAILS 12b asks
        // for "throttled the same way in both branches": if the throttle sat *after*
        // `findAuthUidByEmail`, an unknown address would never be refused and a
        // registered one would be, and the second request would answer the question the
        // first refuses. Both routes, because both are written the same way and either
        // could drift alone.
        for (const path of ["/auth/activation/resend", "/auth/password/forgot"]) {
            const { email } = await unactivated();
            const stranger = address();
            expect((await post(path, { email })).status).toBe(200);
            expect((await post(path, { email: stranger })).status).toBe(200);

            const registered = await post(path, { email });
            const unknown = await post(path, { email: stranger });

            expect(registered.status).toBe(429);
            expect(unknown.status).toBe(429);
            expect(registered.text).toBe(unknown.text);
            expect(headersWithoutClock(registered)).toBe(headersWithoutClock(unknown));
        }
    });
});

describe("an account that went away between the email and the click", () => {
    // `DELETE /me` writes a tombstone first and removes the document last, so a link can
    // land on either shape. Both are dead links — an activation must not stamp an account
    // mid-delete, and a reset must not set credentials on one.
    test("a tombstoned account cannot be activated and cannot have its password reset", async () => {
        const { email, uid } = await unactivated();
        const activation = await issueToken(uid, email, "activation");
        const reset = await issueToken(uid, email, "reset");
        expect(await markUserDeleted(uid)).toBe(true);

        expect((await activate(activation)).error!.code).toBe(
            "INVALID_TOKEN",
        );
        const res = await post("/auth/password/reset", { token: reset, password: "brand-new-42" });
        expect(res.status).toBe(400);
        expect(res.error!.code).toBe("INVALID_TOKEN");
        // And the sign-in credentials are untouched: the reset never reached `setPassword`.
        expect((await post("/auth/signin", { email, password: "brand-new-42" })).status).toBe(401);
    });

    test("deleting the account takes its tokens with it", async () => {
        // `deleteTokensForUid` is unit-tested in email-tokens.test.ts; this pins that
        // `DELETE /me` actually calls it. A token document carries the account's address,
        // and a deleted account keeps nothing (GUARDRAILS, ARCHITECTURE §3).
        const { email, uid } = await unactivated();
        const activation = await issueToken(uid, email, "activation");
        expect((await activate(activation)).status).toBe(200);
        await issueToken(uid, email, "reset");
        expect((await tokenDocs(uid)).size).toBe(2);

        const session = await signIn(BASE, email, PASSWORD);
        const res = await fetch(`${BASE}/me`, {
            method: "DELETE",
            headers: { authorization: `Bearer ${session}` },
        });
        expect(res.status).toBe(200);

        expect((await tokenDocs(uid)).size).toBe(0);
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

    test("a password past the ceiling is refused before the token is spent", async () => {
        // Identity Platform has a ceiling of its own and enforces it in `setPassword` —
        // after `consumeToken`. Without the edge check the user would get a 500 and a
        // dead link, which is the outcome checking the rule first exists to prevent.
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");

        const long = await post("/auth/password/reset", {
            token,
            password: `${"a".repeat(400)}1`,
        });
        expect(long.status).toBe(400);
        expect(long.error!.code).toBe("WEAK_PASSWORD");
        // Not the "at least 8 characters" rule, which they had satisfied.
        expect(long.error!.message).not.toContain("At least 8");

        expect((await post("/auth/password/reset", { token, password: NEW_PASSWORD })).status)
            .toBe(200);
    });

    test("the answer is never cached", async () => {
        const { email, uid } = await unactivated();
        const token = await issueToken(uid, email, "reset");
        const res = await post("/auth/password/reset", { token, password: NEW_PASSWORD });
        expect(JSON.parse(res.headers) as [string, string][]).toContainEqual([
            "cache-control",
            "no-store",
        ]);
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

describe("a second factor is not a session", () => {
    /**
     * `requireSignedIn` was added for `/auth/idp` in the fourth review of #7 and called only
     * from there, while ARCHITECTURE claimed it guarded "any sign-in response". The password
     * path — which has more users — was the one left open.
     *
     * Identity Toolkit answers a password sign-in for an MFA-enrolled user with **200**,
     * `localId`, `email`, an `mfaPendingCredential`, and **no `idToken`**: the first factor
     * checked out, the second has not been supplied. Reading `localId` out of that mints a
     * full 30-day Eva session for someone who completed half of a sign-in.
     *
     * Driven against the live server, with no module mocks anywhere near it — the Auth
     * emulator has `mfaConfig.state === "ENABLED"` at project level, so enrolling a factor
     * through the Admin SDK is enough to produce the real response shape. MFA is off on the
     * production project today; it is one console switch from being on, and that switch
     * would otherwise be silent.
     */
    test("a password sign-in that only cleared the first factor mints nothing", async () => {
        const { email, uid } = await unactivated();
        // **Activated first, and that is load-bearing.** An unactivated account is refused
        // by #6's gate with a 403, which satisfies "not a session" all on its own — the
        // first version of this test passed with the guard deleted, for that reason and not
        // for the one in its name. Activation also sets `emailVerified`, which Firebase
        // requires before a second factor can be enrolled.
        await activate(await issueToken(uid, email, "activation"));
        expect((await post("/auth/signin", { email, password: PASSWORD })).status).toBe(200);

        await adminAuth.updateUser(uid, {
            multiFactor: {
                enrolledFactors: [
                    {
                        uid: `mfa-${crypto.randomUUID()}`,
                        phoneNumber: "+15555550100",
                        displayName: "phone",
                        factorId: "phone",
                    },
                ],
            },
        });

        // The same request that succeeded a moment ago, now with a second factor enrolled.
        const res = await post("/auth/signin", { email, password: PASSWORD });

        // Whatever it answers, it must not be a session.
        expect(res.status).not.toBe(200);
        expect(res.body.token).toBeUndefined();
        // And nothing of Identity Toolkit's own vocabulary reaches the caller.
        expect(res.text.toLowerCase()).not.toContain("mfa");
    });
});

describe("proving the address takes back what was attached while it was not", () => {
    /**
     * The takeover that survived two rounds of fixing `/auth/idp`, by waiting.
     *
     * `claimUnprovenAccount` guards the provider route and is gated on `activatedAt`. But
     * activation and password reset also stamp `activatedAt`, and they used to stamp it and
     * nothing else — so an attacker who had reserved the victim's address and attached their
     * own provider identity to it only had to sit still. The moment the victim proved the
     * address, by either door, the claim was skipped forever and the attacker's identity
     * signed in to the victim's account.
     *
     * The premise that was wrong is worth stating because it reads as obviously true:
     * proving the address does *not* retroactively legitimise a credential attached before
     * it was proven. It proves the address.
     */

    /** The attacker's foothold: their own provider `sub` on an address they merely reserved. */
    const attach = async (uid: string, providerId: string): Promise<void> => {
        await adminAuth.updateUser(uid, {
            providerToLink: {
                providerId,
                uid: `attacker-sub-${crypto.randomUUID()}`,
                email: address(),
            },
        });
    };

    const providers = async (uid: string): Promise<string[]> =>
        (await adminAuth.getUser(uid)).providerData.map((p) => p.providerId).sort();

    test("the activation link unlinks a provider attached before it was clicked", async () => {
        const { email, uid } = await unactivated();
        await attach(uid, "google.com");
        expect(await providers(uid)).toEqual(["google.com", "password"]);

        const res = await activate(await issueToken(uid, email, "activation"));
        expect(res.status).toBe(200);

        // Gone. `/auth/idp` will never look at this account again — it is activated from
        // here on — so this was the last chance to take it back.
        expect(await providers(uid)).toEqual(["password"]);
    });

    test("activation makes Firebase agree that the address is proven", async () => {
        // They were never connected: every account activated by an emailed link stayed
        // `emailVerified: false` at Firebase forever. That is not cosmetic — Identity
        // Toolkit deletes the password *and every provider* when it merges a verified
        // provider address onto an unverified account, so a real user adding Google would
        // silently lose the password that `users/{uid}.authProviders` still advertised.
        const { email, uid } = await unactivated();
        expect((await adminAuth.getUser(uid)).emailVerified).toBe(false);

        await activate(await issueToken(uid, email, "activation"));

        expect((await adminAuth.getUser(uid)).emailVerified).toBe(true);
    });

    test("a password reset retracts it too, because that is the recovery an owner is sent to", async () => {
        // The route matters as much as the activation link: an owner who finds their address
        // already taken is told to use forgot-password, so this door has to close the same
        // hole. It is the one `claimUnprovenAccount`'s own comment recommends.
        const { email, uid } = await unactivated();
        await attach(uid, "apple.com");

        const res = await post("/auth/password/reset", {
            token: await issueToken(uid, email, "reset"),
            password: "a-brand-new-password-9",
        });
        expect(res.status).toBe(200);

        expect(await providers(uid)).toEqual(["password"]);
        expect((await adminAuth.getUser(uid)).emailVerified).toBe(true);
    });

    test("a provider linked deliberately survives a later password reset", async () => {
        // The other half, and the reason this is keyed on the *transition* rather than on
        // every stamp. Someone who connected Apple from Profile and then forgot their
        // password must still have Apple afterwards.
        const { email, uid } = await unactivated();
        await activate(await issueToken(uid, email, "activation"));
        await attach(uid, "apple.com");
        expect(await providers(uid)).toEqual(["apple.com", "password"]);

        const res = await post("/auth/password/reset", {
            token: await issueToken(uid, email, "reset"),
            password: "another-new-password-9",
        });
        expect(res.status).toBe(200);

        expect(await providers(uid)).toEqual(["apple.com", "password"]);
    });

    test("activation revokes a session taken before the address was proven", async () => {
        // The attacker signs in at Identity Toolkit directly — the web API key is public —
        // and a refresh token outlives the password that made it.
        const { email, uid } = await unactivated();
        const signInUrl = `${config.identityToolkitBaseUrl}/v1/accounts:signInWithPassword?key=${config.firebaseWebApiKey}`;
        const before = await fetch(signInUrl, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ email, password: PASSWORD, returnSecureToken: true }),
        });
        const { idToken } = (await before.json()) as { idToken: string };
        expect(await adminAuth.verifyIdToken(idToken, true)).toBeTruthy();

        // One-second resolution on `tokensValidAfterTime`: without crossing the boundary,
        // "revoked in the same second" is indistinguishable from "not revoked" to Firebase
        // itself, not just to this assertion.
        await Bun.sleep(1_100);
        await activate(await issueToken(uid, email, "activation"));

        await expect(adminAuth.verifyIdToken(idToken, true)).rejects.toThrow();
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

import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { mintToken } from "../src/auth";
import { config } from "../src/config";
import { adminAuth, firestore } from "../src/firebase";
import { resetAuthRateLimits } from "../src/rate-limit";
import { getUser, markActivated } from "../src/users";
import { createUnactivatedAccount } from "./support/session";
import type { IdpCredential } from "../src/identity-toolkit";

/**
 * Sign in with Apple and Google, through the API (#7).
 *
 * ## What this suite can and cannot prove — read this before trusting it
 *
 * There is no way to obtain a real Apple `identityToken` or a real Google authorization
 * code from a test process: Apple needs a device and a human at an Apple ID, and Google's
 * code is minted by a consent screen. So the **provider boundary is faked** and everything
 * on our side of it is real — the same trade `signin-non-enumeration.test.ts` made, for the
 * same reason, and the mock is at the same seam (`mock.module` on
 * `../src/identity-toolkit`, the route driven in-process through `app.fetch`).
 *
 * Real, and therefore actually under test: the route's validation, `ensureUser`, the
 * `users/{uid}` documents themselves in the **live Firebase project**, the activation
 * stamp, `authProviders`, the account gate, and `DELETE /me`.
 *
 * Faked, and therefore *not* under test: that Apple's token is well-formed, that Firebase
 * rejects a replayed nonce, that Google's token endpoint accepts our PKCE exchange, and
 * that Apple's revocation endpoint accepts our client secret. The last describe below
 * closes the one piece of that which *is* ours — that the raw nonce reaches the wire — by
 * driving the real `signInWithIdp` against a stubbed `fetch`. Everything else in that list
 * needs a provisioned provider and a device, and `docs/PROVIDER-SIGNIN.md` says so.
 *
 * ## The `mock.module` caveat, as the other in-process suites state it
 *
 * Bun's module mocks are process-global and permanent, and `bun test` does not run files
 * alphabetically. So: the namespace is snapshotted on the way in and handed back in
 * `afterAll`; the rate-limit counters are shared with the other in-process files and are
 * reset around every test; and every account here is `e2e+<uuid>@e2e.evaapp.dev`
 * (GUARDRAILS 16) and is swept whether or not the test that made it got that far.
 */

// A copy, not the namespace object: `mock.module` replaces the bindings inside the live
// namespace, so a reference taken from it later would be this file's own mock.
const identityToolkit = { ...(await import("../src/identity-toolkit")) };
const { IdentityToolkitError, PROVIDER_IDS } = identityToolkit;

/** Captured before the mock replaces it, so the last describe can drive the real client
 *  against a stubbed `fetch` while every other test sees the fake. */
const realSignInWithIdp = identityToolkit.signInWithIdp;

/** What the next `signInWithIdp` does. `null` is a bug in the test: a default that quietly
 *  succeeded would write a document for a fabricated uid into the live project. */
let idp: ((credential: IdpCredential, linkTo?: string) => { localId: string; email: string })
    | null = null;

/** The last credential the route handed the boundary — how the nonce is checked without
 *  reaching for the mock's internals. */
let lastIdp: { credential: IdpCredential; linkTo?: string } | null = null;

const unset = (): never => {
    throw new Error("test/provider-signin.test.ts reached signInWithIdp without setting `idp`");
};

mock.module("../src/identity-toolkit", () => ({
    ...identityToolkit,
    signInWithIdp: async (credential: IdpCredential, linkTo?: string) => {
        lastIdp = { credential, linkTo };
        return (idp ?? unset)(credential, linkTo);
    },
    // The Admin-SDK half of linking. Faked because `createCustomToken` needs a signing
    // credential the test process is not guaranteed to hold (and on Cloud Run needs an IAM
    // role that is an infra gate) — what this suite is testing is what the route does with
    // the ID token, not how it got one.
    idTokenForUid: async (uid: string) => `firebase-id-token-for-${uid}`,
}));

// Imported after the mock, and never as a listening server.
const { default: server } = await import("../src/index");

const PASSWORD = "correct-horse-8";

/** The nonce the "app" hashed into its ASAuthorization request. Distinctive so a leak of it
 *  into a body, a header or a log line is findable by substring. */
const RAW_NONCE = "raw-nonce-a1b2c3d4e5";
const IDENTITY_TOKEN = "apple-identity-token-f6g7h8";

const appleBody = () => ({
    provider: "apple",
    identityToken: IDENTITY_TOKEN,
    rawNonce: RAW_NONCE,
});

const newEmail = () => `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;

const createdUids: string[] = [];

/** An Auth user with no Eva document — what Firebase leaves behind when it creates an
 *  account for a provider `sub` it has not seen. */
const createAuthUser = async (email: string): Promise<string> => {
    const { uid } = await adminAuth.createUser({ email });
    createdUids.push(uid);
    return uid;
};

const trackedUnactivatedAccount = async (email: string): Promise<string> => {
    const uid = await createUnactivatedAccount(email, PASSWORD);
    createdUids.push(uid);
    return uid;
};

interface Answer {
    status: number;
    /** The raw bytes, not a parse of them: a leak may be anywhere in the response. */
    text: string;
    headers: string;
    body: any;
}

const send = async (
    method: string,
    path: string,
    body: unknown,
    headers: Record<string, string> = {},
): Promise<Answer> => {
    const res = await server.fetch(
        new Request(`http://api.test${path}`, {
            method,
            headers: { "content-type": "application/json", ...headers },
            body: JSON.stringify(body),
        }),
    );
    const text = await res.text();
    return {
        status: res.status,
        text,
        headers: JSON.stringify([...res.headers]),
        body: text === "" ? null : JSON.parse(text),
    };
};

const post = (path: string, body: unknown, headers?: Record<string, string>) =>
    send("POST", path, body, headers);

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

/** Every `users/{uid}` id holding this address. The whole point of the identity rule is
 *  what this returns, so it is asked directly of Firestore rather than of a route. */
const accountsForEmail = async (email: string): Promise<string[]> =>
    (await firestore.collection("users").where("email", "==", email).get()).docs
        .map((doc) => doc.id)
        .sort();

/**
 * Does this password still open this account? The question the takeover fix turns on.
 *
 * Asked of Google **directly**, with `fetch`, deliberately touching neither `POST
 * /auth/signin` nor `identity-toolkit.ts`. Both are unusable for it:
 *
 * - The route would answer `403 NOT_ACTIVATED` for exactly the accounts this cares about,
 *   hiding a live credential behind a gate.
 * - The module is replaced by `mock.module` in this file *and* in
 *   `signin-non-enumeration.test.ts`. Those mocks are process-global, permanent, and
 *   installed by whichever file Bun loads first — so even the snapshot taken at the top of
 *   this file can already be another suite's fake. An earlier version of this helper used
 *   that snapshot, passed when the file ran alone, and reported "the password was already
 *   dead" for every account in a full run.
 *
 * Not touching the module at all is the only version that answers about the credential
 * rather than about the test run.
 */
const passwordStillWorks = async (email: string, password: string): Promise<boolean> => {
    const res = await fetch(
        `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${config.firebaseWebApiKey}`,
        {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ email, password, returnSecureToken: true }),
        },
    );
    return res.ok;
};

const activatedAt = async (uid: string): Promise<unknown> =>
    (await firestore.collection("users").doc(uid).get()).get("activatedAt");

/** Slow because each case is a chain of real round trips to Auth and Firestore. */
const SLOW = 20_000;

beforeEach(() => {
    resetAuthRateLimits();
    idp = null;
    lastIdp = null;
});

afterAll(async () => {
    resetAuthRateLimits();
    idp = null;
    for (const uid of createdUids) {
        await adminAuth.deleteUser(uid).catch(() => {});
        await firestore.collection("users").doc(uid).delete().catch(() => {});
    }
    // Hand the module back as it was found — Bun's mocks are permanent and process-global.
    mock.module("../src/identity-toolkit", () => identityToolkit);
}, 120_000);

describe("POST /auth/idp — identity is the provider's sub, and only sub", () => {
    test(
        "a sub Firebase has seen lands on the same users/{uid}, with no second document",
        async () => {
            const email = newEmail();
            const uid = await createAuthUser(email);
            idp = () => ({ localId: uid, email });

            const first = await post("/auth/idp", appleBody());
            const second = await post("/auth/idp", appleBody());

            expect(first.status).toBe(200);
            expect(second.status).toBe(200);
            expect(first.body.user.id).toBe(uid);
            expect(second.body.user.id).toBe(uid);
            expect(first.body.token).toBeString();
            // One document, not two — the acceptance criterion, asked of Firestore.
            expect(await accountsForEmail(email)).toEqual([uid]);
            expect(first.body.user.authProviders).toEqual([PROVIDER_IDS.apple]);
            // A second sign-in adds no duplicate: `arrayUnion`, and the returned copy of it.
            expect(second.body.user.authProviders).toEqual([PROVIDER_IDS.apple]);
        },
        SLOW,
    );

    test(
        "the account is whichever uid the boundary returns — this route never looks up an email",
        async () => {
            // Whether a shared address resolves to one account or two is **Firebase's**
            // decision (`Settings → User account linking`, set to "Link accounts that use
            // the same email" on 2026-09-03), and it is made before this route sees
            // anything. What is ours, and all this can prove, is that the route adds no
            // second opinion: it acts on the uid it was handed and performs no lookup of
            // its own. A regression that grew one would show up here as the pre-existing
            // account being touched.
            //
            // This is also the real Hide My Email case: a relay address matches nothing,
            // so Firebase hands back a new uid and the user gets a new account.
            const email = newEmail();
            const passwordUid = await trackedUnactivatedAccount(email);
            const appleUid = await createAuthUser(newEmail());
            idp = () => ({ localId: appleUid, email });

            const res = await post("/auth/idp", appleBody());

            expect(res.status).toBe(200);
            expect(res.body.user.id).toBe(appleUid);
            expect(res.body.user.id).not.toBe(passwordUid);
            expect(await accountsForEmail(email)).toEqual([appleUid, passwordUid].sort());

            // The account the route was NOT pointed at is untouched — no link, no
            // activation, and its password still its own.
            const original = (await getUser(passwordUid))!;
            expect(original.authProviders).toEqual(["password"]);
            expect(original.activated).toBe(false);
            expect(await passwordStillWorks(email, PASSWORD)).toBe(true);
        },
        SLOW,
    );

    test(
        "linking onto an unactivated password account kills the password that was never proven",
        async () => {
            // The takeover this closes: Firebase merges a provider sign-in into an existing
            // account when the addresses match, and `POST /auth/signup` (#6) creates that
            // account before anyone proves the address. So an attacker signs up as the
            // victim, waits for the victim to tap Sign in with Google, and inherits an
            // account this route then marks activated for them.
            const email = newEmail();
            const uid = await trackedUnactivatedAccount(email);
            idp = () => ({ localId: uid, email });

            // Asserted before as well as after, so the "false" below can only mean the
            // password changed — not that it was never right, or that some gate refused it.
            expect(await passwordStillWorks(email, PASSWORD)).toBe(true);

            const res = await post("/auth/idp", appleBody());
            expect(res.status).toBe(200);
            expect(res.body.user.id).toBe(uid);
            expect(await accountsForEmail(email)).toEqual([uid]);
            expect(res.body.user.authProviders.sort()).toEqual(
                ["password", PROVIDER_IDS.apple].sort(),
            );

            // The attacker's password is gone.
            expect(await passwordStillWorks(email, PASSWORD)).toBe(false);
        },
        SLOW,
    );

    test(
        "an already-activated account keeps its password when a provider is linked to it",
        async () => {
            // The other half, and the reason the check is on `activatedAt` rather than on
            // "has a password": someone who confirmed their address has proven the password
            // is theirs. Invalidating it here would log a real user out of their own
            // account for adding Apple to it.
            const email = newEmail();
            const uid = await trackedUnactivatedAccount(email);
            await markActivated(uid);
            idp = () => ({ localId: uid, email });

            expect(await passwordStillWorks(email, PASSWORD)).toBe(true);
            expect((await post("/auth/idp", appleBody())).status).toBe(200);
            expect(await passwordStillWorks(email, PASSWORD)).toBe(true);
        },
        SLOW,
    );

    test(
        "the session comes back activated, so a provider user never meets the #6 gate",
        async () => {
            const email = newEmail();
            const uid = await createAuthUser(email);
            idp = () => ({ localId: uid, email });

            const res = await post("/auth/idp", appleBody());

            expect(res.status).toBe(200);
            expect(res.body.user.activated).toBe(true);
            // Stamped, not merely reported: `activatedAt` is a timestamp, not the `null` a
            // new document starts with.
            expect(await activatedAt(uid)).not.toBeNull();
        },
        SLOW,
    );

    test("the raw nonce reaches the boundary", async () => {
        const email = newEmail();
        const uid = await createAuthUser(email);
        idp = () => ({ localId: uid, email });

        await post("/auth/idp", appleBody());

        expect(lastIdp?.credential).toEqual({
            provider: "apple",
            idToken: IDENTITY_TOKEN,
            rawNonce: RAW_NONCE,
        });
        // A sign-in, not a link: nothing was passed to link against.
        expect(lastIdp?.linkTo).toBeUndefined();
    }, SLOW);

    test("a credential the provider refuses is one answer, carrying none of its reason", async () => {
        idp = () => {
            throw new IdentityToolkitError("INVALID_IDP_RESPONSE", 400);
        };

        const res = await post("/auth/idp", appleBody());

        expect(res.status).toBe(401);
        expect(res.body.error.code).toBe("INVALID_CREDENTIALS");
        const whole = `${res.text} ${res.headers}`.toLowerCase();
        for (const leak of [
            "INVALID_IDP_RESPONSE",
            "Identity Toolkit",
            RAW_NONCE,
            IDENTITY_TOKEN,
        ]) {
            expect(whole).not.toContain(leak.toLowerCase());
        }
    });

    test("an upstream outage is 503 with the constant Retry-After, not a 500", async () => {
        idp = () => {
            throw new IdentityToolkitError("INTERNAL_ERROR", 500);
        };

        const res = await post("/auth/idp", appleBody());

        expect(res.status).toBe(503);
        expect(res.body.error.code).toBe("SERVICE_UNAVAILABLE");
        expect(res.headers).toContain("retry-after");
    });

    test("the body is validated at the edge", async () => {
        for (const body of [
            {},
            { provider: "facebook", identityToken: "t", rawNonce: "n" },
            { provider: "apple", identityToken: IDENTITY_TOKEN },
            { provider: "apple", rawNonce: RAW_NONCE },
            { provider: "apple", identityToken: "", rawNonce: RAW_NONCE },
            { provider: "google", code: "c", codeVerifier: "v" },
            { provider: "google", code: "c", codeVerifier: "v", redirectUri: "not a uri" },
        ]) {
            const res = await post("/auth/idp", body);
            expect(res.status).toBe(400);
            expect(res.body.error.code).toBe("VALIDATION");
        }
        // Nothing reached the boundary: validation is the edge, not the module.
        expect(lastIdp).toBeNull();
    });

    test.skipIf(config.providers.googleIosClientId !== null)(
        "Google is unavailable, not broken, while its client id is unprovisioned",
        async () => {
            const res = await post("/auth/idp", {
                provider: "google",
                code: "auth-code",
                codeVerifier: "code-verifier",
                redirectUri: "com.googleusercontent.apps.1234:/oauth2redirect",
            });

            expect(res.status).toBe(503);
            expect(res.body.error.code).toBe("SERVICE_UNAVAILABLE");
            expect(lastIdp).toBeNull();
        },
    );
});

describe("POST /me/auth/providers — linking is deliberate, and never a merge", () => {
    /** An activated password account and a session for it. */
    const signedIn = async (): Promise<{ uid: string; email: string; token: string }> => {
        const email = newEmail();
        const uid = await trackedUnactivatedAccount(email);
        await markActivated(uid);
        return { uid, email, token: await mintToken(uid, email) };
    };

    test(
        "a provider attaches to the account the bearer token names",
        async () => {
            const { uid, email, token } = await signedIn();
            idp = () => ({ localId: uid, email });

            const res = await post("/me/auth/providers", appleBody(), bearer(token));

            expect(res.status).toBe(200);
            expect(res.body.user.id).toBe(uid);
            expect(res.body.user.authProviders).toEqual(["password", PROVIDER_IDS.apple]);
            // Persisted, not just reported.
            expect((await getUser(uid))!.authProviders).toEqual([
                "password",
                PROVIDER_IDS.apple,
            ]);
            // Linked against *this* account's Firebase ID token, which is what makes it a
            // link rather than a sign-in.
            expect(lastIdp?.linkTo).toBe(`firebase-id-token-for-${uid}`);
            expect(lastIdp?.credential.rawNonce).toBe(RAW_NONCE);
            // No second account was created for the address.
            expect(await accountsForEmail(email)).toEqual([uid]);
        },
        SLOW,
    );

    test(
        "a sub already owned by another account is refused, and nothing is merged",
        async () => {
            const { uid, token } = await signedIn();
            idp = () => {
                throw new IdentityToolkitError("FEDERATED_USER_ID_ALREADY_LINKED", 400);
            };

            const res = await post("/me/auth/providers", appleBody(), bearer(token));

            expect(res.status).toBe(409);
            expect(res.body.error.code).toBe("PROVIDER_ALREADY_LINKED");
            // The account is exactly as it was: no provider added, no silent merge.
            expect((await getUser(uid))!.authProviders).toEqual(["password"]);
        },
        SLOW,
    );

    test("it needs a session", async () => {
        const res = await post("/me/auth/providers", appleBody());
        expect(res.status).toBe(401);
        expect(res.body.error.code).toBe("UNAUTHORIZED");
        expect(lastIdp).toBeNull();
    });
});

describe("DELETE /me — Apple revocation never fails the delete", () => {
    test(
        "an unrevokable code still deletes the account, and logs no credential",
        async () => {
            const email = newEmail();
            const uid = await trackedUnactivatedAccount(email);
            const token = await mintToken(uid, email);
            const APPLE_CODE = "apple-authorization-code-z9y8x7";
            const logged: string[] = [];
            const spy = spyOn(console, "error").mockImplementation((...args: unknown[]) => {
                logged.push(args.map(String).join(" "));
            });

            let res: Answer;
            try {
                res = await send("DELETE", "/me", { appleAuthorizationCode: APPLE_CODE }, bearer(token));
            } finally {
                spy.mockRestore();
            }

            // Apple is unprovisioned in every environment this suite runs in, so the
            // revocation cannot succeed — which is the case under test: the delete goes
            // through anyway. A configured environment takes the same branch on any Apple
            // failure, and that half is unproven here.
            expect(res.status).toBe(200);
            expect(res.body).toEqual({ deleted: true });
            expect(await getUser(uid)).toBeNull();
            expect((await firestore.collection("users").doc(uid).get()).exists).toBe(false);
            await expect(adminAuth.getUser(uid)).rejects.toThrow();

            // One line, and nothing in it that a credential could be recovered from.
            const line = logged.join(" ");
            expect(line).toContain("apple_revocation_failed");
            expect(line).toContain("unconfigured");
            expect(line).not.toContain(APPLE_CODE);
            expect(line).not.toContain(email);
            expect(line).not.toContain(uid);
        },
        SLOW,
    );

    test(
        "a delete with no authorization code is exactly what it was",
        async () => {
            const email = newEmail();
            const uid = await trackedUnactivatedAccount(email);
            const token = await mintToken(uid, email);

            const res = await send("DELETE", "/me", {}, bearer(token));

            expect(res.status).toBe(200);
            expect(res.body).toEqual({ deleted: true });
            expect(await getUser(uid)).toBeNull();
        },
        SLOW,
    );
});

describe("identity-toolkit puts the nonce on the wire", () => {
    /**
     * The one part of the Apple flow that is ours rather than Firebase's: the raw nonce has
     * to arrive at `accounts:signInWithIdp` inside `postBody`, because Firebase hashing it
     * and comparing with the token's is the whole of what stops a captured `identityToken`
     * being replayed here by somebody else. The test above proves the route passes it along;
     * this proves the module sends it.
     *
     * The real client, against a stubbed `fetch`. The request URL is deliberately never
     * asserted on or printed — it carries the Firebase web API key (GUARDRAILS 1).
     */
    test("the Apple credential is sent as id_token + providerId + nonce", async () => {
        let sentBody: unknown = null;
        const spy = spyOn(globalThis, "fetch").mockImplementation((async (
            _url: unknown,
            init: { body?: string },
        ) => {
            sentBody = JSON.parse(init.body!);
            return new Response(
                JSON.stringify({ localId: "wire-test-uid", email: "e2e+wire@e2e.evaapp.dev" }),
                { status: 200, headers: { "content-type": "application/json" } },
            );
        }) as never);

        try {
            const result = await realSignInWithIdp({
                provider: "apple",
                idToken: IDENTITY_TOKEN,
                rawNonce: RAW_NONCE,
            });
            expect(result.localId).toBe("wire-test-uid");
        } finally {
            spy.mockRestore();
        }

        const postBody = new URLSearchParams(
            (sentBody as { postBody: string }).postBody,
        );
        expect(postBody.get("id_token")).toBe(IDENTITY_TOKEN);
        expect(postBody.get("providerId")).toBe(PROVIDER_IDS.apple);
        expect(postBody.get("nonce")).toBe(RAW_NONCE);
        // Not a link: no account ID token was attached.
        expect((sentBody as { idToken?: string }).idToken).toBeUndefined();
    });

    test("a Google credential carries no nonce, because Google's flow has none", async () => {
        let sentBody: unknown = null;
        const spy = spyOn(globalThis, "fetch").mockImplementation((async (
            _url: unknown,
            init: { body?: string },
        ) => {
            sentBody = JSON.parse(init.body!);
            return new Response(
                JSON.stringify({ localId: "wire-test-uid", email: "e2e+wire@e2e.evaapp.dev" }),
                { status: 200, headers: { "content-type": "application/json" } },
            );
        }) as never);

        try {
            await realSignInWithIdp({ provider: "google", idToken: "google-id-token" });
        } finally {
            spy.mockRestore();
        }

        const postBody = new URLSearchParams((sentBody as { postBody: string }).postBody);
        expect(postBody.get("providerId")).toBe(PROVIDER_IDS.google);
        expect(postBody.has("nonce")).toBe(false);
    });
});

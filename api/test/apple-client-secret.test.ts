import { afterEach, describe, expect, test } from "bun:test";
import { config } from "../src/config";
import { revokeAppleToken } from "../src/providers";

/**
 * The Apple client secret, actually constructed (#7).
 *
 * ## Why this file exists
 *
 * `appleClientSecret` had never run. Not once, in any suite, on either verify path — the
 * only test that reached `revokeAppleToken` did so with Apple unprovisioned, so it took the
 * `unconfigured` early return and stopped one line short. `pemToDer`, the pkcs8 import, the
 * `kid` header and the raw `r‖s` signature were all dead code as far as verification went.
 *
 * That matters more here than the coverage number suggests, because **a wrong client secret
 * fails silently by design**: revocation is non-fatal, so `DELETE /me` still answers
 * `200 { deleted: true }` and the only trace is one log line. The failure mode is Apple's
 * App Review entitlement quietly unmet in production — which is the exact thing
 * `docs/PROVIDER-SIGNIN.md` §3 warns about — with a green suite and a successful delete.
 *
 * ## What is real here
 *
 * Everything on our side of the wire. A genuine P-256 key pair is generated, exported as
 * pkcs8, PEM-wrapped exactly as Secret Manager stores a `.p8`, and the JWT that comes back
 * is **verified against the matching public key**. So this proves the bytes Apple would
 * check, not merely that a string of three dot-separated parts was produced.
 *
 * Not real, and not claimable: that Apple accepts it. That needs Apple.
 *
 * `config` is mutated and restored rather than mocked — it is a plain object, and the
 * alternative is a module mock, which in Bun is process-global and permanent.
 */

const APPLE_AUDIENCE = "https://appleid.apple.com";

const TEAM_ID = "TEAMID1234";
const KEY_ID = "KEYID56789";
const CLIENT_ID = "com.evaapp.ios";

const pem = (der: ArrayBuffer): string => {
    const body = Buffer.from(der).toString("base64").replace(/(.{64})/g, "$1\n");
    return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`;
};

const decodePart = (part: string): any =>
    JSON.parse(Buffer.from(part.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString());

const original = { ...config.providers.apple };

afterEach(() => {
    Object.assign(config.providers.apple, original);
});

/** Provisions Apple with a real key pair and returns the public half for verification. */
const provision = async (): Promise<CryptoKey> => {
    const pair = await crypto.subtle.generateKey(
        { name: "ECDSA", namedCurve: "P-256" },
        true,
        ["sign", "verify"],
    );
    const der = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    Object.assign(config.providers.apple, {
        clientId: CLIENT_ID,
        teamId: TEAM_ID,
        keyId: KEY_ID,
        signingKey: pem(der),
    });
    return pair.publicKey;
};

/** Runs a revocation with `fetch` stubbed, and hands back what went to Apple's token
 *  endpoint. Nothing leaves the process. */
const capture = async (
    respond: (url: string) => Response,
): Promise<{ urls: string[]; bodies: URLSearchParams[]; outcome: Awaited<ReturnType<typeof revokeAppleToken>> }> => {
    const urls: string[] = [];
    const bodies: URLSearchParams[] = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = (async (input: any, init?: any) => {
        const url = String(input?.url ?? input);
        urls.push(url);
        bodies.push(new URLSearchParams(String(init?.body ?? "")));
        return respond(url);
    }) as typeof fetch;
    try {
        return { urls, bodies, outcome: await revokeAppleToken("an-authorization-code") };
    } finally {
        globalThis.fetch = realFetch;
    }
};

const ok = (body: unknown) =>
    new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
    });

describe("the Apple client secret is a JWT Apple could verify", () => {
    test("it is ES256 over the exact bytes, and the signature checks out", async () => {
        const publicKey = await provision();

        const { bodies, outcome } = await capture(() => ok({ refresh_token: "rt" }));

        expect(outcome).toEqual({ ok: true, stage: "revoked", upstreamStatus: null });
        const secret = bodies[0]!.get("client_secret")!;
        expect(secret).toBeString();

        const [headerPart, payloadPart, signaturePart] = secret.split(".");
        expect(headerPart && payloadPart && signaturePart).toBeTruthy();

        // `kid` in the header is the reason this is hand-rolled rather than `hono/jwt`.
        expect(decodePart(headerPart!)).toEqual({ alg: "ES256", kid: KEY_ID, typ: "JWT" });

        const payload = decodePart(payloadPart!);
        expect(payload.iss).toBe(TEAM_ID);
        expect(payload.aud).toBe(APPLE_AUDIENCE);
        // The App ID, not the Services ID. A native `ASAuthorization` code is issued to the
        // bundle identifier, and exchanging it under the Services ID is refused — silently,
        // because revocation is non-fatal.
        expect(payload.sub).toBe(CLIENT_ID);
        expect(payload.exp).toBeGreaterThan(payload.iat);

        // JWS says ES256 is the raw r‖s pair over P-256: 64 bytes, no DER wrapper.
        const signature = Buffer.from(
            signaturePart!.replace(/-/g, "+").replace(/_/g, "/"),
            "base64",
        );
        expect(signature.length).toBe(64);

        // The whole point: Apple verifies this, so the test does too.
        const verified = await crypto.subtle.verify(
            { name: "ECDSA", hash: "SHA-256" },
            publicKey,
            signature,
            new TextEncoder().encode(`${headerPart}.${payloadPart}`),
        );
        expect(verified).toBe(true);
    });

    test("the token request is an authorization-code exchange carrying the code", async () => {
        // The Google half of this was asserted in google-exchange.test.ts; the Apple half
        // was not. `grant_type: "refresh_token"` with `code` deleted entirely left the whole
        // suite green — this file verifies `client_secret` to the byte and never looked at
        // the rest of the body it travels in.
        //
        // Which is the same silence the file's header is about: revocation is non-fatal, so
        // `DELETE /me` still answers 200 and the App Review entitlement is quietly unmet.
        await provision();

        const { bodies } = await capture(() => ok({ refresh_token: "rt" }));

        const body = bodies[0]!;
        expect(body.get("grant_type")).toBe("authorization_code");
        expect(body.get("code")).toBe("an-authorization-code");
        expect(body.get("client_id")).toBe(CLIENT_ID);
    });

    test("the same secret is presented to both endpoints, and the refresh token is what gets revoked", async () => {
        await provision();

        const { urls, bodies } = await capture((url) =>
            url.includes("/auth/token")
                ? ok({ refresh_token: "the-refresh-token", access_token: "the-access-token" })
                : ok({}),
        );

        expect(urls).toEqual([
            "https://appleid.apple.com/auth/token",
            "https://appleid.apple.com/auth/revoke",
        ]);
        // Revoking the refresh token revokes everything derived from it; the access token
        // is only the fallback for a response that carries no refresh token.
        expect(bodies[1]!.get("token")).toBe("the-refresh-token");
        expect(bodies[1]!.get("token_type_hint")).toBe("refresh_token");
        expect(bodies[1]!.get("client_secret")).toBe(bodies[0]!.get("client_secret"));
        expect(bodies[1]!.get("client_id")).toBe(CLIENT_ID);
    });

    test("a response with only an access token still revokes, and says so", async () => {
        await provision();

        const { urls, bodies } = await capture((url) =>
            url.includes("/auth/token") ? ok({ access_token: "only-an-access-token" }) : ok({}),
        );

        expect(urls.length).toBe(2);
        expect(bodies[1]!.get("token")).toBe("only-an-access-token");
        // The hint has to follow the token. Apple takes `token_type_hint` at its word, so
        // an access token labelled `refresh_token` is refused — and refused *silently*,
        // because revocation is non-fatal by design and the delete succeeds anyway. That
        // is the App Review entitlement quietly unmet, which is what this file exists for.
        expect(bodies[1]!.get("token_type_hint")).toBe("access_token");
    });
});

describe("an outage at Apple is an outage, not a spent code", () => {
    // Deliberately not named for `classify`: `revokeAppleToken` maps every token-endpoint
    // failure to `stage: "token"` and discards `kind`, so nothing here can tell `rejected`
    // from `unavailable`. Collapsing `classify` leaves this test green. Where that
    // distinction is actually load-bearing is the Google route, and it is asserted there.
    test("a 500 from the token endpoint is reported as a token-stage failure with its status", async () => {
        // `classify` in providers.ts had no test: collapsing it to always-`rejected` was
        // green. It decides whether the caller is told their credential is bad or an
        // operator is told the provider is down — and on the Google path the wrong answer
        // is silent, because `rejected` becomes a 401 with no log line at all.
        await provision();

        // JSON, so this goes through `classify` rather than the malformed-response branch
        // in front of it — the two are different paths and only one is under test here.
        const { outcome } = await capture(
            () => new Response(JSON.stringify({ error: "backend_error" }), {
                status: 500,
                headers: { "content-type": "application/json" },
            }),
        );

        expect(outcome.ok).toBe(false);
        expect(outcome.stage).toBe("token");
        // The status is what the operator is paged with; it must survive the mapping.
        expect(outcome.upstreamStatus).toBe(500);
    });

    test("a 429 is the same — retry, do not tell the user their code is bad", async () => {
        await provision();

        const { outcome } = await capture(
            () => new Response(JSON.stringify({ error: "rate_limited" }), {
                status: 429,
                headers: { "content-type": "application/json" },
            }),
        );

        expect(outcome.upstreamStatus).toBe(429);
    });
});

describe("a key that will not sign is reported as ours, not as the caller's", () => {
    test("a malformed .p8 is `client-secret`, not `token`", async () => {
        // The realistic corruption: a `\n` that did not survive the env var, a PKCS#1 key
        // where PKCS#8 was expected, a truncated paste. Reported as `token` this reads as
        // "the code was already spent" and sends the operator to look at the client.
        Object.assign(config.providers.apple, {
            clientId: CLIENT_ID,
            teamId: TEAM_ID,
            keyId: KEY_ID,
            signingKey: "-----BEGIN PRIVATE KEY-----\nbm90LWEta2V5\n-----END PRIVATE KEY-----\n",
        });

        const { urls, outcome } = await capture(() => ok({ refresh_token: "rt" }));

        expect(outcome).toEqual({ ok: false, stage: "client-secret", upstreamStatus: null });
        // It never got as far as talking to Apple, which is the fact the stage now carries.
        expect(urls).toEqual([]);
    });

    test("a partly-provisioned Apple is unconfigured, not a signing failure", async () => {
        Object.assign(config.providers.apple, {
            clientId: CLIENT_ID,
            teamId: TEAM_ID,
            keyId: null,
            signingKey: null,
        });

        const { urls, outcome } = await capture(() => ok({}));

        expect(outcome).toEqual({ ok: false, stage: "unconfigured", upstreamStatus: null });
        expect(urls).toEqual([]);
    });
});

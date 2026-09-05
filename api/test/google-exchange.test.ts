import { afterEach, describe, expect, test } from "bun:test";
import { config } from "../src/config";
import { exchangeGoogleAuthCode, ProviderError } from "../src/providers";

/**
 * Google's PKCE code exchange, actually asserted (#7).
 *
 * ## Why this file exists
 *
 * `apple-client-secret.test.ts` was written because `appleClientSecret` had never run. The
 * same gap was sitting on the other provider and went unnoticed in the same review round:
 * nothing anywhere asserted what `exchangeGoogleAuthCode` puts on the wire. Deleting
 * `code_verifier` left the suite green. So did changing `grant_type` to `refresh_token`.
 *
 * And it fails as quietly as the Apple secret did. `ProviderError('rejected')` becomes
 * `401 INVALID_CREDENTIALS` at the route with **no log line**, so a wrong request body would
 * present in production as every Google user's credential being bad, with nothing pointing
 * at the request we sent.
 *
 * ## What is real here
 *
 * The request. `fetch` is stubbed, so nothing leaves the process and the test does not
 * depend on whether `GOOGLE_IOS_CLIENT_ID` happens to be set in `api/.env` — it sets it.
 * What Google would do with the request is Google's, and not claimable from here.
 */

const CLIENT_ID = "1234-abcd.apps.googleusercontent.com";
const CODE = "the-authorization-code";
const VERIFIER = "the-code-verifier-43-chars-minimum-per-rfc7636";
const REDIRECT = "com.googleusercontent.apps.1234:/oauth2redirect";

const original = config.providers.googleIosClientId;

afterEach(() => {
    (config.providers as { googleIosClientId: string | null }).googleIosClientId = original;
});

const provision = () => {
    (config.providers as { googleIosClientId: string | null }).googleIosClientId = CLIENT_ID;
};

const capture = async (
    respond: () => Response,
): Promise<{ urls: string[]; bodies: URLSearchParams[]; headers: Record<string, string>[] }> => {
    const urls: string[] = [];
    const bodies: URLSearchParams[] = [];
    const headers: Record<string, string>[] = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = (async (input: any, init?: any) => {
        urls.push(String(input?.url ?? input));
        bodies.push(new URLSearchParams(String(init?.body ?? "")));
        headers.push({ ...(init?.headers ?? {}) });
        return respond();
    }) as typeof fetch;
    try {
        await exchangeGoogleAuthCode({
            code: CODE,
            codeVerifier: VERIFIER,
            redirectUri: REDIRECT,
        }).catch(() => undefined);
        return { urls, bodies, headers };
    } finally {
        globalThis.fetch = realFetch;
    }
};

const ok = (body: unknown) =>
    new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
    });

describe("the Google token request is the one PKCE requires", () => {
    test("every parameter Google checks is present and is the value it was given", async () => {
        provision();

        const { urls, bodies, headers } = await capture(() => ok({ id_token: "an-id-token" }));

        expect(urls).toEqual(["https://oauth2.googleapis.com/token"]);
        const body = bodies[0]!;
        expect(body.get("grant_type")).toBe("authorization_code");
        expect(body.get("code")).toBe(CODE);
        // The whole of PKCE. Without it the exchange is a bearer-code flow that any app
        // holding an intercepted code could complete, which is why the app runs PKCE at all
        // instead of pulling in the GoogleSignIn SDK.
        expect(body.get("code_verifier")).toBe(VERIFIER);
        expect(body.get("redirect_uri")).toBe(REDIRECT);
        expect(body.get("client_id")).toBe(CLIENT_ID);
        // An iOS OAuth client has no secret, and sending an empty one is not the same as
        // sending none: Google rejects the request rather than ignoring the parameter.
        expect(body.has("client_secret")).toBe(false);
        // Form-encoded, and said so. The body and the header are set in different places,
        // so they can drift apart — and if they do, both provider token endpoints reject
        // every request, which on this path is a silent 401 for every Google user.
        expect(headers[0]!["content-type"]).toBe("application/x-www-form-urlencoded");
    });

    test("only the id_token is kept out of the response", async () => {
        provision();

        const realFetch = globalThis.fetch;
        globalThis.fetch = (async (_input: any) =>
            ok({
                id_token: "the-id-token",
                access_token: "an-access-token-for-apis-eva-does-not-call",
                refresh_token: "a-refresh-token-worth-keeping-out-of-eva",
            })) as typeof fetch;
        try {
            expect(
                await exchangeGoogleAuthCode({
                    code: CODE,
                    codeVerifier: VERIFIER,
                    redirectUri: REDIRECT,
                }),
            ).toBe("the-id-token");
        } finally {
            globalThis.fetch = realFetch;
        }
    });

    test("a response with no id_token is the caller's fault, not an outage", async () => {
        provision();
        const realFetch = globalThis.fetch;
        globalThis.fetch = (async (_input: any) => ok({ access_token: "no-openid-scope" })) as typeof fetch;
        try {
            await expect(
                exchangeGoogleAuthCode({
                    code: CODE,
                    codeVerifier: VERIFIER,
                    redirectUri: REDIRECT,
                }),
            ).rejects.toThrow(ProviderError);
        } finally {
            globalThis.fetch = realFetch;
        }
    });

    test("an error page in front of Google is an outage, not a bad code", async () => {
        // A proxy or load balancer answering HTML is a verdict about nothing. It has its
        // own branch in `form`, ahead of `classify`, and needs its own test: a 502 with a
        // non-JSON body was for a while the only "outage" case covered anywhere, which meant
        // `classify` itself could be collapsed to always-`rejected` with the suite green.
        //
        // Told apart because the consequences differ: `rejected` is a 401 with no log line,
        // so a Google outage would present as every user's credential being bad.
        provision();
        const realFetch = globalThis.fetch;
        globalThis.fetch = (async (_input: any) =>
            new Response("<html>502 Bad Gateway</html>", { status: 502 })) as typeof fetch;

        let thrown: unknown;
        try {
            await exchangeGoogleAuthCode({
                code: CODE,
                codeVerifier: VERIFIER,
                redirectUri: REDIRECT,
            }).catch((err) => {
                thrown = err;
            });
        } finally {
            globalThis.fetch = realFetch;
        }

        expect(thrown).toBeInstanceOf(ProviderError);
        expect((thrown as InstanceType<typeof ProviderError>).kind).toBe("unavailable");
        expect((thrown as InstanceType<typeof ProviderError>).upstreamStatus).toBe(502);
    });

    test("an unprovisioned client id sends nothing at all", async () => {
        (config.providers as { googleIosClientId: string | null }).googleIosClientId = null;

        const { urls } = await capture(() => ok({ id_token: "should-never-be-reached" }));

        expect(urls).toEqual([]);
    });
});

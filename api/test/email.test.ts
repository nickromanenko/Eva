import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { createHash } from "node:crypto";
import { EmailError, createEmailSender, type EmailOptions, type FetchLike } from "../src/email";

/**
 * The transport (#6): what leaves for Postmark, what the `log` transport prints, and —
 * the part this file spends most of its assertions on — what is written to the console
 * when a send fails. A token, its hash, or the recipient's address in a log line is the
 * link itself, or the fact that the address has an account (GUARDRAILS 12).
 *
 * The sender is built here with a stubbed `fetch` rather than driven through the routes:
 * `config.email` is fixed at boot to whatever `.env` says, and the live suites run under
 * the `log` transport, so the Postmark path is only reachable by constructing it.
 */

/** Deliberately not shaped like a real token, so it is findable by substring. */
const TOKEN = "LEAK-RAW-TOKEN-6-" + "x".repeat(26);
const TOKEN_HASH = createHash("sha256").update(TOKEN).digest("hex");
const TO = "e2e+email-transport-leak@e2e.evaapp.dev";
/** A fake, and findable. */
const API_KEY = "LEAK-POSTMARK-KEY-6";

const postmarkOptions: EmailOptions = {
    transport: "postmark",
    postmarkApiKey: API_KEY,
    from: "hello@eva.test",
    publicWebUrl: "https://web.eva.test",
};

const LEAKS = [TOKEN, TOKEN_HASH, "email-transport-leak", "evaapp.dev", API_KEY];

const expectNoLeak = (haystack: string) => {
    for (const leak of LEAKS) expect(haystack).not.toContain(leak);
};

/** Every console line written during a test, whichever stream it went to. */
let logged: string[] = [];
let spies: ReturnType<typeof spyOn>[] = [];

beforeEach(() => {
    logged = [];
    spies = (["log", "error", "warn", "info"] as const).map((level) =>
        spyOn(console, level).mockImplementation((...args: unknown[]) => {
            logged.push(args.map((a) => String(a)).join(" "));
        }),
    );
});
afterEach(() => {
    for (const spy of spies) spy.mockRestore();
});

interface Captured {
    url: string;
    init: RequestInit | undefined;
    body: Record<string, string>;
}

/** A `fetch` that records the one request and answers as told. */
const capturing = (answer: () => Response | never) => {
    const calls: Captured[] = [];
    const fetchImpl: FetchLike = async (url, init) => {
        calls.push({ url, init, body: JSON.parse(String(init?.body)) });
        return answer();
    };
    return { calls, fetchImpl };
};

const ok = () => new Response(JSON.stringify({ ErrorCode: 0, Message: "OK" }), { status: 200 });

describe("what goes to Postmark", () => {
    test("one POST, token in the header, both bodies carrying the activation link", async () => {
        const { calls, fetchImpl } = capturing(ok);
        const sender = createEmailSender(postmarkOptions, fetchImpl);

        await sender.sendActivationEmail(TO, TOKEN);

        expect(calls).toHaveLength(1);
        const [call] = calls;
        expect(call!.url).toBe("https://api.postmarkapp.com/email");
        expect(call!.init?.method).toBe("POST");
        const headers = call!.init?.headers as Record<string, string>;
        expect(headers["x-postmark-server-token"]).toBe(API_KEY);
        expect(headers["content-type"]).toBe("application/json");

        const link = `https://web.eva.test/activate#token=${TOKEN}`;
        expect(call!.body.From).toBe("hello@eva.test");
        expect(call!.body.To).toBe(TO);
        expect(call!.body.Subject).toBe("Confirm your email for Eva");
        expect(call!.body.TextBody).toContain(link);
        expect(call!.body.HtmlBody).toContain(`href="${link}"`);
        expect(call!.body.TextBody).toContain("24 hours");
        expect(call!.body.MessageStream).toBe("outbound");
    });

    test("the reset message: its own subject, link, lifetime, and the ignore-it line", async () => {
        const { calls, fetchImpl } = capturing(ok);
        const sender = createEmailSender(postmarkOptions, fetchImpl);

        await sender.sendPasswordResetEmail(TO, TOKEN);

        const body = calls[0]!.body;
        const link = `https://web.eva.test/reset#token=${TOKEN}`;
        expect(body.Subject).toBe("Reset your Eva password");
        expect(body.TextBody).toContain(link);
        expect(body.HtmlBody).toContain(`href="${link}"`);
        expect(body.TextBody).toContain("60 minutes");
        expect(body.TextBody).toContain("If you didn't ask for this");
    });

    test("a successful send logs nothing at all", async () => {
        const { fetchImpl } = capturing(ok);
        const sender = createEmailSender(postmarkOptions, fetchImpl);

        await sender.sendActivationEmail(TO, TOKEN);
        await sender.sendPasswordResetEmail(TO, TOKEN);

        expect(logged).toEqual([]);
    });

    test("a trailing slash on PUBLIC_WEB_URL is not the sender's problem to double", async () => {
        // config.ts strips it; this pins that the sender appends the path without a second
        // slash when handed the value config produces.
        const { calls, fetchImpl } = capturing(ok);
        await createEmailSender(postmarkOptions, fetchImpl).sendActivationEmail(TO, TOKEN);
        expect(calls[0]!.body.TextBody).not.toContain("//activate");
    });
});

describe("when Postmark does not take the message", () => {
    test("a non-2xx is an EmailError carrying the kind and the status", async () => {
        const { fetchImpl } = capturing(
            () => new Response(JSON.stringify({ ErrorCode: 300, Message: `Invalid 'To' address: '${TO}'` }), { status: 422 }),
        );
        const sender = createEmailSender(postmarkOptions, fetchImpl);

        const err = await sender.sendActivationEmail(TO, TOKEN).catch((e: unknown) => e);
        expect(err).toBeInstanceOf(EmailError);
        expect((err as EmailError).kind).toBe("activation");
        expect((err as EmailError).upstreamStatus).toBe(422);
    });

    test("a fetch that never lands is an EmailError with no status, and its message travels nowhere", async () => {
        const { fetchImpl } = capturing(() => {
            throw new Error(`Unable to connect: https://api.postmarkapp.com/email to=${TO}`);
        });
        const sender = createEmailSender(postmarkOptions, fetchImpl);

        const err = await sender.sendPasswordResetEmail(TO, TOKEN).catch((e: unknown) => e);
        expect(err).toBeInstanceOf(EmailError);
        expect((err as EmailError).kind).toBe("reset");
        expect((err as EmailError).upstreamStatus).toBeNull();
        expect((err as Error).cause).toBeUndefined();
        expectNoLeak(`${(err as Error).message} ${(err as Error).stack ?? ""}`);
    });

    test("the one log line names the kind and the status, and nothing about anyone", async () => {
        const { fetchImpl } = capturing(() => new Response("Service Unavailable", { status: 503 }));
        const sender = createEmailSender(postmarkOptions, fetchImpl);

        await sender.sendActivationEmail(TO, TOKEN).catch(() => {});

        expect(logged).toHaveLength(1);
        const line = JSON.parse(logged[0]!) as Record<string, unknown>;
        expect(Object.keys(line).sort()).toEqual(["event", "kind", "upstreamStatus"]);
        expect(line.event).toBe("email_send_failed");
        expect(line.kind).toBe("activation");
        expect(line.upstreamStatus).toBe(503);
    });

    test("no failure, of either kind, writes a token, a hash, an address, or the key", async () => {
        const down = capturing(() => new Response("", { status: 500 }));
        const unreachable = capturing(() => {
            throw new Error(`refused ${TO} ${TOKEN}`);
        });
        await createEmailSender(postmarkOptions, down.fetchImpl)
            .sendActivationEmail(TO, TOKEN)
            .catch(() => {});
        await createEmailSender(postmarkOptions, unreachable.fetchImpl)
            .sendPasswordResetEmail(TO, TOKEN)
            .catch(() => {});

        expect(logged).toHaveLength(2);
        expectNoLeak(logged.join("\n"));
    });
});

describe("the log transport", () => {
    const logOptions: EmailOptions = { ...postmarkOptions, transport: "log", postmarkApiKey: null };

    test("prints the whole link, prefixed, and calls nothing", async () => {
        const { calls, fetchImpl } = capturing(ok);
        const sender = createEmailSender(logOptions, fetchImpl);

        await sender.sendActivationEmail(TO, TOKEN);

        expect(calls).toHaveLength(0);
        expect(logged).toHaveLength(1);
        expect(logged[0]).toStartWith("[email:log] activation ");
        expect(logged[0]).toContain(`https://web.eva.test/activate#token=${TOKEN}`);
    });

    test("the postmark transport refuses to be built without a key", () => {
        expect(() => createEmailSender({ ...postmarkOptions, postmarkApiKey: null })).toThrow();
    });

    test(
        "the process refuses to boot with the log transport in production",
        async () => {
            // The safety valve under GUARDRAILS 12: `log` writes whole links to stdout,
            // which is a live credential in a log line. `config.ts` refuses it under
            // NODE_ENV=production, and that refusal is the only thing standing between a
            // careless deploy variable and every activation link in Cloud Logging — so it
            // is worth a test that actually boots the module.
            //
            // A subprocess, because `config.ts` reads the environment once at import and
            // this process has already imported it.
            const boot = Bun.spawn(["bun", "run", "src/config.ts"], {
                cwd: `${import.meta.dir}/..`,
                env: {
                    ...process.env,
                    NODE_ENV: "production",
                    EMAIL_TRANSPORT: "log",
                },
                stdout: "pipe",
                stderr: "pipe",
            });
            const [code, stderr] = await Promise.all([
                boot.exited,
                new Response(boot.stderr).text(),
            ]);

            expect(code).not.toBe(0);
            expect(stderr).toContain("EMAIL_TRANSPORT=log");
            // And the same environment minus the production flag boots fine, so the test
            // is about the refusal and not about some unrelated failure to start.
            const dev = Bun.spawn(["bun", "run", "src/config.ts"], {
                cwd: `${import.meta.dir}/..`,
                env: { ...process.env, NODE_ENV: "development", EMAIL_TRANSPORT: "log" },
                stdout: "pipe",
                stderr: "pipe",
            });
            expect(await dev.exited).toBe(0);
        },
        20_000,
    );
});

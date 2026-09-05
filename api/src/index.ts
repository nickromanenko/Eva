import { Hono, type Context } from "hono";
import { cors } from "hono/cors";
import { createMiddleware } from "hono/factory";
import { routePath } from "hono/route";
import { mintToken, requireAuth, type TokenClaims } from "./auth";
import { config } from "./config";
import { EmailError, sendActivationEmail, sendPasswordResetEmail } from "./email";
import { TOKEN_LENGTH, consumeToken, deleteTokensForUid, issueToken } from "./email-tokens";
import {
    authRetryAfterSeconds,
    consumeAuthAttempt,
    consumeProviderAttempt,
    consumeTokenAttempt,
    type ProviderRoute,
    type TokenRoute,
    type AuthRoute,
} from "./rate-limit";
import {
    IdentityToolkitError,
    PROVIDER_IDS,
    deleteAuthAccount,
    findAuthUidByEmail,
    idTokenForUid,
    claimUnprovenAccount,
    markCredentialsProven,
    retractUnprovenIdentities,
    setPassword,
    signInWithIdp,
    signInWithPassword,
    signUpWithPassword,
    type IdpCredential,
} from "./identity-toolkit";
import { ProviderError, exchangeGoogleAuthCode, revokeAppleToken } from "./providers";
import {
    RETENTION_DAYS,
    createEvent,
    deleteAllUserEvents,
    listEvents,
    restoreEvent,
    softDeleteEvent,
    updateEvent,
    type AppointmentPayload,
    type BodySignalsPayload,
    type CyclePayload,
    type EventPatch,
    type EventPayload,
    type EventSource,
    type LoggableEventType,
    type NewEvent,
    type SportPayload,
    type Symptom,
    type SymptomSeverity,
} from "./events";
import { getRefData, getSymptomRules, type SymptomRules } from "./refdata";
import {
    deleteUserDocument,
    ensureUser,
    getUser,
    isActivated,
    markActivated,
    markUserDeleted,
    readUser,
    saveQuestionnaire,
    type Profile,
    type User,
} from "./users";

const app = new Hono();

const error = (code: string, message: string) => ({ error: { code, message } });

/** Everything a caller is ever told about a failure nobody planned for. One sentence, the
 *  same one every time, plus the `ref` the handler below generates. */
const INTERNAL_MESSAGE = "Something went wrong on our end. Please try again.";

/** Identifier-shaped, or nothing. Bounds the one field whose text a library chooses. */
const ERROR_NAME = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;

const errorName = (err: unknown): string => {
    const name = err instanceof Error ? err.name : typeof err;
    return ERROR_NAME.test(name) ? name : "unknown";
};

/**
 * The floor under every route (issue #48). Nothing else changes: a handler that already
 * answers — every shaped 4xx, #32's Identity Toolkit mapping, #5's 429 — never throws, so
 * this is only reached when *nothing* handled the failure. A Firestore outage inside
 * `ensureUser` is the case that motivated it: before this it fell through to Hono's default
 * handler, which answers a bare `500` with no `{ error: { code, message } }` body at all.
 *
 * **What is not here is the point.** `err.message` reaches neither the body nor the log,
 * because nobody wrote it for either: #32 found that a failed `fetch`'s message names the
 * request URL and that URL carries the web API key, and a Firestore error's message can
 * name the document path, which is a uid. The same goes for `err.stack`, whose first line
 * *is* the message, and for `err.cause`, which is another error's message one hop away.
 * A library's choice of words is not a reviewed field, so it is treated as untrusted
 * (GUARDRAILS 1, 12).
 *
 * What the line carries instead, and why each field is safe to write down:
 * - `event` — a constant, so the count of these is alertable and greppable, next to
 *   `identity_toolkit_unavailable`. These two now separate an outage of Google's from an
 *   outage of anything else, and a bug of ours from either.
 * - `ref` — generated here from `crypto.randomUUID`, derived from nothing about the
 *   request. It is the one field also given to the caller (in `message`), so a user can
 *   quote it and an operator can find the single line it came from.
 * - `method` and `route` — `route` is the *registered* path (`/me/events/:id`), never
 *   `c.req.path`, which would carry the id, the query string, and — at
 *   `/me/body-signals/2026-08-27` — the date a user logged health data for, which
 *   GUARDRAILS 12 keeps out of logs as surely as the payload itself.
 * - `errorName` — a class name, chosen where the class is declared rather than formatted
 *   from runtime values, so `FirebaseError` vs `TypeError` distinguishes "the database is
 *   gone" from "we shipped a bug" with no data in it. Sanitized anyway, because a `name`
 *   *can* be assigned at runtime and this is the one field a library controls.
 *
 * The cost is real and worth stating: no stack, so this line locates a fault to a route
 * and a class, not to a line number. Reproducing from `route` + `errorName` is the trade
 * for a log that cannot leak. If that proves too thin, the answer is a reviewed field
 * (an error class of ours carrying a safe code), not the message.
 *
 * One boundary, stated rather than papered over: Hono routes only a thrown **`Error`**
 * here — `#handleError` rethrows anything else at the runtime, which answers its own
 * unshaped 500. Closing that means a wildcard middleware wrapping every request, which is
 * more routing surface than this is worth while nothing in the stack throws a non-Error;
 * it is filed, not fixed.
 */
app.onError((err, c) => {
    // Short enough to read out over a support call, random enough to be unique among the
    // 500s anyone is looking through. It identifies a log line, never a user.
    const ref = crypto.randomUUID().slice(0, 8);
    console.error(
        JSON.stringify({
            event: "unhandled_error",
            ref,
            method: c.req.method,
            route: routePath(c),
            errorName: errorName(err),
        }),
    );
    return c.json(error("INTERNAL", `${INTERNAL_MESSAGE} (ref: ${ref})`), 500);
});

/**
 * `EMAIL_MAX_LENGTH` is RFC 5321's cap on a path. It is here rather than left to the
 * pattern because every accepted address becomes a key in the throttle's maps
 * (`rate-limit.ts`), which bound how many keys they hold but not how large each is — and
 * #6 added four more maps keyed the same way.
 */
const EMAIL_MAX_LENGTH = 254;

/** A non-empty string no longer than `max`. The ceiling matters for every provider field
 *  (#7): they are opaque credentials we forward, so nothing about their *content* can be
 *  checked here, and an unbounded one is a body we would carry to a provider for free. */
const isBounded = (value: unknown, max: number): value is string =>
    typeof value === "string" && value.length > 0 && value.length <= max;

const normalizeEmail = (email: unknown): string | null => {
    if (typeof email !== "string") return null;
    const normalized = email.trim().toLowerCase();
    if (normalized.length > EMAIL_MAX_LENGTH) return null;
    return /\S+@\S+\.\S+/.test(normalized) ? normalized : null;
};

/**
 * The password rule, stated exactly as the sign-up screen states it —
 * `passwordRule` in mobile/Eva/Onboarding/Steps/CreateAccountStepView.swift. The user
 * must never be told two different rules, so this string is the rejection message
 * verbatim, and test/auth.test.ts reads the Swift file to pin the two together.
 *
 * Creation only. Sign-in never applies it: accounts predating this rule keep working.
 */
const PASSWORD_RULE = "At least 8 characters, including one number.";

/**
 * `\p{N}`, not `\d`, so "a number" means the same thing here as it does in the client's
 * `Character.isNumber` (Unicode Nd/Nl/No). ASCII-only here would reject a password the
 * sign-up CTA accepted, while quoting the rule the user just satisfied.
 */
const isValidPassword = (password: string): boolean =>
    password.length >= 8 && password.length <= PASSWORD_MAX_LENGTH && /\p{N}/u.test(password);

/**
 * A ceiling, because Identity Platform has one of its own and enforces it late. Without
 * this, `/auth/password/reset` spends the token and *then* fails in `setPassword`, which
 * is a `500` and a dead link — precisely what checking the rule before the token is spent
 * exists to prevent. 128 is well past any password a person or a manager produces.
 *
 * Its own message: quoting the "at least 8 characters" rule at someone who typed 400
 * would be telling them a rule they had satisfied.
 */
const PASSWORD_MAX_LENGTH = 128;
const PASSWORD_TOO_LONG = `Passwords are limited to ${PASSWORD_MAX_LENGTH} characters.`;

/** The `WEAK_PASSWORD` message for a password that fails the rule: which end it failed. */
const passwordFailure = (password: string): string =>
    password.length > PASSWORD_MAX_LENGTH ? PASSWORD_TOO_LONG : PASSWORD_RULE;

/**
 * The calling client's address, for the per-IP half of the auth throttle (issue #5).
 *
 * The **rightmost** `X-Forwarded-For` entry, not the leftmost. Cloud Run appends the
 * address it actually accepted the connection from, and everything to the left of that is
 * whatever the caller chose to send — trusting the left would put the per-IP limit one
 * request header away from useless. This assumes `eva-api` stays a *direct* Cloud Run
 * service, as `.github/workflows/deploy-api.yml` deploys it; put an external load balancer
 * in front and the rightmost entry becomes the balancer's, so revisit this then.
 *
 * `null` when there is no header, which skips the per-IP dimension rather than bucketing
 * every caller together — collapsing the world into one counter is an outage, and the
 * per-address limit still applies. Cloud Run always sets the header, so in production this
 * is unreachable; locally, and for in-process tests, it is the ordinary case.
 */
const clientIp = (c: Context): string | null => {
    const forwarded = c.req.header("x-forwarded-for");
    if (!forwarded) return null;
    const hops = forwarded.split(",");
    const client = hops[hops.length - 1]?.trim() ?? "";
    return client === "" ? null : client;
};

/**
 * Counts this attempt and, if it is over the limit, answers instead of serving it.
 * `null` means carry on.
 *
 * Called *after* validation and *before* the Identity Toolkit call, so a throttled request
 * costs neither us nor the bill anything, and so the answer cannot depend on what the
 * upstream would have said. The response is one constant for every caller: same status,
 * same code, same message, same `Retry-After`, with nothing derived from the address —
 * which is what keeps the sign-in non-enumeration property (§3) intact under throttling.
 */
const throttleAuth = (c: Context, route: AuthRoute, email: string) => {
    if (consumeAuthAttempt(route, clientIp(c), email)) return null;
    return c.json(error("RATE_LIMITED", "Too many attempts. Try again later."), 429, {
        "retry-after": String(authRetryAfterSeconds(route)),
    });
};

/**
 * How long we tell a caller to wait when Identity Toolkit could not answer (issue #32).
 *
 * A constant, for the reason #5 gives for the throttle's own `Retry-After`: anything
 * computed — time left on a breaker, a backoff that grows per address — is a per-caller
 * value, and a per-caller value in a header is a channel that can differ between a
 * registered address and an unknown one. One number for everybody differs from nothing.
 *
 * Long enough that a client honouring it does not amplify an outage, short enough that a
 * blip is not a minute of dead app.
 */
const UPSTREAM_RETRY_AFTER_SECONDS = 30;

/**
 * The upstream is down, or refusing to serve us. `503` + `Retry-After`, in the standard
 * error shape, saying only that this is temporary — nothing about what upstream said and
 * nothing about the address (issue #32).
 *
 * **This is also the operator's signal, and the only one.** A `503 SERVICE_UNAVAILABLE`
 * plus this log line means Identity Toolkit did not answer us; a bare `500` from these
 * routes now means a bug in our own code, because every Identity Toolkit failure is
 * mapped. Alert on the count of `identity_toolkit_unavailable` and the two are separable
 * without anything user-identifying being written down: the line carries the route and
 * the upstream HTTP status (`null` when the request never landed) and deliberately not
 * `err.reason`, not the address, not the password (GUARDRAILS 12).
 */
const serviceUnavailable = (c: Context) =>
    c.json(
        error(
            "SERVICE_UNAVAILABLE",
            "We can't reach the account service right now. Please try again in a moment.",
        ),
        503,
        { "retry-after": String(UPSTREAM_RETRY_AFTER_SECONDS) },
    );

const upstreamUnavailable = (
    c: Context,
    route: AuthRoute | ProviderRoute,
    err: IdentityToolkitError,
) => {
    console.error(
        JSON.stringify({
            event: "identity_toolkit_unavailable",
            route,
            upstreamStatus: err.upstreamStatus,
        }),
    );
    return serviceUnavailable(c);
};

/**
 * The account gate, and the second half of every authenticated route: `requireAuth`
 * proves the token was minted by us, this proves the account it names still exists.
 *
 * It exists because the Eva JWT is stateless, lives 30 days and has no revocation
 * (ARCHITECTURE §3), so a token minted before an account was deleted would otherwise keep
 * working for up to a month — and at `GET /me`, whose old `ensureUser` fallback treated
 * "no document" as "create one", it would have *recreated the account* from the claims it
 * carries. Deletion cannot mean deletion while that is true (#8).
 *
 * The user document is the revocation list, rather than a new one: every account has
 * exactly one, `users.ts` already owns it, and it stops answering the moment a delete
 * starts (`markUserDeleted`) — so nothing about a deleted account is kept in order to keep
 * refusing it. The cost, stated plainly, is one Firestore read on every authenticated
 * request; `GET /me` pays no more than before, since it needed that read anyway.
 *
 * It lives here rather than beside `requireAuth` because `auth.ts` must not reach
 * Firestore and `users.ts` is the only module that may (GUARDRAILS 10) — so the composing
 * of the two belongs at the route edge, which is what this file is.
 */
const requireAccount = createMiddleware<{
    Variables: { claims: TokenClaims; account: User };
}>(async (c, next) => {
    const account = await getUser(c.get("claims").sub);
    // 401, not 404: the caller's credential is the thing that is no longer good, and the
    // app signs out on it wherever it lands — `AppSession.authorized` routes every
    // authorized request through one handler, so this is not only caught at launch (#55).
    // Same code and message as any other dead token —
    // "your account was deleted" is not a distinction worth drawing for a caller who,
    // by definition, cannot be told anything about it.
    if (!account) {
        return c.json(error("UNAUTHORIZED", "Invalid or expired token"), 401);
    }
    c.set("account", account);
    await next();
});

app.get("/", (c) => c.text("Eva API"));
app.get("/health", (c) => c.json({ status: "ok" }));

app.post("/auth/signup", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    const password = typeof body.password === "string" ? body.password : "";
    if (!email)
        return c.json(error("VALIDATION", "A valid email is required"), 400);
    if (!isValidPassword(password)) {
        return c.json(error("WEAK_PASSWORD", passwordFailure(password)), 400);
    }
    const throttled = throttleAuth(c, "signup", email);
    if (throttled) return throttled;

    try {
        const { localId } = await signUpWithPassword(email, password);
        const user = await ensureUser(localId, email, "password");
        // `null` means the uid is mid-deletion, and Identity Toolkit has just minted this
        // one, so it cannot be. Raised as the fault it would be rather than papered over
        // with a plausible answer; `app.onError` shapes it into a 500 with a `ref`.
        if (!user) throw new Error("ensureUser refused a newly created uid");
        // No session (#6): the account exists but its address is not proven, and the
        // activation gate in `/auth/signin` is what proves it. The caller gets the address
        // back — the one it just sent — so the gate screen can name where the link went.
        //
        // Nothing here is allowed to fail the request. The Auth user and the document are
        // already committed, so a throw would answer `500` on an account that exists, and
        // the retry would be `409 EMAIL_EXISTS` on an account nobody can sign into — with
        // the recovery, Resend, living on the gate screen the failed sign-up never
        // reached. Better a gate with no email yet and a working Resend.
        await sendActivationLink(localId, email).catch(() => {});
        return c.json({ pending: true, email }, 201);
    } catch (err) {
        if (err instanceof IdentityToolkitError) {
            if (err.kind === "email-exists") {
                return c.json(
                    error("EMAIL_EXISTS", "This email is already registered"),
                    409,
                );
            }
            if (err.kind === "unavailable") return upstreamUnavailable(c, "signup", err);
            // `rejected`: upstream refused the credentials for something our own edge
            // validation did not catch — a shape of address our regex allows and Google
            // does not, most likely. Answered in our words, at 400 because the request is
            // the problem; the upstream reason stays in the exception (GUARDRAILS 12), so
            // we say what the caller can act on and no more.
            return c.json(
                error(
                    "VALIDATION",
                    "That email or password can't be used. Check them and try again.",
                ),
                400,
            );
        }
        throw err;
    }
});

app.post("/auth/signin", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    const password = typeof body.password === "string" ? body.password : "";
    if (!email || !password) {
        return c.json(
            error("VALIDATION", "Email and password are required"),
            400,
        );
    }
    const throttled = throttleAuth(c, "signin", email);
    if (throttled) return throttled;

    try {
        const { localId } = await signInWithPassword(email, password);
        // Self-healing: also the attach point for future providers (same uid → same doc).
        const user = await ensureUser(localId, email, "password");
        // `null` means the account is being deleted. The credentials are real, and that is
        // exactly why this must not mint a token: signing in is the one path that could
        // otherwise walk an account back out of its own deletion. Answered as a failed
        // sign-in — the same answer a wrong password gets, which is also the honest one,
        // because the account those credentials named is gone.
        if (!user) {
            return c.json(
                error("INVALID_CREDENTIALS", "Wrong email or password"),
                401,
            );
        }
        // The activation gate (#6), and *where* it sits is the design: after Identity
        // Toolkit has verified the password. Answering "not activated" for an unverified
        // password would tell anyone holding an address that an account exists behind it,
        // which is the question the 401 below refuses to answer. So the only caller who
        // can ever see this 403 already knows the password.
        // test/auth.test.ts pins the ordering, against the real upstream.
        if (!isActivated(user)) {
            return c.json(
                error("NOT_ACTIVATED", "Confirm your email address first"),
                403,
            );
        }
        return c.json({ token: await mintToken(localId, email), user });
    } catch (err) {
        if (err instanceof IdentityToolkitError) {
            if (err.kind === "unavailable") return upstreamUnavailable(c, "signin", err);
            // Everything else collapses into one answer — a wrong password, an address
            // that was never registered, an address upstream considers malformed. The
            // branch is chosen from `kind`, which is derived from the upstream *status*
            // and a fixed list of reasons, never from anything that varies with the
            // address: that is what keeps the non-enumeration property (ARCHITECTURE §3)
            // true of our layer and not merely of Google's. Signin has no 400 branch on
            // purpose — "that address is malformed" would answer the question the 401
            // refuses to. test/signin-non-enumeration.test.ts pins both halves.
            return c.json(
                error("INVALID_CREDENTIALS", "Wrong email or password"),
                401,
            );
        }
        throw err;
    }
});

// ── Activation and password reset (#6) ─────────────────────────────────────────
// The API owns the tokens (issue, spend, expire — `email-tokens.ts`) and the delivery
// (`email.ts`); Firebase's own action emails would have put both outside the code this
// repo can test, and the link on a page we could barely brand. Links land on the website
// (`PUBLIC_WEB_URL/activate`, `/reset`), whose pages call the two routes below
// cross-origin — hence CORS on exactly those two, for exactly that origin, and nowhere
// else. `*` would let any page on the web spend a token it was handed.

const webCors = cors({
    origin: config.publicWebOrigin,
    allowMethods: ["POST", "OPTIONS"],
    allowHeaders: ["Content-Type"],
});
app.use("/auth/activate", webCors);
app.use("/auth/password/reset", webCors);

/** Both link routes change state and are reached with a one-time credential in the body.
 *  Nothing between here and the browser may keep a copy of either half. */
const noStore = createMiddleware(async (c, next) => {
    await next();
    // `c.res.headers`, not `c.header()`: after `next()` the handler has already built the
    // response, and only the built response's headers are what goes out.
    c.res.headers.set("cache-control", "no-store");
});
app.use("/auth/activate", noStore);
app.use("/auth/password/reset", noStore);

/**
 * The shape `email-tokens.ts` issues — `TOKEN_LENGTH` characters of base64url — and
 * nothing else gets as far as a lookup. Anything malformed is a dead link, answered like
 * one; a missing token altogether is a request the client built wrong.
 */
const TOKEN_SHAPE = new RegExp(`^[A-Za-z0-9_-]{${TOKEN_LENGTH}}$`);

/**
 * The floor both "send me a link" routes answer against, comfortably above what the
 * registered branch costs (an Auth lookup, a Firestore write and a POST to Postmark —
 * a few hundred milliseconds). See the note on the routes for why a floor and not a
 * detached send.
 */
const SEND_LINK_FLOOR_MS = 800;

/** Runs `work` and does not return before `floor` milliseconds have passed, whichever
 *  takes longer. A failure inside `work` still waits, or the floor would only apply to
 *  the branch that succeeded. */
const atLeast = async (floor: number, work: () => Promise<void>): Promise<void> => {
    const [outcome] = await Promise.all([
        work().then(
            () => null,
            (err: unknown) => err,
        ),
        new Promise((resolve) => setTimeout(resolve, floor)),
    ]);
    if (outcome !== null) throw outcome;
};

/**
 * The per-IP throttle on the two routes a link lands on. They are unauthenticated, they
 * run a Firestore transaction per call, and they carry no address to count against — so
 * this is the only dimension there is. Guessing a token is infeasible at 256 bits; the
 * counter is here so the routes cannot be used as a free amplifier against Firestore.
 */
const throttleToken = (c: Context, route: TokenRoute) => {
    if (consumeTokenAttempt(route, clientIp(c))) return null;
    return c.json(error("RATE_LIMITED", "Too many attempts. Try again later."), 429, {
        "retry-after": String(authRetryAfterSeconds("signin")),
    });
};

const parseToken = (value: unknown): string | null =>
    typeof value === "string" && TOKEN_SHAPE.test(value) ? value : null;

/**
 * A spent, unknown, or malformed token, and an expired one, are told apart — expiry is
 * the one the user can act on by asking for a new link. Neither says which account the
 * link named, and "used" is folded into "invalid" so the holder of a link cannot learn
 * whether someone else already clicked it.
 */
const tokenFailure = (c: Context, reason: "invalid" | "expired") =>
    reason === "expired"
        ? c.json(error("TOKEN_EXPIRED", "This link has expired. Request a new one."), 400)
        : c.json(error("INVALID_TOKEN", "This link is not valid. Request a new one."), 400);

/**
 * Issues an activation token and sends the link. A delivery failure is deliberately not
 * the caller's failure: the account exists, the token is stored, and the gate screen has
 * a Resend — so `email.ts` has already written the one line an operator needs and the
 * typed error is swallowed here. Anything else (Firestore, on the token write) is a fault
 * of ours and still lands in `app.onError`.
 */
const sendActivationLink = async (uid: string, email: string): Promise<void> => {
    const token = await issueToken(uid, email, "activation");
    try {
        await sendActivationEmail(email, token);
    } catch (err) {
        if (!(err instanceof EmailError)) throw err;
    }
};

/** The reset counterpart: issuing also invalidates every earlier reset link. */
const sendResetLink = async (uid: string, email: string): Promise<void> => {
    const token = await issueToken(uid, email, "reset");
    try {
        await sendPasswordResetEmail(email, token);
    } catch (err) {
        if (!(err instanceof EmailError)) throw err;
    }
};

/**
 * Spends an activation token and stamps the account. Idempotent from the user's side: a
 * valid link on an account activated by some other route (a password reset, say) still
 * answers `200`, because the thing the user did — prove the address — is done either way.
 * The token is consumed regardless, so the link cannot be replayed.
 */
const activate = async (c: Context, raw: unknown) => {
    if (raw === undefined || raw === null || raw === "") {
        return c.json(error("VALIDATION", "A token is required"), 400);
    }
    const token = parseToken(raw);
    if (!token) return tokenFailure(c, "invalid");

    const result = await consumeToken(token, "activation");
    if (!result.ok) return tokenFailure(c, result.reason);
    // The token was real but the account behind it is gone or going — a delete landed
    // between the email and the click. Nothing to activate, and a dead link is what the
    // holder of a deleted account's link should see.
    const before = await readUser(result.uid);
    if (before.deleted || !before.user) return tokenFailure(c, "invalid");
    // **Retract first, stamp second, and the order is the whole point.** An earlier version
    // stamped `activatedAt` and then retracted, which left a window — three Admin SDK round
    // trips wide — in which the document said activated while the attacker's provider was
    // still linked. `/auth/idp` reads exactly that flag to decide whether to run its claim,
    // so a request landing inside the window skipped the claim and was minted a 30-day Eva
    // JWT, which nothing can revoke. And a transient failure of the retraction left the
    // account activated with the identity still attached, permanently, because the
    // transition had already been spent.
    //
    // This way round, every failure leaves the account unactivated with the claim gate
    // still armed, and the worst case is a user clicking their link again. `proveAddress`
    // is idempotent, so two concurrent activations both running it is harmless.
    if (!before.user.activated) await retractUnprovenIdentities(result.uid);
    // Last, and still checked: a delete may have landed since the read above.
    if (!(await markActivated(result.uid))) return tokenFailure(c, "invalid");
    return c.json({ activated: true });
};

// POST only, and the token is in the body. A `GET /auth/activate?token=…` would write
// the raw token into Cloud Run's request log — `httpRequest.requestUrl` carries the query
// string — which is the same secret `authTokens/` keeps by storing only a hash. The link
// in the email carries its token in the URL *fragment* for the same reason one layer out
// (`email.ts`), so the website's page has it and no server ever saw it.
app.post("/auth/activate", async (c) => {
    const throttled = throttleToken(c, "activate");
    if (throttled) return throttled;
    const body = await c.req.json().catch(() => ({}));
    return activate(c, body.token);
});

/**
 * The two "send me a link" routes answer `200 { sent: true }` for every well-formed
 * address, registered or not, activated or not — for the reason `/auth/signin` answers a
 * wrong password and an unknown address identically (§3): whether an address has an Eva
 * account is not the caller's to learn. The throttle runs before the lookup, so a refused
 * request is refused the same way for both.
 *
 * The branches also have to answer in the same *time*, which they do not naturally: a
 * registered address costs a Firestore write and a POST to Postmark, an unknown one costs
 * a failed Auth lookup and nothing else — hundreds of milliseconds against tens, readable
 * from a single request. `atLeast` holds both to a floor well above the slow branch, so
 * the fast one cannot be told from it. That is a floor, not a constant: a Postmark call
 * slower than `SEND_LINK_FLOOR_MS` still overruns it, and the residue is bounded by
 * Postmark's own variance rather than by the difference between doing the work and not.
 * Answering before the send instead would be exact, but Cloud Run throttles CPU after the
 * response, so the email would go out whenever the next request happened to arrive.
 */
app.post("/auth/activation/resend", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    if (!email) return c.json(error("VALIDATION", "A valid email is required"), 400);
    const throttled = throttleAuth(c, "resend", email);
    if (throttled) return throttled;

    await atLeast(SEND_LINK_FLOOR_MS, async () => {
        const uid = await findAuthUidByEmail(email);
        if (!uid) return;
        const user = await getUser(uid);
        if (user && !isActivated(user)) await sendActivationLink(uid, user.email);
    });
    return c.json({ sent: true });
});

app.post("/auth/password/forgot", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    if (!email) return c.json(error("VALIDATION", "A valid email is required"), 400);
    const throttled = throttleAuth(c, "forgot", email);
    if (throttled) return throttled;

    await atLeast(SEND_LINK_FLOOR_MS, async () => {
        const uid = await findAuthUidByEmail(email);
        if (!uid) return;
        // Activated or not: a reset proves control of the address as surely as the
        // activation link does, and the reset route stamps the account accordingly.
        const user = await getUser(uid);
        if (user) await sendResetLink(uid, user.email);
    });
    return c.json({ sent: true });
});

/**
 * Spends a reset token, sets the password, and **mints a session**: the user has just
 * proven control of the address and chosen a password, which is more than a sign-in asks
 * for, and sending them back to the sign-in screen to type it again would be ceremony.
 * The password rule is checked *before* the token is spent, so a weak password costs the
 * user a retry, not the link.
 */
app.post("/auth/password/reset", async (c) => {
    const throttled = throttleToken(c, "reset");
    if (throttled) return throttled;
    const body = await c.req.json().catch(() => ({}));
    if (body.token === undefined || body.token === null || body.token === "") {
        return c.json(error("VALIDATION", "A token is required"), 400);
    }
    const token = parseToken(body.token);
    if (!token) return tokenFailure(c, "invalid");
    const password = typeof body.password === "string" ? body.password : "";
    if (!isValidPassword(password)) {
        return c.json(error("WEAK_PASSWORD", passwordFailure(password)), 400);
    }

    const result = await consumeToken(token, "reset");
    if (!result.ok) return tokenFailure(c, result.reason);
    // Gone or going: the credentials must not be reset on an account mid-delete, and the
    // link is as dead as the account.
    const user = await getUser(result.uid);
    if (!user) return tokenFailure(c, "invalid");

    await setPassword(result.uid, password);
    // Same retraction as the activation route, and reachable by the same person: this is
    // the recovery an owner is sent to when someone else has reserved their address, so it
    // has to take that person's credentials away rather than merely reset the password.
    //
    // Keyed on the state read *above*, before anything was written, and run before the
    // stamp — see the activation route for why that order matters. Only when the account
    // was not already activated: someone who linked Apple deliberately from Profile and
    // then forgot their password must still have Apple afterwards.
    if (!user.activated) await retractUnprovenIdentities(result.uid);
    // Only here, and never from the activation route: a reset proves address control *and*
    // sets the password in the same request, so the credentials are the caller's. At
    // activation the password may be a stranger's, and Firebase's merge-wipe is what takes
    // it away — see `markCredentialsProven`.
    //
    // Unconditional rather than transition-only: a long-activated user who resets has just
    // proven the password whoever they are, and a wipe on their next provider sign-in would
    // be pure loss.
    await markCredentialsProven(result.uid);
    // Proof of control of the address, whichever link it came by. Last, for the same
    // reason as the activation route. A delete landing since the read above answers a dead
    // link rather than a session for a tombstone.
    if (!(await markActivated(result.uid))) return tokenFailure(c, "invalid");
    return c.json({
        token: await mintToken(result.uid, user.email),
        user: { ...user, activated: true },
    });
});

// ── Sign in with Apple and Google (#7) ─────────────────────────────────────────
// The app never talks to Apple, Google or Firebase (ARCHITECTURE §2): it obtains a
// provider credential natively and sends *that* here, and this spends it through
// `identity-toolkit.ts` — the same seam the password path already goes through, and still
// the only place the web API key lives.
//
// **This code never matches on email. Firebase does, and that is the whole design.**
// `signInWithIdp` returns the uid Firebase keyed to the provider's `sub`; `ensureUser`
// lands on that document. Whether an address that already has a password account resolves
// to the *same* uid is the console setting `Authentication → Settings → User account
// linking`, set to "Link accounts that use the same email" (decided 2026-09-03). So a
// Google sign-in on an existing address logs into that account, which is what the PRD's
// edge case always asked for. Do not add a lookup here: the rule lives in one place, and a
// second copy is how the two come to disagree invisibly.
//
// Hide My Email is the case the setting cannot help — a relay address matches nothing, so
// those users get a new account regardless, and `POST /me/auth/providers` is their only
// route into an existing one.
//
// **`claimUnprovenAccount` below is what makes the linking safe, and is not optional.**
// Sign-up creates the Auth user before the address is confirmed, and the web API key is
// public, so anyone can pre-register an address and attach their own provider identity to
// it directly at Identity Toolkit. Deleting that call re-opens an account takeover; the
// full walk-through is on the function.
//
// Nothing here stores a display name, and nothing widens `users/{uid}`. Apple offers a name
// on first authorization and Eva shows a name nowhere, so collecting it would be personal
// data held for no purpose (#7's decision) — it is dropped where it arrives, which is
// `signInWithIdp`, which never asks for it.

/** A ceiling on the opaque credentials the app forwards. An Apple `identityToken` is a JWT
 *  of a few hundred bytes and an authorization code is shorter; 4096 is far above either
 *  and far below anything worth carrying to a provider on a caller's say-so. */
const PROVIDER_TOKEN_MAX_LENGTH = 4096;
const REDIRECT_URI_MAX_LENGTH = 512;

/** Apple's authorization code on `DELETE /me`. Same reasoning, smaller thing. */
const APPLE_AUTH_CODE_MAX_LENGTH = 2048;

/**
 * What the client sends, per provider. Apple is native — the app already holds an
 * `identityToken` — and `rawNonce` is the nonce it hashed into its `ASAuthorization`
 * request, which is required rather than optional: without it Firebase has nothing to check
 * a replayed token against.
 *
 * Google is PKCE against a *public* iOS OAuth client, so what comes back from the dance is
 * an authorization code and there is no client secret anywhere in it — that is what keeps
 * the GoogleSignIn SDK out of the app (GUARDRAILS 25).
 */
type ProviderCredential =
    | { provider: "apple"; identityToken: string; rawNonce: string }
    | { provider: "google"; code: string; codeVerifier: string; redirectUri: string };

type CredentialCheck =
    | { ok: true; value: ProviderCredential }
    | { ok: false; message: string };

/** Echoed to Google, which checks it against the client the code was issued for. Parsed
 *  only for shape — the app's is a custom scheme (`com.googleusercontent.apps.…:/…`), so
 *  this cannot demand https. */
const isRedirectUri = (value: unknown): value is string => {
    if (!isBounded(value, REDIRECT_URI_MAX_LENGTH)) return false;
    try {
        new URL(value);
        return true;
    } catch {
        return false;
    }
};

/** Validation at the edge, for both provider routes (GUARDRAILS 13). Nothing below this
 *  line inspects the shape of a request again. */
const parseProviderCredential = (body: Record<string, unknown>): CredentialCheck => {
    if (body.provider === "apple") {
        if (
            !isBounded(body.identityToken, PROVIDER_TOKEN_MAX_LENGTH) ||
            !isBounded(body.rawNonce, PROVIDER_TOKEN_MAX_LENGTH)
        ) {
            return { ok: false, message: "identityToken and rawNonce are required" };
        }
        return {
            ok: true,
            value: {
                provider: "apple",
                identityToken: body.identityToken,
                rawNonce: body.rawNonce,
            },
        };
    }
    if (body.provider === "google") {
        if (
            !isBounded(body.code, PROVIDER_TOKEN_MAX_LENGTH) ||
            !isBounded(body.codeVerifier, PROVIDER_TOKEN_MAX_LENGTH) ||
            !isRedirectUri(body.redirectUri)
        ) {
            return {
                ok: false,
                message: "code, codeVerifier and redirectUri are required",
            };
        }
        return {
            ok: true,
            value: {
                provider: "google",
                code: body.code,
                codeVerifier: body.codeVerifier,
                redirectUri: body.redirectUri,
            },
        };
    }
    return { ok: false, message: "provider must be 'apple' or 'google'" };
};

/**
 * The OIDC token to spend at Firebase, whichever dance produced it. Apple's arrives with
 * the request; Google's has to be fetched from its token endpoint with the code verifier,
 * which is the one outbound call `providers.ts` exists for.
 *
 * `index.ts` does no `fetch` of its own here (ARCHITECTURE §3) — it decides which module
 * answers the question and nothing else.
 */
const providerIdToken = async (credential: ProviderCredential): Promise<IdpCredential> =>
    credential.provider === "apple"
        ? {
              provider: "apple",
              idToken: credential.identityToken,
              rawNonce: credential.rawNonce,
          }
        : { provider: "google", idToken: await exchangeGoogleAuthCode(credential) };

/** Per IP and only per IP — `ProviderRoute` says why there is no per-address dimension.
 *  Counted after validation and before either upstream call, exactly as the password
 *  routes' throttle is, so a refused request costs nothing and can depend on nothing. */
const throttleProvider = (c: Context, route: ProviderRoute) => {
    if (consumeProviderAttempt(route, clientIp(c))) return null;
    return c.json(error("RATE_LIMITED", "Too many attempts. Try again later."), 429, {
        "retry-after": String(authRetryAfterSeconds("signin")),
    });
};

/**
 * The one thing a caller is told about a provider credential that did not work: an expired
 * Apple token, a nonce that does not match, a code already spent, a code minted for another
 * client. All one answer, in our words, with nothing of the provider's own reason in it
 * (GUARDRAILS 12) — the caller's recovery is the same for every one of them, which is to
 * start the sign-in again.
 */
const PROVIDER_REJECTED = "That sign-in couldn't be completed. Please try again.";

/**
 * Maps both upstream boundaries — Firebase's and the provider's own — onto the contract,
 * by the rule ARCHITECTURE §3 already states for Identity Toolkit: **the status decides
 * before the reason does**, and the reason string reaches no body, header, or log line.
 *
 * `null` means this was not an upstream failure at all, and the caller rethrows so
 * `app.onError` answers it as the bug it is.
 */
const providerFailure = (c: Context, route: ProviderRoute, err: unknown) => {
    if (err instanceof IdentityToolkitError) {
        if (err.kind === "unavailable") return upstreamUnavailable(c, route, err);
        // The `sub` is attached to a different Eva account. Answered plainly rather than
        // merged: merging two accounts on a credential is the account-takeover shape #7
        // rejected, and only the holder of a session for one account and a provider
        // credential for the other can ever see this.
        if (err.kind === "provider-linked") {
            return c.json(
                error(
                    "PROVIDER_ALREADY_LINKED",
                    "That Apple or Google account is already connected to another Eva account.",
                ),
                409,
            );
        }
        return c.json(error("INVALID_CREDENTIALS", PROVIDER_REJECTED), 401);
    }
    if (err instanceof ProviderError) {
        if (err.kind === "rejected") {
            return c.json(error("INVALID_CREDENTIALS", PROVIDER_REJECTED), 401);
        }
        // The operator's signal, and separable from `identity_toolkit_unavailable` because
        // it is a different upstream with a different fix. `kind` distinguishes an outage
        // at Apple or Google (`unavailable`) from credentials this deploy was never given
        // (`unconfigured`) — the second is a page, not a retry. Both are constants of ours;
        // no code, no token, no address (GUARDRAILS 12).
        console.error(
            JSON.stringify({
                event: "provider_endpoint_unavailable",
                route,
                kind: err.kind,
                upstreamStatus: err.upstreamStatus,
            }),
        );
        return serviceUnavailable(c);
    }
    return null;
};

/**
 * Sign in — or sign up; with a provider they are the same request, which is the point.
 *
 * **The session comes back activated**, and that is a decision rather than an oversight
 * (#7). Google's address is verified and Apple's relay is Apple's own, so a provider
 * sign-in proves the address at least as well as the link we email does — and without this,
 * every Apple user would hit `403 NOT_ACTIVATED` from #6 and we would send a confirmation
 * link to a relay address to prove something Apple has already proved.
 */
app.post("/auth/idp", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const parsed = parseProviderCredential(body);
    if (!parsed.ok) return c.json(error("VALIDATION", parsed.message), 400);
    const throttled = throttleProvider(c, "idp");
    if (throttled) return throttled;

    try {
        const { localId, email } = await signInWithIdp(await providerIdToken(parsed.value));
        // A **read**, deliberately, and before anything else. `ensureUser` writes — it
        // unions the provider into `authProviders` — and running it first meant a credential
        // this route was about to refuse still left its provider mirrored on the account it
        // collided with. Permanently, and where the app can see it: Profile reads
        // `authProviders` to decide whether to offer "Connect Apple", so a false entry takes
        // away the real owner's only way to link the identity that is actually theirs.
        const existing = await readUser(localId);
        // Mid-deletion, the same case `/auth/signin` refuses: the credential is real and
        // that is exactly why this must not mint a token, or a provider sign-in would walk
        // an account back out of its own deletion.
        if (existing.deleted) {
            return c.json(error("INVALID_CREDENTIALS", PROVIDER_REJECTED), 401);
        }
        // An unactivated account is one nobody has proven they own, and #6 creates it
        // before the address is confirmed — so every credential already on it was attached
        // by someone unverified. `claimUnprovenAccount` takes them all away, keeping only
        // the provider that just signed in, before the line below marks the account
        // activated on that person's behalf.
        //
        // The condition is `!user.activated` **alone**. An earlier version also required
        // `authProviders` to contain "password", which reads Eva's Firestore mirror rather
        // than Firebase's record of the account — and those diverge in exactly the case
        // that matters, because sign-up writes the Auth user before the document.
        // `claimUnprovenAccount` does test for a password, but against Firebase's
        // `providerData`, which is the authoritative record the mirror only copies.
        //
        // Fails **closed**: the throw is not a provider failure, so it falls through to
        // `app.onError` as a 500 and no token is minted. Continuing would hand out a
        // session for an account still carrying credentials we meant to take away.
        if (!existing.user?.activated) {
            const outcome = await claimUnprovenAccount(
                localId,
                PROVIDER_IDS[parsed.value.provider],
            );
            // `refused` means the address on this account was reserved by someone who never
            // proved it, and this provider is not them. Answering as for any bad credential
            // is deliberate: it says nothing about whether the address is registered
            // (GUARDRAILS 12b), and returning here is what keeps `markActivated` below from
            // stamping the account on the attacker's behalf — which is the step that would
            // disarm the claim for the real owner's later sign-in.
            if (outcome === "refused") {
                return c.json(error("INVALID_CREDENTIALS", PROVIDER_REJECTED), 401);
            }
        }
        // Only now, once the credential has earned the account. The second tombstone check
        // is `ensureUser`'s own, and closes the window between the read above and this
        // write: a `DELETE /me` landing in between must still win.
        const user = await ensureUser(localId, email, PROVIDER_IDS[parsed.value.provider]);
        if (!user) return c.json(error("INVALID_CREDENTIALS", PROVIDER_REJECTED), 401);
        // The claim above has already taken the account, so there is nothing left to
        // retract — and `proveAddress` must not run here: a provider sign-in would unlink
        // the very identity that just signed in.
        await markActivated(localId);
        return c.json({
            token: await mintToken(localId, email),
            user: { ...user, activated: true },
        });
    } catch (err) {
        const answer = providerFailure(c, "idp", err);
        if (answer) return answer;
        throw err;
    }
});

/**
 * Attaches a provider to **the account the bearer token names** — the deliberate link #7
 * put in place of automatic email matching, and the only way an existing email/password
 * account ever gains an Apple or Google credential.
 *
 * How, and why this way: the Admin SDK mints a custom token for the signed-in uid,
 * `identity-toolkit.ts` exchanges it for a Firebase ID token, and `signInWithIdp` links
 * against that. Every step stays inside seams that already exist and adds no dependency.
 * The one-call alternative — `adminAuth.updateUser(uid, { providerToLink })` — takes a
 * `sub` we would have had to verify ourselves, which means owning Apple's and Google's JWKS
 * and the nonce check; letting Firebase remain the only validator of a provider token is
 * the same choice ARCHITECTURE §2 makes for passwords.
 */
app.post("/me/auth/providers", requireAuth, requireAccount, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const parsed = parseProviderCredential(body);
    if (!parsed.ok) return c.json(error("VALIDATION", parsed.message), 400);
    const throttled = throttleProvider(c, "link");
    if (throttled) return throttled;

    const account = c.get("account");
    try {
        // The provider credential is resolved first, so a code that was never going to work
        // fails before we mint a Firebase session for the account it would have joined.
        const credential = await providerIdToken(parsed.value);
        const { localId } = await signInWithIdp(
            credential,
            await idTokenForUid(account.id),
        );
        // Linking that landed on another account would mean Firebase merged rather than
        // linked — the console setting in step 0 of docs/PROVIDER-SIGNIN.md. There is no
        // safe answer to give a caller for that, so it is raised as the fault it is and
        // `app.onError` answers 500 with a `ref`.
        if (localId !== account.id) {
            throw new Error("signInWithIdp resolved a different account");
        }
        const user = await ensureUser(
            account.id,
            account.email,
            PROVIDER_IDS[parsed.value.provider],
        );
        // A delete landed between the account gate and here.
        if (!user) return c.json(error("UNAUTHORIZED", "Invalid or expired token"), 401);
        return c.json({ user });
    } catch (err) {
        const answer = providerFailure(c, "link", err);
        if (answer) return answer;
        throw err;
    }
});

/**
 * Apple's revocation step on account deletion (#7). Never throws and never fails the
 * delete: revocation not happening is a compliance problem, revocation stopping a deletion
 * is a data problem, and the second is worse. One log line, of the same no-PII shape as
 * every other upstream failure — a stage and a status, no code, no uid, no address.
 */
const revokeApple = async (authorizationCode: string): Promise<void> => {
    const outcome = await revokeAppleToken(authorizationCode).catch(() => null);
    if (outcome?.ok) return;
    console.error(
        JSON.stringify({
            event: "apple_revocation_failed",
            stage: outcome?.stage ?? "threw",
            upstreamStatus: outcome?.upstreamStatus ?? null,
        }),
    );
};

app.get("/me", requireAuth, requireAccount, (c) => c.json({ user: c.get("account") }));

/**
 * Account deletion is **immediate and complete** (#8): no grace period, no delayed purge,
 * nothing recoverable — including entries inside their own 30-day event window, because a
 * recovery window inside an account that no longer exists is a promise to nobody.
 *
 * The order is the design, and it is chosen so that every partial failure is safe *and*
 * resumable rather than fast:
 *
 *   1. mark the user document deleted — one write, and from that instant the account is
 *      inert: every gated route 401s and sign-in refuses to revive it;
 *   2. delete the Firebase Auth user — the credentials stop opening anything and the
 *      address is free to sign up again;
 *   3. delete every event, soft-deleted ones included, and every activation or reset
 *      token (#6) — a token document carries the account's address;
 *   4. delete the user document, which is the tombstone step 1 wrote.
 *
 * Data goes before the tombstone and the tombstone goes last on purpose. The invariant
 * that buys is: **a missing user document implies a missing Auth user**, so there is no
 * state in which health data outlives its owner unmarked, and none in which somebody can
 * sign in to an account whose document has already gone (which is what would let
 * `ensureUser` create a fresh one). The cost is the milder failure mode — an interrupted
 * delete can leave an Auth user with no data behind it — and that resolves itself: the
 * account is already unusable, and a retry finishes the job.
 *
 * Every step is idempotent, so this route is too: deleting twice is a `200`, not an error.
 * It is also the one authenticated route deliberately *not* behind `requireAccount` — the
 * gate would reject the very token a client needs to retry with. What that token can still
 * do here is re-delete an account that is already gone, which is nothing.
 */
app.delete("/me", requireAuth, async (c) => {
    const { sub } = c.get("claims");
    // An **optional** fresh Apple authorization code (#7), obtained by the app re-prompting
    // for authorization just before it calls this. Optional because deletion cannot depend
    // on it: an old client, a user who declines the prompt, or a request built by anything
    // else must still delete the account. Absent, this route is exactly what it was.
    //
    // A code and not a stored refresh token, deliberately: keeping Apple's refresh token
    // would put a long-lived third-party credential in a health app's user document and
    // would widen `users/{uid}`, which #7 does not do. See `providers.ts` for the cost.
    const body = await c.req.json().catch(() => ({}));
    // Absent and malformed are **not** the same answer, though one expression used to give
    // them one. Absent is the documented case above and deletes without revoking. Present
    // but over-long or not a string is a client bug, and folding it into "absent" meant the
    // account was deleted with Apple's entitlement quietly unmet — no error, no log line,
    // and nothing the caller could see. Every other field on this API is refused at the
    // edge; this one now is too.
    const rawAppleCode = (body as Record<string, unknown>).appleAuthorizationCode;
    const supplied = rawAppleCode !== undefined && rawAppleCode !== null;
    if (supplied && !isBounded(rawAppleCode, APPLE_AUTH_CODE_MAX_LENGTH)) {
        return c.json(
            error("VALIDATION", "appleAuthorizationCode must be a short, non-empty string"),
            400,
        );
    }
    const appleAuthorizationCode = supplied ? (rawAppleCode as string) : null;

    await markUserDeleted(sub);
    // After the tombstone, so the account is already inert whatever Apple answers, and
    // before the Auth user goes, so the ordering below is untouched. Revocation is Apple's
    // requirement of any app offering Sign in with Apple *and* in-app deletion, and App
    // Review rejects on its absence.
    if (appleAuthorizationCode) await revokeApple(appleAuthorizationCode);
    await deleteAuthAccount(sub);
    await deleteAllUserEvents(sub);
    await deleteTokensForUid(sub);
    await deleteUserDocument(sub);
    // No count, no email, no id — a delete is exactly where a log line is tempting
    // (GUARDRAILS 12). Anything that throws above lands in `app.onError` as a 500 with a
    // `ref`, and the account is already inert by then.
    return c.json({ deleted: true });
});

app.put("/me/questionnaire", requireAuth, requireAccount, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const profile = parseProfile(body);
    if (!profile)
        return c.json(
            error("VALIDATION", "Invalid questionnaire payload"),
            400,
        );

    const user = await saveQuestionnaire(c.get("claims").sub, profile);
    if (!user) return c.json(error("UNAUTHORIZED", "User not found"), 401);
    return c.json({ user });
});

const parseProfile = (body: Record<string, unknown>): Profile | null => {
    const isStringArray = (v: unknown): v is string[] =>
        Array.isArray(v) && v.every((x) => typeof x === "string");
    const inRange = (v: unknown, min: number, max: number): v is number =>
        typeof v === "number" && Number.isFinite(v) && v >= min && v <= max;

    const {
        age,
        weightKg,
        heightCm,
        goals,
        conditions,
        medications,
        lifestyle,
        sports,
    } = body;
    if (
        !inRange(age, 13, 99) ||
        !inRange(weightKg, 30, 200) ||
        !inRange(heightCm, 120, 220) ||
        !isStringArray(goals) ||
        !isStringArray(conditions) ||
        typeof medications !== "string" ||
        typeof lifestyle !== "string" ||
        !isStringArray(sports)
    ) {
        return null;
    }
    return {
        age,
        weightKg,
        heightCm,
        goals,
        conditions,
        medications,
        lifestyle,
        sports,
    };
};

// ── Reference data ─────────────────────────────────────────────────────────────
// The option lists the client draws (PRD:483 — new options ship without an app
// release). `version` is a hash of the content, so it changes exactly when a
// catalogue does. The client stores it beside its copy and sends it back; an
// unchanged catalogue answers 304 with no body, and the client keeps what it has.
// `If-None-Match` does the same thing for anything that speaks HTTP caching.

/** Strips the weak-validator prefix and quotes: `W/"abc"` and `"abc"` are both abc. */
const etagValue = (header: string | undefined): string | undefined =>
    header?.trim().replace(/^W\//, "").replace(/^"|"$/g, "");

app.get("/refdata", requireAuth, requireAccount, async (c) => {
    const refdata = await getRefData();
    c.header("ETag", `"${refdata.version}"`);
    // Reference data changes rarely but must not go stale silently: revalidate always,
    // and the revalidation is a 304 with an empty body.
    c.header("Cache-Control", "private, no-cache");
    const known = c.req.query("version") ?? etagValue(c.req.header("if-none-match"));
    if (known === refdata.version) return c.body(null, 304);
    return c.json(refdata);
});

// ── Calendar events ────────────────────────────────────────────────────────────
// Everything below validates at the edge and delegates to events.ts, which is the
// only module allowed to touch users/{uid}/events (GUARDRAILS rule 10).
//
// Times on the wire are the user's wall clock, never an instant: `localDate` is
// what the device says the day is, and the server never derives it from its own
// clock. `timeZone` (optional, IANA) is used only to work out what "today" is for
// the caller — it is not stored. Without it the server falls back to UTC and allows
// a day of slack in both directions, because UTC-12..UTC+14 means someone's real
// today is always within one day of the server's.

type Parsed<T> = { ok: true; value: T } | { ok: false; code: string; message: string };

const good = <T>(value: T): Parsed<T> => ({ ok: true, value });
const bad = (message: string, code = "VALIDATION"): Parsed<never> => ({
    ok: false,
    code,
    message,
});

const CALENDAR_DATE = /^\d{4}-\d{2}-\d{2}$/;
const LOCAL_DATETIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/;
const NOTE_LIMIT = 280;
const APPOINTMENT_NOTE_LIMIT = 10_000;
const MAX_RANGE_DAYS = 400;

/** `YYYY-MM-DD` that is also a real day — 2026-02-30 parses but is not one. */
const isCalendarDate = (value: unknown): value is string => {
    if (typeof value !== "string" || !CALENDAR_DATE.test(value)) return false;
    const parsed = new Date(`${value}T00:00:00.000Z`);
    return (
        !Number.isNaN(parsed.getTime()) &&
        parsed.toISOString().slice(0, 10) === value
    );
};

const shiftDays = (date: string, days: number): string =>
    new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000)
        .toISOString()
        .slice(0, 10);

/** Twelve months back. 29 Feb lands on 1 Mar in a non-leap year, which is fine
 *  for a cap — it is a day either way. */
const minusTwelveMonths = (date: string): string => {
    const [year, month, day] = date.split("-").map(Number);
    return new Date(Date.UTC(year! - 1, month! - 1, day!)).toISOString().slice(0, 10);
};

interface Clock {
    /** The caller's current local date. */
    today: string;
    /** The caller's current local time, `HH:mm:ss`. */
    timeOfDay: string;
    /** Days of tolerance around `today` when the caller did not name its zone. */
    slackDays: number;
}

const resolveClock = (timeZone: unknown): Parsed<Clock> => {
    if (timeZone !== undefined && typeof timeZone !== "string") {
        return bad("timeZone must be an IANA time zone name");
    }
    const zone = timeZone ?? "UTC";
    let parts: Intl.DateTimeFormatPart[];
    try {
        parts = new Intl.DateTimeFormat("en-US", {
            timeZone: zone,
            year: "numeric",
            month: "2-digit",
            day: "2-digit",
            hour: "2-digit",
            minute: "2-digit",
            second: "2-digit",
            hourCycle: "h23",
        }).formatToParts(new Date());
    } catch {
        return bad(`Unknown time zone: ${zone}`);
    }
    const part = (name: string) => parts.find((p) => p.type === name)!.value;
    return good({
        today: `${part("year")}-${part("month")}-${part("day")}`,
        timeOfDay: `${part("hour")}:${part("minute")}:${part("second")}`,
        slackDays: timeZone === undefined ? 1 : 0,
    });
};

/** Future dates are for appointments only — you cannot observe something that has
 *  not happened. Everything is capped at 12 months of backdating (PRD edge case 1). */
const checkDatePolicy = (
    type: LoggableEventType,
    localDate: string,
    clock: Clock,
): Parsed<true> => {
    if (type !== "appointment") {
        const latest = shiftDays(clock.today, clock.slackDays);
        if (localDate > latest) {
            return bad(
                "Only appointments can be logged on a future date",
                "FUTURE_DATE_NOT_ALLOWED",
            );
        }
    }
    const earliest = shiftDays(minusTwelveMonths(clock.today), -clock.slackDays);
    if (localDate < earliest) {
        return bad(
            "Entries can only be backdated 12 months",
            "BACKDATE_LIMIT_EXCEEDED",
        );
    }
    return good(true);
};

/** Now for today, 12:00 otherwise. The date half always matches `localDate`: the
 *  day sheet orders entries by this, so it is a time *on that day*, not an instant. */
const defaultLoggedAt = (localDate: string, clock: Clock): string =>
    localDate === clock.today
        ? `${localDate}T${clock.timeOfDay}`
        : `${localDate}T12:00:00`;

const parseLoggedAt = (value: unknown, localDate: string, clock: Clock): Parsed<string> => {
    if (value === undefined || value === null) return good(defaultLoggedAt(localDate, clock));
    if (typeof value !== "string" || !LOCAL_DATETIME.test(value)) {
        return bad("loggedAt must be a local YYYY-MM-DDTHH:mm:ss");
    }
    const normalized = value.length === 16 ? `${value}:00` : value;
    if (!normalized.startsWith(`${localDate}T`)) {
        return bad("loggedAt must fall on the entry's localDate");
    }
    return good(normalized);
};

const parseNote = (value: unknown, type: LoggableEventType): Parsed<string | null> => {
    if (value === undefined || value === null) return good(null);
    if (typeof value !== "string") return bad("note must be text");
    const limit = type === "appointment" ? APPOINTMENT_NOTE_LIMIT : NOTE_LIMIT;
    const note = value.trim();
    if (note.length > limit) return bad(`note must be ${limit} characters or fewer`);
    return good(note.length > 0 ? note : null);
};

const parseSource = (value: unknown): Parsed<EventSource> => {
    if (value === undefined || value === null) return good("user");
    if (value !== "user" && value !== "eva") return bad("source must be user or eva");
    return good(value);
};

const parseIdempotencyKey = (value: unknown): Parsed<string | null> => {
    if (value === undefined || value === null) return good(null);
    if (typeof value !== "string" || value.length < 1 || value.length > 128) {
        return bad("idempotencyKey must be 1–128 characters");
    }
    return good(value);
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
    typeof value === "object" && value !== null && !Array.isArray(value);

const parseCyclePayload = (body: Record<string, unknown>): Parsed<CyclePayload> => {
    const hasSpotting = body.spotting !== undefined && body.spotting !== null;
    const hasFlow = body.flow !== undefined && body.flow !== null;
    // Spotting is a marker, not a flow level: a spotting day does not start a period.
    if (hasSpotting && hasFlow) {
        return bad("A cycle entry is either spotting or a flow level, not both");
    }
    if (hasSpotting) {
        return body.spotting === true
            ? good({ spotting: true })
            : bad("spotting must be true when present");
    }
    if (hasFlow) {
        return body.flow === "light" || body.flow === "medium" || body.flow === "heavy"
            ? good({ flow: body.flow })
            : bad("flow must be light, medium or heavy");
    }
    return bad("A cycle entry needs either spotting or a flow level");
};

const parseRating = (value: unknown, name: string): Parsed<number | undefined> => {
    if (value === undefined || value === null) return good(undefined);
    if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 5) {
        return bad(`${name} must be a whole number from 1 to 5`);
    }
    return good(value);
};

/** Codes are checked against the catalogue `refdata.ts` serves, so the client and the
 *  validator agree on one vocabulary (PRD:484). `rules` is null when the catalogue is
 *  unavailable — codes then stay opaque, as they were before #24, because refusing a
 *  health entry over missing reference data is the worse failure.
 *
 *  A *retired* code is accepted: an offline queue may hold an entry logged while the
 *  chip was still offered, and the user must still be able to edit it. Only a code the
 *  catalogue has never carried is rejected. */
const parseSymptoms = (value: unknown, rules: SymptomRules | null): Parsed<Symptom[]> => {
    if (value === undefined || value === null) return good([]);
    if (!Array.isArray(value)) return bad("symptoms must be a list");
    if (value.length > 40) return bad("symptoms must hold 40 entries or fewer");
    const symptoms: Symptom[] = [];
    for (const entry of value) {
        if (!isRecord(entry)) return bad("each symptom must be an object");
        const { severity } = entry;
        if (typeof entry.code !== "string" || entry.code.trim().length < 1 || entry.code.length > 64) {
            return bad("each symptom needs a code of 1–64 characters");
        }
        const code = entry.code.trim();
        if (rules && !rules.has(code)) {
            // Its own code so a stale client can refetch /refdata instead of guessing.
            return bad(`Unknown symptom code: ${code}`, "UNKNOWN_SYMPTOM_CODE");
        }
        if (severity !== undefined && severity !== null && severity !== "normal" && severity !== "severe") {
            return bad("symptom severity must be normal or severe");
        }
        const parsedValue = parseSymptomValue(entry.value, code, rules);
        if (!parsedValue.ok) return parsedValue;
        if (symptoms.some((s) => s.code === code)) {
            return bad(`symptom ${code} is listed twice`);
        }
        symptoms.push({
            code,
            severity: (severity as SymptomSeverity) ?? "normal",
            // Absent, never undefined: Firestore rejects an undefined field.
            ...(parsedValue.value !== undefined ? { value: parsedValue.value } : {}),
        });
    }
    return good(symptoms);
};

/** The chip's own picker (discharge: dry/sticky/creamy/watery/egg-white). Optional
 *  even where the catalogue offers one — a chip logged without a choice is still a
 *  logged chip — but a value the catalogue does not offer is a client bug. */
const parseSymptomValue = (
    value: unknown,
    code: string,
    rules: SymptomRules | null,
): Parsed<string | undefined> => {
    if (value === undefined || value === null) return good(undefined);
    if (typeof value !== "string" || value.trim().length < 1 || value.length > 64) {
        return bad("symptom value must be 1–64 characters");
    }
    const trimmed = value.trim();
    if (!rules) return good(trimmed);
    const allowed = rules.valuesFor(code);
    if (!allowed) return bad(`symptom ${code} does not take a value`);
    if (!allowed.includes(trimmed)) {
        return bad(`symptom ${code} value must be one of ${allowed.join(", ")}`);
    }
    return good(trimmed);
};

const parseBodySignalsPayload = (
    body: Record<string, unknown>,
    rules: SymptomRules | null,
): Parsed<BodySignalsPayload> => {
    const energy = parseRating(body.energy, "energy");
    if (!energy.ok) return energy;
    const mood = parseRating(body.mood, "mood");
    if (!mood.ok) return mood;
    const sleep = parseRating(body.sleep, "sleep");
    if (!sleep.ok) return sleep;
    const symptoms = parseSymptoms(body.symptoms, rules);
    if (!symptoms.ok) return symptoms;
    // Absent ratings stay absent — nothing is preselected, and 3 is not "unanswered".
    return good({
        ...(energy.value !== undefined ? { energy: energy.value } : {}),
        ...(mood.value !== undefined ? { mood: mood.value } : {}),
        ...(sleep.value !== undefined ? { sleep: sleep.value } : {}),
        symptoms: symptoms.value,
    });
};

const parseSportPayload = (body: Record<string, unknown>): Parsed<SportPayload> => {
    const { activity, durationMin, intensity } = body;
    if (typeof activity !== "string" || activity.trim().length < 1 || activity.length > 64) {
        return bad("activity must be 1–64 characters");
    }
    if (
        typeof durationMin !== "number" ||
        !Number.isInteger(durationMin) ||
        durationMin < 5 ||
        durationMin > 300
    ) {
        return bad("durationMin must be a whole number of minutes from 5 to 300");
    }
    if (intensity !== "light" && intensity !== "medium" && intensity !== "hard") {
        return bad("intensity must be light, medium or hard");
    }
    return good({ activity: activity.trim(), durationMin, intensity });
};

const parseAppointmentPayload = (
    body: Record<string, unknown>,
    localDate: string,
): Parsed<AppointmentPayload> => {
    const { startAt, type, questions, reminderMinutesBefore } = body;
    if (typeof startAt !== "string" || !LOCAL_DATETIME.test(startAt)) {
        return bad("startAt must be a local YYYY-MM-DDTHH:mm:ss");
    }
    const normalizedStart = startAt.length === 16 ? `${startAt}:00` : startAt;
    if (!normalizedStart.startsWith(`${localDate}T`)) {
        return bad("startAt must fall on the appointment's localDate");
    }
    if (type !== undefined && type !== null && (typeof type !== "string" || type.length > 64)) {
        return bad("type must be 64 characters or fewer");
    }
    const list: string[] = [];
    if (questions !== undefined && questions !== null) {
        if (!Array.isArray(questions)) return bad("questions must be a list");
        if (questions.length > 50) return bad("questions must hold 50 entries or fewer");
        for (const question of questions) {
            if (typeof question !== "string" || question.trim().length < 1 || question.length > 500) {
                return bad("each question must be 1–500 characters");
            }
            list.push(question.trim());
        }
    }
    // Omitted means the PRD's default of one day before; explicit null means none.
    let reminder: number | null = 1440;
    if (reminderMinutesBefore === null) reminder = null;
    else if (reminderMinutesBefore !== undefined) {
        if (
            typeof reminderMinutesBefore !== "number" ||
            !Number.isInteger(reminderMinutesBefore) ||
            reminderMinutesBefore < 0 ||
            reminderMinutesBefore > 40_320
        ) {
            return bad("reminderMinutesBefore must be a whole number of minutes from 0 to 40320");
        }
        reminder = reminderMinutesBefore;
    }
    return good({
        startAt: normalizedStart,
        type: typeof type === "string" && type.trim().length > 0 ? type.trim() : null,
        questions: list,
        reminderMinutesBefore: reminder,
    });
};

/** `rules` is fetched once per request at the route edge and threaded down, so
 *  validation stays here and `refdata.ts` stays the only reader of its collection. */
const parsePayload = (
    type: LoggableEventType,
    payload: unknown,
    localDate: string,
    rules: SymptomRules | null,
): Parsed<EventPayload> => {
    if (!isRecord(payload)) return bad("payload must be an object");
    switch (type) {
        case "cycle":
            return parseCyclePayload(payload);
        case "bodySignals":
            return parseBodySignalsPayload(payload, rules);
        case "sport":
            return parseSportPayload(payload);
        case "appointment":
            return parseAppointmentPayload(payload, localDate);
    }
};

const parseEventType = (value: unknown): Parsed<LoggableEventType> => {
    if (value === "sex") {
        // Reserved in the model; ships in C10 with its privacy switch.
        return bad("The sex event type is not available yet");
    }
    if (
        value !== "cycle" &&
        value !== "bodySignals" &&
        value !== "sport" &&
        value !== "appointment"
    ) {
        return bad("type must be cycle, bodySignals, sport or appointment");
    }
    return good(value);
};

const parseNewEvent = (
    body: Record<string, unknown>,
    rules: SymptomRules | null,
): Parsed<NewEvent> => {
    const type = parseEventType(body.type);
    if (!type.ok) return type;
    if (!isCalendarDate(body.localDate)) return bad("localDate must be YYYY-MM-DD");
    const localDate = body.localDate;

    const clock = resolveClock(body.timeZone);
    if (!clock.ok) return clock;
    const policy = checkDatePolicy(type.value, localDate, clock.value);
    if (!policy.ok) return policy;

    const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value);
    if (!loggedAt.ok) return loggedAt;
    const note = parseNote(body.note, type.value);
    if (!note.ok) return note;
    const source = parseSource(body.source);
    if (!source.ok) return source;
    const idempotencyKey = parseIdempotencyKey(body.idempotencyKey);
    if (!idempotencyKey.ok) return idempotencyKey;
    const payload = parsePayload(type.value, body.payload, localDate, rules);
    if (!payload.ok) return payload;

    return good({
        type: type.value,
        localDate,
        loggedAt: loggedAt.value,
        note: note.value,
        source: source.value,
        idempotencyKey: idempotencyKey.value,
        payload: payload.value,
    } as NewEvent);
};

app.get("/me/events", requireAuth, requireAccount, async (c) => {
    const from = c.req.query("from");
    const to = c.req.query("to");
    if (!isCalendarDate(from) || !isCalendarDate(to)) {
        return c.json(error("VALIDATION", "from and to must be YYYY-MM-DD"), 400);
    }
    if (from > to) return c.json(error("VALIDATION", "from must not be after to"), 400);
    if (Date.parse(`${to}T00:00:00.000Z`) - Date.parse(`${from}T00:00:00.000Z`) >
        MAX_RANGE_DAYS * 86_400_000) {
        return c.json(
            error("VALIDATION", `Range must be ${MAX_RANGE_DAYS} days or fewer`),
            400,
        );
    }
    return c.json({ events: await listEvents(c.get("claims").sub, from, to) });
});

app.post("/me/events", requireAuth, requireAccount, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const parsed = parseNewEvent(body, await getSymptomRules());
    if (!parsed.ok) return c.json(error(parsed.code, parsed.message), 400);
    return c.json({ event: await createEvent(c.get("claims").sub, parsed.value) }, 201);
});

app.patch("/me/events/:id", requireAuth, requireAccount, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    // `type` and `localDate` are always required: with both, every payload and
    // timestamp rule can be checked here instead of after a read in the module.
    const type = parseEventType(body.type);
    if (!type.ok) return c.json(error(type.code, type.message), 400);
    if (!isCalendarDate(body.localDate)) {
        return c.json(error("VALIDATION", "localDate must be YYYY-MM-DD"), 400);
    }
    const localDate = body.localDate;
    const clock = resolveClock(body.timeZone);
    if (!clock.ok) return c.json(error(clock.code, clock.message), 400);
    const policy = checkDatePolicy(type.value, localDate, clock.value);
    if (!policy.ok) return c.json(error(policy.code, policy.message), 400);

    const patch: EventPatch = { type: type.value, localDate };
    if (body.note !== undefined) {
        const note = parseNote(body.note, type.value);
        if (!note.ok) return c.json(error(note.code, note.message), 400);
        patch.note = note.value;
    }
    if (body.payload !== undefined) {
        const payload = parsePayload(type.value, body.payload, localDate, await getSymptomRules());
        if (!payload.ok) return c.json(error(payload.code, payload.message), 400);
        patch.payload = payload.value;
    }
    if (body.loggedAt !== undefined) {
        const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value);
        if (!loggedAt.ok) return c.json(error(loggedAt.code, loggedAt.message), 400);
        patch.loggedAt = loggedAt.value;
    }

    const result = await updateEvent(c.get("claims").sub, c.req.param("id"), patch);
    if (result.ok) return c.json({ event: result.event });
    if (result.reason === "not-found") return c.json(error("NOT_FOUND", "No such event"), 404);
    if (result.reason === "type-mismatch") {
        return c.json(error("VALIDATION", "type does not match the stored event"), 400);
    }
    return c.json(
        error("VALIDATION", "This entry is one per day — delete it and log the other day instead"),
        400,
    );
});

app.delete("/me/events/:id", requireAuth, requireAccount, async (c) => {
    const deleted = await softDeleteEvent(c.get("claims").sub, c.req.param("id"));
    if (!deleted) return c.json(error("NOT_FOUND", "No such event"), 404);
    return c.json({ deleted: true });
});

/** Undo for the delete toast. Nothing to validate — the id is the whole request, and
 *  what may be restored is a question about stored state, which the module answers. */
app.post("/me/events/:id/restore", requireAuth, requireAccount, async (c) => {
    const result = await restoreEvent(c.get("claims").sub, c.req.param("id"));
    if (result.ok) return c.json({ event: result.event });
    if (result.reason === "day-taken") {
        // 409, not 404: the entry is not missing, the day is occupied. Restoring would
        // have to overwrite a newer entry, so the client is told rather than obeyed.
        return c.json(
            error("DAY_ALREADY_LOGGED", "That day already has an entry, so this one can't be restored"),
            409,
        );
    }
    if (result.reason === "expired") {
        return c.json(
            error("NOT_FOUND", `That entry is past its ${RETENTION_DAYS}-day recovery window`),
            404,
        );
    }
    return c.json(error("NOT_FOUND", "No such event"), 404);
});

/** Upsert-by-day: one body signals entry per user per day, always replaced whole.
 *  The ratings sit at the top level here — the route already says what this is. */
app.put("/me/body-signals/:date", requireAuth, requireAccount, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const localDate = c.req.param("date");
    if (!isCalendarDate(localDate)) {
        return c.json(error("VALIDATION", "date must be YYYY-MM-DD"), 400);
    }

    const clock = resolveClock(body.timeZone);
    if (!clock.ok) return c.json(error(clock.code, clock.message), 400);
    const policy = checkDatePolicy("bodySignals", localDate, clock.value);
    if (!policy.ok) return c.json(error(policy.code, policy.message), 400);

    const payload = parseBodySignalsPayload(body, await getSymptomRules());
    if (!payload.ok) return c.json(error(payload.code, payload.message), 400);
    const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value);
    if (!loggedAt.ok) return c.json(error(loggedAt.code, loggedAt.message), 400);
    const note = parseNote(body.note, "bodySignals");
    if (!note.ok) return c.json(error(note.code, note.message), 400);
    const source = parseSource(body.source);
    if (!source.ok) return c.json(error(source.code, source.message), 400);
    const idempotencyKey = parseIdempotencyKey(body.idempotencyKey);
    if (!idempotencyKey.ok) return c.json(error(idempotencyKey.code, idempotencyKey.message), 400);

    const event = await createEvent(c.get("claims").sub, {
        type: "bodySignals",
        localDate,
        loggedAt: loggedAt.value,
        note: note.value,
        source: source.value,
        idempotencyKey: idempotencyKey.value,
        payload: payload.value,
    });
    return c.json({ event });
});

export default {
    // Cloud Run injects PORT (8080); default to 3003 for local dev
    port: Number(process.env.PORT ?? 3003),
    fetch: app.fetch,
};

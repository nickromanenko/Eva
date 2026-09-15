import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { adminAuth, firestore } from "../src/firebase";
import { mintToken } from "../src/auth";
import { config } from "../src/config";
import { addressOfAuthAccount } from "../src/identity-toolkit";
import { default as server } from "../src/index";
import { consumeAuthAttempt, resetAuthRateLimits } from "../src/rate-limit";
import { markUserDeleted, saveQuestionnaire } from "../src/users";
import { activateAccount, createLegacyAccount, signUpActivated } from "./support/session";

/**
 * `DELETE /me` — immediate and complete (#8), and the resurrection path it has to close.
 *
 * Integration against the REAL Firebase project, same pattern as the other suites: every
 * account is `e2e+<uuid>@e2e.evaapp.dev` and is swept in `afterAll` whether or not the
 * tests got as far as deleting it themselves.
 *
 * The property under test is not "the route answers 200". It is that **a token minted
 * before the delete can do nothing afterwards**. Our JWT is stateless, lives 30 days and
 * cannot be revoked (ARCHITECTURE §3), so before this issue such a token still passed
 * `requireAuth`, reached `GET /me`, found no document, and had `ensureUser` *recreate the
 * account* from its own claims — for up to a month, from a phone the user no longer
 * controls the token on. "Every authenticated route" below is the whole authenticated
 * surface for that reason, not a sample of it.
 *
 * Both accounts here hold events across several types, one of them soft-deleted, because
 * a soft delete is the one thing that survives `DELETE /me/events/{id}` and must *not*
 * survive this.
 */

const BASE = process.env.EVA_API_URL ?? "http://localhost:3003";
const password = "correct-horse-8";

/** Slow because each one is a chain of real round trips to Auth and Firestore; stated per
 *  test rather than left to Bun's 5s default, which several cases already sit close to
 *  (#31). */
const SLOW = 20_000;

const createdUids: string[] = [];

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
    fetch(`${BASE}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token ? { authorization: `Bearer ${init.token}` } : {}),
        },
    });

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

interface AuthResponse {
    token: string;
    user: { id: string; email: string; questionnaireCompleted: boolean; profile: unknown };
}
interface EventResponse {
    event: { id: string };
}
interface EventsResponse {
    events: { id: string }[];
}
interface ErrorResponse {
    error: { code: string; message: string };
}

const userDoc = (uid: string) => firestore.collection("users").doc(uid);
const eventDocs = (uid: string) => userDoc(uid).collection("events");

/** Document ids rather than the `DocumentReference`s themselves, deliberately: a failing
 *  `toEqual` on a reference makes Bun serialize the whole Firestore client behind it,
 *  which does not fail — it exhausts memory and takes the runner down with it. Ids are
 *  strings, so a break here reports as a break. */
const eventIds = async (uid: string): Promise<string[]> =>
    (await eventDocs(uid).listDocuments()).map((doc) => doc.id);

/** Today in UTC — the suite passes `timeZone: "UTC"` everywhere so the date policy is
 *  decided by the same clock the assertions use. */
const todayUtc = (): string => new Date().toISOString().slice(0, 10);

const authUserExists = async (uid: string): Promise<boolean> => {
    try {
        await adminAuth.getUser(uid);
        return true;
    } catch {
        return false;
    }
};

/** One account with a calendar behind it: three live entries across three types, plus a
 *  fourth that has been soft-deleted and so is sitting inside its 30-day window. */
const seedAccount = async (): Promise<{ email: string; token: string; uid: string }> => {
    const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
    // Sign up, activate, sign in (#6) — a session no longer falls out of sign-up.
    const { token, uid } = await signUpActivated(BASE, email, password);
    createdUids.push(uid);
    await seedEvents(token);
    return { email, token, uid };
};

const seedEvents = async (token: string) => {
    const today = todayUtc();
    const post = (body: Record<string, unknown>) =>
        api("/me/events", { method: "POST", token, body: JSON.stringify(body) });

    const cycle = await post({
        type: "cycle",
        localDate: today,
        timeZone: "UTC",
        payload: { flow: "medium" },
    });
    expect(cycle.status).toBe(201);

    const appointment = await post({
        type: "appointment",
        localDate: today,
        timeZone: "UTC",
        payload: { startAt: `${today}T09:30`, type: "Gynaecologist", questions: [] },
    });
    expect(appointment.status).toBe(201);

    const signals = await api(`/me/body-signals/${today}`, {
        method: "PUT",
        token,
        body: JSON.stringify({ timeZone: "UTC", energy: 3, symptoms: [] }),
    });
    expect(signals.status).toBe(200);

    // The one that gets soft-deleted: still a document, with `deletedAt` set, recoverable
    // for 30 days — until the account itself goes.
    const sport = await post({
        type: "sport",
        localDate: today,
        timeZone: "UTC",
        payload: { activity: "Yoga", durationMin: 30, intensity: "light" },
    });
    expect(sport.status).toBe(201);
    const sportId = (await json<EventResponse>(sport)).event.id;
    const softDeleted = await api(`/me/events/${sportId}`, { method: "DELETE", token });
    expect(softDeleted.status).toBe(200);
};

/** Every authenticated route, with a request that would succeed for a live account. The
 *  point is the list being exhaustive: a route added without the account gate is a route
 *  a deleted account's token still reaches. */
const authenticatedRoutes = (): { name: string; call: (token: string) => Promise<Response> }[] => {
    const today = todayUtc();
    return [
        { name: "GET /me", call: (t) => api("/me", { token: t }) },
        {
            name: "PUT /me/questionnaire",
            call: (t) =>
                api("/me/questionnaire", {
                    method: "PUT",
                    token: t,
                    body: JSON.stringify({
                        age: 30,
                        weightKg: 60,
                        heightCm: 170,
                        goals: [],
                        conditions: [],
                        medications: "",
                        lifestyle: "active",
                        sports: [],
                    }),
                }),
        },
        { name: "GET /refdata", call: (t) => api("/refdata", { token: t }) },
        {
            // Added by #7, and missing from this list until the fifth review of that PR —
            // which is the failure mode the comment above predicts. Replacing
            // `requireAccount` on it with a pass-through left the whole suite green, and it
            // is the worst route to lose the gate on: the handler calls `ensureUser`, which
            // *creates* `users/{uid}` when there is no document, so a deleted account's
            // still-valid 30-day token would rebuild the document #8 deleted.
            name: "POST /me/auth/providers",
            call: (t) =>
                api("/me/auth/providers", {
                    method: "POST",
                    token: t,
                    body: JSON.stringify({
                        provider: "apple",
                        identityToken: "an-apple-identity-token",
                        rawNonce: "a-raw-nonce",
                    }),
                }),
        },
        {
            name: "GET /me/events",
            call: (t) => api(`/me/events?from=${today}&to=${today}`, { token: t }),
        },
        {
            name: "POST /me/events",
            call: (t) =>
                api("/me/events", {
                    method: "POST",
                    token: t,
                    body: JSON.stringify({
                        type: "sport",
                        localDate: today,
                        timeZone: "UTC",
                        payload: { activity: "Yoga", durationMin: 30, intensity: "light" },
                    }),
                }),
        },
        {
            name: "PATCH /me/events/:id",
            call: (t) =>
                api("/me/events/anything", {
                    method: "PATCH",
                    token: t,
                    body: JSON.stringify({ type: "sport", localDate: today, timeZone: "UTC" }),
                }),
        },
        {
            name: "DELETE /me/events/:id",
            call: (t) => api("/me/events/anything", { method: "DELETE", token: t }),
        },
        {
            name: "POST /me/events/:id/restore",
            call: (t) => api("/me/events/anything/restore", { method: "POST", token: t }),
        },
        {
            name: "PUT /me/body-signals/:date",
            call: (t) =>
                api(`/me/body-signals/${today}`, {
                    method: "PUT",
                    token: t,
                    body: JSON.stringify({ timeZone: "UTC", energy: 3, symptoms: [] }),
                }),
        },
    ];
};

afterAll(async () => {
    for (const uid of createdUids) {
        const docs = await eventDocs(uid)
            .listDocuments()
            .catch(() => []);
        await Promise.all(docs.map((doc) => doc.delete().catch(() => {})));
        await userDoc(uid)
            .delete()
            .catch(() => {});
        await adminAuth.deleteUser(uid).catch(() => {});
    }
});

describe("DELETE /me removes the account and everything keyed to it", () => {
    let email = "";
    let token = "";
    let uid = "";

    beforeAll(async () => {
        ({ email, token, uid } = await seedAccount());
    }, SLOW);

    test("the account starts with events across types, one of them soft-deleted", async () => {
        const snapshot = await eventDocs(uid).get();
        expect(snapshot.size).toBe(4);
        expect(new Set(snapshot.docs.map((d) => d.get("type")))).toEqual(
            new Set(["cycle", "appointment", "bodySignals", "sport"]),
        );
        expect(snapshot.docs.filter((d) => d.get("deletedAt") !== null).length).toBe(1);
    });

    test(
        "deleting takes the Auth user, the document and every event, soft-deleted included",
        async () => {
            const res = await api("/me", { method: "DELETE", token });
            expect(res.status).toBe(200);
            expect(await json<{ deleted: boolean }>(res)).toEqual({ deleted: true });

            expect(await authUserExists(uid)).toBe(false);
            expect((await userDoc(uid).get()).exists).toBe(false);
            // `listDocuments`, not `get`: it would also see a document that exists only as
            // a parent of something, which is exactly the orphan we are ruling out.
            expect(await eventIds(uid)).toEqual([]);
        },
        SLOW,
    );

    test(
        "a token minted before the delete is useless on every authenticated route",
        async () => {
            for (const route of authenticatedRoutes()) {
                const res = await route.call(token);
                expect(`${route.name} → ${res.status}`).toBe(`${route.name} → 401`);
                expect((await json<ErrorResponse>(res)).error.code).toBe("UNAUTHORIZED");
            }
            // The regression this issue is really about: `GET /me` used to treat "no
            // document" as "create one", so the loop above would have rebuilt the account
            // rather than refused it.
            expect((await userDoc(uid).get()).exists).toBe(false);
        },
        SLOW,
    );

    test("the deleted account's credentials no longer sign in", async () => {
        const res = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email, password }),
        });
        expect(res.status).toBe(401);
        expect((await json<ErrorResponse>(res)).error.code).toBe("INVALID_CREDENTIALS");
        expect((await userDoc(uid).get()).exists).toBe(false);
    });

    test(
        "deleting twice is not an error",
        async () => {
            const res = await api("/me", { method: "DELETE", token });
            expect(res.status).toBe(200);
            expect(await json<{ deleted: boolean }>(res)).toEqual({ deleted: true });
            expect((await userDoc(uid).get()).exists).toBe(false);
            expect(await authUserExists(uid)).toBe(false);
        },
        SLOW,
    );

    test(
        "the same address signs up again into a fresh, empty account",
        async () => {
            const res = await api("/auth/signup", {
                method: "POST",
                body: JSON.stringify({ email, password }),
            });
            expect(res.status).toBe(201);
            // The address is free again, and the new account has to prove it again: the
            // delete took every token with it (#6), so nothing survives to skip the gate.
            expect(await json<{ pending: boolean; email: string }>(res)).toEqual({
                pending: true,
                email,
            });
            // No account exists yet — sign-up creates none (#120) — so the uid can only be
            // read after the link is spent, which is also when the password is set.
            await activateAccount(BASE, null, email, password);
            const { uid: freshUid } = await adminAuth.getUserByEmail(email);
            createdUids.push(freshUid);
            const signin = await api("/auth/signin", {
                method: "POST",
                body: JSON.stringify({ email, password }),
            });
            expect(signin.status).toBe(200);
            const fresh = await json<AuthResponse>(signin);

            expect(fresh.user.id).not.toBe(uid);
            expect(fresh.user.email).toBe(email);
            expect(fresh.user.questionnaireCompleted).toBe(false);
            expect(fresh.user.profile).toBeNull();

            const today = todayUtc();
            const events = await api(`/me/events?from=${today}&to=${today}`, {
                token: fresh.token,
            });
            expect(events.status).toBe(200);
            expect((await json<EventsResponse>(events)).events).toEqual([]);
            expect(await eventIds(fresh.user.id)).toEqual([]);
        },
        SLOW,
    );
});

describe("a delete interrupted after the first step", () => {
    let email = "";
    let token = "";
    let uid = "";

    /**
     * The partial state is produced by calling `markUserDeleted` directly — step 1 of the
     * route's four, with steps 2–4 never run. That is the shape of every failure the route
     * can suffer, because the mark is what it does first: whatever throws afterwards, this
     * is what is left behind.
     *
     * The account is created through the Admin SDK and then signed in to, rather than
     * signed up: the credentials are real either way, and it keeps the suite off the
     * per-IP sign-up budget, which the whole `test/` directory shares (#5). It is written
     * in the pre-#6 shape — no `activatedAt` at all — because an Auth user with no
     * document is *not* activated by design, and this suite is about deletion, not the
     * activation gate.
     */
    beforeAll(async () => {
        email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
        uid = await createLegacyAccount(email, password);
        createdUids.push(uid);

        const signin = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email, password }),
        });
        expect(signin.status).toBe(200);
        token = (await json<AuthResponse>(signin)).token;
        await seedEvents(token);

        expect(await markUserDeleted(uid)).toBe(true);
    }, SLOW);

    test("the account is already inert, before anything has actually been removed", async () => {
        // Everything is still on disk...
        expect((await userDoc(uid).get()).exists).toBe(true);
        expect((await eventDocs(uid).get()).size).toBe(4);
        expect(await authUserExists(uid)).toBe(true);

        // ...and none of it is reachable.
        const me = await api("/me", { token });
        expect(me.status).toBe(401);
        expect((await json<ErrorResponse>(me)).error.code).toBe("UNAUTHORIZED");
    });

    test("signing in cannot walk the account back out of its deletion", async () => {
        const res = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email, password }),
        });
        expect(res.status).toBe(401);
        expect((await json<ErrorResponse>(res)).error.code).toBe("INVALID_CREDENTIALS");
        // The mark is not cleared, and no token was handed out to work around it.
        expect((await userDoc(uid).get()).get("deletedAt")).not.toBeNull();
    });

    test(
        "Firebase refuses to repoint an account at an address nobody verified",
        async () => {
            // **The premise behind the gate, measured rather than assumed** — and it does not
            // hold the way the code's comments say it does.
            //
            // `identity-toolkit.ts` states that "an idToken holder can move their own Auth
            // address with `accounts:update` — the web API key is public", and both #139 and
            // #140 are built on that step. Against this project it is **refused**:
            // `400 OPERATION_NOT_ALLOWED : Please verify the new email before changing email`.
            //
            // So an address is not freely movable here, and the gate on `forgetEmail` is
            // defence in depth rather than the thing standing between a caller and someone
            // else's counters. That deserves a test rather than a comment, because it is a
            // **project setting** and not a property of this code: whoever turns it off
            // silently makes #139 and #140 reachable, and this is what would say so.
            //
            // **The Auth emulator does not implement it**, so the two environments assert
            // different things below — each the one that is true of it, and both worth having.
            const own = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
            const moved = `e2e+moved-${crypto.randomUUID()}@e2e.evaapp.dev`;
            const { uid: movable } = await adminAuth.createUser({
                email: own,
                password,
                emailVerified: true,
            });
            createdUids.push(movable);

            const signIn = await fetch(
                `${config.identityToolkitBaseUrl}/v1/accounts:signInWithPassword?key=${config.firebaseWebApiKey}`,
                {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ email: own, password, returnSecureToken: true }),
                },
            );
            expect(signIn.ok).toBe(true);
            const { idToken } = (await signIn.json()) as { idToken: string };

            const update = await fetch(
                `${config.identityToolkitBaseUrl}/v1/accounts:update?key=${config.firebaseWebApiKey}`,
                {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ idToken, email: moved, returnSecureToken: false }),
                },
            );

            if (process.env.FIREBASE_AUTH_EMULATOR_HOST) {
                // **The emulator allows it.** Found by this test going red in CI while green
                // against the real project — the divergence `scripts/ci-api.sh` warns about in
                // its own header: a green emulator run proves the code against Firebase's
                // model of Firebase, not against Google. Here the model is the more permissive
                // of the two, so the emulator can never be what tells anyone the setting is on.
                //
                // Asserted rather than skipped, because what it demonstrates is the half the
                // gate actually needs: move the address, and `proven` goes false.
                expect(update.ok).toBe(true);
                const movedTo = await addressOfAuthAccount(movable);
                expect(movedTo.address).toBe(moved);
                expect(movedTo.proven).toBe(false);
                return;
            }

            expect(update.ok).toBe(false);
            expect(await update.text()).toContain("OPERATION_NOT_ALLOWED");
            // And the account still holds what it held.
            const unchanged = await addressOfAuthAccount(movable);
            expect(unchanged.address).toBe(own);
            expect(unchanged.proven).toBe(true);
        },
        SLOW,
    );

    test("the address a delete acts on reports whether Auth considers it proven", async () => {
        // The gate on `forgetEmail` (#56). That call is the one step of a delete that
        // touches state keyed by an *address* rather than by this account's uid, and an
        // idToken holder can point their own Auth account at any address no Firebase user
        // holds. `accounts:update` clears `emailVerified` when the address moves, so
        // `proven` is the distinction the route needs — asserted here rather than in the
        // route, because producing a moved address means calling Identity Toolkit directly
        // with a credential this suite has no reason to hold.
        const seen = await addressOfAuthAccount(uid);
        expect(seen.address).toBe(email);
        // `createLegacyAccount` makes an Auth user the way one existed before #6: no
        // confirmation, so nothing has proven the address and the clear must not run.
        expect(seen.proven).toBe(false);

        // And a uid with no Auth account at all answers the same, fail-closed way.
        const gone = await addressOfAuthAccount("no-such-uid-for-issue-56");
        expect(gone.address).toBeNull();
        expect(gone.proven).toBe(false);
    });

    test("saveQuestionnaire refuses the tombstone on its own, not only via the gate", async () => {
        // Called **directly**, with no route and no middleware in front of it (#56).
        // `requireAccount` already refuses a deleted account, so through the API this is
        // unreachable — which is precisely why it is asserted here instead. Every other
        // read in `users.ts` refuses a tombstone itself; this one used to be safe only
        // because of where the gate happened to sit, and a second caller or a reordered
        // middleware would have made it write the profile onto a deleted account.
        // The precondition, asserted rather than inherited from where this case sits in the
        // file. Placed after "retrying the delete finishes it" the document would be gone,
        // `!snapshot.exists` would return null on its own, and this would pass while
        // proving nothing.
        expect((await userDoc(uid).get()).get("deletedAt")).not.toBeNull();

        const written = await saveQuestionnaire(uid, {
            age: 30,
            weightKg: 65,
            heightCm: 170,
            goals: ["energy"],
            conditions: [],
            medications: "",
            lifestyle: "active",
            sports: ["running"],
        });

        expect(written).toBeNull();
        // And it wrote nothing on the way to saying so.
        const doc = await userDoc(uid).get();
        expect(doc.get("profile") ?? null).toBeNull();
        expect(doc.get("questionnaireCompleted") ?? false).toBe(false);
    });

    test(
        "retrying the delete finishes it",
        async () => {
            const res = await api("/me", { method: "DELETE", token });
            expect(res.status).toBe(200);

            expect(await authUserExists(uid)).toBe(false);
            expect((await userDoc(uid).get()).exists).toBe(false);
            expect(await eventIds(uid)).toEqual([]);
        },
        SLOW,
    );
});

/**
 * That `DELETE /me` actually gives the address's throttle budget back (#56).
 *
 * The counters live in the API server's memory, so a test that drives the route over HTTP
 * — which is how the rest of this file works — is in a different process from the counters
 * it wants to read, and can assert nothing about them. That was offered as a reason the
 * behaviour could not be tested end to end. It is not one: the route runs in *this* process
 * through `server.fetch`, against the same real Firebase, and then the counters are right
 * there. `rate-limit.test.ts` covers `forgetEmail` itself; what is missing without this is
 * anything at all tying the route to it — delete the call from `index.ts` and every other
 * test stays green.
 */
describe("deleting an account returns its address's throttle budget", () => {
    /** The route, in-process. Never as a listening server — the default export is a plain
     *  object until something serves it. */
    const deleteMe = async (token: string) =>
        server.fetch(
            new Request("http://api.test/me", {
                method: "DELETE",
                headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
            }),
        );

    /** Spends an address's sign-in budget until the next attempt is refused. */
    const exhaust = (email: string) => {
        for (let i = 0; i < config.rateLimit.signinPerEmail + 1; i += 1) {
            consumeAuthAttempt("signin", null, email);
        }
    };

    test(
        "an address Auth never proved is left alone",
        async () => {
            // The gate itself (#56). Without this, deleting `if (proven)` from the route
            // breaks nothing: the case above creates its account `emailVerified: true`, so
            // it passes either way, and the `proven` assertions elsewhere cover the function
            // rather than the route's decision.
            //
            // `createLegacyAccount` makes an Auth user the way one existed before #6 — no
            // confirmation, so `emailVerified` is false by construction and nothing had to
            // be moved to get there.
            const email = `e2e+unproven-${crypto.randomUUID()}@e2e.evaapp.dev`;
            const uid = await createLegacyAccount(email, password);
            createdUids.push(uid);
            expect((await addressOfAuthAccount(uid)).proven).toBe(false);

            resetAuthRateLimits();
            exhaust(email);
            expect(consumeAuthAttempt("signin", null, email)).toBe(false);

            const res = await deleteMe(await mintToken(uid, email));
            expect(res.status).toBe(200);

            // Still spent: the delete completed, and the counters were not the delete's to
            // give back. Skipping is the harmless direction — they expire on their own.
            expect(consumeAuthAttempt("signin", null, email)).toBe(false);
            resetAuthRateLimits();
        },
        SLOW,
    );

    test(
        "the address is served again, and the caller's IP budget is not given back",
        async () => {
            const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
            // `emailVerified: true` because the route only forgets an address Auth
            // considers proven — see the note on `forgetEmail` in the route.
            const { uid } = await adminAuth.createUser({ email, password, emailVerified: true });
            createdUids.push(uid);
            await userDoc(uid).set({
                email,
                authProviders: ["password"],
                questionnaireCompleted: false,
                profile: null,
                activatedAt: new Date(),
                createdAt: new Date(),
                updatedAt: new Date(),
            });

            resetAuthRateLimits();
            exhaust(email);
            expect(consumeAuthAttempt("signin", null, email)).toBe(false);
            // A second address, throttled and *not* deleted: what the clear must not reach.
            const bystander = `e2e+bystander-${crypto.randomUUID()}@e2e.evaapp.dev`;
            exhaust(bystander);
            expect(consumeAuthAttempt("signin", null, bystander)).toBe(false);

            const res = await deleteMe(await mintToken(uid, email));
            expect(res.status).toBe(200);

            expect(consumeAuthAttempt("signin", null, email)).toBe(true);
            expect(consumeAuthAttempt("signin", null, bystander)).toBe(false);
            resetAuthRateLimits();
        },
        SLOW,
    );
});

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { adminAuth, firestore } from "../src/firebase";
import { markUserDeleted } from "../src/users";

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
    const signup = await api("/auth/signup", {
        method: "POST",
        body: JSON.stringify({ email, password }),
    });
    expect(signup.status).toBe(201);
    const { token, user } = await json<AuthResponse>(signup);
    createdUids.push(user.id);
    await seedEvents(token);
    return { email, token, uid: user.id };
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
            const fresh = await json<AuthResponse>(res);
            createdUids.push(fresh.user.id);

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
     * per-IP sign-up budget, which the whole `test/` directory shares (#5).
     */
    beforeAll(async () => {
        email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
        const created = await adminAuth.createUser({ email, password });
        uid = created.uid;
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

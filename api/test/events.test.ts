import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";

// Every case here makes real round trips to Identity Toolkit and Firestore, and #8's
// account gate added one Firestore read per authenticated request — which pushed
// "the day's entry is upserted" past Bun's 5000ms default and failed a run.
//
// 20s is not a measurement of how long these take; it is a ceiling that still fails
// loudly on a genuine hang. Normal cases in this suite finish well under 2s, so a case
// approaching this number means something is wrong rather than merely slow. The general
// question of what these should cost is #31.
setDefaultTimeout(20_000);
import { adminAuth, firestore } from "../src/firebase";
import { signUpActivated } from "./support/session";

/**
 * Integration tests against the REAL Firebase project, same pattern as auth.test.ts:
 * one e2e+<uuid>@e2e.evaapp.dev account, swept in afterAll.
 *
 * The suite deliberately does not assume the server, or this process, runs in UTC —
 * see the "timezone" describe block, which is the point of the exercise.
 */

const BASE = process.env.EVA_API_URL ?? "http://localhost:3003";
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
const password = "correct-horse-8";
let token = "";
let uid = "";

const api = (
    path: string,
    init?: RequestInit & { token?: string | null; base?: string },
) =>
    fetch(`${init?.base ?? BASE}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
        },
    });

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

interface EvaEventBody {
    id: string;
    type: string;
    localDate: string;
    loggedAt: string;
    note: string | null;
    source: string;
    payload: Record<string, unknown>;
    idempotencyKey: string | null;
    deletedAt: string | null;
}
interface EventResponse {
    event: EvaEventBody;
}
interface EventsResponse {
    events: EvaEventBody[];
}
interface ErrorResponse {
    error: { code: string; message: string };
}

/** Local calendar date in a named zone — the same computation the client does. */
const todayIn = (timeZone: string): string => {
    const parts = new Intl.DateTimeFormat("en-US", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
    }).formatToParts(new Date());
    const part = (name: string) => parts.find((p) => p.type === name)!.value;
    return `${part("year")}-${part("month")}-${part("day")}`;
};

const hourIn = (timeZone: string): number =>
    Number(
        new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", hourCycle: "h23" })
            .formatToParts(new Date())
            .find((p) => p.type === "hour")!.value,
    );

const shiftDays = (date: string, days: number): string =>
    new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000)
        .toISOString()
        .slice(0, 10);

const minusTwelveMonths = (date: string): string => {
    const [year, month, day] = date.split("-").map(Number);
    return new Date(Date.UTC(year! - 1, month! - 1, day!)).toISOString().slice(0, 10);
};

const sport = (localDate: string, extra: Record<string, unknown> = {}) => ({
    type: "sport",
    localDate,
    payload: { activity: "Yoga", durationMin: 30, intensity: "light" },
    ...extra,
});

const post = (body: Record<string, unknown>, base?: string) =>
    api("/me/events", { method: "POST", body: JSON.stringify(body), base });

const range = async (from: string, to: string): Promise<EvaEventBody[]> =>
    (await json<EventsResponse>(await api(`/me/events?from=${from}&to=${to}`))).events;

const eventsCollection = () => firestore.collection("users").doc(uid).collection("events");

/** Whether anything at all answers HTTP at `url` — not whether it is an Eva API. */
const answers = (url: string): Promise<boolean> =>
    fetch(`${url}/`)
        .then(() => true)
        .catch(() => false);

/** Ports this file has spawned on. Only one case spawns today, and it waits for its child to go
 *  before it finishes — but a case that fails earlier leaves through a `finally` that kills
 *  without waiting, so a port handed out once is not reliably free again in this run. */
const claimedPorts = new Set<number>();

/** The suite server's window: `scripts/lib/api-server.sh` takes the first free port from
 *  `EVA_API_PORT` through +10, and reads an empty value as unset, as `||` does here. */
const suitePortsFrom = Number(process.env.EVA_API_PORT || 3003);
const suitePortsTo = suitePortsFrom + 10;

/**
 * A port in 3100–3299 for the UTC+14 API: not in the suite server's window, not answered by
 * anything, and not one this file has spawned on before (#193).
 *
 * **That range can hold the suite's own server** — 3103–3113 under `scripts/ci-api.sh` by
 * default, and since #174 wherever a developer's `EVA_API_PORT` puts it — and every Eva API
 * answers `/` with `Eva API`. A draw that lands on it boots nothing (the child exits with
 * `EADDRINUSE`), the first poll succeeds anyway, and the case compares the suite server with
 * itself: green, in ~80ms where a real UTC+14 boot takes ~440ms.
 *
 * The window is excluded by value because `EVA_API_PORT` is a developer's to set. Asking first
 * is still needed, because the window is not where every Eva API is: `EVA_API_URL` can point
 * the suite somewhere else entirely, `scripts/ci-mobile.sh` runs its own server on 3203, and a
 * server an interrupted run left behind answers `Eva API` just the same.
 */
const freePort = async (): Promise<number> => {
    for (let attempt = 0; attempt < 100; attempt++) {
        const port = 3100 + Math.floor(Math.random() * 200);
        if (claimedPorts.has(port)) continue;
        if (port >= suitePortsFrom && port <= suitePortsTo) continue;
        if (await answers(`http://localhost:${port}`)) continue;
        claimedPorts.add(port);
        return port;
    }
    throw new Error("no free port in 3100-3299 for the UTC+14 API this case needs");
};

beforeAll(async () => {
    // Sign-up no longer hands out a session (#6): the account has to be activated first.
    // `signUpActivated` does the three steps — sign up, spend an activation token, sign in.
    const session = await signUpActivated(BASE, email, password);
    token = session.token;
    uid = session.uid;
});

afterAll(async () => {
    if (uid) {
        const docs = await eventsCollection().listDocuments();
        await Promise.all(docs.map((doc) => doc.delete().catch(() => {})));
        await firestore.collection("users").doc(uid).delete().catch(() => {});
        await adminAuth.deleteUser(uid).catch(() => {});
    }
});

describe("events: auth and basic CRUD", () => {
    test("every event route requires a bearer token", async () => {
        const today = todayIn("UTC");
        expect((await api(`/me/events?from=${today}&to=${today}`, { token: null })).status).toBe(401);
        expect(
            (await api("/me/events", { method: "POST", token: null, body: "{}" })).status,
        ).toBe(401);
        expect(
            (await api("/me/events/x", { method: "PATCH", token: null, body: "{}" })).status,
        ).toBe(401);
        expect((await api("/me/events/x", { method: "DELETE", token: null })).status).toBe(401);
        expect(
            (await api(`/me/body-signals/${today}`, { method: "PUT", token: null, body: "{}" }))
                .status,
        ).toBe(401);
    });

    test("a sport entry round-trips through the range read", async () => {
        const date = shiftDays(todayIn("UTC"), -20);
        const created = await post(sport(date, { note: "Felt good", timeZone: "UTC" }));
        expect(created.status).toBe(201);
        const event = (await json<EventResponse>(created)).event;
        expect(event.localDate).toBe(date);
        expect(event.type).toBe("sport");
        expect(event.note).toBe("Felt good");
        expect(event.source).toBe("user");
        expect(event.deletedAt).toBe(null);
        expect(event.payload).toEqual({ activity: "Yoga", durationMin: 30, intensity: "light" });

        const inRange = await range(date, date);
        expect(inRange.map((e) => e.id)).toEqual([event.id]);
        // and it is not returned outside its range
        expect(await range(shiftDays(date, 1), shiftDays(date, 2))).toEqual([]);
    });

    test("sport payload bounds are enforced", async () => {
        const date = shiftDays(todayIn("UTC"), -21);
        for (const payload of [
            { activity: "Yoga", durationMin: 4, intensity: "light" },
            { activity: "Yoga", durationMin: 301, intensity: "light" },
            { activity: "Yoga", durationMin: 30, intensity: "extreme" },
            { activity: "", durationMin: 30, intensity: "light" },
        ]) {
            const res = await post({ type: "sport", localDate: date, payload, timeZone: "UTC" });
            expect(res.status).toBe(400);
            expect((await json<ErrorResponse>(res)).error.code).toBe("VALIDATION");
        }
    });

    test("the sex type is reserved but not loggable yet", async () => {
        const res = await post({
            type: "sex",
            localDate: todayIn("UTC"),
            payload: {},
            timeZone: "UTC",
        });
        expect(res.status).toBe(400);
        expect((await json<ErrorResponse>(res)).error.code).toBe("VALIDATION");
    });

    test("range reads validate from/to", async () => {
        expect((await api("/me/events")).status).toBe(400);
        expect((await api("/me/events?from=2026-13-01&to=2026-01-02")).status).toBe(400);
        expect((await api("/me/events?from=2026-02-02&to=2026-02-01")).status).toBe(400);
        expect((await api("/me/events?from=2020-01-01&to=2026-01-01")).status).toBe(400);
    });
});

describe("events: timezone", () => {
    /**
     * The claim under test: `localDate` is stored exactly as the device sent it and is
     * never derived from an instant. A UTC-only suite cannot show this, so:
     *
     *  - Pacific/Kiritimati (UTC+14) and Pacific/Midway (UTC-11) are 25 hours apart, so
     *    their local dates ALWAYS differ. A server that derived the day from its own
     *    clock would have to get at least one of them wrong, or reject it as future.
     *  - The second test boots a whole API process in TZ=Pacific/Kiritimati and shows
     *    identical output, so nothing leans on the server's system zone either.
     */
    test("two devices a day apart both keep their own date", async () => {
        const east = todayIn("Pacific/Kiritimati"); // UTC+14
        const west = todayIn("Pacific/Midway"); // UTC-11
        expect(east).not.toBe(west); // 25 hours apart: always a different calendar day

        const eastEvent = (
            await json<EventResponse>(
                await post(sport(east, { timeZone: "Pacific/Kiritimati" })),
            )
        ).event;
        const westEvent = (
            await json<EventResponse>(await post(sport(west, { timeZone: "Pacific/Midway" })))
        ).event;

        expect(eastEvent.localDate).toBe(east);
        expect(westEvent.localDate).toBe(west);

        // and they read back on their own days, not shifted into one another's
        const found = await range(west, east);
        expect(found.find((e) => e.id === eastEvent.id)!.localDate).toBe(east);
        expect(found.find((e) => e.id === westEvent.id)!.localDate).toBe(west);

        // Firestore holds the string, not a converted instant.
        const stored = await eventsCollection().doc(eastEvent.id).get();
        expect(stored.get("localDate")).toBe(east);
    });

    test("a server running in UTC+14 stores the same dates as this one", async () => {
        const port = await freePort();
        const child = Bun.spawn(["bun", "run", "src/index.ts"], {
            cwd: new URL("..", import.meta.url).pathname,
            env: { ...process.env, TZ: "Pacific/Kiritimati", PORT: String(port) },
            stdout: "pipe",
            stderr: "pipe",
        });
        const base = `http://localhost:${port}`;
        try {
            let up = false;
            for (let i = 0; i < 40 && !up; i++) {
                // A child that has already exited could not bind. Polling on would mean
                // waiting for, or adopting, whatever else answers here; stop and fail below.
                if (child.exitCode !== null) break;
                up = await fetch(`${base}/`)
                    .then((r) => r.text())
                    .then((t) => t === "Eva API")
                    .catch(() => false);
                if (!up) await Bun.sleep(250);
            }
            expect(up).toBe(true);

            // Backdated: same stored date and the same 12:00 default on both servers.
            const date = shiftDays(todayIn("UTC"), -40);
            const shifted = (
                await json<EventResponse>(await post(sport(date), base))
            ).event;
            const local = (await json<EventResponse>(await post(sport(date)))).event;
            expect(shifted.localDate).toBe(date);
            expect(local.localDate).toBe(date);
            expect(shifted.loggedAt).toBe(`${date}T12:00:00`);
            expect(shifted.loggedAt).toBe(local.loggedAt);

            // "Today" is the caller's today, not the server's: UTC today is yesterday
            // in Pacific/Kiritimati, and the UTC+14 server must still accept it.
            const today = todayIn("UTC");
            const res = await post(
                { type: "cycle", localDate: today, payload: { flow: "light" }, timeZone: "UTC" },
                base,
            );
            expect(res.status).toBe(201);
            expect((await json<EventResponse>(res)).event.localDate).toBe(today);

            // Nothing above can tell which Eva API answered: `/` says `Eva API` on all of them,
            // and the suite's own server, in the host's zone, passes every assertion here. The
            // only proof it was the UTC+14 child is that the answers stop when it does.
            // `freePort` makes adoption unlikely; this makes it visible if it happens anyway.
            child.kill();
            await child.exited;
            if (await answers(base)) {
                throw new Error(
                    `port ${port} still answers with the UTC+14 API stopped: the dates ` +
                        "above were compared against a server this case did not start",
                );
            }
        } finally {
            child.kill();
        }
    }, 30_000);
});

describe("events: date policy", () => {
    test("future dates are refused for observational types", async () => {
        const tomorrow = shiftDays(todayIn("UTC"), 1);
        const attempts: Record<string, unknown>[] = [
            { type: "cycle", localDate: tomorrow, payload: { flow: "light" }, timeZone: "UTC" },
            { type: "sport", localDate: tomorrow, payload: sport(tomorrow).payload, timeZone: "UTC" },
        ];
        for (const body of attempts) {
            const res = await post(body);
            expect(res.status).toBe(400);
            expect((await json<ErrorResponse>(res)).error.code).toBe("FUTURE_DATE_NOT_ALLOWED");
        }
        const bodySignals = await api(`/me/body-signals/${tomorrow}`, {
            method: "PUT",
            body: JSON.stringify({ energy: 3, timeZone: "UTC" }),
        });
        expect(bodySignals.status).toBe(400);
        expect((await json<ErrorResponse>(bodySignals)).error.code).toBe(
            "FUTURE_DATE_NOT_ALLOWED",
        );
    });

    test("appointments may be booked in the future", async () => {
        const date = shiftDays(todayIn("UTC"), 45);
        const res = await post({
            type: "appointment",
            localDate: date,
            timeZone: "UTC",
            payload: { startAt: `${date}T09:30`, type: "Gynaecologist", questions: ["Is this normal?"] },
        });
        expect(res.status).toBe(201);
        const event = (await json<EventResponse>(res)).event;
        expect(event.payload.startAt).toBe(`${date}T09:30:00`);
        expect(event.payload.reminderMinutesBefore).toBe(1440); // PRD default: 1 day before
        expect(event.payload.questions).toEqual(["Is this normal?"]);
    });

    test("an appointment's startAt must fall on its own day", async () => {
        const date = shiftDays(todayIn("UTC"), 46);
        const res = await post({
            type: "appointment",
            localDate: date,
            timeZone: "UTC",
            payload: { startAt: `${shiftDays(date, 1)}T09:30` },
        });
        expect(res.status).toBe(400);
    });

    test("backdating stops exactly at twelve months", async () => {
        const today = todayIn("UTC");
        const edge = minusTwelveMonths(today);

        const allowed = await post(sport(edge, { timeZone: "UTC" }));
        expect(allowed.status).toBe(201);
        expect((await json<EventResponse>(allowed)).event.localDate).toBe(edge);

        const refused = await post(sport(shiftDays(edge, -1), { timeZone: "UTC" }));
        expect(refused.status).toBe(400);
        expect((await json<ErrorResponse>(refused)).error.code).toBe("BACKDATE_LIMIT_EXCEEDED");
    });

    test("loggedAt is noon when backdated and the current time when it is today", async () => {
        const backdated = shiftDays(todayIn("UTC"), -5);
        const past = (await json<EventResponse>(await post(sport(backdated, { timeZone: "UTC" }))))
            .event;
        expect(past.loggedAt).toBe(`${backdated}T12:00:00`);

        // Pick a zone whose local clock is nowhere near noon, so "now" and "12:00"
        // cannot be confused by coincidence.
        const zone = ["UTC", "Asia/Tokyo", "America/Los_Angeles"].find(
            (tz) => hourIn(tz) < 10 || hourIn(tz) > 14,
        )!;
        const today = todayIn(zone);
        const now = (await json<EventResponse>(await post(sport(today, { timeZone: zone })))).event;
        expect(now.loggedAt.startsWith(`${today}T`)).toBe(true);
        expect(now.loggedAt).not.toBe(`${today}T12:00:00`);
        expect(Number(now.loggedAt.slice(11, 13))).toBe(hourIn(zone));
    });

    test("an invalid time zone or calendar date is refused", async () => {
        expect((await post(sport(todayIn("UTC"), { timeZone: "Mars/Olympus" }))).status).toBe(400);
        expect((await post(sport("2026-02-30", { timeZone: "UTC" }))).status).toBe(400);
        expect((await post(sport("27-08-2026", { timeZone: "UTC" }))).status).toBe(400);
    });
});

describe("events: cycle", () => {
    /** The day's cycle entry as the range read returns it, or `undefined` when the day has
     *  none. That third state is the point of half of what follows: "nothing logged" is not
     *  the same fact as "logged, not marked as the end". */
    const cycleOn = async (date: string): Promise<EvaEventBody | undefined> =>
        (await range(date, date)).find((e) => e.type === "cycle");

    test("spotting and flow cannot both be set, and one of them must be", async () => {
        const date = shiftDays(todayIn("UTC"), -30);
        const both = await post({
            type: "cycle",
            localDate: date,
            timeZone: "UTC",
            payload: { spotting: true, flow: "heavy" },
        });
        expect(both.status).toBe(400);
        expect((await json<ErrorResponse>(both)).error.code).toBe("VALIDATION");

        const neither = await post({
            type: "cycle",
            localDate: date,
            timeZone: "UTC",
            payload: {},
        });
        expect(neither.status).toBe(400);

        const badFlow = await post({
            type: "cycle",
            localDate: date,
            timeZone: "UTC",
            payload: { flow: "spotting" },
        });
        expect(badFlow.status).toBe(400);
    });

    test("a second cycle entry replaces the day's first", async () => {
        const date = shiftDays(todayIn("UTC"), -31);
        const spotting = (
            await json<EventResponse>(
                await post({
                    type: "cycle",
                    localDate: date,
                    timeZone: "UTC",
                    payload: { spotting: true },
                }),
            )
        ).event;
        expect(spotting.payload).toEqual({ spotting: true });

        const flow = (
            await json<EventResponse>(
                await post({
                    type: "cycle",
                    localDate: date,
                    timeZone: "UTC",
                    payload: { flow: "medium" },
                }),
            )
        ).event;
        expect(flow.payload).toEqual({ flow: "medium" });

        const onThatDay = (await range(date, date)).filter((e) => e.type === "cycle");
        expect(onThatDay).toHaveLength(1);
        expect(onThatDay[0]!.payload).toEqual({ flow: "medium" });
    });

    // #75. The mark is a stored fact and nothing reads it, so the only thing these can
    // check is that it survives the trip — in both directions, and without leaking onto
    // days that never claimed it.
    test("the explicit period-end mark round-trips, and an unmarked flow day stays unmarked", async () => {
        const marked = shiftDays(todayIn("UTC"), -41);
        const unmarked = shiftDays(todayIn("UTC"), -42);
        const nulled = shiftDays(todayIn("UTC"), -43);
        const empty = shiftDays(todayIn("UTC"), -44);

        const created = await post({
            type: "cycle",
            localDate: marked,
            timeZone: "UTC",
            payload: { flow: "heavy", periodEnd: true },
        });
        expect(created.status).toBe(201);
        expect((await json<EventResponse>(created)).event.payload).toEqual({
            flow: "heavy",
            periodEnd: true,
        });

        const plainCreated = await post({
            type: "cycle",
            localDate: unmarked,
            timeZone: "UTC",
            payload: { flow: "heavy" },
        });
        expect((await json<EventResponse>(plainCreated)).event.payload).toEqual({ flow: "heavy" });

        // `null` is "not marked", exactly as absent is — never a stored null, which would
        // come back as a field that is present and says nothing.
        const nullCreated = await post({
            type: "cycle",
            localDate: nulled,
            timeZone: "UTC",
            payload: { flow: "medium", periodEnd: null },
        });
        expect((await json<EventResponse>(nullCreated)).event.payload).toEqual({ flow: "medium" });

        // The read is the half that is easy to lose: a field that writes but does not come
        // back is invisible until something downstream tries to use it.
        expect((await cycleOn(marked))!.payload).toEqual({ flow: "heavy", periodEnd: true });
        const plain = (await cycleOn(unmarked))!.payload;
        expect(plain).toEqual({ flow: "heavy" });
        expect(Object.hasOwn(plain, "periodEnd")).toBe(false);
        expect((await cycleOn(nulled))!.payload).toEqual({ flow: "medium" });
        expect(await cycleOn(empty)).toBeUndefined();
    });

    test("the end mark needs a flow level on its own entry, and refuses a spotting day", async () => {
        const date = shiftDays(todayIn("UTC"), -45);

        const onSpotting = await post({
            type: "cycle",
            localDate: date,
            timeZone: "UTC",
            payload: { spotting: true, periodEnd: true },
        });
        expect(onSpotting.status).toBe(400);
        const refusal = (await json<ErrorResponse>(onSpotting)).error;
        expect(refusal.code).toBe("VALIDATION");
        // Every refusal below is also a 400 VALIDATION, so the status says almost nothing
        // about *which* rule fired — and the two rules cover each other's bodies. Delete
        // the spotting rule and this body is still refused, by the no-flow rule, for a
        // different reason. Both names have to be in the message or that deletion is
        // invisible here.
        expect(refusal.message).toContain("periodEnd");
        expect(refusal.message).toContain("spotting");

        // Same again from the other side: the catch-all ("a cycle entry needs either
        // spotting or a flow level") refuses this one too, so a status assertion alone
        // would pass with the no-flow rule deleted. Only its message names the mark.
        const alone = await post({
            type: "cycle",
            localDate: date,
            timeZone: "UTC",
            payload: { periodEnd: true },
        });
        expect(alone.status).toBe(400);
        expect((await json<ErrorResponse>(alone)).error.message).toContain("periodEnd");

        // The mark is only ever `true`. A `false` is a client that thinks it can clear it
        // in place; it clears by sending the payload without it.
        for (const periodEnd of [false, "true", 1]) {
            const res = await post({
                type: "cycle",
                localDate: date,
                timeZone: "UTC",
                payload: { flow: "heavy", periodEnd },
            });
            expect(res.status).toBe(400);
            expect((await json<ErrorResponse>(res)).error.code).toBe("VALIDATION");
        }

        // None of the above took the day: a refused entry writes nothing.
        expect(await cycleOn(date)).toBeUndefined();
    });

    test("PATCH sets and clears the mark without moving the day", async () => {
        const date = shiftDays(todayIn("UTC"), -46);
        const event = (
            await json<EventResponse>(
                await post({
                    type: "cycle",
                    localDate: date,
                    timeZone: "UTC",
                    payload: { flow: "medium" },
                }),
            )
        ).event;

        const patch = (payload: Record<string, unknown>) =>
            api(`/me/events/${event.id}`, {
                method: "PATCH",
                body: JSON.stringify({ type: "cycle", localDate: date, timeZone: "UTC", payload }),
            });

        const set = await patch({ flow: "medium", periodEnd: true });
        expect(set.status).toBe(200);
        const edited = (await json<EventResponse>(set)).event;
        expect(edited.id).toBe(event.id);
        expect(edited.localDate).toBe(date);
        expect(edited.payload).toEqual({ flow: "medium", periodEnd: true });
        expect((await cycleOn(date))!.payload).toEqual({ flow: "medium", periodEnd: true });

        // Cleared by sending the day's payload without it: PATCH replaces `payload` whole,
        // so there is no separate clear to send.
        const cleared = await patch({ flow: "medium" });
        expect(cleared.status).toBe(200);
        expect((await json<EventResponse>(cleared)).event.payload).toEqual({ flow: "medium" });
        const stored = (await cycleOn(date))!.payload;
        expect(stored).toEqual({ flow: "medium" });
        expect(Object.hasOwn(stored, "periodEnd")).toBe(false);

        // The same rule holds on the edit path, not only on create.
        expect((await patch({ spotting: true, periodEnd: true })).status).toBe(400);

        // Still one entry, the same document, the same date: one-per-day is untouched.
        const onThatDay = (await range(date, date)).filter((e) => e.type === "cycle");
        expect(onThatDay.map((e) => e.id)).toEqual([event.id]);
        expect(onThatDay[0]!.localDate).toBe(date);
        expect(onThatDay[0]!.payload).toEqual({ flow: "medium" });
    });

    // #188. Spotting is a mark that is present or absent, so `spotting: false` is a client
    // saying something the model cannot store; "not spotting" is said by omitting the key or
    // by sending a flow level. Coercing the value would store a spotting day she never
    // logged, and since #181 a spotting day changes how her cycles are grouped. A refusal
    // costs the client a retry, which is the cheaper failure, so the value is refused. The
    // parser has always done that, but until these tests nothing checked it.
    //
    // Every refusal here is a 400 VALIDATION, and the catch-all ("A cycle entry needs either
    // spotting or a flow level") refuses a bare `{ spotting: false }` too. Its message
    // *also* names spotting, so #183's check that the message names the field would pass
    // with this rule deleted. Only this rule's message says the value must be true.
    const refusedAsNotTrue = async (res: Response): Promise<void> => {
        expect(res.status).toBe(400);
        const { code, message } = (await json<ErrorResponse>(res)).error;
        expect(code).toBe("VALIDATION");
        expect(message).toContain("spotting must be true");
    };

    test("spotting is only ever true: false and every other value are refused, and store nothing", async () => {
        const date = shiftDays(todayIn("UTC"), -47);
        const log = (payload: Record<string, unknown>) =>
            post({ type: "cycle", localDate: date, timeZone: "UTC", payload });

        // `"true"` is here for truthiness: a check that tests whether the value is truthy
        // rather than whether it is `true` stores the string as a spotting day.
        for (const spotting of [false, 0, "true"]) {
            await refusedAsNotTrue(await log({ spotting }));
        }

        // `null` means absent here, as it does for `flow` and `periodEnd` in the same payload.
        // So this body is empty and the catch-all refuses it. That rule's message is not
        // this one's, which is why only the status is checked.
        const nulled = await log({ spotting: null });
        expect(nulled.status).toBe(400);
        expect((await json<ErrorResponse>(nulled)).error.code).toBe("VALIDATION");

        // Beside a flow level, `false` is refused too. The "not both" rule gets there first,
        // and either rule refusing is enough. What matters is that the body is never read as
        // "not spotting, heavy flow", which would be a guess at what the client meant.
        const withFlow = await log({ spotting: false, flow: "heavy" });
        expect(withFlow.status).toBe(400);
        expect((await json<ErrorResponse>(withFlow)).error.code).toBe("VALIDATION");

        // Nothing above was stored, so the day still has no entry.
        expect(await cycleOn(date)).toBeUndefined();
    });

    test("a spotting day round-trips unchanged, and a null spotting beside a flow level is not a mark", async () => {
        const spottingDay = shiftDays(todayIn("UTC"), -48);
        const flowDay = shiftDays(todayIn("UTC"), -49);
        const nulledDay = shiftDays(todayIn("UTC"), -50);
        const log = (localDate: string, payload: Record<string, unknown>) =>
            post({ type: "cycle", localDate, timeZone: "UTC", payload });

        const spotting = await log(spottingDay, { spotting: true });
        expect(spotting.status).toBe(201);
        expect((await json<EventResponse>(spotting)).event.payload).toEqual({ spotting: true });

        const flow = await log(flowDay, { flow: "light" });
        expect(flow.status).toBe(201);
        expect((await json<EventResponse>(flow)).event.payload).toEqual({ flow: "light" });

        // Accepted as the flow day it is. The null is dropped rather than stored, so it
        // cannot come back later as a spotting key that is present but empty.
        const nulled = await log(nulledDay, { spotting: null, flow: "light" });
        expect(nulled.status).toBe(201);
        expect((await json<EventResponse>(nulled)).event.payload).toEqual({ flow: "light" });

        // Check the range read as well as the write response.
        expect((await cycleOn(spottingDay))!.payload).toEqual({ spotting: true });
        for (const day of [flowDay, nulledDay]) {
            const stored = (await cycleOn(day))!.payload;
            expect(stored).toEqual({ flow: "light" });
            expect(Object.hasOwn(stored, "spotting")).toBe(false);
        }
    });

    test("PATCH refuses a spotting value that is not true, and leaves the day as it was", async () => {
        const date = shiftDays(todayIn("UTC"), -51);
        const event = (
            await json<EventResponse>(
                await post({
                    type: "cycle",
                    localDate: date,
                    timeZone: "UTC",
                    payload: { flow: "light" },
                }),
            )
        ).event;

        const patch = (payload: Record<string, unknown>) =>
            api(`/me/events/${event.id}`, {
                method: "PATCH",
                body: JSON.stringify({ type: "cycle", localDate: date, timeZone: "UTC", payload }),
            });

        // PATCH replaces `payload` whole, so an accepted `false` would turn a flow day into a
        // spotting day in one request.
        for (const spotting of [false, 0, "true"]) {
            await refusedAsNotTrue(await patch({ spotting }));
        }
        expect((await patch({ spotting: null })).status).toBe(400);
        expect((await cycleOn(date))!.payload).toEqual({ flow: "light" });

        // The control: this entry does take an edit, so the refusals above came from the
        // value and not from the edit itself.
        const edited = await patch({ spotting: true });
        expect(edited.status).toBe(200);
        expect((await json<EventResponse>(edited)).event.id).toBe(event.id);
        expect((await cycleOn(date))!.payload).toEqual({ spotting: true });
    });
});

describe("events: body signals", () => {
    test("the day's entry is upserted, never accumulated", async () => {
        const date = shiftDays(todayIn("UTC"), -32);
        const first = await api(`/me/body-signals/${date}`, {
            method: "PUT",
            body: JSON.stringify({
                energy: 2,
                mood: 4,
                symptoms: [{ code: "cramps", severity: "severe" }],
                timeZone: "UTC",
            }),
        });
        expect(first.status).toBe(200);
        const firstEvent = (await json<EventResponse>(first)).event;
        expect(firstEvent.payload).toEqual({
            energy: 2,
            mood: 4,
            symptoms: [{ code: "cramps", severity: "severe" }],
        });
        expect(firstEvent.payload.sleep).toBeUndefined(); // nothing preselected

        const second = await api(`/me/body-signals/${date}`, {
            method: "PUT",
            body: JSON.stringify({ sleep: 5, timeZone: "UTC" }),
        });
        const secondEvent = (await json<EventResponse>(second)).event;
        expect(secondEvent.id).toBe(firstEvent.id);
        expect(secondEvent.payload).toEqual({ sleep: 5, symptoms: [] }); // replaced, not merged

        // POST to the generic route lands on the same day document too.
        await post({
            type: "bodySignals",
            localDate: date,
            timeZone: "UTC",
            payload: { energy: 1, symptoms: [] },
        });

        const onThatDay = (await range(date, date)).filter((e) => e.type === "bodySignals");
        expect(onThatDay).toHaveLength(1);
        expect(onThatDay[0]!.payload).toEqual({ energy: 1, symptoms: [] });
    });

    test("ratings are 1–5 whole numbers and symptoms are shaped", async () => {
        const date = shiftDays(todayIn("UTC"), -33);
        const put = (body: Record<string, unknown>) =>
            api(`/me/body-signals/${date}`, {
                method: "PUT",
                body: JSON.stringify({ timeZone: "UTC", ...body }),
            });
        expect((await put({ energy: 0 })).status).toBe(400);
        expect((await put({ energy: 6 })).status).toBe(400);
        expect((await put({ mood: 2.5 })).status).toBe(400);
        expect((await put({ symptoms: [{ code: "" }] })).status).toBe(400);
        expect((await put({ symptoms: [{ code: "cramps", severity: "awful" }] })).status).toBe(400);
        expect(
            (await put({ symptoms: [{ code: "cramps" }, { code: "cramps" }] })).status,
        ).toBe(400);
        // severity defaults to normal
        const ok = await put({ symptoms: [{ code: "bloating" }] });
        expect(ok.status).toBe(200);
        expect((await json<EventResponse>(ok)).event.payload.symptoms).toEqual([
            { code: "bloating", severity: "normal" },
        ]);
    });
});

describe("events: notes, idempotency, edit and delete", () => {
    test("a note over 280 characters is refused, 280 is fine", async () => {
        const date = shiftDays(todayIn("UTC"), -34);
        const tooLong = await post(sport(date, { note: "x".repeat(281), timeZone: "UTC" }));
        expect(tooLong.status).toBe(400);
        expect((await json<ErrorResponse>(tooLong)).error.code).toBe("VALIDATION");

        const exact = await post(sport(date, { note: "x".repeat(280), timeZone: "UTC" }));
        expect(exact.status).toBe(201);

        // Appointment notes are where results get written down, so they are not capped.
        const apptDate = shiftDays(todayIn("UTC"), 3);
        const appointment = await post({
            type: "appointment",
            localDate: apptDate,
            timeZone: "UTC",
            note: "y".repeat(1000),
            payload: { startAt: `${apptDate}T10:00` },
        });
        expect(appointment.status).toBe(201);
        expect((await json<EventResponse>(appointment)).event.note!.length).toBe(1000);
    });

    test("a repeated idempotency key does not create a second event", async () => {
        const date = shiftDays(todayIn("UTC"), -35);
        const key = crypto.randomUUID();
        const first = (
            await json<EventResponse>(await post(sport(date, { idempotencyKey: key, timeZone: "UTC" })))
        ).event;
        const again = (
            await json<EventResponse>(await post(sport(date, { idempotencyKey: key, timeZone: "UTC" })))
        ).event;
        expect(again.id).toBe(first.id);
        expect((await range(date, date)).filter((e) => e.type === "sport")).toHaveLength(1);
    });

    test("PATCH edits note, loggedAt and payload", async () => {
        const date = shiftDays(todayIn("UTC"), -36);
        const event = (await json<EventResponse>(await post(sport(date, { timeZone: "UTC" })))).event;
        const res = await api(`/me/events/${event.id}`, {
            method: "PATCH",
            body: JSON.stringify({
                type: "sport",
                localDate: date,
                timeZone: "UTC",
                note: "Edited",
                loggedAt: `${date}T07:15`,
                payload: { activity: "Running", durationMin: 45, intensity: "hard" },
            }),
        });
        expect(res.status).toBe(200);
        const updated = (await json<EventResponse>(res)).event;
        expect(updated.note).toBe("Edited");
        expect(updated.loggedAt).toBe(`${date}T07:15:00`);
        expect(updated.payload).toEqual({ activity: "Running", durationMin: 45, intensity: "hard" });
    });

    test("PATCH refuses an unknown id, a mismatched type and a moved one-per-day entry", async () => {
        const date = shiftDays(todayIn("UTC"), -37);
        const missing = await api("/me/events/does-not-exist", {
            method: "PATCH",
            body: JSON.stringify({ type: "sport", localDate: date, timeZone: "UTC", note: "hi" }),
        });
        expect(missing.status).toBe(404);
        expect((await json<ErrorResponse>(missing)).error.code).toBe("NOT_FOUND");

        const event = (await json<EventResponse>(await post(sport(date, { timeZone: "UTC" })))).event;
        const wrongType = await api(`/me/events/${event.id}`, {
            method: "PATCH",
            body: JSON.stringify({ type: "cycle", localDate: date, timeZone: "UTC", note: "hi" }),
        });
        expect(wrongType.status).toBe(400);

        const cycle = (
            await json<EventResponse>(
                await post({
                    type: "cycle",
                    localDate: date,
                    timeZone: "UTC",
                    payload: { flow: "light" },
                }),
            )
        ).event;
        const moved = await api(`/me/events/${cycle.id}`, {
            method: "PATCH",
            body: JSON.stringify({
                type: "cycle",
                localDate: shiftDays(date, -1),
                timeZone: "UTC",
                payload: { flow: "light" },
            }),
        });
        expect(moved.status).toBe(400);
    });

    test("delete is soft: gone from range reads, still on disk", async () => {
        const date = shiftDays(todayIn("UTC"), -38);
        const event = (await json<EventResponse>(await post(sport(date, { timeZone: "UTC" })))).event;
        expect((await range(date, date)).map((e) => e.id)).toContain(event.id);

        const deleted = await api(`/me/events/${event.id}`, { method: "DELETE" });
        expect(deleted.status).toBe(200);
        expect((await range(date, date)).map((e) => e.id)).not.toContain(event.id);

        // Recoverable: the document is still there with a deletedAt stamp.
        const stored = await eventsCollection().doc(event.id).get();
        expect(stored.exists).toBe(true);
        expect(stored.get("deletedAt")).not.toBe(null);
        expect(stored.get("payload").activity).toBe("Yoga");

        // Deleting again is idempotent; editing a deleted entry does not resurrect it.
        expect((await api(`/me/events/${event.id}`, { method: "DELETE" })).status).toBe(200);
        const patched = await api(`/me/events/${event.id}`, {
            method: "PATCH",
            body: JSON.stringify({ type: "sport", localDate: date, timeZone: "UTC", note: "back?" }),
        });
        expect(patched.status).toBe(404);

        expect((await api("/me/events/does-not-exist", { method: "DELETE" })).status).toBe(404);
    });

    test("re-logging a deleted one-per-day entry brings the day back", async () => {
        const date = shiftDays(todayIn("UTC"), -39);
        const first = (
            await json<EventResponse>(
                await post({
                    type: "cycle",
                    localDate: date,
                    timeZone: "UTC",
                    payload: { flow: "heavy" },
                }),
            )
        ).event;
        await api(`/me/events/${first.id}`, { method: "DELETE" });
        expect((await range(date, date)).filter((e) => e.type === "cycle")).toHaveLength(0);

        const again = await post({
            type: "cycle",
            localDate: date,
            timeZone: "UTC",
            payload: { spotting: true },
        });
        expect(again.status).toBe(201);
        const back = (await range(date, date)).filter((e) => e.type === "cycle");
        expect(back).toHaveLength(1);
        expect(back[0]!.payload).toEqual({ spotting: true });
    });
});

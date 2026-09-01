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
        const port = 3100 + Math.floor(Math.random() * 200);
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

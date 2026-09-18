import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { analyzeCycles, type CycleDay, type CycleRules } from "../src/cycle";
import { adminAuth, firestore } from "../src/firebase";
import { signUpActivated } from "./support/session";

/**
 * `GET /me/cycle/predictions` — the calendar's overlay (#205, slice C12a of #11).
 *
 * **Every gate is asserted here, at the route, and not only in `cycle.test.ts`.** That file
 * hands `analyzeCycles` a fixture directly and is where the maths is pinned; this one asks
 * whether the answer survives the trip out — the event read, the `CycleDay` mapping, the
 * projection into the wire shape, and the HTTP mapping. A gate that closes in the module and
 * opens on the way to the client is the one failure #205 exists to prevent, and it passes
 * every unit test of `cycle.ts`.
 *
 * So the load-bearing cases are end to end, against entries created through
 * `POST /me/events`, and the strongest of them compare the route's answer against
 * `analyzeCycles` run in this process over the same days: if the route ever grew arithmetic
 * of its own, the two would disagree.
 *
 * **This file boots its own API**, with the `CYCLE_*` group set explicitly. `config.ts` reads
 * the environment once at import, so a server started by `verify-api.sh` runs whatever
 * `api/.env` happens to carry — and the fixture dates below are placed against specific
 * constants (a fourteen-day luteal phase, a window opening five days before ovulation, the
 * tighter band at six counted cycles). Booting with them named is what makes a green run
 * evidence about those numbers rather than about the developer's `.env`.
 *
 * Nothing here needs a seeded `content/` or the pattern rung, so every case runs under both
 * `scripts/verify-api.sh` and `scripts/ci-api.sh`.
 */

/** A spawned API and live Firestore round trips on most cases (#31). */
setDefaultTimeout(20_000);

const PASSWORD = "correct-horse-8";
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;

/**
 * The constants the fixtures below are built for: A25–A27's values and #186's period gap,
 * which is what `api/.env.example` carries and what production is meant to run.
 *
 * Every fixture date is placed against these — `nextPeriodStart` at the median past the last
 * first flow day, ovulation fourteen days before it, the window five days before that through
 * one day after, peak from two days before ovulation — so a run configured differently would
 * assert the wrong dates while looking green. `CYCLE_ENV` below is derived from this object
 * rather than written twice, so the server this file boots cannot be running other numbers.
 */
const CYCLE_RULES: CycleRules = {
    minCycleLengthDays: 21,
    maxCycleLengthDays: 45,
    minPeriodGapDays: 2,
    historyCycles: 6,
    minCyclesForEstimate: 3,
    narrowBandMinCycles: 6,
    lutealPhaseDays: 14,
    fertileDaysBeforeOvulation: 5,
    fertileDaysAfterOvulation: 1,
    peakDaysBeforeOvulation: 2,
    irregularity: {
        youngMaxAge: 25,
        midMaxAge: 41,
        youngVariationDays: 9,
        midVariationDays: 7,
        olderVariationDays: 9,
    },
};

/** `CYCLE_RULES` as `config.ts` reads it. Derived, so the two cannot disagree. */
const CYCLE_ENV: Record<string, string> = {
    CYCLE_MIN_LENGTH_DAYS: String(CYCLE_RULES.minCycleLengthDays),
    CYCLE_MAX_LENGTH_DAYS: String(CYCLE_RULES.maxCycleLengthDays),
    CYCLE_MIN_PERIOD_GAP_DAYS: String(CYCLE_RULES.minPeriodGapDays),
    CYCLE_HISTORY_CYCLES: String(CYCLE_RULES.historyCycles),
    CYCLE_MIN_CYCLES_FOR_ESTIMATE: String(CYCLE_RULES.minCyclesForEstimate),
    CYCLE_NARROW_BAND_MIN_CYCLES: String(CYCLE_RULES.narrowBandMinCycles),
    CYCLE_LUTEAL_PHASE_DAYS: String(CYCLE_RULES.lutealPhaseDays),
    CYCLE_FERTILE_DAYS_BEFORE_OVULATION: String(CYCLE_RULES.fertileDaysBeforeOvulation),
    CYCLE_FERTILE_DAYS_AFTER_OVULATION: String(CYCLE_RULES.fertileDaysAfterOvulation),
    CYCLE_PEAK_DAYS_BEFORE_OVULATION: String(CYCLE_RULES.peakDaysBeforeOvulation),
    CYCLE_IRREGULAR_YOUNG_MAX_AGE: String(CYCLE_RULES.irregularity.youngMaxAge),
    CYCLE_IRREGULAR_MID_MAX_AGE: String(CYCLE_RULES.irregularity.midMaxAge),
    CYCLE_IRREGULAR_YOUNG_VARIATION_DAYS: String(CYCLE_RULES.irregularity.youngVariationDays),
    CYCLE_IRREGULAR_MID_VARIATION_DAYS: String(CYCLE_RULES.irregularity.midVariationDays),
    CYCLE_IRREGULAR_OLDER_VARIATION_DAYS: String(CYCLE_RULES.irregularity.olderVariationDays),
};

/**
 * The same fifteen, unset — empty rather than absent, because `config.ts` reads them with
 * `optionalString` and an empty value cannot be filled back in by an `api/.env` the way a
 * deleted key can. All fifteen, because a *partial* group is a boot failure rather than an
 * unconfigured capability: leaving one set would spawn a server that never answers instead of
 * one that refuses, and the 503 case would then be about the boot timing out.
 *
 * This is the configuration every deployment runs today (#176, #191).
 */
const NO_CYCLE_ENV = Object.fromEntries(Object.keys(CYCLE_ENV).map((name) => [name, ""]));

let token = "";
let uid = "";
let base = "";
let child: ReturnType<typeof Bun.spawn> | null = null;

const apiAt = (at: string, path: string, init?: RequestInit & { token?: string | null }) =>
    fetch(`${at}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
            ...(init?.headers ?? {}),
        },
    });

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
    apiAt(base, path, init);

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

interface PredictionsBody {
    from: string;
    to: string;
    predictedPeriod: string[];
    fertileWindow: string[];
    peak: string[];
    confidence: "wide" | "narrow" | null;
    /** Written out rather than imported from `cycle.ts`: this is the wire contract the iOS
     *  client switches on, so a reason renamed in the maths should fail here — which it does,
     *  at the comparisons against `analyzeCycles` below — rather than be carried through. */
    withheld: "no-flow-logged" | "too-few-counted-cycles" | "irregular-cycles" | null;
}
interface ErrorBody {
    error: { code: string; message: string };
}

/** Ports this file has already spawned on. Its `beforeAll` server stays up for the whole
 *  run, so "already used" and "already free again" are different things here. */
const claimedPorts = new Set<number>();

/**
 * A port in 3600–3799 that nothing answers on and this file has not already taken.
 *
 * The health check cannot tell one Eva API from another — it asks `/` for the string
 * `Eva API`, which every server started here answers — so drawing a port an earlier one still
 * holds means the new process exits with `EADDRINUSE` while the first poll succeeds against
 * the *old* server, and the case then runs against a process it did not configure. That is
 * #193/#199, and it shows as a case finishing in tens of milliseconds where a real boot takes
 * most of a second.
 *
 * Asking rather than bookkeeping alone, because the collision is not only with this file: a
 * `verify-api.sh` server or another suite can be anywhere. The band is `today.test.ts`'s
 * 3400–3599 plus 200, so the two files cannot draw against each other at all.
 */
const freePort = async (): Promise<number> => {
    for (let attempt = 0; attempt < 100; attempt++) {
        const port = 3600 + Math.floor(Math.random() * 200);
        if (claimedPorts.has(port)) continue;
        const answered = await fetch(`http://localhost:${port}/`)
            .then(() => true)
            .catch(() => false);
        if (answered) continue;
        claimedPorts.add(port);
        return port;
    }
    throw new Error("no free port in 3600-3799 for the API this case needs");
};

/**
 * Spawns an API with `over` layered on this process's environment, and waits for it to
 * answer. `config.ts` reads the environment once at import, so a case that needs a different
 * configuration needs a different *process* — there is no seam short of that. Every server
 * started here shares the same Firestore, secret and account, so one session token works
 * against all of them.
 */
const bootApi = async (over: Record<string, string>) => {
    const port = await freePort();
    const spawned = Bun.spawn(["bun", "run", "src/index.ts"], {
        cwd: new URL("..", import.meta.url).pathname,
        env: { ...process.env, PORT: String(port), ...over },
        stdout: "pipe",
        stderr: "pipe",
    });
    const url = `http://localhost:${port}`;
    let up = false;
    for (let i = 0; i < 60 && !up; i++) {
        // A child that has already exited could not bind. Polling on would mean waiting for
        // — or worse, adopting — whatever else answers here, so stop and fail below.
        if (spawned.exitCode !== null) break;
        up = await fetch(`${url}/`)
            .then((r) => r.text())
            .then((t) => t === "Eva API")
            .catch(() => false);
        if (!up) await Bun.sleep(250);
    }
    expect(up).toBe(true);
    return { base: url, child: spawned };
};

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

/** `YYYY-MM-DD` shifted by whole days in UTC — a calendar label, never an instant. */
const shiftDays = (day: string, by: number): string =>
    new Date(Date.parse(`${day}T00:00:00.000Z`) + by * 86_400_000).toISOString().slice(0, 10);

/** `today - days`, in UTC, which is the zone every case here calls in. */
const back = (days: number) => shiftDays(todayIn("UTC"), -days);

/** `today + days`, likewise. */
const ahead = (days: number) => shiftDays(todayIn("UTC"), days);

const eventDocs = () => firestore.collection("users").doc(uid).collection("events");

/** Hard-removes every entry, soft-deleted ones included: a soft delete is still a row the
 *  range read would have to filter, and every case here asserts an exact set of dates. */
const clearEvents = async () => {
    const snapshot = await eventDocs().get().catch(() => null);
    for (const doc of snapshot?.docs ?? []) await doc.ref.delete().catch(() => {});
};

const post = (body: unknown) => api("/me/events", { method: "POST", body: JSON.stringify(body) });

/** One flow day. Returns its id, which is what the delete case needs. */
const flowOn = async (localDate: string): Promise<string> => {
    const res = await post({
        type: "cycle",
        localDate,
        payload: { flow: "medium" },
        timeZone: "UTC",
    });
    expect(res.status).toBe(201);
    return (await json<{ event: { id: string } }>(res)).event.id;
};

/**
 * Periods as she would log them: two consecutive flow days from each start.
 *
 * Two days rather than one because that is what a logged period looks like, and because it
 * exercises the grouping — the second day must not open a cycle of its own. Returns the id of
 * the *last* period's first flow day, which is the anchor every prediction hangs off.
 */
const periodsStartingOn = async (starts: readonly string[]): Promise<string> => {
    let anchor = "";
    for (const start of starts) {
        anchor = await flowOn(start);
        await flowOn(shiftDays(start, 1));
    }
    return anchor;
};

/** The same days as `cycle.ts` reads them, for the cases that check the route against the
 *  maths run in this process. Two flow days per start, exactly as the fixtures log. */
const daysFor = (starts: readonly string[]): CycleDay[] =>
    starts.flatMap((start) => [
        { localDate: start, kind: "flow" } as const,
        { localDate: shiftDays(start, 1), kind: "flow" } as const,
    ]);

const predictions = async (from: string, to: string): Promise<PredictionsBody> => {
    const res = await api(`/me/cycle/predictions?from=${from}&to=${to}&timeZone=UTC`);
    expect(res.status).toBe(200);
    return json<PredictionsBody>(res);
};

/** A range wide enough to hold anything the fixtures predict: the maths never looks further
 *  ahead than one cycle, and `maxCycleLengthDays` bounds that. */
const WHOLE = () => ({ from: back(1), to: ahead(CYCLE_RULES.maxCycleLengthDays) });

// ── Seven regular periods, 28 days apart, the last opening six days ago ─────────────────
// Six counted 28-day cycles: over A26's ≥3 gate, at A27's ≥6 for the tighter band, and a
// variation of zero, so which FIGO band `bandForAge` picks cannot change the answer.
const REGULAR_STARTS = [174, 146, 118, 90, 62, 34, 6].map(back);

/** The same woman with three periods fewer: three counted cycles — over the gate, under the
 *  tighter band, so the prediction is real and its confidence is `wide`. */
const WIDE_STARTS = [90, 62, 34, 6].map(back);

/** Two counted cycles: under A26's gate, so nothing is predicted at all. */
const TOO_FEW_STARTS = [62, 34, 6].map(back);

/**
 * #181's fail-closed gate, as a calendar: intervals alternating 28 and 60 days.
 *
 * Three counted cycles — all of them 28, so the ≥3 gate *passes* and the median is a clean
 * 28 — while the variation over every interval between them is 32 days, far outside the
 * widest FIGO band. A25 item 2 read literally would hand this woman a fertile window over a
 * variation of zero. She must be handed nothing.
 */
const ALTERNATING_STARTS = [270, 242, 182, 154, 94, 66, 6].map(back);

beforeAll(async () => {
    const spawned = await bootApi(CYCLE_ENV);
    base = spawned.base;
    child = spawned.child;

    const account = await signUpActivated(base, email, PASSWORD);
    token = account.token;
    uid = account.uid;
});

afterAll(async () => {
    await clearEvents();
    if (uid) await firestore.collection("users").doc(uid).delete().catch(() => {});
    if (uid) await adminAuth.deleteUser(uid).catch(() => {});
    child?.kill();
});

describe("GET /me/cycle/predictions: the range", () => {
    test("needs a session", async () => {
        const day = todayIn("UTC");
        const res = await api(`/me/cycle/predictions?from=${day}&to=${day}`, { token: null });
        expect(res.status).toBe(401);
    });

    /**
     * The same four bad ranges `events.test.ts` puts to `GET /me/events`, and the same
     * answers — missing, not a calendar date, inverted, and over the 400-day cap.
     */
    test("is validated and capped exactly as GET /me/events is", async () => {
        expect((await api("/me/cycle/predictions")).status).toBe(400);
        expect(
            (await api("/me/cycle/predictions?from=2026-13-01&to=2026-01-02")).status,
        ).toBe(400);
        expect(
            (await api("/me/cycle/predictions?from=2026-02-02&to=2026-02-01")).status,
        ).toBe(400);
        expect(
            (await api("/me/cycle/predictions?from=2020-01-01&to=2026-01-01")).status,
        ).toBe(400);
    });

    /**
     * **No new error code** — adding or renaming one is always-human under AUTONOMY, and the
     * client contract grows by addition only (GUARDRAILS 11). Asserted by putting the same
     * bad range to both routes and requiring the same body, which is stronger than asserting
     * the string here: it fails if either route's wording drifts from the other's.
     */
    test("a bad range answers what /me/events answers, code and message", async () => {
        for (const query of [
            "from=2026-13-01&to=2026-01-02",
            "from=2026-02-02&to=2026-02-01",
            "from=2020-01-01&to=2026-01-01",
        ]) {
            const [events, cycle] = await Promise.all([
                api(`/me/events?${query}`),
                api(`/me/cycle/predictions?${query}`),
            ]);
            expect(cycle.status).toBe(events.status);
            expect(await json<ErrorBody>(cycle)).toEqual(await json<ErrorBody>(events));
        }
    });

    test("an unknown time zone is a 400, not a prediction anchored on UTC", async () => {
        const day = todayIn("UTC");
        const res = await api(
            `/me/cycle/predictions?from=${day}&to=${day}&timeZone=Mars/Olympus`,
        );
        expect(res.status).toBe(400);
        expect((await json<ErrorBody>(res)).error.code).toBe("VALIDATION");
    });

    test("the 400-day cap is inclusive of its own edge", async () => {
        const from = back(200);
        expect((await api(`/me/cycle/predictions?from=${from}&to=${shiftDays(from, 400)}`)).status)
            .toBe(200);
        expect((await api(`/me/cycle/predictions?from=${from}&to=${shiftDays(from, 401)}`)).status)
            .toBe(400);
    });
});

describe("GET /me/cycle/predictions: what the calendar draws", () => {
    /**
     * The whole overlay, against the maths run in this process over the same days.
     *
     * Not a list of dates written down here: `analyzeCycles` is asked for the answer and the
     * route is required to agree with it. A second implementation of any part of the
     * arithmetic — a period length invented for the predicted days, an ovulation offset
     * applied twice — shows up as a disagreement rather than as a fixture somebody updated.
     */
    test("six regular cycles produce the predicted day, the window, the peak and a band", async () => {
        await clearEvents();
        await periodsStartingOn(REGULAR_STARTS);

        const body = await predictions(WHOLE().from, WHOLE().to);
        const analysis = analyzeCycles(
            { days: daysFor(REGULAR_STARTS), today: todayIn("UTC"), profile: null },
            CYCLE_RULES,
        );
        const prediction = analysis.prediction!;
        expect(prediction).not.toBeNull();

        expect(body.withheld).toBeNull();
        expect(body.confidence).toBe(prediction.confidence);
        expect(body.predictedPeriod).toEqual([prediction.nextPeriodStart]);
        expect(body.fertileWindow[0]).toBe(prediction.fertileWindow.from);
        expect(body.fertileWindow.at(-1)).toBe(prediction.fertileWindow.to);
        expect(body.peak[0]).toBe(prediction.fertileWindow.peakFrom);
        expect(body.peak.at(-1)).toBe(prediction.fertileWindow.peakTo);

        // A26's shape, stated independently of the maths so the agreement above cannot be
        // two copies of the same mistake: the window spans the five days before ovulation
        // through the one after it, and peak is the two before ovulation through the day.
        expect(body.fertileWindow).toHaveLength(
            CYCLE_RULES.fertileDaysBeforeOvulation + CYCLE_RULES.fertileDaysAfterOvulation + 1,
        );
        expect(body.peak).toHaveLength(CYCLE_RULES.peakDaysBeforeOvulation + 1);
        for (const day of body.peak) expect(body.fertileWindow).toContain(day);
    });

    /**
     * A27, which is the distinction the client draws its band from: six counted cycles is
     * `narrow`, three is `wide`. The same woman, three periods fewer — so nothing but the
     * count changes, and the predicted date is identical.
     */
    test("the confidence class is C11's own: narrow at six counted cycles, wide at three", async () => {
        await clearEvents();
        await periodsStartingOn(REGULAR_STARTS);
        const narrow = await predictions(WHOLE().from, WHOLE().to);
        expect(narrow.confidence).toBe("narrow");

        await clearEvents();
        await periodsStartingOn(WIDE_STARTS);
        const wide = await predictions(WHOLE().from, WHOLE().to);
        expect(wide.confidence).toBe("wide");

        // Same anchor, same median: the band moved and the dates did not, which is what makes
        // the band a statement about certainty rather than about the prediction.
        expect(wide.predictedPeriod).toEqual(narrow.predictedPeriod);
        expect(wide.fertileWindow).toEqual(narrow.fertileWindow);
        expect(wide.withheld).toBeNull();
    });

    /**
     * Answering by range means the range decides what comes back — the point of C12a's shape,
     * since `CalendarModel` caches by month and a month grid spans up to three of them.
     *
     * **And an empty overlay is not a withheld one.** The prediction exists; this range is
     * simply last month. `withheld` stays `null` and the confidence stays `narrow`, so a
     * client can tell "nothing here" from "nothing at all" without guessing from emptiness.
     */
    test("a range the prediction falls outside of draws nothing, and says nothing was withheld", async () => {
        await clearEvents();
        await periodsStartingOn(REGULAR_STARTS);

        const body = await predictions(back(60), back(30));
        expect(body.from).toBe(back(60));
        expect(body.to).toBe(back(30));
        expect(body.predictedPeriod).toEqual([]);
        expect(body.fertileWindow).toEqual([]);
        expect(body.peak).toEqual([]);
        expect(body.withheld).toBeNull();
        expect(body.confidence).toBe("narrow");
    });

    /** Nothing outside the range asked for, in any list — a month grid draws what it is
     *  given, and a date outside it is a cell that does not exist. */
    test("no date outside the range is ever returned", async () => {
        await clearEvents();
        await periodsStartingOn(REGULAR_STARTS);

        const whole = await predictions(WHOLE().from, WHOLE().to);
        const half = await predictions(WHOLE().from, ahead(7));
        for (const body of [whole, half]) {
            for (const day of [...body.predictedPeriod, ...body.fertileWindow, ...body.peak]) {
                expect(day >= body.from).toBe(true);
                expect(day <= body.to).toBe(true);
            }
        }
        // The narrower range is a subset of the wider one rather than a different answer.
        expect(half.fertileWindow).toEqual(
            whole.fertileWindow.filter((day) => day <= half.to),
        );
    });

    /**
     * PRD §Predictions 5 and #205's sixth criterion: derived on read, never a batch job.
     *
     * Deleting the flow day the current cycle is anchored on moves the anchor forward one day,
     * so the very next read predicts a day later. Nothing is cached under this route, so the
     * only thing that could fail here is the route storing an answer — which is why the case
     * asserts the new date rather than merely that something changed.
     */
    test("editing a flow entry moves the prediction on the next read", async () => {
        await clearEvents();
        const anchor = await periodsStartingOn(REGULAR_STARTS);

        const before = await predictions(WHOLE().from, WHOLE().to);
        expect(before.predictedPeriod).toHaveLength(1);

        expect((await api(`/me/events/${anchor}`, { method: "DELETE" })).status).toBe(200);

        const after = await predictions(WHOLE().from, WHOLE().to);
        const analysis = analyzeCycles(
            {
                days: daysFor(REGULAR_STARTS).filter(
                    (day) => day.localDate !== REGULAR_STARTS.at(-1),
                ),
                today: todayIn("UTC"),
                profile: null,
            },
            CYCLE_RULES,
        );
        expect(after.predictedPeriod).toEqual([analysis.prediction!.nextPeriodStart]);
        expect(after.predictedPeriod).not.toEqual(before.predictedPeriod);
    });

    /**
     * #80's hard constraint, asserted where it could actually break: a positive test is not
     * a flow day, and nothing about it reaches `cycle.ts`.
     *
     * It is structurally invisible today — `toCycleDay` in `today.ts` answers `null` for
     * every event whose type is not `cycle`, so a separate event type never enters the
     * mapping. But "structurally" is a claim about one line somebody can widen in a
     * keystroke, and every value-level test in the repo passes when they do.
     *
     * The day is chosen to do damage if it counted. `back(160)` sits in the middle of the
     * gap between the periods opening at `back(174)` and `back(146)`, so a flow day there
     * splits one 28-day interval into two 14-day ones — under `minCycleLengthDays`, and a
     * variation far outside the widest FIGO band. The **control** at the end is what makes
     * that claim mean anything: the same date, logged as flow, moves the answer. Without it
     * the assertion above would pass just as well against a route that answered from a
     * cache, or against a fixture whose overlay nothing could disturb.
     */
    test("a positive test is not a flow day: the overlay is identical with and without one", async () => {
        await clearEvents();
        await periodsStartingOn(REGULAR_STARTS);
        const before = await predictions(WHOLE().from, WHOLE().to);
        expect(before.withheld).toBeNull();

        const midCycle = back(160);
        const marked = await post({
            type: "positiveTest",
            localDate: midCycle,
            timeZone: "UTC",
        });
        expect(marked.status).toBe(201);

        // Every list, the band and the withheld reason — the whole body, so a field that
        // started reading it cannot hide behind one this case forgot to name.
        expect(await predictions(WHOLE().from, WHOLE().to)).toEqual(before);

        // The control. A cycle entry on the same date is a different document (the two
        // types have different one-per-day ids), so this adds flow rather than replacing
        // the mark — and the overlay moves.
        await flowOn(midCycle);
        const withFlow = await predictions(WHOLE().from, WHOLE().to);
        expect(withFlow).not.toEqual(before);
    });
});

/**
 * **The half that must not be got wrong.** Each case asserts the same three things: no
 * dates in any list, the reason present in the response, and the confidence `null` — a
 * withheld prediction has no band, because a band with nothing under it is the shape a
 * client draws as a certainty.
 *
 * A bug that shows nothing is acceptable. A bug that draws a fertile window over irregular
 * data is not (PRD §Phase 1 rule 5, #176 Risks).
 */
describe("GET /me/cycle/predictions: every gate fails closed through the route", () => {
    const withheldFor = async (starts: readonly string[]) => {
        await clearEvents();
        if (starts.length > 0) await periodsStartingOn(starts);
        const body = await predictions(WHOLE().from, WHOLE().to);
        expect(body.predictedPeriod).toEqual([]);
        expect(body.fertileWindow).toEqual([]);
        expect(body.peak).toEqual([]);
        expect(body.confidence).toBeNull();
        return body;
    };

    /**
     * #181's gate, through the route, which is #205's third acceptance criterion.
     *
     * Her three counted cycles are all 28 days, so the ≥3 gate passes and a median exists —
     * every reason to answer except the one that matters. The variation over every interval
     * between them is 32 days, and the window is refused.
     */
    test("alternating 28 and 60 day cycles are refused, with irregular-cycles as the reason", async () => {
        const body = await withheldFor(ALTERNATING_STARTS);
        expect(body.withheld).toBe("irregular-cycles");

        // And it is the gate that answered, not a shortage of data: the maths this process
        // runs over the same days counts three cycles, clears the ≥3 gate, and still refuses.
        const analysis = analyzeCycles(
            { days: daysFor(ALTERNATING_STARTS), today: todayIn("UTC"), profile: null },
            CYCLE_RULES,
        );
        // The fixture is the issue's, literally: a mis-typed offset would otherwise make this
        // a case about some other woman's calendar.
        expect(analysis.cycles.map((cycle) => cycle.lengthDays)).toEqual([28, 60, 28, 60, 28, 60]);
        expect(analysis.countedCycles).toBe(CYCLE_RULES.minCyclesForEstimate);
        expect(analysis.enoughCountedCycles).toBe(true);
        expect(analysis.medianCycleLengthDays).not.toBeNull();
        expect(analysis.irregular).toBe(true);
        expect(analysis.withheld).toBe(body.withheld);
    });

    test("under three counted cycles is refused, with the reason in the response", async () => {
        const body = await withheldFor(TOO_FEW_STARTS);
        expect(body.withheld).toBe("too-few-counted-cycles");
    });

    test("an account that has logged no flow at all is refused, with its own reason", async () => {
        const body = await withheldFor([]);
        expect(body.withheld).toBe("no-flow-logged");
    });

    /**
     * The reason is a *field*, not an inference from emptiness. Pinned separately because
     * "empty lists" and "empty lists plus a reason" are the same screen until something goes
     * wrong, and the second is the one C12b can explain to her.
     */
    test("a withheld answer names its gate rather than leaving a null to be read", async () => {
        const body = await withheldFor(TOO_FEW_STARTS);
        expect(Object.keys(body)).toContain("withheld");
        expect(typeof body.withheld).toBe("string");
    });
});

/**
 * `CycleRulesUnsetError` answers 503, not 500 — #205's seventh criterion.
 *
 * The `CYCLE_*` group is unset in every environment today and `deploy-api.yml` sets none of
 * it (#176, #191), so this is the configuration the route actually ships into: without the
 * arm, the first real request is a 500 with a `ref` and no explanation. Its own server,
 * because `config.ts` reads the environment once at import.
 */
describe("GET /me/cycle/predictions refuses rather than failing", () => {
    test("503 when the cycle maths' constants are unconfigured", async () => {
        const server = await bootApi(NO_CYCLE_ENV);
        try {
            const day = todayIn("UTC");
            const res = await apiAt(
                server.base,
                `/me/cycle/predictions?from=${day}&to=${day}&timeZone=UTC`,
            );
            expect(res.status).toBe(503);
            expect((await json<ErrorBody>(res)).error.code).toBe("SERVICE_UNAVAILABLE");
        } finally {
            server.child.kill();
        }
    }, 60_000);

    /**
     * A bad range is answered *before* the maths is asked, so an unconfigured deployment
     * still validates. Otherwise the 503 would mask every 400 and a client could not tell a
     * malformed request from an unavailable capability.
     */
    test("and still answers 400 for a bad range on that same server", async () => {
        const server = await bootApi(NO_CYCLE_ENV);
        try {
            const res = await apiAt(
                server.base,
                "/me/cycle/predictions?from=2026-02-02&to=2026-02-01",
            );
            expect(res.status).toBe(400);
            expect((await json<ErrorBody>(res)).error.code).toBe("VALIDATION");
        } finally {
            server.child.kill();
        }
    }, 60_000);
});

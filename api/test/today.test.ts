import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { applyContent, contentVersion, invalidateContentCache, type Review } from "../src/content";
import { PatternRuleUnsetError, TemplatePhraser, TemplateUnavailableError, getToday, type Phraser, type PhrasedText } from "../src/today";
import type { Subject } from "../src/dashboard-rules";
import type { Template } from "../src/content";
import type { DashboardRules } from "../src/dashboard-rules";
import { firestore } from "../src/firebase";
import { TEMPLATES, REVIEW as SEED_REVIEW } from "../scripts/seed-content";
import { signUpActivated } from "./support/session";

/**
 * The Today card (#98, slice D3 of #10): `GET /me/today`, the daily cache, and the
 * template phraser.
 *
 * Three kinds of case, deliberately separated because they can be trusted to different
 * degrees:
 *
 *  - **`TemplatePhraser`** is pure. No Firestore, no server, runs everywhere, and is where
 *    the confidence and slot rules are actually pinned.
 *  - **The cache rules** run in-process against Firestore through `getToday`, so the test
 *    can hand in its own rules and its own phraser, and can invalidate the content cache
 *    between calls — which is what makes "new copy does not regenerate" a case that can
 *    fail rather than one that passes because the server never saw the new copy.
 *  - **The route** runs against a server this file boots with the pattern rung configured,
 *    because `config.ts` is read at boot and a test process cannot reach into another
 *    process's configuration.
 *
 * **Most of it needs a seeded `content/`, which is emulator-only.** #97 refuses to seed the
 * real project without a reviewer, and writing the three documents the API serves from a
 * test would be worse. So the card-producing cases are `skipIf(!onEmulators)` and run under
 * `scripts/ci-api.sh`; what a local `bun run verify` covers instead is the honest behaviour
 * against an **empty** store, which is what a real device hits today.
 */

/** Live round trips to Firestore and a spawned API on most cases (#31). */
setDefaultTimeout(20_000);

const onEmulators = Boolean(
    process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.FIRESTORE_EMULATOR_HOST,
);

const PASSWORD = "correct-horse-8";
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;

/**
 * The pattern rung's thresholds, for this file only.
 *
 * Chosen here rather than read from `config`, and emphatically not a default proposed for
 * #26: these numbers exist so the ladder can be *exercised*, and nothing outside this file
 * and the spawned server below sees them.
 */
const RULES: DashboardRules = {
    pattern: { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 2 },
};

const REVIEW: Review = {
    reviewedBy: "today.test.ts",
    reviewedAt: "2026-09-16",
    source: "docs/design/Eva App.dc.html — Dashboard card",
};

let token = "";
let uid = "";
/** The API this file boots, with the pattern rung configured. */
let base = "";
let child: ReturnType<typeof Bun.spawn> | null = null;
const seeded: string[] = [];

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
    fetch(`${base}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
            ...(init?.headers ?? {}),
        },
    });

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

interface TodayBody {
    date: string;
    generatedAt: string;
    contentVersion: string;
    card: Record<string, unknown>;
}
interface ErrorBody {
    error: { code: string; message: string };
}

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

/** A slot placeholder the phraser left behind. `{"state":…}` is JSON punctuation and does
 *  not match; `{cycleDay}` does, which is the thing that must never reach a card. */
const UNFILLED = /\{[A-Za-z]\w*\}/;

const todayDocs = () => firestore.collection("users").doc(uid).collection("today");
const storedDays = async () => (await todayDocs().get()).docs;

beforeAll(async () => {
    // Boot our own API, because the pattern rung is configuration and `config.ts` reads it
    // once at boot. A server started by `verify-api.sh` has it unset — which is the correct
    // production default (#26) and useless for exercising the ladder.
    const port = 3400 + Math.floor(Math.random() * 200);
    child = Bun.spawn(["bun", "run", "src/index.ts"], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
            ...process.env,
            PORT: String(port),
            DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: String(RULES.pattern!.lowSignalDays),
            DASHBOARD_PATTERN_LOW_AT_OR_BELOW: String(RULES.pattern!.lowAtOrBelow),
            DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: String(RULES.pattern!.severeSymptomDays),
        },
        stdout: "pipe",
        stderr: "pipe",
    });
    base = `http://localhost:${port}`;
    let up = false;
    for (let i = 0; i < 60 && !up; i++) {
        up = await fetch(`${base}/`)
            .then((r) => r.text())
            .then((t) => t === "Eva API")
            .catch(() => false);
        if (!up) await Bun.sleep(250);
    }
    expect(up).toBe(true);

    const account = await signUpActivated(base, email, PASSWORD);
    token = account.token;
    uid = account.uid;

    if (onEmulators) {
        await applyContent("templates", TEMPLATES, REVIEW, { rewrite: true });
        seeded.push("templates");
        invalidateContentCache();
    }
}, 60_000);

afterAll(async () => {
    for (const doc of await todayDocs().get().then((s) => s.docs).catch(() => [])) {
        await doc.ref.delete().catch(() => {});
    }
    const events = await firestore
        .collection("users")
        .doc(uid)
        .collection("events")
        .get()
        .catch(() => null);
    for (const doc of events?.docs ?? []) await doc.ref.delete().catch(() => {});
    if (uid) await firestore.collection("users").doc(uid).delete().catch(() => {});
    for (const id of seeded) await firestore.collection("content").doc(id).delete().catch(() => {});
    child?.kill();
});

// ── The phraser ────────────────────────────────────────────────────────────────────────
// Pure: these are the cases that pin the tone rules, and they run in every environment.

describe("TemplatePhraser", () => {
    const phraser = new TemplatePhraser();

    const template = (over: Partial<Template>): Template => ({
        id: "phase_energy",
        rung: "phase",
        mode: "cycle",
        state: "home_d",
        confidence: "hedged",
        title: "Many women notice higher energy around now",
        actions: ["View cycle details"],
        slots: [],
        status: "active",
        order: 0,
        ...over,
    });

    const subject = (over: Partial<Subject>): Subject => ({
        rung: "phase",
        templateId: "phase_energy",
        slots: {},
        confidence: "hedged",
        ...over,
    });

    test("substitutes slot values into every line that carries one", () => {
        const text = phraser.phrase(
            subject({ slots: { cycleDay: 15, phase: "follicular" } }),
            [template({ kicker: "Cycle day {cycleDay} · likely {phase}", line2: "day {cycleDay}" })],
        );
        expect(text.kicker).toBe("Cycle day 15 · likely follicular");
        expect(text.line2).toBe("day 15");
        expect(text.state).toBe("home_d");
    });

    test("a hedged subject is rendered by the hedged template", () => {
        const text = phraser.phrase(subject({ confidence: "hedged" }), [
            template({ confidence: "hedged", title: "likely approaching ovulation" }),
        ]);
        expect(text.title).toBe("likely approaching ovulation");
    });

    /**
     * PRD §Dashboard: "the wording must reflect that rather than asserting the phase as
     * fact". The plain copy for the same card exists in the store and must be unreachable
     * at the hedged class — not merely unpreferred.
     */
    test("the plain variant is unreachable at the hedged class", () => {
        expect(() =>
            phraser.phrase(subject({ confidence: "hedged" }), [
                template({ confidence: "plain", title: "You are in your follicular phase" }),
            ]),
        ).toThrow(TemplateUnavailableError);
    });

    test("and the hedged variant is unreachable at the plain class", () => {
        expect(() =>
            phraser.phrase(subject({ confidence: "plain" }), [template({ confidence: "hedged" })]),
        ).toThrow(TemplateUnavailableError);
    });

    test("given both, it picks the one matching the subject's class", () => {
        const text = phraser.phrase(subject({ confidence: "hedged" }), [
            template({ confidence: "plain", title: "plain copy", order: 0 }),
            template({ confidence: "hedged", title: "hedged copy", order: 1 }),
        ]);
        expect(text.title).toBe("hedged copy");
    });

    /**
     * D1 leaves `home_edu`'s `category` and `readMinutes` unfilled on purpose — no slice
     * owns choosing the article. The card must therefore drop its meta line rather than
     * render `{category}` or invent a placeholder.
     */
    test("an unfilled slot removes its line and leaves the rest of the card", () => {
        const text = phraser.phrase(subject({ templateId: "educational", confidence: "plain" }), [
            template({
                id: "educational",
                confidence: "plain",
                state: "home_edu",
                kicker: "Today’s read",
                title: "Why sleep can affect appetite more than willpower",
                meta: "{category} · {readMinutes} min read",
            }),
        ]);
        expect(text.meta).toBeUndefined();
        expect(text.kicker).toBe("Today’s read");
        expect(text.title).toBe("Why sleep can affect appetite more than willpower");
        expect(JSON.stringify(text)).not.toMatch(UNFILLED);
    });

    test("a retired template is not used", () => {
        expect(() => phraser.phrase(subject({}), [template({ status: "retired" })])).toThrow(
            TemplateUnavailableError,
        );
    });

    test("an unseeded store refuses rather than inventing a card", () => {
        expect(() => phraser.phrase(subject({}), [])).toThrow(TemplateUnavailableError);
    });
});

// ── The cache rules ────────────────────────────────────────────────────────────────────

describe.skipIf(!onEmulators)("the daily cache", () => {
    const date = () => todayIn("UTC");
    const request = () => ({ date: date(), timeZone: "UTC" });

    test("an empty account gets the cold-start card, with no slot values", async () => {
        const today = await getToday(uid, request(), RULES);
        expect(today.card.templateId).toBe("cold_start");
        expect(today.card.state).toBe("home_a");
        expect(today.card.rung).toBe("setup");
        // Nothing personalised, because there is nothing to personalise from (PRD
        // Confidence and cold start 4).
        expect(JSON.stringify(today.card)).not.toMatch(UNFILLED);
        const seededCopy = TEMPLATES.find((t) => t.id === "cold_start")!;
        expect(today.card.title).toBe(seededCopy.title);
    });

    /**
     * New data changes the card; new copy does not. The content cache is invalidated
     * between the two calls on purpose — without that the server would be serving a stale
     * bundle and this case would pass even if regeneration were unconditional.
     */
    test("a change to content/ alone does not regenerate an existing day", async () => {
        const first = await getToday(uid, request(), RULES);

        const rewritten = TEMPLATES.map((t) =>
            t.id === "cold_start" ? { ...t, title: "Rewritten by today.test.ts" } : t,
        );
        await applyContent("templates", rewritten, REVIEW, { rewrite: true });
        invalidateContentCache();
        // The store really does hold different words now, so a regeneration would show.
        expect(contentVersion({ templates: rewritten, banners: [], nudges: [] })).not.toBe(
            first.contentVersion,
        );

        const second = await getToday(uid, request(), RULES);
        expect(second.generatedAt).toBe(first.generatedAt);
        expect(second.contentVersion).toBe(first.contentVersion);
        expect(second.card.title).toBe(first.card.title);
        expect(second.card.title).not.toBe("Rewritten by today.test.ts");

        await applyContent("templates", TEMPLATES, REVIEW, { rewrite: true });
        invalidateContentCache();
    });

    test("the phraser cannot change the template id or the rung", async () => {
        await todayDocs().doc(date()).delete();
        const rogue: Phraser = {
            id: "rogue",
            phrase: (): PhrasedText => ({
                state: "home_flag",
                title: "a subject the ladder never chose",
                actions: [],
            }),
        };
        const today = await getToday(uid, request(), RULES, rogue);
        // The words are the phraser's; the subject is not its to name.
        expect(today.card.title).toBe("a subject the ladder never chose");
        expect(today.card.templateId).toBe("cold_start");
        expect(today.card.rung).toBe("setup");
        await todayDocs().doc(date()).delete();
    });

    test("an unconfigured pattern rung is a refusal, not an answer", async () => {
        await expect(getToday(uid, request(), { pattern: null })).rejects.toThrow(
            PatternRuleUnsetError,
        );
    });

    test("the stored card carries no raw signal value and no event", async () => {
        await todayDocs().doc(date()).delete();
        await api(`/me/body-signals/${date()}`, {
            method: "PUT",
            body: JSON.stringify({ energy: 1, mood: 1, sleep: 1, timeZone: "UTC" }),
        });
        await getToday(uid, request(), RULES);

        const stored = (await todayDocs().doc(date()).get()).data()!;
        const card = stored.card as Record<string, unknown>;
        const allowed = [
            "templateId",
            "rung",
            "state",
            "tone",
            "kicker",
            "title",
            "line2",
            "line3",
            "meta",
            "actions",
        ];
        expect(Object.keys(card).filter((key) => !allowed.includes(key))).toEqual([]);
        // The ratings she logged are not on the card; only the words the reviewed copy
        // carries. `sex` cannot reach here at all — D1 receives body signals and nothing
        // else — so this is a floor under that, not the guarantee itself.
        const serialised = JSON.stringify(card);
        expect(serialised).not.toContain("energy\":");
        expect(serialised).not.toContain("payload");
        expect(serialised).not.toContain("sex");
    });
});

// ── The route ──────────────────────────────────────────────────────────────────────────

describe("GET /me/today", () => {
    test("needs a session", async () => {
        expect((await api("/me/today", { token: null })).status).toBe(401);
    });

    test("refuses a time zone that is not one", async () => {
        const res = await api("/me/today?timeZone=Mars/Olympus");
        expect(res.status).toBe(400);
        expect((await json<ErrorBody>(res)).error.code).toBe("VALIDATION");
    });

    /**
     * What a real device hits today. `content/` is unseeded in every environment — #97
     * refuses to seed it without a reviewer — so the card cannot be filled and the route
     * says so as an unavailable capability rather than a 500 or an empty card.
     */
    test.skipIf(onEmulators)("answers 503 against an empty content store", async () => {
        const res = await api("/me/today?timeZone=UTC");
        expect(res.status).toBe(503);
        expect((await json<ErrorBody>(res)).error.code).toBe("SERVICE_UNAVAILABLE");
        // And nothing was cached: a refusal is not a card.
        expect((await storedDays()).length).toBe(0);
    });
});

describe.skipIf(!onEmulators)("GET /me/today, served", () => {
    const post = (body: unknown) =>
        api("/me/events", { method: "POST", body: JSON.stringify(body) });

    const sport = (localDate: string) => ({
        type: "sport",
        localDate,
        payload: { activity: "run", durationMin: 30, intensity: "light" },
        timeZone: "UTC",
    });

    const fetchToday = async () => {
        const res = await api("/me/today?timeZone=UTC");
        expect(res.status).toBe(200);
        return { body: await res.text(), parsed: null as TodayBody | null };
    };

    beforeAll(async () => {
        for (const doc of await storedDays()) await doc.ref.delete();
    });

    /**
     * PRD Other requirements 3 and Edge case 5 — the card "does not change between opens".
     * Byte-identical, not merely equivalent: `generatedAt` advancing is exactly the failure
     * this is here to catch, and D4's "does not change on refresh" rests on it.
     */
    test("two calls with no new data return byte-identical bodies and one document", async () => {
        const first = await fetchToday();
        const second = await fetchToday();
        expect(second.body).toBe(first.body);
        expect((await storedDays()).length).toBe(1);
    });

    test("a new event regenerates it; a refresh after that does not", async () => {
        const before = await fetchToday();
        const created = await post(sport(todayIn("UTC")));
        expect(created.status).toBe(201);

        const after = await fetchToday();
        expect(after.body).not.toBe(before.body);
        const parsedBefore = JSON.parse(before.body) as TodayBody;
        const parsedAfter = JSON.parse(after.body) as TodayBody;
        expect(parsedAfter.generatedAt > parsedBefore.generatedAt).toBe(true);
        expect((await storedDays()).length).toBe(1);

        // and it settles: nothing changed since, so the next open is the same document
        expect((await fetchToday()).body).toBe(after.body);
    });

    test("an edit, a delete, a restore and a body-signals upsert each regenerate it", async () => {
        const date = todayIn("UTC");
        const created = await json<{ event: { id: string } }>(await post(sport(date)));
        const id = created.event.id;

        const afterCreate = await fetchToday();

        const patched = await api(`/me/events/${id}`, {
            method: "PATCH",
            body: JSON.stringify({ type: "sport", localDate: date, note: "edited", timeZone: "UTC" }),
        });
        expect(patched.status).toBe(200);
        const afterEdit = await fetchToday();
        expect(afterEdit.body).not.toBe(afterCreate.body);

        expect((await api(`/me/events/${id}`, { method: "DELETE" })).status).toBe(200);
        const afterDelete = await fetchToday();
        expect(afterDelete.body).not.toBe(afterEdit.body);

        const restored = await api(`/me/events/${id}/restore`, { method: "POST" });
        expect(restored.status).toBe(200);
        const afterRestore = await fetchToday();
        expect(afterRestore.body).not.toBe(afterDelete.body);

        const upserted = await api(`/me/body-signals/${date}`, {
            method: "PUT",
            body: JSON.stringify({ energy: 2, timeZone: "UTC" }),
        });
        expect(upserted.status).toBe(200);
        const afterSignals = await fetchToday();
        expect(afterSignals.body).not.toBe(afterRestore.body);

        expect((await storedDays()).length).toBe(1);
    });

    test("saving the questionnaire regenerates it", async () => {
        const before = await fetchToday();
        const saved = await api("/me/questionnaire", {
            method: "PUT",
            body: JSON.stringify({
                age: 30,
                weightKg: 62,
                heightCm: 170,
                goals: ["energy"],
                conditions: [],
                medications: "",
                lifestyle: "active",
                sports: ["running"],
            }),
        });
        expect(saved.status).toBe(200);
        expect((await fetchToday()).body).not.toBe(before.body);
    });

    /**
     * "Today" is the caller's, never the server's — the same rule `localDate` follows.
     * Pacific/Kiritimati (UTC+14) and Pacific/Midway (UTC-11) are 25 hours apart, so their
     * local dates always differ and a server deriving the day from its own clock would have
     * to get one of them wrong.
     */
    test("the request's time zone decides which day this is", async () => {
        const east = todayIn("Pacific/Kiritimati");
        const west = todayIn("Pacific/Midway");
        expect(east).not.toBe(west);

        const eastCard = await json<TodayBody>(await api("/me/today?timeZone=Pacific/Kiritimati"));
        const westCard = await json<TodayBody>(await api("/me/today?timeZone=Pacific/Midway"));
        expect(eastCard.date).toBe(east);
        expect(westCard.date).toBe(west);

        // Two days, two documents, each stored under the date its caller was on.
        const ids = (await storedDays()).map((doc) => doc.id);
        expect(ids).toContain(east);
        expect(ids).toContain(west);
    });

    test("omitting the time zone falls back to UTC, as events do", async () => {
        const card = await json<TodayBody>(await api("/me/today"));
        expect(card.date).toBe(todayIn("UTC"));
    });
});

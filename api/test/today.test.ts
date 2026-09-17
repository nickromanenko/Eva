import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { Timestamp } from "firebase-admin/firestore";
import { applyContent, contentVersion, invalidateContentCache, type Review } from "../src/content";
import * as todayModule from "../src/today";
import { PatternRuleUnsetError, TemplatePhraser, TemplateUnavailableError, getToday, type Phraser, type PhrasedText } from "../src/today";
import { CycleRulesUnsetError } from "../src/cycle";
import type { Subject } from "../src/dashboard-rules";
import type { Template } from "../src/content";
import type { DashboardRules } from "../src/dashboard-rules";
import { adminAuth, firestore } from "../src/firebase";
import { lastUserChangeAt } from "../src/users";
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
 *    process's configuration. For the same reason the two refusal cases boot their *own*
 *    servers — one with the rung unconfigured, one against an emptied `content/` — since
 *    each 503 branch is only reachable on a server that cannot produce the other.
 *  - **The configuration itself** is a boot, so it is checked by running `config.ts` in a
 *    subprocess and reading its exit code, as `config-emulators.test.ts` does.
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

/** `RULES` as `config.ts` reads it, for the servers this file boots. */
const PATTERN_ENV = {
    DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: String(RULES.pattern!.lowSignalDays),
    DASHBOARD_PATTERN_LOW_AT_OR_BELOW: String(RULES.pattern!.lowAtOrBelow),
    DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: String(RULES.pattern!.severeSymptomDays),
};

/**
 * The same three, unset.
 *
 * Empty rather than absent: `config.ts` reads them with `optionalString`, which treats `''`
 * as "not supplied", and an empty value cannot be filled back in by an `api/.env` the way a
 * deleted key can. This is the configuration every environment actually runs today.
 */
const NO_PATTERN_ENV = {
    DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: "",
    DASHBOARD_PATTERN_LOW_AT_OR_BELOW: "",
    DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: "",
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

/**
 * Spawns an API with `over` layered on this process's environment, and waits for it to
 * answer. `config.ts` reads the environment once at import, so a case that needs a
 * different configuration needs a different *process* — there is no seam short of that.
 * Every server this file starts shares the same emulators, secret and account, so the
 * session token works against all of them.
 */
const bootApi = async (over: Record<string, string>) => {
    const port = 3400 + Math.floor(Math.random() * 200);
    const spawned = Bun.spawn(["bun", "run", "src/index.ts"], {
        cwd: new URL("..", import.meta.url).pathname,
        env: { ...process.env, PORT: String(port), ...over },
        stdout: "pipe",
        stderr: "pipe",
    });
    const url = `http://localhost:${port}`;
    let up = false;
    for (let i = 0; i < 60 && !up; i++) {
        up = await fetch(`${url}/`)
            .then((r) => r.text())
            .then((t) => t === "Eva API")
            .catch(() => false);
        if (!up) await Bun.sleep(250);
    }
    expect(up).toBe(true);
    return { base: url, child: spawned };
};

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

/** `YYYY-MM-DD` shifted by whole days in UTC — a calendar label, as everywhere else here. */
const shiftDays = (day: string, by: number): string =>
    new Date(Date.parse(`${day}T00:00:00.000Z`) + by * 86_400_000).toISOString().slice(0, 10);

const sportOn = (localDate: string) => ({
    type: "sport",
    localDate,
    payload: { activity: "run", durationMin: 30, intensity: "light" },
    timeZone: "UTC",
});

const todayDocs = () => firestore.collection("users").doc(uid).collection("today");
const storedDays = async () => (await todayDocs().get()).docs;
const eventDocs = () => firestore.collection("users").doc(uid).collection("events");

/** Hard-removes every entry, soft-deleted ones included. A case about *which* card the
 *  ladder chose has to start from a known account rather than from whatever ran before it,
 *  and a soft delete is still a row `lastEventChangeAt` can see. */
const clearEvents = async () => {
    const snapshot = await eventDocs().get().catch(() => null);
    for (const doc of snapshot?.docs ?? []) await doc.ref.delete().catch(() => {});
};

beforeAll(async () => {
    // Boot our own API, because the pattern rung is configuration and `config.ts` reads it
    // once at boot. A server started by `verify-api.sh` has it unset — which is the correct
    // production default (#26) and useless for exercising the ladder.
    const spawned = await bootApi(PATTERN_ENV);
    base = spawned.base;
    child = spawned.child;

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
    await clearEvents();
    if (uid) await firestore.collection("users").doc(uid).delete().catch(() => {});
    // And the Auth account, which this file used to leave behind. A live Auth user whose
    // `users/{uid}` is gone is exactly the orphan `account-deletion.test.ts` exists to rule
    // out, and every other suite that signs up deletes it (`events.test.ts:121`,
    // `events-retention.test.ts:144`). Against the real project that orphan is permanent.
    if (uid) await adminAuth.deleteUser(uid).catch(() => {});
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

    /**
     * The other half of that rule, and the half with consequences. `meta` is dropped;
     * `title` cannot be — a card with no title is not a card — so a title whose slot has no
     * value is a refusal rather than a raw string.
     *
     * Driven from the *seeded* copy, because that is what makes it more than a unit test:
     * two of the fourteen templates carry `{appointmentAt}` in their title. Both belong to
     * rung 3, which is inert until D10 wires it — and this guard is the only thing between
     * that wiring and "Your anatomy scan is scheduled for tomorrow, {appointmentAt}"
     * reaching a user.
     */
    test("a title with an unfilled slot is refused, not rendered raw", () => {
        const withSlotInTitle = TEMPLATES.filter((candidate) => UNFILLED.test(candidate.title));
        expect(withSlotInTitle.length).toBeGreaterThan(0);
        for (const seeded of withSlotInTitle) {
            // `Template.id` is an open string and `Subject.templateId` is D1's union; these
            // two ids are in it, and the cast is what lets the case be driven from the copy
            // rather than from a hand-written duplicate of it.
            const named = subject({ templateId: seeded.id as Subject["templateId"] });
            expect(() =>
                phraser.phrase({ ...named, confidence: seeded.confidence }, [seeded]),
            ).toThrow(TemplateUnavailableError);
        }
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

    /**
     * PRD §Dashboard: "the message subject is never free-generated".
     *
     * This phraser **tries**. It returns a `templateId` and a `rung` of its own, and it
     * names `flag` — the one rung that must never be reachable without the ladder. The
     * return value is assembled dynamically on purpose: `PhrasedText` not carrying those
     * keys stops an object *literal* and nothing else, and D9's model phraser (#106) will
     * build its answer exactly this way. What actually holds the line is `buildCard`
     * writing the subject's two fields after spreading the text.
     */
    test("the phraser cannot change the template id or the rung", async () => {
        await todayDocs().doc(date()).delete();
        const rogue: Phraser = {
            id: "rogue",
            phrase: (): PhrasedText => {
                const named: Record<string, unknown> = {
                    state: "home_flag",
                    title: "a subject the ladder never chose",
                    actions: [],
                    templateId: "late_period",
                    rung: "flag",
                };
                return named as unknown as PhrasedText;
            },
        };
        const today = await getToday(uid, request(), RULES, rogue);
        // The words are the phraser's; the subject is not its to name.
        expect(today.card.title).toBe("a subject the ladder never chose");
        expect(today.card.templateId).toBe("cold_start");
        expect(today.card.rung).toBe("setup");

        // And the *stored* card is the ladder's too — that is the one served tomorrow.
        const stored = (await todayDocs().doc(date()).get()).data()!.card as Record<string, unknown>;
        expect(stored.templateId).toBe("cold_start");
        expect(stored.rung).toBe("setup");
        await todayDocs().doc(date()).delete();
    });

    test("an unconfigured pattern rung is a refusal, not an answer", async () => {
        await expect(getToday(uid, request(), { pattern: null })).rejects.toThrow(
            PatternRuleUnsetError,
        );
    });

    /**
     * Rung 2, driven end to end — the only card in this file that the ladder reaches by
     * reading her logs rather than by finding none.
     *
     * Three consecutive days at or below the configured level, today included, which is
     * exactly `lowSignalDays`. The window `today.ts` reads signals over is *derived* from
     * that rule rather than fixed, and this is why: a shorter window makes the rung
     * unmatchable while the configuration still looks live, which is the failure #26's
     * process note exists to prevent.
     */
    test("three consecutive low days reach the pattern card", async () => {
        await clearEvents();
        const day = date();
        for (const on of [shiftDays(day, -2), shiftDays(day, -1), day]) {
            const logged = await api(`/me/body-signals/${on}`, {
                method: "PUT",
                body: JSON.stringify({ mood: 1, sleep: 1, timeZone: "UTC" }),
            });
            expect(logged.status).toBe(200);
        }
        await todayDocs().doc(day).delete();

        const today = await getToday(uid, request(), RULES);
        expect(today.card.rung).toBe("pattern");
        expect(today.card.templateId).toBe("mood_pattern");
        expect(today.card.title).toBe(TEMPLATES.find((t) => t.id === "mood_pattern")!.title);
        expect(JSON.stringify(today.card)).not.toMatch(UNFILLED);
    });

    /**
     * The stored stamp is the *data's* instant, not this process's clock: `getToday` reads
     * `changedAt` before it gathers, and writes that rather than `generatedAt`.
     *
     * The failure it prevents is a server clock running ahead of Firestore's. She logs a
     * moment after the card was built; her entry's `updatedAt` sorts below the stamped
     * `now`, the card never looks stale again, and her log is invisible on Today for the
     * rest of the day. The skew is manufactured here rather than waited for — writing the
     * entry's `updatedAt` directly is the only way to make it deterministic.
     */
    test("the card is stamped with the data's instant, not the server's clock", async () => {
        await clearEvents();
        const day = date();
        await todayDocs().doc(day).delete();
        const created = await json<{ event: { id: string } }>(
            await api("/me/events", { method: "POST", body: JSON.stringify(sportOn(day)) }),
        );
        const entry = eventDocs().doc(created.event.id);

        // Put the newest thing in her data a clear second behind this process's clock,
        // which is what a Cloud Run instance ahead of Firestore looks like from here.
        const userAt = Date.parse((await lastUserChangeAt(uid))!);
        const dataAt = Math.max(userAt + 1, Date.now() - 1_000);
        await entry.update({ updatedAt: Timestamp.fromMillis(dataAt) });

        const first = await getToday(uid, request(), RULES);
        const stored = (await todayDocs().doc(day).get()).data()!;
        expect(stored.dataChangedAt).toBe(new Date(dataAt).toISOString());
        // There really is a gap, so what follows is about the stamp and not about rounding.
        expect(Date.parse(stored.generatedAt)).toBeGreaterThan(dataAt + 1);

        // Her log: one millisecond after the instant the card was built from, and still
        // well below `generatedAt`. Stamped with the data's instant it is newer and the
        // card regenerates; stamped with the clock it is older and she never sees it.
        await entry.update({ updatedAt: Timestamp.fromMillis(dataAt + 1) });
        const second = await getToday(uid, request(), RULES);
        expect(second.generatedAt).not.toBe(first.generatedAt);
    });

    /**
     * A deleted entry is not a log. `lastLoggedDate` filters on `deletedAt === null`;
     * without that filter `daysSinceLastLog` reads `0` for a day whose only entry she just
     * removed, D1 stops treating this as a first open, and she is handed a card that
     * implies she logged something that is gone.
     */
    test("an entry logged and then deleted leaves her on the cold-start card", async () => {
        await clearEvents();
        const day = date();
        const created = await json<{ event: { id: string } }>(
            await api("/me/events", { method: "POST", body: JSON.stringify(sportOn(day)) }),
        );
        expect((await api(`/me/events/${created.event.id}`, { method: "DELETE" })).status).toBe(200);

        await todayDocs().doc(day).delete();
        const today = await getToday(uid, request(), RULES);
        expect(today.card.templateId).toBe("cold_start");
        expect(today.card.rung).toBe("setup");
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

    const sport = sportOn;

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

    /**
     * The zone decides more than which day it is. A stored `loggedAt` is a wall clock in
     * *her* zone, and `today.ts` turns it into an instant using the zone the route passes
     * down — the caller's, not UTC. Read as UTC, an entry made a minute ago in
     * Pacific/Kiritimati (UTC+14) lands fourteen hours in the future, and D1 discards it as
     * something that has not happened yet. So the card she gets changes, not just its date:
     * rung 2 speaks to her log, or the educational fallback stands in for it.
     */
    test("the caller's zone is the one stored wall clocks are read in", async () => {
        await clearEvents();
        for (const doc of await storedDays()) await doc.ref.delete();
        const zone = "Pacific/Kiritimati";
        const day = todayIn(zone);

        // Not low: `lowAtOrBelow` is 2, so this is an observed signal and not a pattern —
        // which keeps the case about the conversion rather than about rung 2's run.
        const logged = await api(`/me/body-signals/${day}`, {
            method: "PUT",
            body: JSON.stringify({ energy: 4, timeZone: zone }),
        });
        expect(logged.status).toBe(200);

        const served = await json<TodayBody>(await api(`/me/today?timeZone=${zone}`));
        expect(served.date).toBe(day);
        expect(served.card.templateId).toBe("signals_today");
        expect(served.card.rung).toBe("pattern");
    });
});

/**
 * The route's two refusals, each on a server that can produce only one of them — which is
 * what makes a green run evidence about *that* `instanceof` arm rather than about 503s in
 * general.
 *
 * Emulator-only and deliberately so. CI runs `scripts/ci-api.sh`, which is emulators, and
 * the only route-level 503 case before this one was `skipIf(onEmulators)` — so it was the
 * suite's single skip and CI exercised neither branch. Each server is started inside its
 * case and killed with it: `config.ts` reads the environment once at import, so this is the
 * only seam, and nothing here runs against the real project.
 */
describe.skipIf(!onEmulators)("GET /me/today refuses rather than failing", () => {
    const utcDay = () => todayIn("UTC");

    test("503 when rung 2's thresholds are unconfigured", async () => {
        await todayDocs().doc(utcDay()).delete();
        // Content is seeded, so `TemplateUnavailableError` cannot fire: D1 throws first,
        // at `requirePatternRule`, before `getContent` is reached.
        const server = await bootApi(NO_PATTERN_ENV);
        try {
            const res = await apiAt(server.base, "/me/today?timeZone=UTC");
            // 503, not the 500 `app.onError` hands back anything the route drops.
            expect(res.status).toBe(503);
            expect((await json<ErrorBody>(res)).error.code).toBe("SERVICE_UNAVAILABLE");
            // A refusal is not a card, and nothing was cached under the day.
            expect((await todayDocs().doc(utcDay()).get()).exists).toBe(false);
        } finally {
            server.child.kill();
        }
    }, 60_000);

    test("503 when the content store holds no template for the subject", async () => {
        await todayDocs().doc(utcDay()).delete();
        await firestore.collection("content").doc("templates").delete();
        // Booted *after* the delete, and `content.ts` never caches an empty bundle — so
        // this server reads the store as it is now rather than a warm copy of it. The
        // pattern rung is configured here, so the only refusal left is the template one.
        const server = await bootApi(PATTERN_ENV);
        try {
            const res = await apiAt(server.base, "/me/today?timeZone=UTC");
            expect(res.status).toBe(503);
            expect((await json<ErrorBody>(res)).error.code).toBe("SERVICE_UNAVAILABLE");
            expect((await todayDocs().doc(utcDay()).get()).exists).toBe(false);
        } finally {
            server.child.kill();
            await applyContent("templates", TEMPLATES, REVIEW, { rewrite: true });
            invalidateContentCache();
        }
    }, 60_000);
});

/**
 * **Every refusal this module exports is mapped, including the one nothing can throw yet.**
 *
 * The two cases above boot a server each and prove their own `instanceof` arm end to end.
 * `CycleRulesUnsetError` cannot be proved that way: `getToday` still hands D1 a
 * no-knowledge `CycleEstimate` and #179 is the change that calls `analyzeCycles`, so no
 * request can reach the arm. The day it can is the day a deployment without the `CYCLE_*`
 * group — which is every deployment today, deliberately (#176) — answers 500 instead of
 * 503 for an unset configuration. So the arm ships with the error, and these two cases are
 * what hold it there:
 *
 *  - the class the route branches on is the *same object* the maths constructs, so the
 *    `instanceof` will match rather than silently falling through to `app.onError`;
 *  - and the route's catch has an arm for every refusal `today.ts` exports, so the next
 *    refusal added below it fails here until it is mapped too.
 *
 * Neither needs Firestore or a server, so both run in every environment.
 */
describe("every refusal today.ts exports is a 503 at the route", () => {
    test("the re-exported class is the one the maths throws, not a second copy", () => {
        expect(todayModule.CycleRulesUnsetError).toBe(CycleRulesUnsetError);
        expect(new CycleRulesUnsetError() instanceof todayModule.CycleRulesUnsetError).toBe(true);
    });

    test("the /me/today catch has an arm for each of them", async () => {
        const source = await Bun.file(`${import.meta.dir}/../src/index.ts`).text();
        const route = source.slice(source.indexOf('app.get("/me/today"'));
        // Comments are stripped before matching: a branch named only in prose is a comment
        // about a mapping, not a mapping.
        const body = route
            .slice(0, route.indexOf("\n});"))
            .split("\n")
            .filter((line) => !line.trimStart().startsWith("//"))
            .join("\n");
        expect(body).toContain("catch (err)");

        const refusals = Object.entries(todayModule)
            .filter(
                ([, value]) => typeof value === "function" && value.prototype instanceof Error,
            )
            .map(([name]) => name);
        // The list is derived, so this assertion is what stops it being derived as empty.
        expect(refusals.sort()).toEqual([
            "CycleRulesUnsetError",
            "PatternRuleUnsetError",
            "TemplateUnavailableError",
        ]);
        for (const name of refusals) {
            expect(body).toContain(`err instanceof ${name}`);
        }
    });
});

/**
 * The pattern rung's thresholds as `config.ts` reads them — a boot-time refusal, so a
 * subprocess, the same shape as `config-emulators.test.ts`. No Firestore, so it runs in
 * every environment.
 */
describe("the pattern rung's configuration", () => {
    /** Enough to get `config.ts` past every other required variable. */
    const BASE_ENV = {
        PATH: process.env.PATH ?? "",
        FIREBASE_PROJECT_ID: "demo-eva-today-test",
        FIREBASE_WEB_API_KEY: "not-a-real-key",
        JWT_SECRET: "not-a-real-secret",
        EMAIL_TRANSPORT: "log",
        NODE_ENV: "test",
        POSTMARK_FROM: "today-test@example.test",
        PUBLIC_WEB_URL: "http://localhost:4321",
    };

    const bootConfig = async (over: Record<string, string>) => {
        // A bare env, not `...process.env`: a developer with these set would decide the
        // result, and the point is what a given trio does at boot.
        const proc = Bun.spawn(["bun", "run", "src/config.ts"], {
            cwd: new URL("..", import.meta.url).pathname,
            env: { ...BASE_ENV, ...over },
            stdout: "pipe",
            stderr: "pipe",
        });
        const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
        return { code, stderr };
    };

    /**
     * Ratings are whole numbers from 1 to 5 (`parseRating`), so `lowAtOrBelow: 5` calls
     * every answered rating low: anyone who logs anything three days running gets the
     * pattern card, and nothing surfaces it — the configuration looks valid and the card
     * looks live. "The 1–5 rating" is a completely plausible reading of the variable name.
     *
     * `requirePatternRule` refuses it too, at selection time (#175). This is the boot-time
     * half: the operator is told at startup rather than by every user's first request.
     */
    test("a rating ceiling that would call every rating low is refused at boot", async () => {
        const { code, stderr } = await bootConfig({
            ...PATTERN_ENV,
            DASHBOARD_PATTERN_LOW_AT_OR_BELOW: "5",
        });
        expect(code).not.toBe(0);
        expect(stderr).toContain("DASHBOARD_PATTERN_LOW_AT_OR_BELOW");
        expect(stderr).toContain("at most 4");
    }, 30_000);

    test("and the trio this file's servers use boots", async () => {
        expect((await bootConfig(PATTERN_ENV)).code).toBe(0);
    }, 30_000);
});

import { beforeAll, describe, expect, test } from "bun:test";
import {
    TEMPLATE,
    selectSubject,
    type CycleEstimate,
    type DashboardInput,
    type DashboardRules,
    type LoggedSymptom,
    type Mode,
    type PatternRule,
    type PhaseCode,
    type SignalEntry,
    type Subject,
    type TemplateId,
} from "../src/dashboard-rules";
import type { Template } from "../src/content";
import type { Phraser } from "../src/today";

/**
 * The copy audit (#177): **does each card's text say anything the input did not contain?**
 *
 * D2 (#97) seeded the canvas' fourteen cards verbatim, and the canvas drew them as
 * *illustrations* — one woman, one day, mostly without slots. D1 (#96) routes a wide range
 * of situations into each subject. Fixed illustrative text plus wide routing is a card that
 * states something specific about a user it is not true of, and two review rounds on #96
 * each found one instance: `mood_pattern` (fixed by #175, by narrowing the rule) and
 * `signals_today` (found because the #175 fix routed a severe-symptom run into it).
 *
 * Both were found by accident. This file looks on purpose, and it is the criterion of #177:
 * walk **every** subject `selectSubject` can return, over a generated space of inputs, and
 * check each rendered string against what the input actually held.
 *
 * ## How it is arranged, and why it can fail
 *
 * `AUDIT` holds, for each reachable template, (a) the seeded strings byte for byte and
 * (b) one claim per string: what that string asserts about her, as a predicate over the
 * input. A string that asserts nothing about her — an instruction, a general statement, an
 * explicitly conditional suggestion — carries `null`, written out rather than omitted, so
 * "nobody looked at this one" and "somebody looked and it makes no claim" are different
 * states in the file.
 *
 * The audit then runs every claim against every case that reaches it and collects the ones
 * that fail somewhere. **That set is compared to `UNTRUE`**, the list of mismatches the
 * canvas has not drawn a fix for. So this file fails three ways, all of them useful:
 *
 * - a *new* mismatch — a copy edit, or a routing change that widens a subject — is not in
 *   `UNTRUE`, and the run is red;
 * - a mismatch that gets *fixed* is still in `UNTRUE`, and the run is red until the entry
 *   is deleted, so the debt cannot be silently carried after the canvas answers;
 * - a string that *changes* fails the byte-for-byte pin, so no copy edit can land without
 *   its claims being re-read. That is the half of `seed-content.ts`'s signature nobody was
 *   re-checking, and #177 exists because it did not hold.
 *
 * **There is a fourth transition it does not catch**, and it is the one that ships a bad card:
 * a mismatch already in `UNTRUE` becoming reachable by real users. See the note above `UNTRUE`
 * — this file is a ledger, and the gate for that transition has to be an issue and a rule
 * change, not a row here.
 *
 * `NOTED`, beside it, carries the claims the input shape cannot falsify at all, so that "not
 * in `UNTRUE`" does not read as "nobody found anything".
 *
 * ## What this file is not
 *
 * It is not a test of `dashboard-rules.ts`'s routing — `dashboard-rules.test.ts` is — and it
 * changes no rule. #177's scope is explicit that the ladder is correct and the copy is the
 * half that has to move. Where a mismatch could only be closed by writing a new sentence,
 * the entry in `UNTRUE` says so and the PR asks the canvas for it; a seed file is not where
 * product copy is authored.
 *
 * **No live round trip, so no default timeout** (api/CLAUDE.md #31). The seed is imported
 * dynamically because it pulls in `content.ts`, and with it the Admin SDK.
 */

// ── The day ────────────────────────────────────────────────────────────────────────────
// One clock for the whole file, and every `loggedAt` at 08:00Z on its own local date, so
// "inside the 24-hour observed window" is decidable by eye: today's entries are in, and an
// entry two days old is out. The one deliberate exception is the "logged last night"
// history, dated yesterday and logged late enough to still be inside the window this
// morning — which is how the cards that say "today" and "this morning" are tested against
// a window that is neither.

const TODAY = "2026-09-16";
const NOW = `${TODAY}T09:00:00Z`;
const YESTERDAY = "2026-09-15";
const TWO_DAYS_AGO = "2026-09-14";
const THREE_DAYS_AGO = "2026-09-13";
const LAST_WEEK = "2026-09-11";

const MODES: Mode[] = ["cycle", "planning", "pregnancy", "postpartum", "loss"];

// ── Rung 2's dose (A32, #26) ───────────────────────────────────────────────────────────

const A32: PatternRule = { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 3 };

/**
 * Two doses, because the dose is configuration and the card's words are not.
 *
 * `mood_pattern` reads "for three consecutive days" and its kicker reads "last 3 days",
 * while `PatternRule.lowSignalDays` arrives from #26 and `dashboard-rules.ts` refuses to
 * hold a default for it. Running the audit at a dose other than three is therefore not a
 * contrived input: it is the configuration #26 is free to set, and the only thing that
 * would notice is this file.
 */
const RULE_SETS: { name: string; rules: DashboardRules }[] = [
    { name: "A32's dose (3 days, ≤2)", rules: { pattern: A32 } },
    {
        name: "a four-day dose",
        rules: { pattern: { ...A32, lowSignalDays: 4, severeSymptomDays: 4 } },
    },
];

// ── C11's answers, as fixtures ─────────────────────────────────────────────────────────
// Coherent states only: `enoughCyclesForEstimates` agrees with `countedCycles` against the
// PRD's ≥3 gate, and a withheld estimate carries no phase. An incoherent input would
// manufacture a mismatch nobody can reach, which is worse than missing one.

const NO_CYCLE: CycleEstimate = {
    countedCycles: 0,
    enoughCyclesForEstimates: false,
    irregular: false,
    cycleDay: null,
    phase: null,
    daysPastPredictedPeriod: null,
};

const estimated = (code: PhaseCode, cycleDay: number): CycleEstimate => ({
    countedCycles: 4,
    enoughCyclesForEstimates: true,
    irregular: false,
    cycleDay,
    phase: { code, confidence: "wide" },
    daysPastPredictedPeriod: null,
});

const CYCLES: { name: string; cycle: CycleEstimate }[] = [
    { name: "no cycle data", cycle: NO_CYCLE },
    {
        // **The commonest state `still_learning` is selected in, and the one its words are
        // furthest from.** C11 measures `cycleDay` from the most recent first-flow day, so
        // one logged period sets it; a *counted cycle* is the interval between two of them,
        // so it is still zero. `phaseRung` asks only whether `cycleDay` is known — so the
        // first card a new cycle-mode user sees after logging her first period is one that
        // counts down from one.
        name: "0 counted cycles, one period logged",
        cycle: { ...NO_CYCLE, cycleDay: 3 },
    },
    { name: "1 counted cycle", cycle: { ...NO_CYCLE, countedCycles: 1, cycleDay: 12 } },
    { name: "2 counted cycles", cycle: { ...NO_CYCLE, countedCycles: 2, cycleDay: 20 } },
    {
        name: "irregular",
        cycle: {
            countedCycles: 6,
            enoughCyclesForEstimates: true,
            irregular: true,
            cycleDay: 12,
            phase: null,
            daysPastPredictedPeriod: null,
        },
    },
    { name: "phase menstrual", cycle: estimated("menstrual", 2) },
    { name: "phase follicular", cycle: estimated("follicular", 13) },
    { name: "phase ovulation", cycle: estimated("ovulation", 15) },
    { name: "phase luteal", cycle: estimated("luteal", 22) },
    {
        name: "estimate withheld",
        cycle: {
            countedCycles: 6,
            enoughCyclesForEstimates: true,
            irregular: false,
            cycleDay: 12,
            phase: { code: "luteal", confidence: "none" },
            daysPastPredictedPeriod: null,
        },
    },
    {
        name: "two days past the prediction",
        cycle: { ...estimated("luteal", 31), countedCycles: 6, daysPastPredictedPeriod: 2 },
    },
    {
        name: "the predicted day itself",
        cycle: { ...estimated("luteal", 29), countedCycles: 6, daysPastPredictedPeriod: 0 },
    },
];

// ── What she logged ────────────────────────────────────────────────────────────────────

const severe = (code: string): LoggedSymptom[] => [{ code, severity: "severe" }];

const entry = (over: Partial<SignalEntry> & { localDate: string }): SignalEntry => ({
    loggedAt: `${over.localDate}T08:00:00Z`,
    energy: null,
    mood: null,
    sleep: null,
    symptoms: [],
    ...over,
});

const run = (dates: string[], over: Partial<SignalEntry>): SignalEntry[] =>
    dates.map((localDate) => entry({ localDate, ...over }));

const HISTORIES: { name: string; signals: SignalEntry[] }[] = [
    { name: "nothing ever logged", signals: [] },
    { name: "the sheet opened and nothing saved", signals: [entry({ localDate: TODAY })] },
    { name: "a log last week", signals: [entry({ localDate: LAST_WEEK, energy: 1 })] },
    { name: "low energy only", signals: [entry({ localDate: TODAY, energy: 1 })] },
    {
        name: "low energy and poor sleep",
        signals: [entry({ localDate: TODAY, energy: 1, sleep: 2 })],
    },
    {
        name: "the canvas' own day: low energy and a headache",
        signals: [entry({ localDate: TODAY, energy: 1, symptoms: severe("headache") })],
    },
    { name: "energy 5 and sleep 5", signals: [entry({ localDate: TODAY, energy: 5, sleep: 5 })] },
    { name: "low mood, sleep unanswered", signals: [entry({ localDate: TODAY, mood: 2 })] },
    {
        name: "severe cramps only",
        signals: [entry({ localDate: TODAY, mood: 5, sleep: 5, symptoms: severe("cramps") })],
    },
    {
        name: "logged last night",
        signals: [
            { ...entry({ localDate: YESTERDAY, energy: 1 }), loggedAt: `${YESTERDAY}T23:00:00Z` },
        ],
    },
    {
        name: "three days of low mood and low sleep",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO], { mood: 2, sleep: 2 }),
    },
    {
        name: "four days of low mood and low sleep",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO, THREE_DAYS_AGO], { mood: 2, sleep: 2 }),
    },
    {
        // The three runs that produced `mood_pattern` before #175 narrowed rung 2, and in
        // each of which one of the card's two sentences was false. They are here so that
        // widening the predicate back fails this file and not only `dashboard-rules.test.ts`.
        name: "three days of low mood, sleep fine",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO], { mood: 2, sleep: 5 }),
    },
    {
        name: "three days of low sleep, mood fine",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO], { mood: 5, sleep: 2 }),
    },
    {
        name: "three days of low mood with sleep unanswered",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO], { mood: 2 }),
    },
    {
        name: "three days of severe cramps",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO], {
            mood: 5,
            sleep: 5,
            symptoms: severe("cramps"),
        }),
    },
    {
        name: "three days of low energy only",
        signals: run([TODAY, YESTERDAY, TWO_DAYS_AGO], { energy: 1, mood: 5, sleep: 5 }),
    },
    {
        name: "three days that disagree on which signal was low",
        signals: [
            entry({ localDate: TODAY, mood: 5, sleep: 2 }),
            entry({ localDate: YESTERDAY, energy: 1, mood: 5, sleep: 5 }),
            entry({ localDate: TWO_DAYS_AGO, mood: 2, sleep: 5 }),
        ],
    },
];

// ── Time, exactly as the module measures it ────────────────────────────────────────────

const shiftDays = (localDate: string, delta: number): string => {
    const [year, month, day] = localDate.split("-").map(Number);
    return new Date(Date.UTC(year!, month! - 1, day!) + delta * 86_400_000)
        .toISOString()
        .slice(0, 10);
};

const daysBetween = (from: string, to: string): number =>
    Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);

// ── The case space ─────────────────────────────────────────────────────────────────────

interface Case {
    name: string;
    input: DashboardInput;
    rules: DashboardRules;
}

/** `daysSinceLastLog` is derived rather than varied, so no case can claim she has never
 *  logged while carrying entries — the cold-start card's whole predicate. */
const lastLog = (signals: SignalEntry[]): number | null => {
    if (signals.length === 0) return null;
    const newest = signals.map((e) => e.localDate).sort().at(-1)!;
    return daysBetween(newest, TODAY);
};

const build = (over: Partial<DashboardInput>): DashboardInput => ({
    mode: "cycle",
    today: TODAY,
    now: NOW,
    cycle: NO_CYCLE,
    signals: [],
    redFlag: null,
    upcomingAppointments: [{ startAt: `${shiftDays(TODAY, 1)}T10:30:00`, type: "gp", inDays: 1 }],
    profileComplete: true,
    nutritionSetUp: true,
    todayTotals: { caloriesRemaining: 400, proteinG: 70, waterMl: 1200, activityMin: 30 },
    daysSinceLastLog: null,
    ...over,
});

const LADDER_CASES: Case[] = MODES.flatMap((mode) =>
    CYCLES.flatMap(({ name: cycleName, cycle }) =>
        HISTORIES.flatMap(({ name: historyName, signals }) =>
            RULE_SETS.map(({ name: ruleName, rules }) => ({
                name: `${mode} · ${cycleName} · ${historyName} · ${ruleName}`,
                input: build({ mode, cycle, signals, daysSinceLastLog: lastLog(signals) }),
                rules,
            })),
        ),
    ),
);

/**
 * Rung 1's cases, kept apart because a red flag wins outright: folding the flag into the
 * product above would have made four fifths of the space name the same card.
 *
 * `redFlag` is `null` in every mode until D10 supplies the mapping (and #173's
 * `gatherInput` passes `null` today), so nothing here is live — but it is reachable from
 * `selectSubject`, which is what this file walks, and D10 lands the mapping into whatever
 * this card says.
 */
const FLAG_CASES: Case[] = MODES.flatMap((mode) =>
    ["reduced-fetal-movement", "cramps"].flatMap((code) =>
        [
            { when: "today", loggedAt: `${TODAY}T08:00:00Z` },
            { when: "three days ago", loggedAt: `${THREE_DAYS_AGO}T08:00:00Z` },
        ].map(({ when, loggedAt }) => ({
            name: `${mode} · red flag ${code} raised ${when}`,
            input: build({ mode, redFlag: { code, loggedAt }, daysSinceLastLog: 0 }),
            rules: RULE_SETS[0]!.rules,
        })),
    ),
);

/**
 * The clock, because everything above is generated at 09:00 and three strings say when.
 *
 * `signal_overrides_phase` says "this morning" in its title *and* in its action label, and
 * `signals_today`'s title says "today". A single fixed `now` in the morning never produces
 * the ordinary evening — an entry made at 20:00, read at 23:30 — and never produces a card
 * whose subject is an otherwise perfectly matching log made on the wrong day. So the temporal
 * half of each was audited against nothing that could contradict it, which is how a claim
 * reads as examined while testing half its string. (`red_flag`'s "today" needs no case here:
 * `FLAG_CASES` already raises one three days back.)
 *
 * The observed window that picks the entry is 24 hours wide and knows nothing about calendar
 * days or mornings, which is the whole reason these are reachable.
 *
 * Three cases rather than a third axis on the product above: an axis would double 2,160 cases
 * to ask a question three of them answer.
 */
const EVENING = `${TODAY}T23:30:00Z`;

const eveningEntry = (over: Partial<SignalEntry>): SignalEntry => ({
    ...entry({ localDate: TODAY, ...over }),
    loggedAt: `${TODAY}T20:00:00Z`,
});

const CLOCK_CASES: Case[] = [
    {
        name: "cycle · phase follicular · logged at 20:00 and read at 23:30 · A32's dose (3 days, ≤2)",
        input: build({
            mode: "cycle",
            now: EVENING,
            cycle: estimated("follicular", 13),
            signals: [eveningEntry({ energy: 1, sleep: 2 })],
            daysSinceLastLog: 0,
        }),
        rules: RULE_SETS[0]!.rules,
    },
    {
        name: "pregnancy · no cycle data · logged at 20:00 and read at 23:30 · A32's dose (3 days, ≤2)",
        input: build({
            mode: "pregnancy",
            now: EVENING,
            signals: [eveningEntry({ energy: 1, symptoms: severe("headache") })],
            daysSinceLastLog: 0,
        }),
        rules: RULE_SETS[0]!.rules,
    },
    {
        // The canvas' own day — low energy and a headache — logged late enough last night to
        // still be the entry this morning's card is about. Everything `home_g`'s title names
        // is there; only the day is wrong, which is the half that was not audited.
        name: "pregnancy · no cycle data · low energy and a headache logged last night · A32's dose (3 days, ≤2)",
        input: build({
            mode: "pregnancy",
            signals: [
                {
                    ...entry({ localDate: YESTERDAY, energy: 1, symptoms: severe("headache") }),
                    loggedAt: `${YESTERDAY}T23:00:00Z`,
                },
            ],
            daysSinceLastLog: 1,
        }),
        rules: RULE_SETS[0]!.rules,
    },
];

const CASES: Case[] = [...LADDER_CASES, ...FLAG_CASES, ...CLOCK_CASES];

// ── The ladder's own reading of the input, mirrored ────────────────────────────────────
// `observedSignal` and `runEndingToday` are not exported, and the claims below have to ask
// the same questions of the input that the card's words do. These are deliberate copies,
// and "the mirror agrees with the ladder" below is what stops them drifting: if the mirror
// said "nothing observed" where the ladder selected an observed-data card, that case would
// fail there rather than quietly passing a claim it never evaluated.

const hasSignal = (e: SignalEntry): boolean =>
    e.energy !== null || e.mood !== null || e.sleep !== null || e.symptoms.length > 0;

const observedEntry = (input: DashboardInput): SignalEntry | null => {
    const now = Date.parse(input.now);
    const reachable = new Set([shiftDays(input.today, -1), input.today, shiftDays(input.today, 1)]);
    let latest: SignalEntry | null = null;
    let latestAt = Number.NEGATIVE_INFINITY;
    for (const e of input.signals) {
        if (!hasSignal(e) || !reachable.has(e.localDate)) continue;
        const at = Date.parse(e.loggedAt);
        if (at > now || now - at > 86_400_000) continue;
        if (at > latestAt) {
            latestAt = at;
            latest = e;
        }
    }
    return latest;
};

const runEndingToday = (input: DashboardInput, days: number): SignalEntry[] | null => {
    const out: SignalEntry[] = [];
    for (let back = 0; back < days; back += 1) {
        const date = shiftDays(input.today, -back);
        const found = input.signals.find((e) => e.localDate === date && hasSignal(e));
        if (!found) return null;
        out.push(found);
    }
    return out;
};

const doseOf = (c: Case): PatternRule => {
    const rule = c.rules.pattern;
    if (!rule) throw new Error("every case in this file carries a pattern rule");
    return rule;
};

// ── The claims ─────────────────────────────────────────────────────────────────────────

type Field = "kicker" | "title" | "line2" | "line3" | "meta" | "actions";

/** What one string asserts about her, as a predicate over the input — or `null` where the
 *  string asserts nothing about her at all. */
type Claim = { says: string; holds: (c: Case) => boolean } | null;

interface Audited {
    /** The canvas state, which is the language the acceptance criteria are written in. */
    state: string;
    /** The seeded strings, byte for byte. A copy edit fails here first. */
    copy: Partial<Record<Exclude<Field, "actions">, string>> & { actions: string[] };
    claims: Partial<Record<Field, Claim>>;
}

const observed = (c: Case): SignalEntry | null => observedEntry(c.input);

/** "Low", where the only definition of low this system has is rung 2's configured level.
 *  No card carries a number, so a card that says "low" is saying "at or below that". */
const isLow = (value: number | null, c: Case): boolean =>
    value !== null && value <= doseOf(c).lowAtOrBelow;

/**
 * **No card says "this morning" or "today" about something she logged any more**, so the two
 * helpers that measured it are gone: `loggedInTheMorning`, which read the hour off the
 * entry's own offset-bearing `loggedAt` (ISO-8601 with an offset, so the wall time in the
 * string is the time she saw it — no process timezone needed, and none available), and
 * `flagRaisedToday`, which compared the flag's date to `today`.
 *
 * They are named here rather than quietly deleted, because they are what a temporal claim
 * would be written with the next time a card says when. The two facts that made them
 * necessary both outlived the sentences that tripped over them: the window that picks the
 * entry is 24 hours wide and knows nothing about calendar days or mornings, and rung 1
 * applies no window at all.
 */

const phaseOf = (c: Case): PhaseCode | null => {
    const { cycle } = c.input;
    if (!cycle.enoughCyclesForEstimates || cycle.irregular) return null;
    if (cycle.phase === null || cycle.phase.confidence === "none") return null;
    return cycle.phase.code;
};

/** The phases a card may say energy tends to be higher in. Written down here rather than
 *  assumed, because it is the claim `home_d` and `home_e` both rest on. */
const HIGHER_ENERGY_PHASES: PhaseCode[] = ["follicular", "ovulation"];

const AUDIT: Record<TemplateId, Audited> = {
    [TEMPLATE.coldStart]: {
        state: "home_a",
        copy: {
            title: "Start with your first log",
            line2: "Log your period or today’s body signals so Eva can begin recognizing patterns that are specific to you.",
            actions: ["Log now", "Open Calendar"],
        },
        claims: {
            title: {
                says: "nothing has ever been logged",
                holds: (c) => c.input.daysSinceLastLog === null,
            },
            // An instruction and a promise about later, not a statement about her data.
            line2: null,
            actions: null,
        },
    },

    [TEMPLATE.stillLearning]: {
        state: "home_b",
        copy: {
            kicker: "Cycle tracking · {cycleCount} of 3 cycles",
            title: "Eva is still learning your cycle",
            line2: "Log more periods to help estimate your cycle phases more reliably. Until then, no phase is shown.",
            actions: ["Open Calendar"],
        },
        claims: {
            // The card names the gate; this claim can only ask C11's own answer about it.
            // Why "3" itself is not checkable here is in `NOTED`.
            kicker: {
                says: "she is short of the counted cycles C11's gate asks for, which the card says is three",
                holds: (c) => c.input.cycle.countedCycles < 3,
            },
            title: {
                says: "no phase can be estimated yet",
                holds: (c) => !c.input.cycle.enoughCyclesForEstimates,
            },
            line2: {
                // "two more" became "more", and the sentence stopped counting down from
                // one. It was selected at zero, one *and* two counted cycles, and zero is
                // the commonest of the three — `phaseRung` asks only for a known `cycleDay`,
                // which one logged period sets, while a counted cycle needs two first-flow
                // days. So the card asked for two more when she needed three.
                //
                // **The number is not recoverable here**, which is why the sentence carries
                // none. It would have to be `minCyclesForEstimate − countedCycles`, and C11
                // hands this module its *answer* to the gate and never the gate — see
                // `NOTED` on this card's kicker, which hard-codes the same number for the
                // same reason. Nothing in `SubjectSlots` can reach a remainder, so the
                // sentence asks for "more" and the claim checks both halves of what it says:
                // that periods are the thing still missing, and that no phase is being shown
                // meanwhile. Deliberately not the title's predicate alone — a claim that only
                // repeated the line above would leave the half about *periods* unexamined.
                says: "she is short of the counted cycles the gate asks for, and no phase is being estimated meanwhile",
                holds: (c) =>
                    c.input.cycle.countedCycles < 3 && !c.input.cycle.enoughCyclesForEstimates,
            },
            actions: null,
        },
    },

    [TEMPLATE.irregular]: {
        state: "home_c",
        copy: {
            kicker: "Cycle tracking",
            title: "Your current phase cannot be estimated reliably",
            line2: "Your recent cycle lengths vary significantly, so Eva will not show a confident prediction.",
            actions: ["View cycle history"],
        },
        claims: {
            kicker: null,
            title: { says: "no phase is speakable", holds: (c) => phaseOf(c) === null },
            line2: {
                says: "C11's irregularity flag is set",
                holds: (c) => c.input.cycle.irregular,
            },
            actions: null,
        },
    },

    [TEMPLATE.phaseEnergy]: {
        state: "home_d",
        copy: {
            kicker: "Cycle day {cycleDay} · likely approaching ovulation",
            title: "Many women notice higher energy around now",
            line2: "This is a tendency across cycles, not a prediction about your day.",
            line3: "If that matches how you feel, a harder training session may be an option.",
            actions: ["View cycle details"],
        },
        claims: {
            kicker: {
                says: "the estimated phase is the approach to ovulation",
                holds: (c) => phaseOf(c) === "follicular",
            },
            title: {
                says: "the estimated phase is one energy tends to be higher in",
                holds: (c) => HIGHER_ENERGY_PHASES.includes(phaseOf(c)!),
            },
            // The card's own disclaimer: it says the line above is a tendency rather than
            // a claim about her day, which is why the title is audited as a tendency.
            line2: null,
            // "If that matches how you feel" — conditional on the sentence above, and
            // withdrawn by its own wording when that one does not apply.
            line3: null,
            actions: null,
        },
    },

    [TEMPLATE.signalOverridesPhase]: {
        state: "home_e",
        copy: {
            kicker: "Cycle day {cycleDay}",
            title: "Eva is reading what you logged, not what the phase predicts",
            line2: "Your phase is context for what you reported, not a substitute for it.",
            line3: "Sleep, stress and iron affect daily energy more than cycle phase.",
            actions: ["Review what I logged"],
        },
        claims: {
            kicker: null,
            title: {
                // **It names no signal and no clock, and neither was fixable by naming them
                // better.** The old title asserted a low energy rating, a low sleep rating
                // and a morning; the rung selects this card for *any* observed entry in
                // cycle mode with a speakable phase, so severe cramps with ratings of 5 got
                // it too. A `{signal}` slot is not the escape: `dashboard-rules.ts` holds
                // symptom *codes* and never words by design, `SLOTS` has no key that takes
                // one, and the phraser only substitutes what the subject already carries —
                // so nothing in this system can turn a rating of 1 into "low energy". And
                // the window that picked the entry is 24 hours wide, so "this morning" was
                // false for anything logged the previous evening.
                //
                // What is left is the two facts the rung itself guarantees, which is a
                // duller card than the canvas drew. The card that names what she logged
                // needs a reviewed phrase vocabulary — codes and rating bands to words —
                // and that is a slice, not a copy edit.
                says: "she logged something inside the observed window, and a phase Eva could have spoken from is not what the card is speaking from",
                holds: (c) => observed(c) !== null && phaseOf(c) !== null,
            },
            line2: {
                // PRD §Dashboard's own sentence for this card — "The phase is context for
                // what she reported; it is not a substitute for it" — which is true in every
                // phase. "energy can be higher around this phase" was true in two of four,
                // and read as a contrast with a tendency that was not there in the other two.
                says: "a phase estimate exists to be context",
                holds: (c) => phaseOf(c) !== null,
            },
            // A general statement about physiology. Its second sentence went with the
            // title: "A lighter session may feel more manageable today" was offered to
            // whatever she logged, ratings of 5 included, which is the same untargeted rest
            // advice `NOTED` recorded against `home_g`'s line2 and which that card has now
            // also dropped.
            line3: null,
            // `home_g`'s label, which the canvas draws and which names no clock. The old one
            // said "this morning" about the same 24-hour window the title did, and was
            // audited on the day alone for the same reason the title was.
            actions: null,
        },
    },

    [TEMPLATE.latePeriod]: {
        state: "home_f",
        copy: {
            kicker: "Cycle day {cycleDay}",
            title: "Your period is later than predicted",
            line2: "Eva cannot determine the reason from cycle data alone.",
            actions: ["Log period", "Log test"],
        },
        claims: {
            kicker: null,
            title: {
                says: "the predicted first flow day has passed",
                holds: (c) => (c.input.cycle.daysPastPredictedPeriod ?? 0) > 0,
            },
            line2: null,
            actions: null,
        },
    },

    [TEMPLATE.signalsToday]: {
        state: "home_g",
        copy: {
            kicker: "Logged · last 24 hours",
            title: "Your own log comes first",
            line2: "Eva can see what you logged but not what caused it.",
            actions: ["Review what I logged"],
        },
        claims: {
            kicker: {
                // The PRD's own window — "If the user has logged body signals in the last 24
                // hours…" — which is the one this rung actually applies. "Logged today" was
                // false for the entry made at 23:00 last night that the window still holds,
                // and the fixture that demonstrated it is still in `HISTORIES`.
                says: "a body signal was logged inside the observed 24-hour window",
                holds: (c) => observed(c) !== null,
            },
            title: {
                // **#177's headline case, and it names nothing on purpose.** Every logged
                // day in the four non-cycle modes reaches this card, as do severe-symptom,
                // low-energy-only and low-mood runs in cycle mode — so "low energy and a
                // headache" was false in 1,351 of the 1,460 cases that render it. The only
                // things true of all of them are that she logged, and that this card leads
                // with it rather than with a phase. Same slot wall as `home_e`'s title.
                says: "she logged something, and it is what this card is about",
                holds: (c) => observed(c) !== null,
            },
            // `home_h`'s "Eva can see the pattern but not its cause", in the singular: a
            // statement of Eva's limits, not a claim about her. It replaces "a slower pace
            // or additional rest may feel more appropriate", which claimed nothing either —
            // and was offered to a pregnant user who logged energy 5 and sleep 5, which is
            // why `NOTED` carried it. That entry is gone with the sentence.
            line2: null,
            actions: null,
        },
    },

    [TEMPLATE.moodPattern]: {
        state: "home_h",
        copy: {
            kicker: "Pattern · last 3 days",
            title: "You’ve logged low mood for three consecutive days",
            line2: "Sleep has also been below your usual level during the same period. Eva can see the pattern but not its cause.",
            line3: "Consider checking in with yourself, or talking it through with someone you trust.",
            actions: ["View pattern"],
        },
        claims: {
            kicker: {
                says: "the run the rule matched is three days long",
                holds: (c) => doseOf(c).lowSignalDays === 3,
            },
            title: {
                says: "mood was low on three consecutive logged days ending today",
                holds: (c) => {
                    const days = runEndingToday(c.input, 3);
                    return (
                        doseOf(c).lowSignalDays === 3 &&
                        days !== null &&
                        days.every((e) => isLow(e.mood, c))
                    );
                },
            },
            line2: {
                says: "sleep was low on every day of that same run",
                holds: (c) => {
                    const days = runEndingToday(c.input, doseOf(c).lowSignalDays);
                    return days !== null && days.every((e) => isLow(e.sleep, c));
                },
            },
            line3: null,
            actions: null,
        },
    },

    [TEMPLATE.educational]: {
        state: "home_edu",
        copy: {
            kicker: "Today’s read",
            title: "Why sleep can affect appetite more than willpower",
            line2: "Educational content, not personalized insight — no new body signals in the last 24 hours.",
            meta: "{category} · {readMinutes} min read",
            actions: ["Read article"],
        },
        claims: {
            kicker: null,
            // An article's headline. It says nothing about her, so there is nothing here to
            // be false — but "nothing to be false" is not "nothing to read": see `NOTED`.
            title: null,
            // **The sentence now says what this module can see.** "nothing new in your logs
            // today" was a claim about logs of every kind, and `signals` is body signals
            // only — `SignalEntry`'s own doc says so ("This is the only logged-data input,
            // and it is body signals only"): cycle, sport, meals, appointments and sex never
            // reach here. So a day whose only entry was a run, a meal, a period or an
            // appointment was told there was nothing new in her logs. `daysSinceLastLog`
            // does see them, and no sentence here can be true of a number this card cannot
            // read — the fixture that demonstrated it reached this card through a sheet
            // opened and not saved, which is the same input by the same route.
            //
            // The narrowing is the repo's own reading: the `logging_gap` nudge says "any
            // body signals" where it means body signals, and this card now does too.
            //
            // It is a *guarantee*, not a likelihood: rung 2 returns `signals_today` for any
            // observed entry, so reaching rung 6 at all means `observedSignal` found none.
            // "the mirror of the ladder's observed-data rule agrees with the ladder" below
            // is what holds that true rather than this claim assuming it.
            line2: {
                says: "no body signal was logged inside the observed 24-hour window",
                holds: (c) => observed(c) === null,
            },
            meta: null,
            actions: null,
        },
    },

    [TEMPLATE.redFlag]: {
        state: "home_flag",
        copy: {
            kicker: "Logged {loggedAt}",
            title: "You logged a symptom that needs medical attention",
            line2: "Contact your provider or a local urgent care service for guidance. Eva cannot assess this.",
            actions: ["View contact options", "Review what I logged"],
        },
        claims: {
            kicker: {
                // "today" is gone, because rung 1 applies no window: it fires on whatever
                // `loggedAt` the caller passes, and it is evaluated before any time input is
                // parsed on purpose — an escalation must not be suppressed by a problem, or
                // a date, below it. So the card states the time it was given and claims
                // nothing about which day that was.
                says: "the time named is the time the flag carries",
                holds: (c) => c.input.redFlag !== null,
            },
            // **The title asserted two things and now asserts neither, which is the whole
            // reason this row could be retired at all.** The code is not recoverable here:
            // `RedFlagSignal` carries a `refdata/` code, `dashboard-rules.ts` holds codes and
            // never labels by design ("the words are the client's"), and no key in `SLOTS`
            // takes a symptom — so "reduced fetal movement" was the one flag D10 might map,
            // rendered for every flag it maps. The labels do exist, on `refdata.ts`'s
            // `SymptomItem`, and nothing carries one toward a subject; wiring that is D3 plus
            // a field on `RedFlagSignal` plus a new slot, and it belongs with D10's mapping.
            // The day was never audited at all.
            //
            // **So the trapdoor named here before is still open, from the other side.** When
            // D10 draws a card per code, the sentence that replaces this one must be audited
            // for its day as well as its symptom, or a flag raised three days ago renders as
            // "today" on the one card with real clinical weight, with the ledger green.
            title: {
                says: "a red flag was raised",
                holds: (c) => c.input.redFlag !== null,
            },
            // An instruction, and now the same instruction in every mode. It named a
            // maternity provider while rung 1 fires in all five — `redFlagRung` has no mode
            // gate, deliberately, because "always wins" has no mode in it. "your provider" is
            // DESIGN §8's neutral role, which is correct in cycle, planning, pregnancy,
            // postpartum and loss alike.
            line2: null,
            actions: null,
        },
    },
};

// ── The ledger ─────────────────────────────────────────────────────────────────────────

interface KnownUntrue {
    template: TemplateId;
    field: Field;
    /**
     * Fragments of case names that demonstrate it — **one per distinct way the string is
     * untrue**. A sentence that asserts two things ("You logged reduced fetal movement
     * *today*") needs a case for each, so that fixing one half cannot leave the other
     * unwatched: that is how a row gets deleted, the claim rewritten in the same shape, and
     * the remaining falsehood shipped green.
     *
     * Every fragment is asserted, so the fixture proving a mismatch cannot quietly disappear.
     */
    examples: string[];
    /** What the canvas would have to draw. Not a suggested sentence — #177: where the
     *  canvas has not drawn a card, the honest output is a request, not an invention. */
    canvasMustDraw: string;
}

/**
 * **Every mismatch this audit can demonstrate.** Two, where this list held fourteen when it
 * was written and twelve after #184 narrowed rung 4.
 *
 * `api/scripts/seed-content.ts` is a transcription of `docs/design/Eva App.dc.html`, and
 * `content.test.ts`'s "every string the seed ships is the canvas' string" enforces that
 * mechanically, fragment by fragment. So closing a line below means the canvas draws the
 * variant first, and that is what happened: ten rows came off this list because `CARDS` now
 * draws `home_b`, `home_e`, `home_g`, `home_edu` and `home_flag` in words that are true of
 * everyone the ladder routes to them. The claims above each say what moved and what it cost.
 *
 * **Two of those closed by saying less rather than by saying it accurately**, and they are
 * the ones to re-read rather than the ones left below: `home_e`'s and `home_g`'s titles both
 * stopped naming what she logged, because nothing in this system can turn a rating of 1 into
 * the words "low energy". The slot route — `'You logged {signal} today'` — is a boundary
 * rather than a preference: `dashboard-rules.ts` contains no text by design and holds symptom
 * *codes*, never labels, so nothing in the ladder can produce those words; #173's
 * `TemplatePhraser` only substitutes slot values the subject already carries, and a title
 * with an unfilled slot is a refusal — so a slot nobody fills turns card G from a card that
 * is sometimes wrong into a card that never renders. Giving those two cards their content
 * back means a reviewed vocabulary from codes and rating bands to words, which is a slice.
 *
 * ## The two that remain are not a canvas question
 *
 * Both are `mood_pattern`'s, both are the same mismatch, and **neither is fixable by drawing
 * anything**: the card names a number that is configuration. They are left here deliberately.
 * Closing them needs either a `patternDays` slot — an entry in `SLOTS` and a line in
 * `patternRung` — or #26 fixing `lowSignalDays` at three, and both are rule changes. The
 * PR that retired the other ten is a signature on *words*; mixing a rules change into it
 * would make what is being signed less clear. Nothing in the copy above depends on them.
 *
 * ## This is a ledger, not a gate — read this before trusting a green run
 *
 * The three ways this file goes red are all about **the list changing**: a mismatch appears,
 * a mismatch is fixed, or a string is edited. It is **silent when a mismatch already on the
 * list becomes reachable by real users.** Nothing below records how often a row fires, or
 * whether the rung that selects it is live at all — so a routing change that takes a row from
 * "reachable in principle" to "the card most users see" passes here without a word.
 *
 * That is not hypothetical. It is exactly the transition #179 performs, and #184 exists to
 * gate it *because this file cannot*. A row here means somebody looked and wrote down what is
 * wrong with the sentence. It does not mean anyone is being protected from it.
 */
const UNTRUE: KnownUntrue[] = [
    // `still_learning.line2`, `signal_overrides_phase`'s title, line2 and actions,
    // `signals_today`'s kicker and title, `educational.line2` and all three `red_flag` rows
    // stood here. The canvas drew every one of them and the seed follows it, so they are
    // deleted in the same change that made their sentences true — the second of this file's
    // three failure modes, spent on purpose. `phase_energy`'s two went one commit earlier,
    // to #184, by narrowing the rung instead.
    {
        template: TEMPLATE.moodPattern,
        field: "kicker",
        examples: ["four-day dose"],
        canvasMustDraw:
            "home_h's kicker as a slot, or #26 fixing lowSignalDays at three — the card says '3 days' and the dose is configuration. **Not a drawing, despite the field name**: no sentence the canvas can draw is true at every dose `requirePatternRule` accepts, because it accepts 1 (where 'consecutive days' is false) and has no ceiling (where 'the last few days' is). Deliberately left on this list by the PR that closed the other ten, which changed words only.",
    },
    {
        template: TEMPLATE.moodPattern,
        field: "title",
        examples: ["four-day dose"],
        canvasMustDraw:
            "home_h's sentence as a slot, for the same reason as its kicker, and with the same caveat. At A32's own dose of three the sentence is true — which is why this ships: `DASHBOARD_PATTERN_LOW_SIGNAL_DAYS` is what decides whether it is, and nothing enforces that it is three.",
    },
];

/**
 * **What a signer must read that this audit cannot demonstrate.**
 *
 * `UNTRUE` is bounded by what `DashboardInput` can express: a row gets in only when some
 * generated case renders the string and the claim comes back false. A sentence whose problem
 * lies outside that shape — one that implies data the input has no field for, or that is
 * advice rather than an assertion — can never produce a row, and keeping it out is right.
 * Leaving it *unwritten* is not. The seed's signature says "these words, this ladder, these
 * known gaps, and no others", and a PR body is not in the repo; in six months this file is
 * where someone will look.
 *
 * So this is the other half of the same list, and `seed-content.ts` points at both.
 */
interface Noted {
    template: TemplateId;
    field: Field;
    /** Why no generated input can falsify it, and what a reader should do with that. */
    note: string;
}

const NOTED: Noted[] = [
    {
        template: TEMPLATE.moodPattern,
        field: "line2",
        note: "'Sleep has also been below your usual level' implies a personal baseline. Rung 2 holds none: `lowAtOrBelow` is an absolute threshold, the same number for every user, so 'your usual level' names data the rule does not have. Nothing can demonstrate it — the checkable claim is 'sleep was low on every day of the run', and that is true wherever the card is selected. A wording question for whoever draws the slotted home_h.",
    },
    {
        template: TEMPLATE.stillLearning,
        field: "kicker",
        note: "'{cycleCount} of 3 cycles' hard-codes the gate it is counting towards, and `dashboard-rules.ts` is explicit that it holds C11's *answer* and never the number ('A11 routed that constant to #26 and C11 reads it from configuration'). Since #181 it is literally `CYCLE_MIN_CYCLES_FOR_ESTIMATE`, an env var an operator can set to anything. This is the same mismatch as `mood_pattern`'s kicker, which is in `UNTRUE` — the only difference is where the number lives: `lowSignalDays` arrives inside `DashboardRules`, so `RULE_SETS` can vary it and demonstrate the gap, while `minCyclesForEstimate` never reaches this module at all, so no generated input can falsify the '3'. home_b's canvas request should carry the count as a slot, the way home_h's kicker does.",
    },
    {
        template: TEMPLATE.educational,
        field: "title",
        note: "A fixed article headline over a link nobody has wired: no slice chooses the article (D7), so every user reads the same one under 'Today's read'. It asserts nothing about her and cannot fail a claim — but 'Why sleep can affect appetite more than willpower', shown to someone who has never logged sleep, is a state rather than an insight.",
    },
];

/** The four templates the ladder cannot select today, with the slice that will. When D10
 *  lands, `selectSubject` starts returning them and the coverage case below turns red,
 *  which is the point: the audit has to grow with the ladder. */
const OUT_OF_REACH: Record<string, string> = {
    planning_window: "D10 — planning mode's fertile-window rung",
    pregnancy_appointment: "D10 — rung 3, the milestone rung, returns null unconditionally",
    postpartum_check: "D10 — rung 3",
    loss_ended: "D10 — rung 3",
};

// ── Running it ─────────────────────────────────────────────────────────────────────────

const fieldOf = (template: Template, field: Field): string | undefined =>
    field === "actions" ? template.actions.join(" · ") : template[field];

const FIELDS: Field[] = ["kicker", "title", "line2", "line3", "meta", "actions"];

let TEMPLATES: Template[] = [];
let byId = new Map<string, Template>();
/** #173's own `TemplatePhraser`, not a copy of it — see `beforeAll`. */
let phraser: Phraser;

interface Walked {
    case: Case;
    subject: Subject;
    /** What `byId` holds for the subject's id. Guarded below against what the phraser
     *  actually selected, which is a narrower question. */
    template: Template;
    /** Fields that rendered, i.e. carried no unfilled slot. */
    rendered: Field[];
}

let WALK: Walked[] = [];
/** `templateId.field` → the names of the cases whose input does not bear the claim out. */
let FAILURES = new Map<string, string[]>();

beforeAll(async () => {
    // Imported here, not at the top of the file: the seed pulls in `content.ts`, and `today.ts`
    // pulls in `config.ts` and the Admin SDK. Same reason `dashboard-rules.test.ts` does it
    // this way, and the types both files need are `import type`, which is erased.
    TEMPLATES = (await import("../scripts/seed-content")).TEMPLATES;
    byId = new Map(TEMPLATES.map((t) => [t.id, t]));
    // **#173's phraser, not a re-implementation of it.** This file used to carry its own
    // `fill` — the slot semantics matched, but a copy of the thing under audit is one edit
    // away from auditing something nobody ships. `TemplatePhraser` also filters on
    // confidence, which the copy did not; the case below is what says the two agree.
    phraser = new (await import("../src/today")).TemplatePhraser();

    WALK = CASES.map((c) => {
        const subject = selectSubject(c.input, c.rules);
        const template = byId.get(subject.templateId);
        if (!template) throw new Error(`the seed has no template ${subject.templateId}`);
        // Whatever the phraser leaves out did not render: an unfilled slot removes its line,
        // and a title with one is a `TemplateUnavailableError` rather than a card.
        const text = phraser.phrase(subject, TEMPLATES);
        const rendered = FIELDS.filter((field) =>
            field === "actions" ? text.actions.length > 0 : text[field] !== undefined,
        );
        return { case: c, subject, template, rendered };
    });

    FAILURES = new Map();
    for (const step of WALK) {
        const audited = AUDIT[step.subject.templateId];
        for (const field of step.rendered) {
            const claim = audited.claims[field];
            if (!claim || claim.holds(step.case)) continue;
            const key = `${step.subject.templateId}.${field}`;
            FAILURES.set(key, [...(FAILURES.get(key) ?? []), step.case.name]);
        }
    }
});

describe("the copy audit walks every subject the ladder can select", () => {
    test("it reaches all ten of them, and the four it cannot are named", () => {
        const reached = [...new Set(WALK.map((s) => s.subject.templateId))].sort();
        expect(reached).toEqual(Object.values(TEMPLATE).slice().sort());
        // And the seed's other four are out of reach for a reason that is written down,
        // rather than for one nobody noticed.
        const seeded = TEMPLATES.map((t) => t.id).sort();
        expect(seeded).toEqual([...reached, ...Object.keys(OUT_OF_REACH)].sort());
    });

    test("and the space it walks is wide enough to have found them", () => {
        // A floor would let the fixture table be gutted without a signal, which is the
        // quiet way an audit stops auditing. Exact, like the seed's fragment count.
        expect(LADDER_CASES).toHaveLength(MODES.length * CYCLES.length * HISTORIES.length * 2);
        expect(CASES).toHaveLength(2183); // 2,160 from the product, 20 red-flag, 3 clock

        // Every mode reaches a card, every phase code reaches rung 4's decision, and every
        // history reaches something — the three axes the mismatches below turn on.
        for (const mode of MODES) {
            expect(WALK.some((s) => s.case.input.mode === mode)).toBe(true);
        }
        // Rung 4 gives the phase card to the one phase its words are true of and lets the
        // other three fall through to the fallback (#184). Both halves are pinned, and the
        // second is the one that matters here: a re-widened rung is only a *new* mismatch in
        // this file if the cases that would expose it are still walked into rung 4 in cycle
        // mode. The filter is cycle mode because every other mode reaches the fallback with
        // all four phases, follicular included.
        const speakablePhasesAt = (templateId: TemplateId): PhaseCode[] =>
            [
                ...new Set(
                    WALK.filter(
                        (s) => s.case.input.mode === "cycle" && s.subject.templateId === templateId,
                    ).map((s) => phaseOf(s.case)),
                ),
            ]
                .filter((code): code is PhaseCode => code !== null)
                .sort();
        expect(speakablePhasesAt(TEMPLATE.phaseEnergy)).toEqual(["follicular"]);
        expect(speakablePhasesAt(TEMPLATE.educational)).toEqual([
            "luteal",
            "menstrual",
            "ovulation",
        ]);
        const histories = new Set(WALK.map((s) => s.case.name.split(" · ")[2]));
        // +3: the red-flag cases carry no history segment at all, and the clock cases carry
        // two between them (the evening pair share one).
        expect(histories.size).toBe(HISTORIES.length + 3);

        // And the clock, whose three cases exist to strain a temporal claim each. Which card
        // each reaches is pinned: a routing change that sent them elsewhere would leave the
        // temporal half of three sentences unexercised again, and fail nothing.
        expect(
            CLOCK_CASES.map((c) => WALK.find((s) => s.case === c)!.subject.templateId),
        ).toEqual([TEMPLATE.signalOverridesPhase, TEMPLATE.signalsToday, TEMPLATE.signalsToday]);
        expect(WALK.filter((s) => s.case.input.now === EVENING)).toHaveLength(2);
    });

    test("and it renders through #173's phraser, so `byId` is not a looser lookup", () => {
        // `byId` keys on the template id alone. `TemplatePhraser` requires the id, `active`
        // status *and* a confidence equal to the subject's, then takes the lowest `order`.
        // Every reachable id agrees today; this is what says so, rather than the shortcut
        // quietly being right — the same guard `observedEntry` gets above.
        for (const step of WALK) {
            const candidates = TEMPLATES.filter(
                (t) => t.id === step.subject.templateId && t.status === "active",
            );
            expect(`${step.subject.templateId}: ${candidates.length} active`).toBe(
                `${step.subject.templateId}: 1 active`,
            );
            expect(`${step.subject.templateId}: ${candidates[0]!.confidence}`).toBe(
                `${step.subject.templateId}: ${step.subject.confidence}`,
            );
            expect(step.template).toBe(candidates[0]!);
        }
    });

    test("the mirror of the ladder's observed-data rule agrees with the ladder", () => {
        // `observedEntry` above is a copy of a function `dashboard-rules.ts` does not
        // export, and the claims rest on it. If it drifted, those claims would be asking
        // the wrong question — so it is checked against the ladder's own choice.
        for (const step of WALK) {
            const observedHere = observedEntry(step.case.input) !== null;
            if (
                step.subject.templateId === TEMPLATE.signalsToday ||
                step.subject.templateId === TEMPLATE.signalOverridesPhase
            ) {
                expect(observedHere).toBe(true);
            }
            if (step.subject.templateId === TEMPLATE.educational) {
                expect(observedHere).toBe(false);
            }
        }
    });
});

describe("the copy that was audited is the copy that ships", () => {
    test("every audited string matches the seed byte for byte", () => {
        for (const [id, audited] of Object.entries(AUDIT)) {
            const template = byId.get(id);
            expect(template).toBeDefined();
            expect(template!.state).toBe(audited.state);
            expect(template!.actions).toEqual(audited.copy.actions);
            for (const field of ["kicker", "title", "line2", "line3", "meta"] as const) {
                expect(`${id}.${field}: ${template![field] ?? "—"}`).toBe(
                    `${id}.${field}: ${audited.copy[field] ?? "—"}`,
                );
            }
        }
    });

    test("every string that renders has been looked at, and nothing is looked at twice", () => {
        // The hole a claim table has is the string nobody wrote a claim for: it renders,
        // asserts something, and the audit is silent. So a rendered field with no entry —
        // not even an explicit `null` — is a failure.
        for (const step of WALK) {
            const claims = AUDIT[step.subject.templateId].claims;
            for (const field of step.rendered) {
                expect(
                    `${step.subject.templateId}.${field} ${field in claims ? "examined" : "NOT examined"}`,
                ).toBe(`${step.subject.templateId}.${field} examined`);
            }
        }
        // And the reverse: a claim about a string the seed no longer has.
        for (const [id, audited] of Object.entries(AUDIT)) {
            const template = byId.get(id)!;
            for (const field of Object.keys(audited.claims) as Field[]) {
                expect(fieldOf(template, field)).toBeDefined();
            }
        }
    });

    test("home_edu's meta never renders, because no slice chooses the article", () => {
        const edu = WALK.filter((s) => s.subject.templateId === TEMPLATE.educational);
        expect(edu.length).toBeGreaterThan(0);
        for (const step of edu) expect(step.rendered).not.toContain("meta");
        // The claim table would otherwise be checking a string no user ever sees.
        expect(byId.get(TEMPLATE.educational)!.meta).toContain("{category}");
    });
});

describe("no card asserts something the input did not contain", () => {
    test("the mismatches the audit finds are exactly the ones the canvas owes", () => {
        const found = [...FAILURES.keys()].sort();
        const declared = UNTRUE.map((u) => `${u.template}.${u.field}`).sort();
        // Read a diff here as: a line only in `found` is a new mismatch — a copy edit or a
        // widened subject — and a line only in `declared` is one that has been fixed, so
        // the entry comes out of `UNTRUE` in the same change.
        expect(found).toEqual(declared);
    });

    test("and the notes beside it still name strings the seed ships", () => {
        // `NOTED` is prose and cannot be checked for truth. Two things can be: that a note has
        // not outlived the sentence it is about, and that nothing demonstrable was filed there
        // instead of in `UNTRUE` — which would be a mismatch downgraded to a comment.
        expect(NOTED.length).toBeGreaterThan(0);
        const ledgered = new Set(UNTRUE.map((u) => `${u.template}.${u.field}`));
        for (const n of NOTED) {
            const key = `${n.template}.${n.field}`;
            const template = byId.get(n.template);
            expect(template).toBeDefined();
            expect(`${key}: ${fieldOf(template!, n.field) !== undefined}`).toBe(`${key}: true`);
            expect(`${key} examined: ${n.field in AUDIT[n.template].claims}`).toBe(
                `${key} examined: true`,
            );
            expect(`${key} in UNTRUE: ${ledgered.has(key)}`).toBe(`${key} in UNTRUE: false`);
        }
    });

    test("each one is demonstrated by a case, so the fixture proving it cannot vanish", () => {
        for (const u of UNTRUE) {
            const names = FAILURES.get(`${u.template}.${u.field}`) ?? [];
            // Every fragment, not just one: a string that is untrue two ways has to stay
            // demonstrated both ways, or fixing the easy half silently retires the hard one.
            expect(u.examples.length).toBeGreaterThan(0);
            for (const example of u.examples) {
                expect(
                    `${u.template}.${u.field} ← ${names.some((n) => n.includes(example)) ? example : names.slice(0, 3).join(" | ")}`,
                ).toBe(`${u.template}.${u.field} ← ${example}`);
            }
        }
    });

    test("and every other claim holds for every case that reaches it", () => {
        // The positive half, stated separately so a green run says what it covered: each
        // string not in `UNTRUE` was evaluated against every input that renders it.
        const checked: string[] = [];
        for (const step of WALK) {
            const audited = AUDIT[step.subject.templateId];
            for (const field of step.rendered) {
                const claim = audited.claims[field];
                if (!claim) continue;
                const key = `${step.subject.templateId}.${field}`;
                if (FAILURES.has(key)) continue;
                expect(`${key}: ${claim.holds(step.case)}`).toBe(`${key}: true`);
                checked.push(key);
            }
        }
        // Every claim not in the ledger was actually exercised — an unreachable claim is
        // not a passing one.
        const exercised = new Set(checked);
        const all = Object.entries(AUDIT).flatMap(([id, audited]) =>
            (Object.entries(audited.claims) as [Field, Claim][])
                .filter(([, claim]) => claim !== null)
                .map(([field]) => `${id}.${field}`),
        );
        expect(all.filter((key) => !exercised.has(key)).sort()).toEqual(
            UNTRUE.map((u) => `${u.template}.${u.field}`).sort(),
        );
    });
});

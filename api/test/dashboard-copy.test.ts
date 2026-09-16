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
    type SubjectSlots,
    type TemplateId,
} from "../src/dashboard-rules";
import type { Slot, Template } from "../src/content";

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

const CASES: Case[] = [...LADDER_CASES, ...FLAG_CASES];

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
            line2: "Log two more periods to help estimate your cycle phases more reliably. Until then, no phase is shown.",
            actions: ["Open Calendar"],
        },
        claims: {
            kicker: {
                says: "she is short of the three counted cycles C11's gate asks for",
                holds: (c) => c.input.cycle.countedCycles < 3,
            },
            title: {
                says: "no phase can be estimated yet",
                holds: (c) => !c.input.cycle.enoughCyclesForEstimates,
            },
            line2: {
                says: "exactly two more periods are needed — she has logged one cycle",
                holds: (c) => c.input.cycle.countedCycles === 1,
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
            title: "You logged low energy this morning after a poor night’s sleep",
            line2: "Although energy can be higher around this phase, your own log comes first.",
            line3: "Sleep, stress and iron affect daily energy more than cycle phase. A lighter session may feel more manageable today.",
            actions: ["Review this morning’s log"],
        },
        claims: {
            kicker: null,
            title: {
                says: "the entry the card is about carries a low energy rating and a low sleep rating, logged today",
                holds: (c) => {
                    const e = observed(c);
                    return (
                        e !== null &&
                        isLow(e.energy, c) &&
                        isLow(e.sleep, c) &&
                        e.localDate === c.input.today
                    );
                },
            },
            line2: {
                says: "the estimated phase is one energy tends to be higher in",
                holds: (c) => HIGHER_ENERGY_PHASES.includes(phaseOf(c)!),
            },
            // A general statement about physiology plus a suggestion in "may" — neither is
            // a claim about what she logged.
            line3: null,
            actions: {
                says: "the entry the card is about was logged today",
                holds: (c) => observed(c)?.localDate === c.input.today,
            },
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
            kicker: "Logged today",
            title: "You logged low energy and a headache today",
            line2: "A slower pace or additional rest may feel more appropriate.",
            actions: ["Review what I logged"],
        },
        claims: {
            kicker: {
                says: "the entry the card is about was logged today",
                holds: (c) => observed(c)?.localDate === c.input.today,
            },
            title: {
                says: "the entry the card is about carries a low energy rating and a headache",
                holds: (c) => {
                    const e = observed(c);
                    return (
                        e !== null &&
                        isLow(e.energy, c) &&
                        e.symptoms.some((s) => s.code === "headache")
                    );
                },
            },
            // "may feel more appropriate" — offered, not asserted.
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
            line2: "Educational content, not personalized insight — nothing new in your logs today.",
            meta: "{category} · {readMinutes} min read",
            actions: ["Read article"],
        },
        claims: {
            kicker: null,
            // An article's headline. It says nothing about her — but no slice chooses the
            // article, so today it is a fixed headline over a link nobody has wired (D7).
            title: null,
            line2: {
                says: "nothing was logged today",
                holds: (c) =>
                    !c.input.signals.some((e) => e.localDate === c.input.today && hasSignal(e)),
            },
            meta: null,
            actions: null,
        },
    },

    [TEMPLATE.redFlag]: {
        state: "home_flag",
        copy: {
            kicker: "Logged {loggedAt} today",
            title: "You logged reduced fetal movement today",
            line2: "Contact your maternity provider or local urgent care service for guidance. Eva cannot assess this.",
            actions: ["View contact options", "Review what I logged"],
        },
        claims: {
            kicker: {
                says: "the flag was raised today",
                holds: (c) => c.input.redFlag?.loggedAt.startsWith(c.input.today) === true,
            },
            title: {
                says: "the flag is reduced fetal movement",
                holds: (c) => c.input.redFlag?.code === "reduced-fetal-movement",
            },
            line2: {
                says: "a maternity provider is the person to contact — she is pregnant",
                holds: (c) => c.input.mode === "pregnancy",
            },
            actions: null,
        },
    },
};

// ── The ledger ─────────────────────────────────────────────────────────────────────────

interface KnownUntrue {
    template: TemplateId;
    field: Field;
    /** A fragment of a case name that demonstrates it. Asserted, so the fixture that
     *  proves the mismatch cannot quietly disappear. */
    example: string;
    /** What the canvas would have to draw. Not a suggested sentence — #177: where the
     *  canvas has not drawn a card, the honest output is a request, not an invention. */
    canvasMustDraw: string;
}

/**
 * **Every mismatch this audit can demonstrate, and none of it is fixable in a seed file.**
 *
 * `api/scripts/seed-content.ts` is a transcription of `docs/design/Eva App.dc.html`, and
 * `content.test.ts`'s "every string the seed ships is the canvas' string" enforces that
 * mechanically, fragment by fragment. So closing any line below means the canvas draws the
 * variant first. The PR that adds this file carries the request; each entry names what it
 * asks for.
 *
 * The slot route — `'You logged {signal} today'` — is not available either, and the reason
 * is a boundary rather than a preference: `dashboard-rules.ts` contains no text by design
 * and holds symptom *codes*, never labels, so nothing in the ladder can produce the words
 * "low energy"; #173's `TemplatePhraser` only substitutes slot values the subject already
 * carries, and a title with an unfilled slot is a refusal — so a slot nobody fills turns
 * card G from a card that is sometimes wrong into a card that never renders.
 */
const UNTRUE: KnownUntrue[] = [
    {
        template: TEMPLATE.stillLearning,
        field: "line2",
        example: "2 counted cycles",
        canvasMustDraw:
            "home_b at two counted cycles — the card counts down from one ('Log two more periods') and the ladder selects it at one *or* two.",
    },
    {
        template: TEMPLATE.phaseEnergy,
        field: "kicker",
        example: "phase luteal",
        canvasMustDraw:
            "home_d for the phases other than the approach to ovulation — the kicker names one phase and the ladder selects the card for all four.",
    },
    {
        template: TEMPLATE.phaseEnergy,
        field: "title",
        example: "phase menstrual",
        canvasMustDraw:
            "home_d's tendency line for the menstrual and luteal phases, where 'higher energy around now' is the opposite of the tendency.",
    },
    {
        template: TEMPLATE.signalOverridesPhase,
        field: "title",
        example: "severe cramps only",
        canvasMustDraw:
            "home_e for a logged day that is not low energy plus poor sleep — a symptom alone, a mood alone, or ratings that are fine.",
    },
    {
        template: TEMPLATE.signalOverridesPhase,
        field: "line2",
        example: "phase luteal",
        canvasMustDraw:
            "home_e's phase line for the phases energy is not higher in; it reads as a contrast with a tendency that is not there.",
    },
    {
        template: TEMPLATE.signalOverridesPhase,
        field: "actions",
        example: "logged last night",
        canvasMustDraw:
            "home_e's action label for an entry logged the previous evening — the observed window is 24 hours, the label says 'this morning'.",
    },
    {
        template: TEMPLATE.signalsToday,
        field: "kicker",
        example: "logged last night",
        canvasMustDraw:
            "home_g's kicker for an entry inside the 24-hour window but not on today's date.",
    },
    {
        template: TEMPLATE.signalsToday,
        field: "title",
        example: "severe cramps only",
        canvasMustDraw:
            "home_g for a logged day that is not low energy plus a headache. This is #177's headline case: every logged day in the four non-cycle modes reaches this card, as do severe-symptom, low-energy-only and low-mood runs in cycle mode.",
    },
    {
        template: TEMPLATE.moodPattern,
        field: "kicker",
        example: "four-day dose",
        canvasMustDraw:
            "home_h's kicker as a slot, or #26 fixing lowSignalDays at three — the card says '3 days' and the dose is configuration.",
    },
    {
        template: TEMPLATE.moodPattern,
        field: "title",
        example: "four-day dose",
        canvasMustDraw:
            "home_h's sentence as a slot, for the same reason as its kicker. At A32's own dose of three the sentence is true.",
    },
    {
        template: TEMPLATE.redFlag,
        field: "kicker",
        example: "raised three days ago",
        canvasMustDraw:
            "home_flag for a flag raised before today — rung 1 applies no window, so the card says 'today' for any flag the caller passes.",
    },
    {
        template: TEMPLATE.redFlag,
        field: "title",
        example: "red flag cramps",
        canvasMustDraw:
            "home_flag for each red-flag code D10 will map. The subject carries only `loggedAt`, never the code, so every flag renders as reduced fetal movement.",
    },
    {
        template: TEMPLATE.redFlag,
        field: "line2",
        example: "cycle · red flag",
        canvasMustDraw:
            "home_flag outside pregnancy — rung 1 fires in all five modes and the contact line names a maternity provider.",
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

const PLACEHOLDER = /\{(\w+)\}/g;

/** #173's `TemplatePhraser`, in the one respect this file needs: slot values substituted,
 *  and a string with a slot the subject did not carry is not rendered at all. */
const fill = (value: string | undefined, slots: SubjectSlots): string | undefined => {
    if (value === undefined) return undefined;
    let complete = true;
    const filled = value.replace(PLACEHOLDER, (match, slot: string) => {
        const supplied = slots[slot as Slot];
        if (supplied === undefined) {
            complete = false;
            return match;
        }
        return String(supplied);
    });
    return complete ? filled : undefined;
};

const fieldOf = (template: Template, field: Field): string | undefined =>
    field === "actions" ? template.actions.join(" · ") : template[field];

const FIELDS: Field[] = ["kicker", "title", "line2", "line3", "meta", "actions"];

let TEMPLATES: Template[] = [];
let byId = new Map<string, Template>();

interface Walked {
    case: Case;
    subject: Subject;
    template: Template;
    /** Fields that rendered, i.e. carried no unfilled slot. */
    rendered: Field[];
}

let WALK: Walked[] = [];
/** `templateId.field` → the names of the cases whose input does not bear the claim out. */
let FAILURES = new Map<string, string[]>();

beforeAll(async () => {
    // Imported here, not at the top of the file: the seed pulls in `content.ts`, and with
    // it the Admin SDK. Same reason `dashboard-rules.test.ts` does it this way.
    TEMPLATES = (await import("../scripts/seed-content")).TEMPLATES;
    byId = new Map(TEMPLATES.map((t) => [t.id, t]));

    WALK = CASES.map((c) => {
        const subject = selectSubject(c.input, c.rules);
        const template = byId.get(subject.templateId);
        if (!template) throw new Error(`the seed has no template ${subject.templateId}`);
        const rendered = FIELDS.filter(
            (field) =>
                (field === "actions" && template.actions.length > 0) ||
                (field !== "actions" && fill(template[field], subject.slots) !== undefined),
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
        expect(CASES).toHaveLength(2000);

        // Every mode reaches a card, every phase code reaches the phase card, and every
        // history reaches something — the three axes the mismatches below turn on.
        for (const mode of MODES) {
            expect(WALK.some((s) => s.case.input.mode === mode)).toBe(true);
        }
        const phases = new Set(
            WALK.filter((s) => s.subject.templateId === TEMPLATE.phaseEnergy).map(
                (s) => s.case.input.cycle.phase?.code,
            ),
        );
        expect([...phases].sort()).toEqual(["follicular", "luteal", "menstrual", "ovulation"]);
        const histories = new Set(WALK.map((s) => s.case.name.split(" · ")[2]));
        expect(histories.size).toBe(HISTORIES.length + 1); // +1: the red-flag cases' own shape
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

    test("each one is demonstrated by a case, so the fixture proving it cannot vanish", () => {
        for (const u of UNTRUE) {
            const names = FAILURES.get(`${u.template}.${u.field}`) ?? [];
            expect(
                `${u.template}.${u.field} ← ${names.some((n) => n.includes(u.example)) ? u.example : names.slice(0, 3).join(" | ")}`,
            ).toBe(`${u.template}.${u.field} ← ${u.example}`);
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

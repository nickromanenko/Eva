import { describe, expect, test } from "bun:test";
import { tmpdir } from "node:os";
import {
    InvalidTimeError,
    PatternRuleUnsetError,
    TEMPLATE,
    selectSubject,
    type CycleEstimate,
    type DashboardInput,
    type DashboardRules,
    type PatternRule,
    type Rung,
    type SignalEntry,
    type Subject,
    type SubjectSlots,
    type TemplateId,
} from "../src/dashboard-rules";
import type { Confidence, Slot } from "../src/content";

/**
 * The Today card's rules layer (#96) — the priority ladder, the cold-start rules and the
 * observed-data rule, against fixtures.
 *
 * **This file makes no live round trip and therefore sets no default timeout** (api/CLAUDE.md
 * #31). That is not an oversight to be corrected later: if these cases ever need Firestore or
 * a network, the module under test has stopped being pure and the fix is in `src/`, not here.
 * The two cases that spawn a process carry their own timeout, because a cold `bun` start is
 * the one slow thing in the file.
 *
 * The scenario table below is written in **canvas states** (`home_a` … `home_edu`), because
 * that is the language the acceptance criteria and the design review use. The module holds
 * template *ids*; `content/`'s seed is what ties an id to a state, and one case at the end
 * checks every scenario against it rather than restating the mapping here.
 */

const TODAY = "2026-09-16";
const NOW = "2026-09-16T09:00:00Z";
const YESTERDAY = "2026-09-15";
const TWO_DAYS_AGO = "2026-09-14";

/**
 * A32's rule, as configuration — which is the point. Every number in it lives here, in a
 * fixture, and none of them is in `dashboard-rules.ts`: the "config-driven" case below
 * proves that by changing them and watching the answer change.
 */
const PATTERN_RULE: PatternRule = { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 3 };
const RULES: DashboardRules = { pattern: PATTERN_RULE };

// ── C11 fixtures (#11) ─────────────────────────────────────────────────────────────────
// The shape is `dashboard-rules.ts`'s; the arithmetic that would produce these is C11's and
// is deliberately absent. Each one is a state a real account reaches, named for it.

const NO_CYCLE: CycleEstimate = {
    countedCycles: 0,
    enoughCyclesForEstimates: false,
    irregular: false,
    cycleDay: null,
    phase: null,
    daysPastPredictedPeriod: null,
};

/** One counted cycle: below C11's gate, so no phase — but a cycle day is known. */
const LEARNING: CycleEstimate = {
    ...NO_CYCLE,
    countedCycles: 1,
    cycleDay: 12,
};

/** Six cycles, past the gate, but the FIGO band says irregular. */
const IRREGULAR: CycleEstimate = {
    countedCycles: 6,
    enoughCyclesForEstimates: true,
    irregular: true,
    cycleDay: 12,
    phase: null,
    daysPastPredictedPeriod: null,
};

/** The PRD's worked example: day 13, approaching ovulation, four cycles behind it. */
const ESTIMATED: CycleEstimate = {
    countedCycles: 4,
    enoughCyclesForEstimates: true,
    irregular: false,
    cycleDay: 13,
    phase: { code: "follicular", confidence: "wide" },
    daysPastPredictedPeriod: null,
};

/** Two days past the predicted first flow day. */
const LATE: CycleEstimate = {
    countedCycles: 6,
    enoughCyclesForEstimates: true,
    irregular: false,
    cycleDay: 31,
    phase: { code: "luteal", confidence: "narrow" },
    daysPastPredictedPeriod: 2,
};

const signal = (over: Partial<SignalEntry> & { localDate: string }): SignalEntry => ({
    loggedAt: `${over.localDate}T08:00:00Z`,
    energy: null,
    mood: null,
    sleep: null,
    symptoms: [],
    ...over,
});

/** A day with nothing worth naming on it — used to prove a *logged* day is not the same as
 *  a day she reported something. */
const emptyDay = (localDate: string): SignalEntry => signal({ localDate });

const base = (over: Partial<DashboardInput> = {}): DashboardInput => ({
    mode: "cycle",
    today: TODAY,
    now: NOW,
    cycle: NO_CYCLE,
    signals: [],
    redFlag: null,
    upcomingAppointments: [],
    profileComplete: false,
    nutritionSetUp: false,
    todayTotals: null,
    daysSinceLastLog: null,
    ...over,
});

const APPOINTMENT_TOMORROW = {
    startAt: "2026-09-17T10:30:00",
    type: "gp",
    inDays: 1,
} as const;

// ── The scenario table ─────────────────────────────────────────────────────────────────

interface Scenario {
    /** The canvas state, and what the acceptance criterion calls it. */
    state: string;
    why: string;
    input: DashboardInput;
    rung: Rung;
    templateId: TemplateId;
    slots: SubjectSlots;
    confidence: Confidence;
}

const SCENARIOS: Scenario[] = [
    {
        state: "home_a",
        why: "no data at all — first open after sign-up (PRD Edge case 1)",
        input: base(),
        rung: "setup",
        templateId: TEMPLATE.coldStart,
        slots: {},
        confidence: "plain",
    },
    {
        state: "home_b",
        why: "fewer counted cycles than C11's gate — no phase, the count as a fact",
        input: base({ cycle: LEARNING, daysSinceLastLog: 0 }),
        rung: "phase",
        templateId: TEMPLATE.stillLearning,
        slots: { cycleCount: 1 },
        confidence: "hedged",
    },
    {
        state: "home_c",
        why: "irregular per C11's flag — the phase cannot be estimated reliably",
        input: base({ cycle: IRREGULAR, daysSinceLastLog: 0 }),
        rung: "phase",
        templateId: TEMPLATE.irregular,
        slots: {},
        confidence: "hedged",
    },
    {
        state: "home_d",
        why: "phase context, nothing logged in the last 24 h (PRD worked example 1)",
        input: base({ cycle: ESTIMATED, daysSinceLastLog: 3 }),
        rung: "phase",
        templateId: TEMPLATE.phaseEnergy,
        slots: { cycleDay: 13, phase: "follicular" },
        confidence: "hedged",
    },
    {
        state: "home_e",
        why: "same day, energy 1 and sleep 2 logged (PRD worked example 2)",
        input: base({
            cycle: ESTIMATED,
            daysSinceLastLog: 0,
            signals: [signal({ localDate: TODAY, energy: 1, sleep: 2 })],
        }),
        rung: "pattern",
        templateId: TEMPLATE.signalOverridesPhase,
        slots: { cycleDay: 13 },
        confidence: "plain",
    },
    {
        state: "home_f",
        why: "the period is later than predicted (PRD Edge case 2)",
        input: base({ cycle: LATE, daysSinceLastLog: 0 }),
        rung: "pattern",
        templateId: TEMPLATE.latePeriod,
        slots: { cycleDay: 31 },
        confidence: "plain",
    },
    {
        state: "home_g",
        why: "signals logged, no cycle data — responds to the signals alone (Edge case 3)",
        input: base({
            daysSinceLastLog: 0,
            signals: [
                signal({
                    localDate: TODAY,
                    energy: 1,
                    symptoms: [{ code: "headache", severity: "severe" }],
                }),
            ],
        }),
        rung: "pattern",
        templateId: TEMPLATE.signalsToday,
        slots: {},
        confidence: "plain",
    },
    {
        state: "home_h",
        why: "three consecutive logged days at or below the configured level (A32)",
        input: base({
            cycle: ESTIMATED,
            daysSinceLastLog: 0,
            signals: [
                signal({ localDate: TODAY, mood: 2 }),
                signal({ localDate: YESTERDAY, mood: 2 }),
                signal({ localDate: TWO_DAYS_AGO, mood: 1 }),
            ],
        }),
        rung: "pattern",
        templateId: TEMPLATE.moodPattern,
        slots: {},
        confidence: "plain",
    },
    {
        state: "home_edu",
        why: "she has logged before, but no rung applies today",
        input: base({ daysSinceLastLog: 5 }),
        rung: "education",
        templateId: TEMPLATE.educational,
        slots: {},
        confidence: "plain",
    },
];

describe("every cycle-mode canvas state", () => {
    for (const scenario of SCENARIOS) {
        test(`${scenario.state} — ${scenario.why}`, () => {
            const subject = selectSubject(scenario.input, RULES);
            expect(subject).toEqual({
                rung: scenario.rung,
                templateId: scenario.templateId,
                slots: scenario.slots,
                confidence: scenario.confidence,
            });
        });
    }
});

// ── The ladder ─────────────────────────────────────────────────────────────────────────

describe("priority ladder", () => {
    /** Everything applicable at once, the day PRD Edge case 4 describes. */
    const everything = base({
        cycle: { ...ESTIMATED, daysPastPredictedPeriod: 2 },
        daysSinceLastLog: 0,
        redFlag: { code: "reduced_fetal_movement", loggedAt: `${TODAY}T07:45:00Z` },
        signals: [
            signal({ localDate: TODAY, mood: 2 }),
            signal({ localDate: YESTERDAY, mood: 2 }),
            signal({ localDate: TWO_DAYS_AGO, mood: 2 }),
        ],
        upcomingAppointments: [APPOINTMENT_TOMORROW],
        profileComplete: true,
        nutritionSetUp: true,
        todayTotals: { caloriesRemaining: 420, proteinG: 58, waterMl: 1200, activityMin: 35 },
    });

    test("all six conditions true at once: exactly one rung wins (PRD Edge case 4)", () => {
        expect(selectSubject(everything, RULES)).toEqual({
            rung: "flag",
            templateId: TEMPLATE.redFlag,
            slots: { loggedAt: `${TODAY}T07:45:00Z` },
            confidence: "plain",
        });
    });

    /**
     * Peel one rung off at a time and the next one down answers. This is the case that
     * fails if the ladder is reordered — which is the failure a table of independent
     * fixtures cannot see, because each of those has only one rung applicable.
     */
    test("removing the winning condition hands the day to the next rung down", () => {
        const noFlag = { ...everything, redFlag: null };
        expect(selectSubject(noFlag, RULES).templateId).toBe(TEMPLATE.moodPattern);

        // One log today instead of a three-day run: still rung 2, but the late period is
        // the more consequential thing to say, so it leads.
        const noRun = { ...noFlag, signals: [signal({ localDate: TODAY, mood: 2 })] };
        expect(selectSubject(noRun, RULES).templateId).toBe(TEMPLATE.latePeriod);

        // Not late any more: her own log still outranks the phase.
        const notLate = { ...noRun, cycle: ESTIMATED };
        expect(selectSubject(notLate, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase);

        // Nothing logged in the window: phase context. The appointment is still there, which
        // is the point — cycle mode has no rung-3 template, so rung 3 cannot outrank it.
        const noSignals = { ...notLate, signals: [], daysSinceLastLog: 3 };
        expect(selectSubject(noSignals, RULES).templateId).toBe(TEMPLATE.phaseEnergy);

        // Below C11's gate: the phase rung still answers, without a phase.
        const learning = { ...noSignals, cycle: LEARNING };
        expect(selectSubject(learning, RULES).templateId).toBe(TEMPLATE.stillLearning);

        // No cycle data at all, but she has logged something before: the fallback.
        const nothing = { ...learning, cycle: NO_CYCLE };
        expect(selectSubject(nothing, RULES).templateId).toBe(TEMPLATE.educational);
    });

    test("an escalation does not wait on another rung's configuration", () => {
        // Rung 1 is deterministic and bypasses everything (PRD §Calendar Other req. 5). It is
        // evaluated before rung 2 asks for its rule, so a missing #26 config cannot suppress
        // a red flag.
        expect(selectSubject(everything, { pattern: null }).templateId).toBe(TEMPLATE.redFlag);
    });

    test("an upcoming appointment selects nothing in cycle mode — rung 3 is D10's", () => {
        const withAppointment = base({
            cycle: ESTIMATED,
            daysSinceLastLog: 3,
            upcomingAppointments: [APPOINTMENT_TOMORROW],
        });
        expect(selectSubject(withAppointment, RULES).rung).toBe("phase");
    });

    test("a mode this slice has no rules for falls back, it does not borrow cycle content", () => {
        for (const mode of ["planning", "pregnancy", "postpartum", "loss"] as const) {
            const subject = selectSubject(
                base({ mode, cycle: ESTIMATED, daysSinceLastLog: 3 }),
                RULES,
            );
            expect(subject.templateId).toBe(TEMPLATE.educational);
        }
    });
});

// ── Observed data outranks predicted data ──────────────────────────────────────────────

describe("observed data outranks predicted data", () => {
    test("the PRD's two worked examples: the same day, with and without a log", () => {
        const day13 = base({ cycle: ESTIMATED, daysSinceLastLog: 0 });

        expect(selectSubject({ ...day13, daysSinceLastLog: 3 }, RULES).templateId).toBe(
            TEMPLATE.phaseEnergy,
        );

        const logged = {
            ...day13,
            signals: [signal({ localDate: TODAY, energy: 1, sleep: 2 })],
        };
        expect(selectSubject(logged, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase);
    });

    test("a log older than 24 h does not displace the phase", () => {
        const stale = base({
            cycle: ESTIMATED,
            daysSinceLastLog: 2,
            signals: [signal({ localDate: TWO_DAYS_AGO, energy: 1 })],
        });
        expect(selectSubject(stale, RULES).templateId).toBe(TEMPLATE.phaseEnergy);
    });

    test("an entry she opened but reported nothing in is not a log", () => {
        const opened = base({
            cycle: ESTIMATED,
            daysSinceLastLog: 0,
            signals: [emptyDay(TODAY)],
        });
        expect(selectSubject(opened, RULES).templateId).toBe(TEMPLATE.phaseEnergy);
    });

    test("signals with no speakable phase never mention one", () => {
        for (const cycle of [NO_CYCLE, LEARNING, IRREGULAR]) {
            const subject = selectSubject(
                base({
                    cycle,
                    daysSinceLastLog: 0,
                    signals: [signal({ localDate: TODAY, energy: 1 })],
                }),
                RULES,
            );
            expect(subject.templateId).toBe(TEMPLATE.signalsToday);
            expect(subject.slots).toEqual({});
        }
    });
});

// ── C11's confidence gate ──────────────────────────────────────────────────────────────

describe("the phase is spoken only when C11 says it may be", () => {
    test("a withheld estimate selects a no-phase subject, never a hedged phase", () => {
        const withheld = base({
            cycle: { ...ESTIMATED, phase: { code: "follicular", confidence: "none" } },
            daysSinceLastLog: 3,
        });
        const subject = selectSubject(withheld, RULES);
        expect(subject.templateId).not.toBe(TEMPLATE.phaseEnergy);
        expect(subject.templateId).toBe(TEMPLATE.educational);
        expect(subject.slots.phase).toBeUndefined();
    });

    test("C11's two gates hold even if an estimate arrives anyway", () => {
        const belowGate = base({
            cycle: { ...ESTIMATED, enoughCyclesForEstimates: false, countedCycles: 2 },
            daysSinceLastLog: 3,
        });
        expect(selectSubject(belowGate, RULES)).toEqual({
            rung: "phase",
            templateId: TEMPLATE.stillLearning,
            slots: { cycleCount: 2 },
            confidence: "hedged",
        });

        const irregular = base({
            cycle: { ...ESTIMATED, irregular: true },
            daysSinceLastLog: 3,
        });
        expect(selectSubject(irregular, RULES).templateId).toBe(TEMPLATE.irregular);
    });

    test("both gates at once: too few cycles is what the card says (PRD cold start 2)", () => {
        // Below C11's gate there are not enough cycles to call variation irregular in the
        // first place, so "still learning" is the honest answer even when the flag is set —
        // "With fewer than 3 logged cycles the card does not estimate a phase. It states what
        // is needed instead." Nothing else in this file puts both gates up at once, and
        // without this case the two branches can be swapped and the suite stays green.
        const both = base({
            cycle: {
                countedCycles: 2,
                enoughCyclesForEstimates: false,
                irregular: true,
                cycleDay: 9,
                phase: null,
                daysPastPredictedPeriod: null,
            },
            daysSinceLastLog: 0,
        });
        expect(selectSubject(both, RULES)).toEqual({
            rung: "phase",
            templateId: TEMPLATE.stillLearning,
            slots: { cycleCount: 2 },
            confidence: "hedged",
        });
    });

    test("below the gate there is no phase slot at all", () => {
        for (const cycle of [LEARNING, IRREGULAR]) {
            const subject = selectSubject(base({ cycle, daysSinceLastLog: 0 }), RULES);
            expect(subject.slots.phase).toBeUndefined();
            expect(subject.confidence).toBe("hedged");
        }
    });

    test("both estimated bands hedge — v1 has no confirmed-ovulation path", () => {
        for (const band of ["wide", "narrow"] as const) {
            const subject = selectSubject(
                base({
                    cycle: { ...ESTIMATED, phase: { code: "follicular", confidence: band } },
                    daysSinceLastLog: 3,
                }),
                RULES,
            );
            expect(subject.confidence).toBe("hedged");
        }
    });
});

// ── Rung 2 ─────────────────────────────────────────────────────────────────────────────

describe("rung 2 is inert until #26's rule is configured", () => {
    const day = SCENARIOS.find((s) => s.state === "home_h")!.input;

    test("an unset rule throws a named error", () => {
        expect(() => selectSubject(day, { pattern: null })).toThrow(PatternRuleUnsetError);
        try {
            selectSubject(day, { pattern: null });
            expect.unreachable();
        } catch (error) {
            expect((error as Error).name).toBe("PatternRuleUnsetError");
        }
    });

    test("it is never silently skipped — a day that would answer at rung 4 throws too", () => {
        const phaseDay = base({ cycle: ESTIMATED, daysSinceLastLog: 3 });
        expect(selectSubject(phaseDay, RULES).templateId).toBe(TEMPLATE.phaseEnergy);
        expect(() => selectSubject(phaseDay, { pattern: null })).toThrow(PatternRuleUnsetError);
    });

    test("a rule that cannot match is refused rather than run", () => {
        for (const broken of [
            { ...PATTERN_RULE, lowSignalDays: 0 },
            { ...PATTERN_RULE, lowAtOrBelow: 0 },
            { ...PATTERN_RULE, severeSymptomDays: 1.5 },
        ]) {
            expect(() => selectSubject(day, { pattern: broken })).toThrow(PatternRuleUnsetError);
        }
    });

    test("the thresholds come from the config, not from the code", () => {
        // Two consecutive low days, and nothing else applicable.
        const twoDays = base({
            daysSinceLastLog: 0,
            signals: [
                signal({ localDate: TODAY, mood: 2 }),
                signal({ localDate: YESTERDAY, mood: 2 }),
            ],
        });
        expect(selectSubject(twoDays, RULES).templateId).toBe(TEMPLATE.signalsToday);
        expect(
            selectSubject(twoDays, { pattern: { ...PATTERN_RULE, lowSignalDays: 2 } }).templateId,
        ).toBe(TEMPLATE.moodPattern);

        // The level is configuration too: mood 3 is not low at 2, and is at 3.
        const threes = base({
            daysSinceLastLog: 0,
            signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
                signal({ localDate, mood: 3 }),
            ),
        });
        expect(selectSubject(threes, RULES).templateId).toBe(TEMPLATE.signalsToday);
        expect(
            selectSubject(threes, { pattern: { ...PATTERN_RULE, lowAtOrBelow: 3 } }).templateId,
        ).toBe(TEMPLATE.moodPattern);
    });

    test("the run must be consecutive, and must reach today", () => {
        const gap = base({
            daysSinceLastLog: 0,
            signals: [
                signal({ localDate: TODAY, mood: 2 }),
                signal({ localDate: TWO_DAYS_AGO, mood: 2 }),
                signal({ localDate: "2026-09-13", mood: 2 }),
            ],
        });
        expect(selectSubject(gap, RULES).templateId).toBe(TEMPLATE.signalsToday);

        const endedYesterday = base({
            daysSinceLastLog: 1,
            signals: [YESTERDAY, TWO_DAYS_AGO, "2026-09-13"].map((localDate) =>
                signal({ localDate, mood: 2 }),
            ),
        });
        expect(selectSubject(endedYesterday, RULES).templateId).toBe(TEMPLATE.educational);
    });

    test("energy, mood and sleep each count; a mixture of them still counts", () => {
        const mixed = base({
            daysSinceLastLog: 0,
            signals: [
                signal({ localDate: TODAY, sleep: 2 }),
                signal({ localDate: YESTERDAY, energy: 1 }),
                signal({ localDate: TWO_DAYS_AGO, mood: 2 }),
            ],
        });
        expect(selectSubject(mixed, RULES).templateId).toBe(TEMPLATE.moodPattern);
    });

    test("the severe-symptom arm needs the same symptom on every day", () => {
        const sameCode = base({
            daysSinceLastLog: 0,
            signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
                signal({ localDate, symptoms: [{ code: "cramps", severity: "severe" }] }),
            ),
        });
        expect(selectSubject(sameCode, RULES).templateId).toBe(TEMPLATE.moodPattern);

        const differentCodes = base({
            daysSinceLastLog: 0,
            signals: [
                signal({ localDate: TODAY, symptoms: [{ code: "cramps", severity: "severe" }] }),
                signal({ localDate: YESTERDAY, symptoms: [{ code: "nausea", severity: "severe" }] }),
                signal({
                    localDate: TWO_DAYS_AGO,
                    symptoms: [{ code: "cramps", severity: "severe" }],
                }),
            ],
        });
        expect(selectSubject(differentCodes, RULES).templateId).toBe(TEMPLATE.signalsToday);

        const notSevere = base({
            daysSinceLastLog: 0,
            signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
                signal({ localDate, symptoms: [{ code: "cramps", severity: "normal" }] }),
            ),
        });
        expect(selectSubject(notSevere, RULES).templateId).toBe(TEMPLATE.signalsToday);
    });
});

// ── The output shape, and what may never be in it ──────────────────────────────────────

/**
 * Every slot `content.ts` defines, as a value the compiler checks for completeness. A
 * `Slot` added there without a line here fails `bun run typecheck`, which is the point:
 * the vocabulary has one definition and this file cannot drift from it. It is spelled out
 * rather than imported because importing the runtime `SLOTS` would pull `content.ts`, and
 * with it Firestore, into a suite whose whole claim is that it needs neither.
 */
const EVERY_SLOT: Record<Slot, true> = {
    cycleDay: true,
    phase: true,
    cycleCount: true,
    appointmentAt: true,
    appointmentWith: true,
    appointmentPlace: true,
    loggedAt: true,
    pregnancyWeek: true,
    pregnancyDay: true,
    postpartumDay: true,
    readMinutes: true,
    category: true,
};

const everySubject = (): Subject[] => [
    ...SCENARIOS.map((scenario) => selectSubject(scenario.input, RULES)),
    selectSubject(
        base({ redFlag: { code: "reduced_fetal_movement", loggedAt: `${TODAY}T07:45:00Z` } }),
        RULES,
    ),
];

describe("the output is a subject, not a message", () => {
    test("four fields, and nothing else", () => {
        for (const subject of everySubject()) {
            expect(Object.keys(subject).sort()).toEqual([
                "confidence",
                "rung",
                "slots",
                "templateId",
            ]);
        }
    });

    test("the only strings are a template id and slot values", () => {
        for (const subject of everySubject()) {
            expect(Object.values(TEMPLATE)).toContain(subject.templateId);
            for (const [key, value] of Object.entries(subject.slots)) {
                expect(EVERY_SLOT[key as Slot]).toBe(true);
                expect(["string", "number"]).toContain(typeof value);
            }
        }
    });

    test("no score, no streak, no comparison — and no field that could become one", () => {
        // PRD tone rule 4. The logging gap is an input and never leaves as a slot; `Slot`
        // has no key for it, so this case is a statement of what the type already enforces.
        const banned = [
            "streak",
            "score",
            "rank",
            "percentile",
            "daysSinceLastLog",
            "consecutiveDays",
            "comparison",
        ];
        for (const subject of everySubject()) {
            for (const key of banned) {
                expect(subject).not.toHaveProperty(key);
                expect(subject.slots).not.toHaveProperty(key);
            }
        }
        for (const key of banned) {
            expect(EVERY_SLOT).not.toHaveProperty(key);
        }
    });

    test("the logging gap never reaches the card, even when it is what decided it", () => {
        // `home_a` is chosen *because* nothing has been logged; the number behind that must
        // not turn up as something to read.
        const coldStart = selectSubject(base({ daysSinceLastLog: null }), RULES);
        expect(coldStart.slots).toEqual({});
        const gap = selectSubject(base({ daysSinceLastLog: 11 }), RULES);
        expect(Object.values(gap.slots)).not.toContain(11);
    });

    test("the same inputs answer the same way, and the inputs come back unchanged", () => {
        // PRD Other requirements 3: the card does not change between opens. The cache is
        // D3's; determinism is what makes the cache honest.
        for (const scenario of SCENARIOS) {
            const before = JSON.stringify(scenario.input);
            const first = selectSubject(scenario.input, RULES);
            const second = selectSubject(scenario.input, RULES);
            expect(second).toEqual(first);
            expect(JSON.stringify(scenario.input)).toBe(before);
        }
    });
});

// ── Sex events (PRD Edge case 6) ───────────────────────────────────────────────────────

describe("sex events are not an input", () => {
    test("the input type has no channel for one", () => {
        // @ts-expect-error — there is no event list and no event type here, so hiding Sex in
        // Settings needs no branch in the rules layer. This line is the pin: it stops
        // compiling the day someone adds one, which is where that should be argued.
        const withSex: DashboardInput = { ...base(), sexEvents: [{ localDate: TODAY }] };
        expect(withSex).toBeDefined();

        // @ts-expect-error — nor on the one logged-data shape the module does take.
        const entry: SignalEntry = { ...signal({ localDate: TODAY }), sex: true };
        expect(entry).toBeDefined();
    });

    test("the whole input surface, pinned", () => {
        expect(Object.keys(base()).sort()).toEqual([
            "cycle",
            "daysSinceLastLog",
            "mode",
            "now",
            "nutritionSetUp",
            "profileComplete",
            "redFlag",
            "signals",
            "today",
            "todayTotals",
            "upcomingAppointments",
        ]);
        expect(Object.keys(signal({ localDate: TODAY })).sort()).toEqual([
            "energy",
            "localDate",
            "loggedAt",
            "mood",
            "sleep",
            "symptoms",
        ]);
    });
});

// ── Instants ───────────────────────────────────────────────────────────────────────────

describe("times are instants, not wall clocks", () => {
    test("a wall-clock string is refused rather than quietly ignored", () => {
        const wallClock = base({
            cycle: ESTIMATED,
            daysSinceLastLog: 0,
            signals: [signal({ localDate: TODAY, energy: 1, loggedAt: `${TODAY}T08:00:00` })],
        });
        expect(() => selectSubject(wallClock, RULES)).toThrow(InvalidTimeError);

        expect(() => selectSubject(base({ now: "2026-09-16 09:00" }), RULES)).toThrow(
            InvalidTimeError,
        );
    });

    test("a malformed local date is refused, not quietly unmatched", () => {
        // A `today` the run cannot land on would make rung 2 match nothing — a rule that
        // looks live and is not, which is the failure this slice is written against.
        const badToday = base({
            today: "16/09/2026",
            daysSinceLastLog: 0,
            signals: [signal({ localDate: TODAY, mood: 2 })],
        });
        expect(() => selectSubject(badToday, RULES)).toThrow(InvalidTimeError);
    });

    test("an offset other than Z works, and the window is measured from `now`", () => {
        const input = base({
            cycle: ESTIMATED,
            daysSinceLastLog: 0,
            now: "2026-09-16T11:00:00+02:00",
            signals: [
                signal({ localDate: TODAY, energy: 1, loggedAt: "2026-09-16T10:30:00+02:00" }),
            ],
        });
        expect(selectSubject(input, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase);

        // 25 hours earlier, same wall-clock date on the entry: outside the window.
        const stale = {
            ...input,
            signals: [signal({ localDate: TODAY, energy: 1, loggedAt: "2026-09-15T08:00:00Z" })],
        };
        expect(selectSubject(stale, RULES).templateId).toBe(TEMPLATE.phaseEnergy);
    });
});

// ── Purity ─────────────────────────────────────────────────────────────────────────────

const importInABareProcess = async (modulePath: string) => {
    const proc = Bun.spawn(
        ["bun", "--eval", `await import(${JSON.stringify(modulePath)})`],
        {
            // Outside `api/`, so Bun does not auto-load `api/.env`: the case is a process
            // holding no configuration and no credential at all.
            cwd: tmpdir(),
            env: { PATH: process.env.PATH ?? "" },
            stdout: "pipe",
            stderr: "pipe",
        },
    );
    const [exitCode, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
    return { exitCode, stderr };
};

describe("the module reaches nothing", () => {
    test(
        "it imports in a process with no environment and no credentials",
        async () => {
            const { exitCode, stderr } = await importInABareProcess(
                `${import.meta.dir}/../src/dashboard-rules.ts`,
            );
            expect(stderr).toBe("");
            expect(exitCode).toBe(0);
        },
        10_000,
    );

    test(
        "and a module that does touch Firestore fails there, which is what makes that a test",
        async () => {
            const { exitCode, stderr } = await importInABareProcess(
                `${import.meta.dir}/../src/content.ts`,
            );
            expect(exitCode).not.toBe(0);
            expect(stderr).toContain("Missing required env var");
        },
        10_000,
    );

    test("its only import is a type import", async () => {
        const source = await Bun.file(`${import.meta.dir}/../src/dashboard-rules.ts`).text();
        const imports = source.match(/^import .*$/gm) ?? [];
        expect(imports).toEqual(["import type { Confidence, Slot } from './content'"]);
        for (const forbidden of ["./firebase", "./users", "./events", "./config"]) {
            expect(source).not.toContain(forbidden);
        }
    });
});

// ── The content store agrees ───────────────────────────────────────────────────────────

describe("every subject names a template the content store actually has", () => {
    test("rung, confidence and slots match the seeded template", async () => {
        // Imported here rather than at the top of the file: the seed pulls in `content.ts`,
        // and with it Firestore's Admin SDK. Nothing above this line may do that.
        const { TEMPLATES } = await import("../scripts/seed-content");

        const byState = new Map(TEMPLATES.map((template) => [template.state, template]));

        for (const scenario of SCENARIOS) {
            const template = byState.get(scenario.state);
            expect(template).toBeDefined();
            if (!template) continue;

            const subject = selectSubject(scenario.input, RULES);
            expect(subject.templateId).toBe(template.id as TemplateId);
            expect(subject.rung).toBe(template.rung as Rung);
            expect(subject.confidence).toBe(template.confidence);
            expect(template.status).toBe("active");
            expect(["cycle", "any"]).toContain(template.mode);

            // Never a slot the template does not declare.
            const emitted = Object.keys(subject.slots);
            for (const slot of emitted) expect(template.slots).toContain(slot as Slot);

            // And every slot it does declare is filled — with one known exception, pinned
            // here rather than waved at: `home_edu`'s two slots describe the *article*, and
            // choosing an article is not this slice's job, nor D3's. If that changes, this
            // line is what fails.
            const unfilled = template.slots.filter((slot) => !emitted.includes(slot)).sort();
            expect(unfilled).toEqual(
                scenario.state === "home_edu" ? ["category", "readMinutes"] : [],
            );
        }
    });
});

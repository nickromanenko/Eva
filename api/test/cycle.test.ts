import { describe, expect, test } from "bun:test";
import { tmpdir } from "node:os";
import {
    CycleRulesUnsetError,
    ImpossibleAgeError,
    InvalidCycleDateError,
    ageYearsOn,
    analyzeCycles,
    bandForAge,
    cycleRulesProblem,
    toCycleEstimate,
    type CycleDay,
    type CycleRules,
} from "../src/cycle";
import {
    TEMPLATE,
    selectSubject,
    type DashboardInput,
    type DashboardRules,
    type PhaseCode,
    type Subject,
} from "../src/dashboard-rules";
import type { Profile } from "../src/users";

/**
 * The cycle maths (C11, #176) — counted cycles, the median prediction, the FIGO bands and
 * the confidence gates, against fixtures.
 *
 * **This file makes no live round trip and therefore sets no default timeout** (api/CLAUDE.md
 * #31), with the same caveat `dashboard-rules.test.ts` carries: if these cases ever need
 * Firestore or a network, the module under test has stopped being pure and the fix is in
 * `src/`. The cases that spawn a process carry their own timeout.
 *
 * **What the cases are written to survive.** Every behavioural claim below was checked by
 * breaking the code and watching a case die — the gate constants, each FIGO band, the
 * median, both halves of the 21–45 filter, the unknown-age default and the luteal offset.
 * A case that passes with its guarantee removed is not a test of that guarantee, and this
 * repo has shipped several. The PR body carries the table of which mutation killed which
 * case.
 */

// ── The constants, as PRD §Predictions in Cycle mode settled them ──────────────────────
// Written here rather than read from `config`, exactly as `dashboard-rules.test.ts` holds
// A32's rule: these numbers exist so the maths can be *exercised*, and the "no literal in
// the arithmetic" case below proves the module has none of its own by changing them.

const RULES: CycleRules = {
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

// ── Fixtures ───────────────────────────────────────────────────────────────────────────

const TODAY = "2026-06-15";

const shift = (date: string, delta: number): string =>
    new Date(Date.parse(`${date}T00:00:00.000Z`) + delta * 86_400_000).toISOString().slice(0, 10);

const flow = (localDate: string): CycleDay => ({ localDate, kind: "flow" });
const spotting = (localDate: string): CycleDay => ({ localDate, kind: "spotting" });
/** A flow day she marked as the end of her period (#75). */
const flowEnded = (localDate: string): CycleDay => ({ localDate, kind: "flow", periodEnd: true });
/** The same days with every period-end mark taken off. */
const unmarked = (days: readonly CycleDay[]): CycleDay[] =>
    days.map((day) => (day.kind === "flow" ? flow(day.localDate) : spotting(day.localDate)));

/**
 * Logged flow for periods whose consecutive *starts* are `gaps` days apart, the most recent
 * starting `daysAgo` before `TODAY`, each lasting `flowDays`.
 *
 * `gaps` is therefore the list of cycle lengths, oldest first, and `gaps.length + 1` periods
 * are logged. `flowDays` stays well under the smallest gap so two periods never run into one
 * another — a merged run would be a different fixture than the one the case is named for.
 */
const periods = (gaps: readonly number[], daysAgo: number, flowDays = 4): CycleDay[] => {
    const starts = [shift(TODAY, -daysAgo)];
    for (let i = gaps.length - 1; i >= 0; i -= 1) starts.unshift(shift(starts[0]!, -gaps[i]!));
    return starts.flatMap((start) =>
        Array.from({ length: flowDays }, (_, day) => flow(shift(start, day))),
    );
};

/** A profile carrying exactly this date of birth, whatever that turns out to mean. */
const profileBornOn = (dateOfBirth: string): Profile => ({
    dateOfBirth,
    weightKg: 62,
    heightCm: 168,
    goals: [],
    conditions: ["noneOfThese"],
    medications: "none",
    lifestyle: "",
    sports: [],
});

/**
 * A date of birth that makes her exactly `age` on `TODAY` (#81 — the profile stores the
 * date and the maths derives the age).
 *
 * Her birthday **is** `TODAY`, deliberately: every band case below therefore sits on the
 * day the derivation has to get right rather than safely inside a year, so an off-by-one in
 * `ageYearsOn` moves the band cases and not only the boundary case written for it.
 */
const profileAged = (age: number): Profile => {
    const [year, monthAndDay] = [TODAY.slice(0, 4), TODAY.slice(4)];
    return profileBornOn(`${Number(year) - age}${monthAndDay}`);
};

const analyze = (days: readonly CycleDay[], profile: Profile | null = profileAged(30)) =>
    analyzeCycles({ days, today: TODAY, profile }, RULES);

// ── A counted cycle (A25 item 1) ───────────────────────────────────────────────────────

describe("a counted cycle runs first flow day to next first flow day", () => {
    test("consecutive period starts become the cycle lengths, oldest first", () => {
        const result = analyze(periods([28, 30, 27], 5));
        expect(result.cycles.map((cycle) => cycle.lengthDays)).toEqual([28, 30, 27]);
        expect(result.countedCycles).toBe(3);
        expect(result.cycles.every((cycle) => cycle.counted)).toBe(true);
    });

    /**
     * #23 gave spotting its own marker precisely so it could not start a period. A fixture
     * where the spotting day is the *only* thing that could open a cycle: remove the
     * distinction and the run starts a day earlier, and every length shifts by one.
     */
    test("a spotting day never starts a cycle", () => {
        const start = shift(TODAY, -30);
        const withSpotting = analyze([
            ...periods([28], 30),
            spotting(shift(start, -1)),
            spotting(shift(start, -2)),
        ]);
        expect(withSpotting.cycles.map((cycle) => cycle.lengthDays)).toEqual([28]);
        expect(withSpotting.lastPeriodStart).toBe(start);
    });

    /** A25 item 6, the other half: those spotting days belong to the *previous* cycle, so
     *  cycle day counts from the flow day and not from the first day she bled at all. */
    test("spotting before a first flow day belongs to the previous cycle, so cycle day counts from the flow", () => {
        const start = shift(TODAY, -10);
        const plain = analyze(periods([28], 10));
        const spotted = analyze([...periods([28], 10), spotting(shift(start, -1))]);
        expect(plain.cycleDay).toBe(11);
        expect(spotted.cycleDay).toBe(11);
        expect(spotted.lastPeriodStart).toBe(start);
    });

    test("a run of spotting with no flow in it starts nothing at all", () => {
        const result = analyze([spotting(shift(TODAY, -3)), spotting(shift(TODAY, -2))]);
        expect(result.lastPeriodStart).toBe(null);
        expect(result.cycles).toEqual([]);
        expect(result.withheld).toBe("no-flow-logged");
    });
});

// ── What one period is (#186) ──────────────────────────────────────────────────────────

/**
 * #180's measured history: six periods 28 days apart, each logged for five days, the most
 * recent starting on 2026-06-05, ten days before `TODAY`. The first five are fixed; the
 * cases below say how the most recent one was logged, as offsets from its first day.
 */
const LATEST_START = "2026-06-05";
const on = (offset: number): string => shift(LATEST_START, offset);
const history = (...latest: CycleDay[]): CycleDay[] => [
    ...periods([28, 28, 28, 28], 38, 5),
    ...latest,
];
const loggedDaily = (from: number, to: number): CycleDay[] =>
    Array.from({ length: to - from + 1 }, (_, index) => flow(on(from + index)));

/**
 * **Grouping is upstream of every number the maths returns**, so these cases assert what she
 * would see — the anchor, cycle day, the predicted date and the phase — and not only which
 * days were put together. #180's table is the model: one missed tap moved all four.
 */
describe("a missed day inside a period does not split it (#186)", () => {
    /**
     * The exact case #180 measured. On `main` before this change the missed day made day 4 a
     * new period: `lastPeriodStart` 2026-06-08, cycle day 8, and — since #181 reads every
     * interval — a phantom 3-day cycle that withheld the prediction and the phase outright.
     */
    test("#180: a period logged on days 1, 2, 4 and 5 reads exactly as one logged 1-5", () => {
        const clean = analyze(history(...loggedDaily(0, 4)));
        const missed = analyze(history(flow(on(0)), flow(on(1)), flow(on(3)), flow(on(4))));

        // #180's four rows, and the clean column is now the answer for both.
        for (const result of [clean, missed]) {
            expect(result.lastPeriodStart).toBe("2026-06-05");
            expect(result.cycleDay).toBe(11);
            expect(result.prediction?.nextPeriodStart).toBe("2026-07-03");
            expect(toCycleEstimate(result).phase?.code).toBe("ovulation");
        }
        // No phantom row in her history…
        expect(missed.cycles.map((cycle) => cycle.lengthDays)).toEqual([28, 28, 28, 28, 28]);
        // …and nothing else moved either: counted cycles, the median, the variation, the
        // window, the band and the period's own end are all the clean history's.
        expect(missed).toEqual(clean);
    });

    /** The boundary, from both sides, with what each side does to her estimate. */
    test("two days in a row with nothing logged separate two periods; one does not", () => {
        const oneMissed = analyze(history(flow(on(0)), flow(on(2))));
        expect(oneMissed.lastPeriodStart).toBe(on(0));
        expect(oneMissed.currentPeriodEnd).toBe(on(2));
        expect(oneMissed.cycles.map((cycle) => cycle.lengthDays)).toEqual([28, 28, 28, 28, 28]);
        expect(oneMissed.cycleDay).toBe(11);
        expect(oneMissed.prediction?.nextPeriodStart).toBe("2026-07-03");
        expect(toCycleEstimate(oneMissed).phase?.code).toBe("ovulation");

        const twoMissed = analyze(history(flow(on(0)), flow(on(3))));
        expect(twoMissed.lastPeriodStart).toBe(on(3));
        expect(twoMissed.currentPeriodEnd).toBe(on(3));
        // A split is not a relabelling: it is a short interval on her record, flagged, and an
        // estimate withheld because of it.
        expect(twoMissed.cycles.at(-1)).toEqual({
            startDate: on(0),
            endDate: on(3),
            lengthDays: 3,
            counted: false,
            excluded: "unusual-length",
        });
        expect(twoMissed.cycleDay).toBe(8);
        expect(twoMissed.prediction).toBe(null);
        expect(twoMissed.withheld).toBe("irregular-cycles");
        expect(toCycleEstimate(twoMissed).phase).toBe(null);
    });

    /** The same fix seen on the day it matters: the morning she logs again. */
    test("the day she logs again after a missed one is day 4 of her period, not day 1 of another", () => {
        const days = history(flow(on(0)), flow(on(1)), flow(on(3)));
        const result = analyzeCycles({ days, today: on(3), profile: profileAged(30) }, RULES);
        expect(result.lastPeriodStart).toBe(on(0));
        expect(result.cycleDay).toBe(4);
        expect(result.currentPeriodEnd).toBe(on(3));
        expect(toCycleEstimate(result).phase?.code).toBe("menstrual");
        expect(result.prediction?.nextPeriodStart).toBe(shift(on(0), 28));
    });

    /**
     * **The gap counts days with nothing logged, not days without flow**, which is the one
     * place this reads the decision's wording rather than repeating it: a logged spotting day
     * keeps the run open, as #181 built it. Counting spotting as a dry day would make the
     * first fixture two periods four days apart — the quiet split #186 was written to stop.
     */
    test("a logged spotting day keeps a period open; only days with nothing logged are a gap", () => {
        const spottedMiddle = analyze(
            history(flow(on(0)), flow(on(1)), spotting(on(2)), spotting(on(3)), flow(on(4))),
        );
        expect(spottedMiddle.lastPeriodStart).toBe(on(0));
        expect(spottedMiddle.currentPeriodEnd).toBe(on(4));

        // One missed day beside a spotting day is still one missed day…
        const besideSpotting = history(flow(on(0)), spotting(on(1)), flow(on(3)));
        expect(analyze(besideSpotting).lastPeriodStart).toBe(on(0));
        // …and spotting on either side does not bridge two of them.
        const twoBetweenSpotting = history(flow(on(0)), spotting(on(1)), spotting(on(4)), flow(on(5)));
        expect(analyze(twoBetweenSpotting).lastPeriodStart).toBe(on(5));
    });

    /**
     * #181's case, which the parent issue requires stays closed: the gap rule must not turn a
     * history that genuinely varies into a regular one. Missing a day in every period changes
     * nothing about it — the answer is the clean history's, and the clean history is withheld.
     */
    test("alternating 28 and 60 days stays withheld, with a day missed in every period or not", () => {
        const alternating = periods([28, 60, 28, 60, 28, 60], 5, 5);
        // `periods` writes five days per period in order, so index 2 of each five is day 3.
        const missedEach = alternating.filter((_, index) => index % 5 !== 2);
        for (const days of [alternating, missedEach]) {
            const result = analyze(days, profileAged(30));
            expect(result.countedCycles).toBe(3);
            expect(result.variationDays).toBe(32);
            expect(result.irregular).toBe(true);
            expect(result.prediction).toBe(null);
            expect(result.withheld).toBe("irregular-cycles");
            expect(toCycleEstimate(result).phase).toBe(null);
        }
        expect(analyze(missedEach, profileAged(30))).toEqual(analyze(alternating, profileAged(30)));
    });
});

// ── The period-end mark (#75, #186) ────────────────────────────────────────────────────

/**
 * **What the mark decides, and the only thing it decides**: whether a later flow day
 * continues the period she marked as ended. Within the gap it does — the mark was premature
 * and changes nothing. At or beyond the gap it opens a new period and the mark stands.
 *
 * The mark is only *observable* where it disagrees with the unmarked rule, and that is a
 * logged spotting day after it: unmarked, spotting keeps a period open; after she said the
 * period ended, it does not. So the cases that prove the mark is read at all are the
 * spotting ones — with only missed days between, marked and unmarked agree by design.
 */
describe("a period-end mark decides only whether later flow continues that period", () => {
    test("flow within the gap after a mark: the period had not ended, and the mark changes nothing", () => {
        const afterTheMark: { after: CycleDay[]; end: string }[] = [
            { after: [flow(on(3))], end: on(3) }, // flow the very next day
            { after: [flow(on(4))], end: on(4) }, // one day missed
            { after: [spotting(on(3)), flow(on(4))], end: on(4) }, // one spotting day
        ];
        for (const { after, end } of afterTheMark) {
            const days = history(flow(on(0)), flow(on(1)), flowEnded(on(2)), ...after);
            const marked = analyze(days);
            expect(marked.lastPeriodStart).toBe(LATEST_START);
            expect(marked.currentPeriodEnd).toBe(end);
            expect(marked.cycleDay).toBe(11);
            expect(marked.prediction?.nextPeriodStart).toBe("2026-07-03");
            expect(toCycleEstimate(marked).phase?.code).toBe("ovulation");
            expect(marked).toEqual(analyze(unmarked(days)));
        }
    });

    test("flow at the gap or beyond it after a mark is a new period, and the mark stands", () => {
        // Two missed days: a new period whether she marked it or not — the mark and the gap agree.
        const missed = history(flow(on(0)), flow(on(1)), flowEnded(on(2)), flow(on(5)));
        expect(analyze(missed).lastPeriodStart).toBe(on(5));
        expect(analyze(unmarked(missed)).lastPeriodStart).toBe(on(5));

        // Two spotting days. Unmarked, spotting keeps the period open and this is one period,
        // with the clean history's estimate…
        const spotted = history(
            flow(on(0)),
            flow(on(1)),
            flowEnded(on(2)),
            spotting(on(3)),
            spotting(on(4)),
            flow(on(5)),
        );
        const withoutMark = analyze(unmarked(spotted));
        expect(withoutMark.lastPeriodStart).toBe(LATEST_START);
        expect(withoutMark.cycleDay).toBe(11);
        expect(withoutMark.prediction?.nextPeriodStart).toBe("2026-07-03");
        expect(toCycleEstimate(withoutMark).phase?.code).toBe("ovulation");

        // …but she said it ended on day 3 and two days without flow followed, so day 6 opens a
        // new period, and everything downstream of the anchor follows from that.
        const withMark = analyze(spotted);
        expect(withMark.lastPeriodStart).toBe(on(5));
        expect(withMark.cycleDay).toBe(6);
        expect(withMark.cycles.at(-1)).toEqual({
            startDate: LATEST_START,
            endDate: on(5),
            lengthDays: 5,
            counted: false,
            excluded: "unusual-length",
        });
        expect(withMark.prediction).toBe(null);
        expect(withMark.withheld).toBe("irregular-cycles");
        expect(toCycleEstimate(withMark).phase).toBe(null);
    });

    /** "Stale" is a property of the mark once flow has continued past it, not of the run. */
    test("a mark that flow has already continued past is stale, and decides nothing later", () => {
        // Marked on day 2, flow again on day 3: the mark was premature. Two spotting days after
        // day 3 then keep the period open as they would for anyone, because day 3 is unmarked.
        const days = history(
            flow(on(0)),
            flowEnded(on(1)),
            flow(on(2)),
            spotting(on(3)),
            spotting(on(4)),
            flow(on(5)),
        );
        expect(analyze(days).lastPeriodStart).toBe(LATEST_START);
        expect(analyze(days)).toEqual(analyze(unmarked(days)));
    });

    /**
     * #75's scope line, which #186 keeps: the mark is not an end date, a period length or a
     * cycle length. With no flow after it, nothing it could decide arises, so the answer is
     * the unmarked one exactly — including the period's end, which still runs through the
     * spotting she logged after the mark. Three spotting days, so the last is past the gap:
     * the mark may not end the run on a day that is not flow either.
     */
    test("with no flow after it, the mark is read for nothing: the answer is the unmarked one", () => {
        const trailing = history(
            flow(on(0)),
            flow(on(1)),
            flowEnded(on(2)),
            spotting(on(3)),
            spotting(on(4)),
            spotting(on(5)),
        );
        const at = (days: CycleDay[]) =>
            analyzeCycles({ days, today: on(5), profile: profileAged(30) }, RULES);
        expect(at(trailing)).toEqual(at(unmarked(trailing)));
        expect(at(trailing).currentPeriodEnd).toBe(on(5));
        expect(toCycleEstimate(at(trailing)).phase?.code).toBe("menstrual");

        // A user who marks the end of every period gets exactly the answer of one who marks none.
        // `periods` writes five days per period in order, so index 4 of each five is the last.
        const everyEndMarked = periods([28, 28, 28, 28, 28], 10, 5).map((day, index) =>
            index % 5 === 4 ? flowEnded(day.localDate) : day,
        );
        expect(everyEndMarked.filter((day) => day.periodEnd === true)).toHaveLength(6);
        expect(analyze(everyEndMarked)).toEqual(analyze(unmarked(everyEndMarked)));
    });

    test("the same days in any order give the same answer, marks included", () => {
        const days = history(
            flow(on(0)),
            flowEnded(on(1)),
            spotting(on(2)),
            spotting(on(3)),
            flow(on(4)),
        );
        expect(analyze(days).lastPeriodStart).toBe(on(4));
        expect(analyze([...days].reverse())).toEqual(analyze(days));

        // Two flow entries on one day only come from a hand-edited document (`events.ts` keys
        // an entry by its day). The mark then holds only if both carry it, whichever is read
        // first — the direction that merges rather than splits.
        const doubledFirst = [flow(on(1)), ...days];
        const doubledLast = [...days, flow(on(1))];
        expect(analyze(doubledFirst).lastPeriodStart).toBe(LATEST_START);
        expect(analyze(doubledFirst)).toEqual(analyze(doubledLast));
        expect(analyze([flowEnded(on(1)), ...days]).lastPeriodStart).toBe(on(4));
    });
});

// ── "Excluded from estimates and still returned, flagged" (A25 item 1) ─────────────────

describe("a cycle outside 21-45 days is excluded AND still returned, flagged", () => {
    /**
     * The named failure, in both halves. Excluding the short cycle from the estimate while
     * omitting it from `cycles` passes every estimate assertion in this file and is exactly
     * the bug "never silently dropped" forbids — so the second expectation is the point of
     * the case, not a decoration on it.
     */
    test("a 20-day cycle is not counted, and is in the output marked unusual-length", () => {
        const result = analyze(periods([28, 20, 29], 5));
        expect(result.countedCycles).toBe(2);
        expect(result.cycles.length).toBe(3);
        const short = result.cycles.find((cycle) => cycle.lengthDays === 20);
        expect(short).toBeDefined();
        expect(short?.counted).toBe(false);
        expect(short?.excluded).toBe("unusual-length");
    });

    test("a 46-day cycle is not counted, and is in the output marked unusual-length", () => {
        const result = analyze(periods([28, 46, 29], 5));
        expect(result.countedCycles).toBe(2);
        expect(result.cycles.length).toBe(3);
        const long = result.cycles.find((cycle) => cycle.lengthDays === 46);
        expect(long?.counted).toBe(false);
        expect(long?.excluded).toBe("unusual-length");
    });

    test("21 and 45 are inside the range; 20 and 46 are the first ones outside it", () => {
        const countedAt = (length: number) =>
            analyze(periods([length], 5)).cycles[0]?.counted ?? null;
        expect(countedAt(20)).toBe(false);
        expect(countedAt(21)).toBe(true);
        expect(countedAt(45)).toBe(true);
        expect(countedAt(46)).toBe(false);
    });

    /** PRD #176 Risks: "A user who mislogs one period start gets a long cycle that is
     *  excluded — and if that leaves her under 3, predictions vanish with no obvious
     *  cause… the reason must be legible in the output." */
    test("an excluded cycle that drops her under the gate withdraws the prediction, with the reason in the output", () => {
        const whole = analyze(periods([28, 29, 30], 5));
        expect(whole.prediction).not.toBe(null);

        const mislogged = analyze(periods([28, 29, 60], 5));
        expect(mislogged.countedCycles).toBe(2);
        expect(mislogged.prediction).toBe(null);
        expect(mislogged.withheld).toBe("too-few-counted-cycles");
        // …and the 60-day interval is still on the record for Cycle history to show.
        expect(mislogged.cycles.map((cycle) => cycle.excluded)).toEqual([
            null,
            null,
            "unusual-length",
        ]);
    });
});

// ── The ≥3 gate (A26, PRD Confidence and cold start 2) ─────────────────────────────────

describe("under three counted cycles there is no prediction and no window", () => {
    test("two counted cycles: nothing predicted, and the reason says which gate", () => {
        const result = analyze(periods([28, 29], 5));
        expect(result.countedCycles).toBe(2);
        expect(result.enoughCountedCycles).toBe(false);
        expect(result.prediction).toBe(null);
        expect(result.withheld).toBe("too-few-counted-cycles");
    });

    test("three counted cycles: a prediction and a fertile window appear", () => {
        const result = analyze(periods([28, 28, 28], 5));
        expect(result.countedCycles).toBe(3);
        expect(result.enoughCountedCycles).toBe(true);
        expect(result.prediction).not.toBe(null);
        expect(result.withheld).toBe(null);
    });

    test("one logged period and no complete cycle yet: a reason, not a null to interpret", () => {
        const result = analyze(periods([], 3));
        expect(result.countedCycles).toBe(0);
        expect(result.lastPeriodStart).not.toBe(null);
        expect(result.prediction).toBe(null);
        // Flow *was* logged — saying "no flow" here would send C12 to explain the wrong thing.
        expect(result.withheld).toBe("too-few-counted-cycles");
    });

    test("nothing logged at all", () => {
        const result = analyze([]);
        expect(result.cycleDay).toBe(null);
        expect(result.prediction).toBe(null);
        expect(result.withheld).toBe("no-flow-logged");
    });
});

// ── The median (A26 item 3) ────────────────────────────────────────────────────────────

describe("next period is the median of the last six counted cycles, not the mean", () => {
    /**
     * Six lengths, every one of them inside 21–45 so the countable range cannot be what
     * separates the two answers, and spanning exactly 9 days so a 20-year-old's FIGO band
     * cannot either. Sorted they are 26, 26, 26, 26, 35, 35: the median is 26 and the mean
     * is 29. Three days between the predicted dates — a case that passed under both would
     * not be a test of this rule at all.
     */
    test("two long cycles inside the range move the mean and do not move the median", () => {
        const result = analyze(periods([26, 35, 26, 26, 35, 26], 5), profileAged(20));
        expect(result.countedCycles).toBe(6);
        expect(result.irregular).toBe(false);
        expect(result.medianCycleLengthDays).toBe(26);
        expect(result.prediction?.nextPeriodStart).toBe(shift(TODAY, -5 + 26));
        // The mean's answer, named so the case says what it is *not*.
        expect(result.prediction?.nextPeriodStart).not.toBe(shift(TODAY, -5 + 29));
    });

    test("an odd-sized sample takes the middle value", () => {
        expect(analyze(periods([22, 40, 30], 5)).medianCycleLengthDays).toBe(30);
    });

    /**
     * An even-sized sample whose two middle values *differ*, which no other case in this
     * file has: 27 and 28 average to 27.5, and half a day is not a date. Every other median
     * fixture is odd-sized or has equal middles, so nothing reached the rounding at all and
     * `Math.floor` passed the whole file.
     *
     * It kills `floor` and cannot kill `ceil`: two integers average to a whole number or to
     * an exact half, and `Math.round` and `Math.ceil` agree on every exact half. `ceil` is
     * an equivalent mutant here rather than an untested branch — which is worth saying,
     * because the two look identical from a mutation table.
     */
    test("an even-sized sample rounds the half-day up to a whole one", () => {
        const result = analyze(periods([25, 26, 27, 28, 29, 30], 5), profileAged(20));
        expect(result.countedCycles).toBe(6);
        expect(result.irregular).toBe(false);
        expect(result.medianCycleLengthDays).toBe(28);
        // …and the rounded value is what the date is built from, not a display-only number.
        expect(result.prediction?.nextPeriodStart).toBe(shift(TODAY, -5 + 28));
        expect(result.prediction?.nextPeriodStart).not.toBe(shift(TODAY, -5 + 27));
    });

    test("only the last six counted cycles are read", () => {
        // Eight cycles; the two oldest are 45s that would drag any answer that saw them.
        const result = analyze(periods([45, 45, 28, 28, 28, 28, 28, 28], 5));
        expect(result.countedCycles).toBe(8);
        expect(result.medianCycleLengthDays).toBe(28);
        expect(result.variationDays).toBe(0);
        expect(result.irregular).toBe(false);
    });

    test("the prediction is applied from the last first flow day", () => {
        const result = analyze(periods([28, 28, 28], 12));
        expect(result.lastPeriodStart).toBe(shift(TODAY, -12));
        expect(result.prediction?.nextPeriodStart).toBe(shift(TODAY, 16));
    });
});

// ── The FIGO bands (A25 item 2) ────────────────────────────────────────────────────────

describe("irregularity uses the FIGO band for the user's age", () => {
    /** Six cycles spanning exactly `spread` days shortest-to-longest, all inside 21–45. */
    const spreadOf = (spread: number) => periods([28, 28, 28, 28, 28, 28 + spread], 5);

    const irregularAt = (age: number | null, spread: number) =>
        analyze(spreadOf(spread), age === null ? null : profileAged(age)).irregular;

    test("18-25: more than 9 days is irregular, 9 is not", () => {
        expect(irregularAt(18, 9)).toBe(false);
        expect(irregularAt(18, 10)).toBe(true);
        expect(irregularAt(25, 9)).toBe(false);
        expect(irregularAt(25, 10)).toBe(true);
    });

    test("26-41: more than 7 days is irregular, 7 is not", () => {
        expect(irregularAt(26, 7)).toBe(false);
        expect(irregularAt(26, 8)).toBe(true);
        expect(irregularAt(41, 7)).toBe(false);
        expect(irregularAt(41, 8)).toBe(true);
    });

    test("42 and over: more than 9 days is irregular, 9 is not", () => {
        expect(irregularAt(42, 9)).toBe(false);
        expect(irregularAt(42, 10)).toBe(true);
        expect(irregularAt(55, 9)).toBe(false);
        expect(irregularAt(55, 10)).toBe(true);
    });

    /**
     * The band edges themselves, which is where a one-off in the comparison hides: at a
     * spread of 8 days the answer flips across 25→26 and flips back across 41→42, so all
     * three bands are distinguished by one fixture.
     */
    test("the band changes at 25→26 and back at 41→42", () => {
        expect([25, 26, 41, 42].map((age) => irregularAt(age, 8))).toEqual([
            false,
            true,
            true,
            false,
        ]);
    });

    test("irregular means no prediction and no fertile window, with the reason stated", () => {
        const result = analyze(spreadOf(10), profileAged(30));
        expect(result.irregular).toBe(true);
        expect(result.prediction).toBe(null);
        expect(result.withheld).toBe("irregular-cycles");
        // She still has enough cycles — D1 needs that to be true, or it would select
        // "still learning" for a user whose problem is variation rather than volume.
        expect(result.enoughCountedCycles).toBe(true);
    });

});

// ── The variation reads every interval, the median only the counted ones ───────────────

/**
 * **The gate sees an out-of-range interval; the estimate still does not.**
 *
 * A25 item 2 says "over the last 6 *counted* cycles", and taken literally that makes the
 * gate fail open on the shape this product is for: intervals alternating 28 and 60 days
 * leave three counted cycles, every one of them 28, so the spread is zero and an
 * oligomenorrhoeic user is handed a fertile window, a confidence band and a phase. §Phase 1
 * rules 4 and 5 and #176's own Risks all say the opposite, and they are the same
 * requirement stated three more times. So the median keeps reading counted cycles only —
 * that is what the range filter is for — and the variation reads every interval between
 * them.
 *
 * Each case below dies if the variation is computed over the counted cycles again.
 */
describe("the variation reads every interval in the window, not only the counted ones", () => {
    /** The measured case: alternating 28 and 60 gave variation 0, a window, and a phase. */
    test("alternating 28 and 60 days is irregular, not a run of perfect 28s", () => {
        const result = analyze(periods([28, 60, 28, 60, 28, 60], 5), profileAged(30));
        expect(result.countedCycles).toBe(3);
        expect(result.variationDays).toBe(32);
        expect(result.irregular).toBe(true);
        expect(result.prediction).toBe(null);
        expect(result.withheld).toBe("irregular-cycles");
        // No phase either: a phase without a prediction is an estimate with no band behind it.
        expect(toCycleEstimate(result).phase).toBe(null);
    });

    /**
     * The same shape at the short end — 20 days is under the 21-day floor.
     *
     * **And the band still decides, which this case says out loud.** The spread is 8 days,
     * so it is over the 26–41 band and under the 18–25 one, and a 20-year-old with these
     * intervals keeps her window. That is A25 item 2 answering, not a gap left by this
     * change: what the change fixes is that the 20-day intervals are *seen* at all. Whether
     * an out-of-range interval should close the gate on its own — regardless of spread — is
     * a rule the PRD has not written, and inventing one here would be inventing a constant.
     */
    test("alternating 28 and 20 days is irregular at the 7-day band", () => {
        const result = analyze(periods([28, 20, 28, 20, 28, 20], 5), profileAged(30));
        expect(result.countedCycles).toBe(3);
        expect(result.variationDays).toBe(8);
        expect(result.irregular).toBe(true);
        expect(result.withheld).toBe("irregular-cycles");
        // Unknown age lands on the tightest band and gets the same answer.
        expect(analyze(periods([28, 20, 28, 20, 28, 20], 5), null).irregular).toBe(true);
        // …and the 9-day band does not, because 8 is not more than 9.
        expect(analyze(periods([28, 20, 28, 20, 28, 20], 5), profileAged(20)).irregular).toBe(
            false,
        );
    });

    /** One long interval among otherwise regular cycles is enough on its own. */
    test("a single 50-day interval among 28s withholds the window", () => {
        const result = analyze(periods([28, 28, 50, 28, 28], 5), profileAged(30));
        expect(result.variationDays).toBe(22);
        expect(result.irregular).toBe(true);
        expect(result.prediction).toBe(null);
    });

    /**
     * Both halves in one case, which is the point: the 60-day interval is loud enough to
     * close the gate and invisible to the median. A mean over the same seven intervals is
     * 33; the median over the six counted ones is 28.
     */
    test("the median still ignores the interval the gate acts on", () => {
        const result = analyze(periods([28, 60, 28, 28, 28, 28, 28], 5), profileAged(30));
        expect(result.countedCycles).toBe(6);
        expect(result.medianCycleLengthDays).toBe(28);
        expect(result.variationDays).toBe(32);
        expect(result.irregular).toBe(true);
        expect(result.withheld).toBe("irregular-cycles");
    });

    /**
     * The window still ends where A25 says it ends. An out-of-range interval older than the
     * oldest counted cycle the median reads is outside the six-cycle window and stays
     * outside it — this change widens *which intervals inside the window* count, not how
     * far back the window reaches.
     */
    test("an interval older than the window is still out of it", () => {
        const result = analyze(periods([60, 28, 28, 28, 28, 28, 28], 5), profileAged(30));
        expect(result.countedCycles).toBe(6);
        expect(result.variationDays).toBe(0);
        expect(result.irregular).toBe(false);
        expect(result.prediction).not.toBe(null);
    });

    /**
     * The other tempting arithmetic — "the last six *intervals*, counted or not" — and why
     * it is not what this does. Six regular cycles followed by six 60-day ones is a history
     * that has changed: the median is still 28 because only the old cycles are countable,
     * and the last six intervals are all 60, so a spread over *them* is zero. She would be
     * told to expect a period in 28 days on the strength of data that stopped applying six
     * cycles ago. The window runs from the oldest cycle the median reads, so it sees both.
     */
    test("cycles that have lengthened are irregular, not a new run of regular 60s", () => {
        const lengthened = [28, 28, 28, 28, 28, 28, 60, 60, 60, 60, 60, 60];
        const result = analyze(periods(lengthened, 5), profileAged(30));
        expect(result.countedCycles).toBe(6);
        expect(result.medianCycleLengthDays).toBe(28);
        expect(result.variationDays).toBe(32);
        expect(result.irregular).toBe(true);
        expect(result.prediction).toBe(null);
    });

    /** And a genuinely regular history is untouched: nothing here suppresses a real window. */
    test("six regular cycles still get their window", () => {
        const result = analyze(periods([27, 28, 29, 28, 27, 28], 5), profileAged(30));
        expect(result.variationDays).toBe(2);
        expect(result.irregular).toBe(false);
        expect(result.prediction?.confidence).toBe("narrow");
    });
});

describe("age unknown takes the tightest band", () => {
    const spreadOf = (spread: number) => periods([28, 28, 28, 28, 28, 28 + spread], 5);

    /**
     * 7, not 9. A spread of 8 days is regular for a 20-year-old and for a 50-year-old, and
     * irregular for someone whose age we do not know — because suppressing more is the safe
     * direction and the permissive bands are the ones a silent fallback would reach for.
     */
    test("no profile: 7 days, the same answer a 26-41-year-old gets", () => {
        expect(analyze(spreadOf(7), null).irregular).toBe(false);
        expect(analyze(spreadOf(8), null).irregular).toBe(true);
        expect(bandForAge(null, RULES, TODAY)).toEqual({ ageYears: null, maxVariationDays: 7 });
    });

    test("it does not fall back to the youngest band, which is the permissive one", () => {
        expect(analyze(spreadOf(8), profileAged(20)).irregular).toBe(false);
        expect(analyze(spreadOf(8), null).irregular).toBe(true);
        expect(bandForAge(null, RULES, TODAY).maxVariationDays).not.toBe(
            RULES.irregularity.youngVariationDays,
        );
    });

    /**
     * **A corrupted date of birth must not be trusted more than a missing one**, which is
     * what this list is about. Under `profile.age` a stored `200`, `1e9`, `2.5` or `5` fell
     * through to a real band, and the bands at both ends of the range are the *permissive*
     * ones — so a nonsense age bought a 9-day tolerance while an absent one got 7. That is
     * the inverse of the rule this describe block is named for, and the shape of it survives
     * the move to a date: `"30"`, `true` and `2026-06-31` are all values the field can hold
     * and none of them is a day.
     *
     * Every entry here is *unreadable* rather than *impossible*. A date that reads fine and
     * puts her under Eva's floor is the other case entirely and throws — see the block
     * below, and `ImpossibleAgeError` for why the two ends differ.
     *
     * The route already refuses all of these (`parseProfile`), so reaching them takes a
     * hand-edited document — the same threat model `dayNumber`'s round-trip check and
     * `firstFlowDays`' both-markers rule are floors under.
     */
    test("a profile carrying no usable date of birth is the same as no profile", () => {
        const notADateOfBirth: unknown[] = [
            undefined,
            null,
            "",
            30,
            "30",
            true,
            "1996-06-15T00:00:00.000Z",
            "15/06/1996",
            "1996-6-15", // right day, wrong shape
            "1996-02-30", // right shape, never a day
            "1820-06-15", // a real day, and past any plausible age
        ];
        for (const dateOfBirth of notADateOfBirth) {
            const profile = { ...profileAged(30), dateOfBirth } as Profile;
            expect(bandForAge(profile, RULES, TODAY).maxVariationDays).toBe(7);
            expect(bandForAge(profile, RULES, TODAY).ageYears).toBe(null);
        }
    });

    /** The edges themselves, so "implausible" cannot quietly grow to swallow a real user.
     *  18 is the floor the route enforces; 99 is the last age this module will band. */
    test("the ages the route accepts still get their own band", () => {
        expect(bandForAge(profileAged(18), RULES, TODAY)).toEqual({ ageYears: 18, maxVariationDays: 9 });
        expect(bandForAge(profileAged(99), RULES, TODAY)).toEqual({ ageYears: 99, maxVariationDays: 9 });
        expect(bandForAge(profileAged(30), RULES, TODAY)).toEqual({ ageYears: 30, maxVariationDays: 7 });
    });

    /** And it reaches the gate, not only the band: an unreadable date suppresses a window
     *  a permissive band would have drawn. */
    test("an implausible date of birth withholds a window the permissive band would have drawn", () => {
        const spread8 = spreadOf(8);
        expect(analyze(spread8, profileAged(20)).prediction).not.toBe(null);
        const corrupted = { ...profileAged(20), dateOfBirth: "1820-06-15" } as Profile;
        const result = analyze(spread8, corrupted);
        expect(result.irregular).toBe(true);
        expect(result.prediction).toBe(null);
        expect(result.withheld).toBe("irregular-cycles");
    });

    /** The tightest band is *computed*, so re-tuning one band tighter than the others moves
     *  the unknown-age answer with it rather than leaving it pinned to a stale winner. */
    test("the fallback follows the configuration rather than naming a band", () => {
        const tighterYoung: CycleRules = {
            ...RULES,
            irregularity: { ...RULES.irregularity, youngVariationDays: 3 },
        };
        expect(bandForAge(null, tighterYoung, TODAY).maxVariationDays).toBe(3);
    });
});

/**
 * **An age below Eva's floor stops; it does not fall back** (#187, closed with #81).
 *
 * This is the one place in the file where an age the module cannot use is *not* read as
 * unknown, and the asymmetry is the point. A25's youngest band is **18**–25, and
 * `bandForAge` applied it from 13 — so a 13-to-17-year-old drew the *most permissive*
 * 9-day tolerance at the age when cycles are least regular, which is the inverse of every
 * other decision here. The fix is not an adolescent band, because FIGO's cited table does
 * not supply one, and not a clamp to the tightest band either: Eva is 18+ (A12) and
 * `parseProfile` refuses a date of birth under it, so an age below the floor means a bug of
 * ours or a minor who got past the account check. Both are conditions to stop on.
 *
 * Nothing was ever live in a harmful way — `config.dashboard.pattern` was unset until #191
 * and no account under 18 exists — so these cases close the door rather than repair damage.
 */
describe("an age under the account floor refuses rather than banding", () => {
    const spreadOf = (spread: number) => periods([28, 28, 28, 28, 28, 28 + spread], 5);

    /** The case #187 was filed for, stated as the band it must not reach. */
    test("a seventeen-year-old does not get the permissive young band", () => {
        expect(bandForAge(profileAged(18), RULES, TODAY).maxVariationDays).toBe(
            RULES.irregularity.youngVariationDays,
        );
        expect(() => bandForAge(profileAged(17), RULES, TODAY)).toThrow(ImpossibleAgeError);
        expect(() => bandForAge(profileAged(13), RULES, TODAY)).toThrow(ImpossibleAgeError);
    });

    /** It fails **loudly**: the whole analysis refuses, rather than answering over a band
     *  chosen for somebody else. A spread of 9 is regular on the young band and irregular on
     *  every other one, so a clamp in either direction would still return an answer here. */
    test("the refusal reaches the whole analysis, not only the band", () => {
        expect(analyze(spreadOf(9), profileAged(18)).irregular).toBe(false);
        expect(() => analyze(spreadOf(9), profileAged(17))).toThrow(ImpossibleAgeError);
    });

    /**
     * The boundary is her birthday itself — the same date of birth, read on two consecutive
     * days. Eighteen today is in; one day short of eighteen is out.
     */
    test("eighteen today is in; the day before her birthday is out", () => {
        const eighteenToday = profileAged(18);
        expect(bandForAge(eighteenToday, RULES, TODAY).ageYears).toBe(18);
        expect(() => bandForAge(eighteenToday, RULES, shift(TODAY, -1))).toThrow(
            ImpossibleAgeError,
        );
    });

    /**
     * The asymmetry, as an assertion rather than a comment: the *upper* end of the range
     * resolves to the tightest band, and this end resolves to nothing at all. They are
     * different because only one of them contradicts a check that actually ran — nothing
     * anywhere refuses a woman of 104, so an age of 206 is a corrupt field, while an age of
     * 17 is an invariant that has not held.
     */
    test("the far end of the range falls back, and this end does not", () => {
        expect(bandForAge(profileBornOn("1820-06-15"), RULES, TODAY)).toEqual({
            ageYears: null,
            maxVariationDays: 7,
        });
        expect(() => bandForAge(profileAged(5), RULES, TODAY)).toThrow(ImpossibleAgeError);
    });

    /** A date of birth after today is impossible, not unknown: it reads as a negative age,
     *  which is under the floor. */
    test("a date of birth in the future refuses", () => {
        expect(() => bandForAge(profileBornOn(shift(TODAY, 1)), RULES, TODAY)).toThrow(
            ImpossibleAgeError,
        );
    });

    /** GUARDRAILS 12: the refusal names our own floor and nothing of hers. An error message
     *  is as readable as a log line, and a date of birth is profile content. */
    test("the refusal carries no date of birth and no derived age", () => {
        const profile = profileAged(17);
        expect(() => bandForAge(profile, RULES, TODAY)).toThrow(/floor of 18/);
        try {
            bandForAge(profile, RULES, TODAY);
            throw new Error("bandForAge did not throw");
        } catch (err) {
            const message = (err as Error).message;
            expect(message).toContain("18");
            expect(message).not.toContain(profile.dateOfBirth);
            expect(message).not.toContain("17");
        }
    });
});

/**
 * **The floor is one number, declared twice.** `cycle.ts` imports only types — that is what
 * keeps it pure, and a source scan above pins it — so the route's floor and the maths' floor
 * cannot be one constant without either a runtime import into the maths or a boundary
 * violation out of it. This reads both files instead, which is the same idiom
 * `auth.test.ts` uses to hold the password rule and its Astro page together.
 *
 * Only the *floor* is duplicated. The arithmetic is not: `parseProfile` imports
 * `ageYearsOn` through `today.ts`, because the obvious second implementation disagrees with
 * this one on 29 February.
 */
describe("the account floor is one number", () => {
    const floorIn = async (file: string): Promise<string | null> => {
        const source = await Bun.file(`${import.meta.dir}/../src/${file}`).text();
        return source.match(/const MIN_ACCOUNT_AGE_YEARS = (\d+)/)?.[1] ?? null;
    };

    test("`cycle.ts` and `index.ts` declare the same one", async () => {
        const maths = await floorIn("cycle.ts");
        // Named, so the case fails if the constant is renamed away rather than passing on
        // two nulls — the way a derived list fails when it derives as empty.
        expect(maths).toBe("18");
        expect(await floorIn("index.ts")).toBe(maths);
    });
});

/**
 * `ageYearsOn` on its own, because it is now exported and `parseProfile` is its second
 * reader (#81). Whole years by calendar parts, not by dividing a day count: 18 years is
 * 6574 days or 6575 depending on the leap days inside it, and the difference is a day on
 * somebody's birthday.
 */
describe("whole years between two calendar dates", () => {
    test("the birthday itself is the increment", () => {
        expect(ageYearsOn("1996-06-15", "2026-06-14")).toBe(29);
        expect(ageYearsOn("1996-06-15", "2026-06-15")).toBe(30);
        expect(ageYearsOn("1996-06-15", "2026-06-16")).toBe(30);
    });

    test("a month boundary is not a year boundary", () => {
        expect(ageYearsOn("1996-12-31", "2026-01-01")).toBe(29);
        expect(ageYearsOn("1996-01-01", "2026-12-31")).toBe(30);
    });

    /** A leap-day birth date has its birthday on 1 March in a non-leap year — a day later
     *  rather than a day earlier, which is the direction an age floor should err in. */
    test("29 February turns a year older on 1 March in a non-leap year", () => {
        expect(ageYearsOn("2008-02-29", "2026-02-28")).toBe(17);
        expect(ageYearsOn("2008-02-29", "2026-03-01")).toBe(18);
        // …and on 29 February itself in a leap year.
        expect(ageYearsOn("2008-02-29", "2028-02-29")).toBe(20);
        expect(ageYearsOn("2008-02-29", "2028-02-28")).toBe(19);
    });

    test("a date of birth after the day it is measured on reads as negative", () => {
        expect(ageYearsOn("2030-06-15", "2026-06-15")).toBe(-4);
    });

    /** `today` is the caller's to get right on every path in this file, so a bad one throws
     *  rather than resolving to anything. */
    test("a today that is not a calendar date throws", () => {
        expect(() => ageYearsOn("1996-06-15", "2026-02-30")).toThrow(InvalidCycleDateError);
    });
});

// ── Ovulation, the fertile window and the band (A26 item 3, A27) ───────────────────────

describe("the fertile window is derived from the fixed-luteal convention", () => {
    const predicted = () => analyze(periods([28, 28, 28], 5)).prediction;

    test("ovulation is the predicted next period minus the luteal phase", () => {
        const next = shift(TODAY, 23);
        expect(predicted()?.nextPeriodStart).toBe(next);
        expect(predicted()?.ovulation).toBe(shift(next, -14));
    });

    test("the window is ovulation − 5 through ovulation + 1, peak two days before through ovulation day", () => {
        const window = predicted()!.fertileWindow;
        const ovulation = predicted()!.ovulation;
        expect(window.from).toBe(shift(ovulation, -5));
        expect(window.to).toBe(shift(ovulation, 1));
        expect(window.peakFrom).toBe(shift(ovulation, -2));
        expect(window.peakTo).toBe(ovulation);
    });

    test("the band is wide at 3-5 counted cycles and narrow at 6 or more", () => {
        const confidenceAt = (cycles: number) =>
            analyze(periods(Array.from({ length: cycles }, () => 28), 5)).prediction?.confidence;
        expect(confidenceAt(3)).toBe("wide");
        expect(confidenceAt(5)).toBe("wide");
        expect(confidenceAt(6)).toBe("narrow");
        expect(confidenceAt(7)).toBe("narrow");
    });
});

// ── Cycle day, lateness and the phase ──────────────────────────────────────────────────

describe("cycle day counts from the current cycle's first flow day", () => {
    test("day 1 is the first flow day itself", () => {
        expect(analyze(periods([28], 0)).cycleDay).toBe(1);
        expect(analyze(periods([28], 1)).cycleDay).toBe(2);
        expect(analyze(periods([28], 20)).cycleDay).toBe(21);
    });

    test("a day before anything she logged has no cycle day and no phase", () => {
        const result = analyzeCycles(
            { days: periods([28, 28, 28], 5), today: "2020-01-01", profile: profileAged(30) },
            RULES,
        );
        expect(result.cycleDay).toBe(null);
        expect(toCycleEstimate(result).phase).toBe(null);
    });
});

describe("lateness is counted, never judged", () => {
    test("null until the predicted day has actually passed", () => {
        // Periods 28 days apart, the last one 28 days ago: the prediction lands on today.
        const onTheDay = analyze(periods([28, 28, 28], 28));
        expect(onTheDay.prediction?.nextPeriodStart).toBe(TODAY);
        expect(toCycleEstimate(onTheDay).daysPastPredictedPeriod).toBe(null);

        const late = analyze(periods([28, 28, 28], 31));
        expect(toCycleEstimate(late).daysPastPredictedPeriod).toBe(3);
    });

    test("no prediction means no lateness, however long ago the last period was", () => {
        const twoCycles = analyze(periods([28, 29], 60));
        expect(twoCycles.prediction).toBe(null);
        expect(toCycleEstimate(twoCycles).daysPastPredictedPeriod).toBe(null);
    });
});

describe("the phase", () => {
    const phaseAt = (daysAgo: number) =>
        toCycleEstimate(analyze(periods([28, 28, 28], daysAgo)))?.phase?.code ?? null;

    test("menstrual while today is inside the logged period run", () => {
        expect(phaseAt(0)).toBe("menstrual");
        expect(phaseAt(3)).toBe("menstrual");
        // The run is four days long. Day five carries nothing, and one dry day no longer ends
        // the phase any more than it ends the period (#197, below); day six is two of them.
        expect(phaseAt(4)).toBe("menstrual");
        expect(phaseAt(5)).not.toBe("menstrual");
    });

    test("follicular before the window, ovulation inside it, luteal after", () => {
        // 28-day median: ovulation on cycle day 15, window days 10-16 inclusive.
        expect(phaseAt(8)).toBe("follicular");
        expect(phaseAt(9)).toBe("ovulation");
        expect(phaseAt(14)).toBe("ovulation");
        expect(phaseAt(15)).toBe("ovulation");
        expect(phaseAt(16)).toBe("luteal");
    });

    test("a withheld prediction withholds the phase too", () => {
        expect(toCycleEstimate(analyze(periods([28, 29], 8))).phase).toBe(null);
        const irregular = analyze(periods([22, 28, 28, 40], 8), profileAged(30));
        expect(irregular.irregular).toBe(true);
        expect(toCycleEstimate(irregular).phase).toBe(null);
    });
});

// ── The morning she has not logged yet (#197) ──────────────────────────────────────────

/**
 * **The phase ends a period the same way the grouping does (#186), and that is the whole
 * change.** It used to end on the run's last *logged* day, so a woman bleeding on cycle day 3
 * who had not logged that day yet was `follicular` — and rung 4, narrowed by #184 to exactly
 * that phase, then told her she was likely approaching ovulation and might consider a harder
 * training session. Every rung, template and gate was behaving as specified, which is what
 * made it invisible; `LogCycleStep.swift` logs one day at a time and back-fills nothing, so
 * "not logged yet" is the normal state of a morning rather than an edge case.
 *
 * **Derived values, not the classification** (#180's model, #186's table): the phase moves the
 * selected card, so the cases below assert the card `dashboard-rules.ts` returns as well as
 * the anchor, the cycle day and the predicted date that did *not* move.
 */
describe("a day she has not logged yet is still her period (#197)", () => {
    const RULES_D1: DashboardRules = {
        pattern: { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 3 },
    };
    /** Everything she has logged is flow, so no signal rung can fire and the card on screen is
     *  the one the phase chose. */
    const cardFor = (days: readonly CycleDay[], daysSinceLastLog: number): Subject => {
        const input: DashboardInput = {
            mode: "cycle",
            today: TODAY,
            now: `${TODAY}T09:00:00Z`,
            cycle: toCycleEstimate(analyze(days)),
            signals: [],
            redFlag: null,
            upcomingAppointments: [],
            profileComplete: true,
            nutritionSetUp: false,
            todayTotals: null,
            daysSinceLastLog,
        };
        return selectSubject(input, RULES_D1);
    };
    const educational: Subject = {
        rung: "education",
        templateId: TEMPLATE.educational,
        slots: {},
        confidence: "plain",
    };
    /** Six regular cycles — enough for a narrow band, so a phase is speakable and rung 4 is
     *  reachable. The most recent period is logged for `flowDays` days from `daysAgo` before
     *  `TODAY`, and nothing after that. */
    const regular = (daysAgo: number, flowDays: number) =>
        periods([28, 28, 28, 28, 28, 28], daysAgo, flowDays);

    /**
     * The issue's own case, with the card she was being shown. Before this change:
     * `follicular`, and `home_d` — "Cycle day 3 · likely approaching ovulation / Many women
     * notice higher energy around now / a harder training session may be an option".
     */
    test("flow logged on days 1 and 2, nothing logged on day 3: she is menstrual, and gets no ovulation card", () => {
        const days = regular(2, 2);
        const result = analyze(days);

        // The premise, stated rather than implied: she logged yesterday and not today.
        expect(result.currentPeriodEnd).toBe(shift(TODAY, -1));
        // #180's four values — only the phase moves; the anchor, the day and the date do not.
        expect(result.lastPeriodStart).toBe(shift(TODAY, -2));
        expect(result.cycleDay).toBe(3);
        expect(result.prediction?.nextPeriodStart).toBe(shift(TODAY, 26));
        expect(toCycleEstimate(result).phase).toEqual({ code: "menstrual", confidence: "narrow" });

        // And the card: the educational fallback, not `phase_energy` on cycle day 3.
        expect(cardFor(days, 1)).toEqual(educational);
    });

    /**
     * The boundary from both sides, and that it is the constant rather than a day written
     * next to it. At 1 — the pre-#186 rule, where any dry day ends a period — the defect is
     * back; at 3, two dry days are still her period.
     */
    test("one dry day is still her period; at the gap it has ended", () => {
        const phaseWith = (daysAgo: number, minPeriodGapDays: number) =>
            toCycleEstimate(
                analyzeCycles(
                    { days: regular(daysAgo, 2), today: TODAY, profile: profileAged(30) },
                    { ...RULES, minPeriodGapDays },
                ),
            ).phase?.code ?? null;

        // Logged through today, then one dry day, then two — the gap is 2.
        expect(phaseWith(1, 2)).toBe("menstrual");
        expect(phaseWith(2, 2)).toBe("menstrual");
        expect(phaseWith(3, 2)).toBe("follicular");

        // The same days read against the other two settings.
        expect(phaseWith(2, 1)).toBe("follicular");
        expect(phaseWith(3, 3)).toBe("menstrual");
        expect(phaseWith(4, 3)).toBe("follicular");
    });

    /**
     * The other end of the trade, which is what bounds it: she is never called menstrual more
     * than `minPeriodGapDays - 1` days past the last day she logged. A period she logged for
     * five days and stopped is over on the second dry morning, not indefinitely.
     */
    test("a period that ended days ago is not still menstrual", () => {
        const phaseAt = (daysAgo: number) =>
            toCycleEstimate(analyze(regular(daysAgo, 5))).phase?.code ?? null;
        expect(phaseAt(5)).toBe("menstrual"); // logged days 1-5, today is day 6: one dry day
        expect(phaseAt(6)).toBe("follicular");
        expect(phaseAt(8)).toBe("follicular");
        expect(cardFor(regular(8, 5), 4)).toEqual({
            rung: "phase",
            templateId: TEMPLATE.phaseEnergy,
            slots: { cycleDay: 9, phase: "follicular" },
            confidence: "hedged",
        });
    });

    /**
     * #181's case, which this must not reopen: a woman whose cycles alternate 28 and 60 days
     * has a variation of 32 and gets no window, no prediction and no phase. It is the case a
     * wider menstrual rule could fail *open* on — the menstrual arm is the one phase that is
     * observed rather than estimated, and reaching it before the withheld gate would hand her
     * a phase her data does not support. Her fixture is one dry day past her last logged day,
     * which is exactly the day this change widens.
     */
    test("[28, 60, 28, 60, 28, 60] stays withheld on the morning after her last logged day", () => {
        const days = periods([28, 60, 28, 60, 28, 60], 5, 5);
        const result = analyze(days, profileAged(30));

        // The premise: today is the first day she has not logged, inside the widened window.
        expect(result.currentPeriodEnd).toBe(shift(TODAY, -1));
        expect(result.countedCycles).toBe(3);
        expect(result.variationDays).toBe(32);
        expect(result.irregular).toBe(true);
        expect(result.prediction).toBe(null);
        expect(result.withheld).toBe("irregular-cycles");
        expect(toCycleEstimate(result).phase).toBe(null);
        // The card says so — no phase in it at all (`home_c`).
        expect(cardFor(days, 1)).toEqual({
            rung: "phase",
            templateId: TEMPLATE.irregular,
            slots: {},
            confidence: "hedged",
        });
    });
});

// ── Recomputed on read (A25 item 5) ────────────────────────────────────────────────────

describe("an edit to a flow entry changes the answer, with nothing cached", () => {
    test("removing the newest period moves the anchor and the prediction", () => {
        const logged = periods([28, 28, 28], 5);
        const before = analyze(logged);
        const newestStart = before.lastPeriodStart!;
        // The whole period, not only the day that opened it: deleting one day of a period
        // leaves the rest of the run, whose next flow day simply becomes the new start.
        const after = analyze(logged.filter((day) => day.localDate < newestStart));

        expect(after.lastPeriodStart).not.toBe(before.lastPeriodStart);
        expect(after.prediction?.nextPeriodStart).not.toBe(before.prediction?.nextPeriodStart);
        expect(after.countedCycles).toBe(before.countedCycles - 1);
    });

    test("changing a flow day to spotting moves the cycle start", () => {
        const start = shift(TODAY, -10);
        const asFlow = analyze(periods([28], 10));
        const asSpotting = analyze([
            ...periods([28], 10).filter((day) => day.localDate !== start),
            spotting(start),
        ]);
        expect(asFlow.lastPeriodStart).toBe(start);
        expect(asSpotting.lastPeriodStart).toBe(shift(start, 1));
    });

    test("the same input always gives the same answer", () => {
        const logged = periods([28, 29, 30], 5);
        expect(analyze(logged)).toEqual(analyze(logged));
    });
});

// ── The constants are configuration, not literals ──────────────────────────────────────

describe("no number in the maths is written in the maths", () => {
    test("the maths refuses to answer without constants", () => {
        expect(() => analyzeCycles({ days: [], today: TODAY, profile: null }, null)).toThrow(
            CycleRulesUnsetError,
        );
    });

    test("moving the countable range moves which cycles count", () => {
        const wider: CycleRules = { ...RULES, minCycleLengthDays: 19 };
        const logged = periods([28, 20, 29], 5);
        expect(analyze(logged).countedCycles).toBe(2);
        expect(analyzeCycles({ days: logged, today: TODAY, profile: null }, wider).countedCycles).toBe(3);
    });

    /**
     * The period gap, from both sides at two settings. At 1 — any missed day ends a period,
     * which is what this module did before #186 — #180's history splits again, which is the
     * proof that the fix is the constant and not a literal next to it.
     */
    test("moving the period gap moves what counts as one period", () => {
        const withRule = (days: CycleDay[], minPeriodGapDays: number) =>
            analyzeCycles(
                { days, today: TODAY, profile: profileAged(30) },
                { ...RULES, minPeriodGapDays },
            );
        const oneMissed = history(flow(on(0)), flow(on(2)));
        const twoMissed = history(flow(on(0)), flow(on(3)));
        const threeMissed = history(flow(on(0)), flow(on(4)));

        expect(withRule(oneMissed, 1).lastPeriodStart).toBe(on(2));
        expect(withRule(oneMissed, 1).withheld).toBe("irregular-cycles");
        expect(withRule(oneMissed, 2).lastPeriodStart).toBe(on(0));

        expect(withRule(twoMissed, 2).lastPeriodStart).toBe(on(3));
        expect(withRule(twoMissed, 3).lastPeriodStart).toBe(on(0));
        expect(withRule(threeMissed, 3).lastPeriodStart).toBe(on(4));

        // #180's own history at the old setting: the phantom row is back.
        const missed = history(flow(on(0)), flow(on(1)), flow(on(3)), flow(on(4)));
        expect(withRule(missed, 1).cycles.map((cycle) => cycle.lengthDays)).toEqual([
            28, 28, 28, 28, 28, 3,
        ]);
        expect(withRule(missed, 1).lastPeriodStart).toBe("2026-06-08");
    });

    test("moving the gate moves when a prediction appears", () => {
        const logged = periods([28, 29], 5);
        const lower: CycleRules = { ...RULES, minCyclesForEstimate: 2, narrowBandMinCycles: 2 };
        expect(analyze(logged).prediction).toBe(null);
        expect(
            analyzeCycles({ days: logged, today: TODAY, profile: null }, lower).prediction,
        ).not.toBe(null);
    });

    test("moving the luteal phase moves ovulation and the whole window with it", () => {
        const logged = periods([28, 28, 28], 5);
        const twelve: CycleRules = { ...RULES, lutealPhaseDays: 12 };
        const base = analyze(logged).prediction!;
        const moved = analyzeCycles({ days: logged, today: TODAY, profile: null }, twelve)
            .prediction!;
        expect(moved.nextPeriodStart).toBe(base.nextPeriodStart);
        expect(moved.ovulation).toBe(shift(base.ovulation, 2));
        expect(moved.fertileWindow.from).toBe(shift(base.fertileWindow.from, 2));
        expect(moved.fertileWindow.peakTo).toBe(moved.ovulation);
    });

    test("moving the band widths moves the narrow/wide boundary", () => {
        const logged = periods([28, 28, 28, 28], 5);
        const earlier: CycleRules = { ...RULES, narrowBandMinCycles: 4 };
        expect(analyze(logged).prediction?.confidence).toBe("wide");
        expect(
            analyzeCycles({ days: logged, today: TODAY, profile: null }, earlier).prediction
                ?.confidence,
        ).toBe("narrow");
    });
});

describe("a set of constants that would produce a plausible wrong answer is refused", () => {
    const refuse = (over: Partial<CycleRules>, field: string, range: string) => {
        const broken = { ...RULES, ...over };
        const problem = cycleRulesProblem(broken);
        expect(problem?.field).toBe(field);
        expect(problem?.message).toContain(range);
        expect(() => analyzeCycles({ days: [], today: TODAY, profile: null }, broken)).toThrow(
            CycleRulesUnsetError,
        );
    };

    test("no constants at all", () => {
        expect(cycleRulesProblem(null)?.field).toBe("rules");
    });

    test("a zero or a fraction is not a quieter setting", () => {
        refuse({ historyCycles: 0 }, "historyCycles", "positive integer");
        refuse({ lutealPhaseDays: 13.5 }, "lutealPhaseDays", "positive integer");
    });

    test("a luteal phase at least as long as the shortest countable cycle", () => {
        refuse({ lutealPhaseDays: 21 }, "lutealPhaseDays", "less than minCycleLengthDays");
    });

    test("a peak window wider than the fertile window that contains it", () => {
        refuse(
            { peakDaysBeforeOvulation: 6 },
            "peakDaysBeforeOvulation",
            "at most fertileDaysBeforeOvulation",
        );
    });

    test("an inverted countable range, which would count nothing", () => {
        refuse({ minCycleLengthDays: 46 }, "maxCycleLengthDays", "at least minCycleLengthDays");
    });

    /**
     * Zero would make every logged day a period of its own. A gap as long as the shortest
     * countable cycle would make that cycle invisible even between two one-day periods, whose
     * gap is the cycle less one day — so 20 is the widest gap that can still see a 21-day
     * cycle, and 1, the rule before #186, is a setting rather than an error.
     */
    test("a period gap of zero, or one as long as the shortest countable cycle", () => {
        refuse({ minPeriodGapDays: 0 }, "minPeriodGapDays", "positive integer");
        refuse({ minPeriodGapDays: 1.5 }, "minPeriodGapDays", "positive integer");
        refuse({ minPeriodGapDays: 21 }, "minPeriodGapDays", "less than minCycleLengthDays");
        expect(cycleRulesProblem({ ...RULES, minPeriodGapDays: 20 })).toBe(null);
        expect(cycleRulesProblem({ ...RULES, minPeriodGapDays: 1 })).toBe(null);
        // …and the edge is what it says: at 20, two one-day periods 21 days apart are two.
        const twoOneDayPeriods = [flow("2026-05-01"), flow("2026-05-22")];
        const at20 = analyzeCycles(
            { days: twoOneDayPeriods, today: TODAY, profile: null },
            { ...RULES, minPeriodGapDays: 20 },
        );
        expect(at20.cycles.map((cycle) => cycle.lengthDays)).toEqual([21]);
    });

    test("a gate below two, where a shortest-to-longest variation has no meaning", () => {
        refuse({ minCyclesForEstimate: 1 }, "minCyclesForEstimate", "at least 2");
    });

    test("a narrow band reachable before the gate, which would make the wide band dead", () => {
        refuse(
            { narrowBandMinCycles: 2 },
            "narrowBandMinCycles",
            "at least minCyclesForEstimate",
        );
    });

    test("inverted FIGO age edges, which would silently apply the wrong band", () => {
        refuse(
            { irregularity: { ...RULES.irregularity, midMaxAge: 25 } },
            "irregularity.midMaxAge",
            "greater than irregularity.youngMaxAge",
        );
    });

    test("the constants the PRD settled on are accepted", () => {
        expect(cycleRulesProblem(RULES)).toBe(null);
    });
});

describe("a date that is not one is refused rather than read as no data", () => {
    test("today", () => {
        expect(() =>
            analyzeCycles({ days: [], today: "15/06/2026", profile: null }, RULES),
        ).toThrow(InvalidCycleDateError);
    });

    test("a logged day", () => {
        expect(() =>
            analyzeCycles({ days: [flow("2026-6-15")], today: TODAY, profile: null }, RULES),
        ).toThrow(InvalidCycleDateError);
    });

    /** `Date.parse` rolls a day that does not exist *forward* — `2026-02-30` is 2 March —
     *  so a lenient read here moves a period start two days and every cycle length around
     *  it. The route edge already refuses one (`isCalendarDate`); this is the floor. */
    test("a day that does not exist is refused rather than rolled forward", () => {
        expect(() =>
            analyzeCycles({ days: [flow("2026-02-30")], today: TODAY, profile: null }, RULES),
        ).toThrow(InvalidCycleDateError);
        expect(() =>
            analyzeCycles({ days: [], today: "2026-04-31", profile: null }, RULES),
        ).toThrow(InvalidCycleDateError);
        // …and a real leap day is not collateral damage.
        expect(() =>
            analyzeCycles({ days: [flow("2028-02-29")], today: TODAY, profile: null }, RULES),
        ).not.toThrow();
    });

    test("and the message names the field, never the value", () => {
        try {
            analyzeCycles({ days: [], today: "not-a-date", profile: null }, RULES);
            expect.unreachable();
        } catch (err) {
            expect((err as Error).message).toContain("today");
            expect((err as Error).message).not.toContain("not-a-date");
        }
    });
});

// ── The seam D1 consumes ───────────────────────────────────────────────────────────────

describe("the estimate D1 already consumes", () => {
    test("every field is C11's own answer, not a second threshold", () => {
        const result = analyze(periods([28, 28, 28, 28, 28, 28], 9));
        expect(toCycleEstimate(result)).toEqual({
            countedCycles: 6,
            enoughCyclesForEstimates: true,
            irregular: false,
            cycleDay: 10,
            phase: { code: "ovulation", confidence: "narrow" },
            daysPastPredictedPeriod: null,
        });
    });

    test("too few cycles: the estimate says so and carries no phase", () => {
        expect(toCycleEstimate(analyze(periods([28, 29], 9)))).toEqual({
            countedCycles: 2,
            enoughCyclesForEstimates: false,
            irregular: false,
            cycleDay: 10,
            phase: null,
            daysPastPredictedPeriod: null,
        });
    });

    /**
     * The whole point of the slice, without the route: D1's phase rung is unreachable while
     * `today.ts` passes a no-knowledge fixture, and this is the fixture replaced. Six counted
     * regular cycles select `home_d` — a card that states a phase — **on a follicular day, and
     * on no other** (#184).
     *
     * This case used to assert `home_d` on cycle day 10, which the maths calls `ovulation`
     * because the fertile window opens there. That was the defect, asserted: the card reads
     * "likely approaching ovulation" over "higher energy around now", and #184 narrowed rung 4
     * to the one phase both lines are true of. The menstrual and luteal rows are the
     * measurement #184 was filed on — day 2 and day 21 of a regular six-cycle history.
     */
    test("fed into D1, six regular cycles select the phase card on a follicular day only", () => {
        const RULES_D1: DashboardRules = {
            pattern: { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 3 },
        };
        // Everything she has logged is flow, so nothing reaches rung 2. Flow is logged up to
        // today and never past it, and the logging gap is the one those days imply.
        const onCycleDay = (cycleDay: number, flowDays: number): DashboardInput => ({
            mode: "cycle",
            today: TODAY,
            now: `${TODAY}T09:00:00Z`,
            cycle: toCycleEstimate(
                analyze(periods([28, 28, 28, 28, 28, 28], cycleDay - 1, flowDays)),
            ),
            signals: [],
            redFlag: null,
            upcomingAppointments: [],
            profileComplete: true,
            nutritionSetUp: false,
            todayTotals: null,
            daysSinceLastLog: cycleDay - flowDays,
        });
        const fallback: Subject = {
            rung: "education",
            templateId: TEMPLATE.educational,
            slots: {},
            confidence: "plain",
        };
        // A 28-day median puts ovulation on day 15 and the window on days 10–16.
        const rows: { cycleDay: number; flowDays: number; phase: PhaseCode; subject: Subject }[] = [
            // Day 2 of a period she has logged both days of.
            { cycleDay: 2, flowDays: 2, phase: "menstrual", subject: fallback },
            {
                cycleDay: 9,
                flowDays: 4,
                phase: "follicular",
                subject: {
                    rung: "phase",
                    templateId: TEMPLATE.phaseEnergy,
                    slots: { cycleDay: 9, phase: "follicular" },
                    // Hedged at every band: v1 has no confirmed-ovulation path (GUARDRAILS 35).
                    confidence: "hedged",
                },
            },
            { cycleDay: 10, flowDays: 4, phase: "ovulation", subject: fallback },
            { cycleDay: 21, flowDays: 4, phase: "luteal", subject: fallback },
        ];

        // One comparison, so a failure names every row that is wrong, and the phase the maths
        // actually produced is part of it — a row whose fixture drifted into another phase
        // would otherwise pass while testing something else.
        const selected = rows.map(({ cycleDay, flowDays }) => {
            const input = onCycleDay(cycleDay, flowDays);
            return {
                cycleDay,
                phase: input.cycle.phase?.code,
                subject: selectSubject(input, RULES_D1),
            };
        });
        expect(selected).toEqual(
            rows.map(({ cycleDay, phase, subject }) => ({ cycleDay, phase, subject })),
        );
    });

    test("and two cycles select the still-learning card instead, carrying the count", () => {
        const RULES_D1: DashboardRules = {
            pattern: { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 3 },
        };
        const input: DashboardInput = {
            mode: "cycle",
            today: TODAY,
            now: `${TODAY}T09:00:00Z`,
            cycle: toCycleEstimate(analyze(periods([28, 29], 9))),
            signals: [],
            redFlag: null,
            upcomingAppointments: [],
            profileComplete: true,
            nutritionSetUp: false,
            todayTotals: null,
            daysSinceLastLog: 9,
        };
        const subject = selectSubject(input, RULES_D1);
        expect(subject.templateId).toBe(TEMPLATE.stillLearning);
        expect(subject.slots).toEqual({ cycleCount: 2 });
    });
});

// ── Purity ─────────────────────────────────────────────────────────────────────────────

const importInABareProcess = async (modulePath: string) => {
    const proc = Bun.spawn(["bun", "--eval", `await import(${JSON.stringify(modulePath)})`], {
        // Outside `api/`, so Bun does not auto-load `api/.env`: the case is a process
        // holding no configuration and no credential at all.
        cwd: tmpdir(),
        env: { PATH: process.env.PATH ?? "" },
        stdout: "pipe",
        stderr: "pipe",
    });
    const [exitCode, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
    return { exitCode, stderr };
};

describe("the module reaches nothing", () => {
    test(
        "it imports in a process with no environment and no credentials",
        async () => {
            const { exitCode, stderr } = await importInABareProcess(
                `${import.meta.dir}/../src/cycle.ts`,
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

    /**
     * The import test alone is **not enough**, and this file says so because a recent review
     * found exactly that gap next door: a bare-process import proves only what runs at
     * import time, so a `fetch` inside a function survives it untouched. So the source is
     * scanned for the call as well as for the module.
     */
    test("its only imports are type imports, and nothing in it reaches out", async () => {
        const source = await Bun.file(`${import.meta.dir}/../src/cycle.ts`).text();
        const imports = source.match(/^import .*$/gm) ?? [];
        expect(imports).toEqual([
            "import type { CycleEstimate, PhaseCode, PhaseConfidence } from './dashboard-rules'",
            "import type { Profile } from './users'",
        ]);
        for (const forbidden of [
            "./firebase",
            "./events",
            "./config",
            "./content",
            "firebase-admin",
            "fetch(",
            "https://",
            "http://",
            "console.",
            "process.env",
            "Date.now",
        ]) {
            expect(source).not.toContain(forbidden);
        }
    });

    /** `new Date(...)` appears twice, both times converting a whole-day number to a
     *  `YYYY-MM-DD` label. A no-argument `new Date()` would be a clock, and a clock here
     *  would make the answer depend on when it was asked. */
    test("it reads no clock", async () => {
        const source = await Bun.file(`${import.meta.dir}/../src/cycle.ts`).text();
        expect(source).not.toContain("new Date()");
    });
});

// ── The configuration is a boot-time refusal ───────────────────────────────────────────

/**
 * `config.ts` reads the environment once at import, so what a given set of variables does
 * is a *boot*, and the only seam is a subprocess — the shape `config-emulators.test.ts`
 * uses. No Firestore, so these run in every environment.
 */
describe("the cycle maths' configuration", () => {
    /** Enough to get `config.ts` past every other required variable. */
    const BASE_ENV = {
        PATH: process.env.PATH ?? "",
        FIREBASE_PROJECT_ID: "demo-eva-cycle-test",
        FIREBASE_WEB_API_KEY: "not-a-real-key",
        JWT_SECRET: "not-a-real-secret",
        EMAIL_TRANSPORT: "log",
        NODE_ENV: "test",
        POSTMARK_FROM: "cycle-test@example.test",
        PUBLIC_WEB_URL: "http://localhost:4321",
    };

    /** `RULES` as `config.ts` reads it. Kept beside the fixture above so the two cannot
     *  disagree about what the PRD settled. */
    const CYCLE_ENV: Record<string, string> = {
        CYCLE_MIN_LENGTH_DAYS: String(RULES.minCycleLengthDays),
        CYCLE_MAX_LENGTH_DAYS: String(RULES.maxCycleLengthDays),
        CYCLE_MIN_PERIOD_GAP_DAYS: String(RULES.minPeriodGapDays),
        CYCLE_HISTORY_CYCLES: String(RULES.historyCycles),
        CYCLE_MIN_CYCLES_FOR_ESTIMATE: String(RULES.minCyclesForEstimate),
        CYCLE_NARROW_BAND_MIN_CYCLES: String(RULES.narrowBandMinCycles),
        CYCLE_LUTEAL_PHASE_DAYS: String(RULES.lutealPhaseDays),
        CYCLE_FERTILE_DAYS_BEFORE_OVULATION: String(RULES.fertileDaysBeforeOvulation),
        CYCLE_FERTILE_DAYS_AFTER_OVULATION: String(RULES.fertileDaysAfterOvulation),
        CYCLE_PEAK_DAYS_BEFORE_OVULATION: String(RULES.peakDaysBeforeOvulation),
        CYCLE_IRREGULAR_YOUNG_MAX_AGE: String(RULES.irregularity.youngMaxAge),
        CYCLE_IRREGULAR_MID_MAX_AGE: String(RULES.irregularity.midMaxAge),
        CYCLE_IRREGULAR_YOUNG_VARIATION_DAYS: String(RULES.irregularity.youngVariationDays),
        CYCLE_IRREGULAR_MID_VARIATION_DAYS: String(RULES.irregularity.midVariationDays),
        CYCLE_IRREGULAR_OLDER_VARIATION_DAYS: String(RULES.irregularity.olderVariationDays),
    };

    const bootConfig = async (over: Record<string, string>) => {
        // A bare env, not `...process.env`: a developer with these set would decide the
        // result, and the point is what a given set does at boot.
        const proc = Bun.spawn(["bun", "run", "src/config.ts"], {
            cwd: new URL("..", import.meta.url).pathname,
            env: { ...BASE_ENV, ...over },
            stdout: "pipe",
            stderr: "pipe",
        });
        const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
        return { code, stderr };
    };

    test("the group the PRD settled boots", async () => {
        expect((await bootConfig(CYCLE_ENV)).code).toBe(0);
    }, 30_000);

    /**
     * Empty rather than absent, wherever a case means "unset".
     *
     * `config.ts` reads these with `optionalString`, which treats `''` as not supplied — and
     * an empty value cannot be filled back in by an `api/.env` the way a deleted key can.
     * That matters more here than it did for the pattern rung: `.env.example` now ships this
     * group **with values**, so a developer who followed the instruction to copy it has all
     * fifteen set, and a case that simply omitted one would be testing her `.env`.
     */
    const UNSET = Object.fromEntries(Object.keys(CYCLE_ENV).map((name) => [name, ""]));

    test("none of them set is not a boot failure — the maths refuses instead", async () => {
        expect((await bootConfig(UNSET)).code).toBe(0);
    }, 30_000);

    test("a partial group is refused, and the failure names what is missing", async () => {
        const { code, stderr } = await bootConfig({
            ...CYCLE_ENV,
            CYCLE_LUTEAL_PHASE_DAYS: "",
        });
        expect(code).not.toBe(0);
        expect(stderr).toContain("CYCLE_LUTEAL_PHASE_DAYS");
    }, 30_000);

    /**
     * #186's constant joined an existing group, which is the moment a deployment can have the
     * old fourteen and not the new one — so both directions of "partial" are asserted for it.
     */
    test("the group without the period gap is refused, and so is the period gap alone", async () => {
        const without = await bootConfig({ ...CYCLE_ENV, CYCLE_MIN_PERIOD_GAP_DAYS: "" });
        expect(without.code).not.toBe(0);
        expect(without.stderr).toContain("Incomplete cycle maths configuration");
        expect(without.stderr).toContain("CYCLE_MIN_PERIOD_GAP_DAYS");

        const alone = await bootConfig({ ...UNSET, CYCLE_MIN_PERIOD_GAP_DAYS: "2" });
        expect(alone.code).not.toBe(0);
        expect(alone.stderr).toContain("Incomplete cycle maths configuration");
        expect(alone.stderr).toContain("CYCLE_MIN_LENGTH_DAYS");
    }, 30_000);

    test("a period gap the maths refuses is refused at boot, naming the variable", async () => {
        const zero = await bootConfig({ ...CYCLE_ENV, CYCLE_MIN_PERIOD_GAP_DAYS: "0" });
        expect(zero.code).not.toBe(0);
        expect(zero.stderr).toContain("Invalid env var CYCLE_MIN_PERIOD_GAP_DAYS");
        expect(zero.stderr).toContain("positive integer");

        const wide = await bootConfig({ ...CYCLE_ENV, CYCLE_MIN_PERIOD_GAP_DAYS: "21" });
        expect(wide.code).not.toBe(0);
        expect(wide.stderr).toContain("Invalid env var CYCLE_MIN_PERIOD_GAP_DAYS");
        expect(wide.stderr).toContain("less than minCycleLengthDays");
    }, 30_000);

    /**
     * The boot-time half of `cycleRulesProblem`, which is the reason `config.ts` imports it
     * rather than restating it: a value that passes the parse and produces a wrong window
     * has to be refused in both places, and one implementation is what makes that true.
     */
    test("an out-of-range value is refused with the valid range named", async () => {
        const { code, stderr } = await bootConfig({
            ...CYCLE_ENV,
            CYCLE_LUTEAL_PHASE_DAYS: "21",
        });
        expect(code).not.toBe(0);
        expect(stderr).toContain("CYCLE_LUTEAL_PHASE_DAYS");
        expect(stderr).toContain("less than minCycleLengthDays");
    }, 30_000);

    test("a value that is not a whole number of days is refused", async () => {
        const { code, stderr } = await bootConfig({
            ...CYCLE_ENV,
            CYCLE_MAX_LENGTH_DAYS: "45.5",
        });
        expect(code).not.toBe(0);
        expect(stderr).toContain("CYCLE_MAX_LENGTH_DAYS");
    }, 30_000);

    /** `.env.example` is the one place an operator copies from, so a group it cannot boot
     *  is a broken instruction rather than a stale comment. */
    test("the values in .env.example are the values this file asserts against", async () => {
        const example = await Bun.file(`${import.meta.dir}/../.env.example`).text();
        // Line-anchored, and read back as a group rather than searched for one at a time: a
        // `toContain` passes on a commented-out line, which is a variable the developer who
        // copies this file does not get — and a group missing one is a boot failure.
        const set = [...example.matchAll(/^(CYCLE_[A-Z_]+)=(\S*)/gm)].map(([, name, value]) => [
            name,
            value,
        ]);
        expect(Object.fromEntries(set)).toEqual(CYCLE_ENV);
    });

    /**
     * And the values CI boots with. `scripts/ci-api.sh` exports the group so the suite runs
     * the configuration production is meant to run; a variable added here and not there would
     * make every suite that loads `config.ts` refuse to boot in CI, and a value that drifted
     * there would test a configuration nobody chose. Line-anchored, so a commented-out export
     * does not count.
     */
    test("the values scripts/ci-api.sh exports are the values this file asserts against", async () => {
        const script = await Bun.file(`${import.meta.dir}/../../scripts/ci-api.sh`).text();
        const exported = [...script.matchAll(/^export (CYCLE_[A-Z_]+)=(.*)$/gm)].map(
            ([, name, value]) => [name, value],
        );
        expect(Object.fromEntries(exported)).toEqual(CYCLE_ENV);
    });
});

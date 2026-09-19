import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'node:os'
import {
  InvalidTimeError,
  PatternRuleUnsetError,
  TEMPLATE,
  selectSubject,
  type CycleEstimate,
  type DashboardInput,
  type DashboardRules,
  type PatternRule,
  type PhaseCode,
  type Rung,
  type SignalEntry,
  type Subject,
  type SubjectSlots,
  type TemplateId,
} from '../src/dashboard-rules'
import type { Confidence, Slot } from '../src/content'

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

const TODAY = '2026-09-16'
const NOW = '2026-09-16T09:00:00Z'
const YESTERDAY = '2026-09-15'
const TWO_DAYS_AGO = '2026-09-14'

/**
 * A32's rule, as configuration — which is the point. Every number in it lives here, in a
 * fixture, and none of them is in `dashboard-rules.ts`: the "config-driven" case below
 * proves that by changing them and watching the answer change.
 */
const PATTERN_RULE: PatternRule = { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 3 }
const RULES: DashboardRules = { pattern: PATTERN_RULE }

// ── C11 fixtures (#11) ─────────────────────────────────────────────────────────────────
// The shape is `dashboard-rules.ts`'s; the arithmetic that would produce these is C11's and
// is deliberately absent. Each one is a state a real account reaches, named for it.

const NO_CYCLE: CycleEstimate = {
  countedCycles: 0,
  enoughCyclesForEstimates: false,
  irregularity: 'none',
  cycleDay: null,
  phase: null,
  daysPastPredictedPeriod: null,
}

/** One counted cycle: below C11's gate, so no phase — but a cycle day is known. */
const LEARNING: CycleEstimate = {
  ...NO_CYCLE,
  countedCycles: 1,
  cycleDay: 12,
}

/** Six cycles, past the gate, but the FIGO band says irregular. */
const IRREGULAR: CycleEstimate = {
  countedCycles: 6,
  enoughCyclesForEstimates: true,
  irregularity: 'cycles-vary',
  cycleDay: 12,
  phase: null,
  daysPastPredictedPeriod: null,
}

/** The PRD's worked example: day 13, approaching ovulation, four cycles behind it. */
const ESTIMATED: CycleEstimate = {
  countedCycles: 4,
  enoughCyclesForEstimates: true,
  irregularity: 'none',
  cycleDay: 13,
  phase: { code: 'follicular', confidence: 'wide' },
  daysPastPredictedPeriod: null,
}

/** Two days past the predicted first flow day. */
const LATE: CycleEstimate = {
  countedCycles: 6,
  enoughCyclesForEstimates: true,
  irregularity: 'none',
  cycleDay: 31,
  phase: { code: 'luteal', confidence: 'narrow' },
  daysPastPredictedPeriod: 2,
}

const signal = (over: Partial<SignalEntry> & { localDate: string }): SignalEntry => ({
  loggedAt: `${over.localDate}T08:00:00Z`,
  energy: null,
  mood: null,
  sleep: null,
  symptoms: [],
  ...over,
})

/** A day with nothing worth naming on it — used to prove a *logged* day is not the same as
 *  a day she reported something. */
const emptyDay = (localDate: string): SignalEntry => signal({ localDate })

const base = (over: Partial<DashboardInput> = {}): DashboardInput => ({
  mode: 'cycle',
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
})

const APPOINTMENT_TOMORROW = {
  startAt: '2026-09-17T10:30:00',
  type: 'gp',
  inDays: 1,
} as const

// ── The scenario table ─────────────────────────────────────────────────────────────────

interface Scenario {
  /** The canvas state, and what the acceptance criterion calls it. */
  state: string
  why: string
  input: DashboardInput
  rung: Rung
  templateId: TemplateId
  slots: SubjectSlots
  confidence: Confidence
}

const SCENARIOS: Scenario[] = [
  {
    state: 'home_a',
    why: 'no data at all — first open after sign-up (PRD Edge case 1)',
    input: base(),
    rung: 'setup',
    templateId: TEMPLATE.coldStart,
    slots: {},
    confidence: 'plain',
  },
  {
    state: 'home_b',
    why: "fewer counted cycles than C11's gate — no phase, the count as a fact",
    input: base({ cycle: LEARNING, daysSinceLastLog: 0 }),
    rung: 'phase',
    templateId: TEMPLATE.stillLearning,
    slots: { cycleCount: 1 },
    confidence: 'hedged',
  },
  {
    state: 'home_c',
    why: "irregular per C11's flag — the phase cannot be estimated reliably",
    input: base({ cycle: IRREGULAR, daysSinceLastLog: 0 }),
    rung: 'phase',
    templateId: TEMPLATE.irregular,
    slots: {},
    confidence: 'hedged',
  },
  {
    state: 'home_d',
    why: 'phase context, nothing logged in the last 24 h (PRD worked example 1)',
    input: base({ cycle: ESTIMATED, daysSinceLastLog: 3 }),
    rung: 'phase',
    templateId: TEMPLATE.phaseEnergy,
    slots: { cycleDay: 13, phase: 'follicular' },
    confidence: 'hedged',
  },
  {
    state: 'home_e',
    why: 'same day, energy 1 and sleep 2 logged (PRD worked example 2)',
    input: base({
      cycle: ESTIMATED,
      daysSinceLastLog: 0,
      signals: [signal({ localDate: TODAY, energy: 1, sleep: 2 })],
    }),
    rung: 'pattern',
    templateId: TEMPLATE.signalOverridesPhase,
    slots: { cycleDay: 13 },
    confidence: 'plain',
  },
  {
    state: 'home_f',
    why: 'the period is later than predicted (PRD Edge case 2)',
    input: base({ cycle: LATE, daysSinceLastLog: 0 }),
    rung: 'pattern',
    templateId: TEMPLATE.latePeriod,
    slots: { cycleDay: 31 },
    confidence: 'plain',
  },
  {
    state: 'home_g',
    why: 'signals logged, no cycle data — responds to the signals alone (Edge case 3)',
    input: base({
      daysSinceLastLog: 0,
      signals: [
        signal({
          localDate: TODAY,
          energy: 1,
          symptoms: [{ code: 'headache', severity: 'severe' }],
        }),
      ],
    }),
    rung: 'pattern',
    templateId: TEMPLATE.signalsToday,
    slots: {},
    confidence: 'plain',
  },
  {
    state: 'home_h',
    why: 'three consecutive logged days with mood *and* sleep at or below the level (A32)',
    input: base({
      cycle: ESTIMATED,
      daysSinceLastLog: 0,
      signals: [
        signal({ localDate: TODAY, mood: 2, sleep: 2 }),
        signal({ localDate: YESTERDAY, mood: 2, sleep: 1 }),
        signal({ localDate: TWO_DAYS_AGO, mood: 1, sleep: 2 }),
      ],
    }),
    rung: 'pattern',
    templateId: TEMPLATE.moodPattern,
    slots: {},
    confidence: 'plain',
  },
  {
    state: 'home_edu',
    why: 'she has logged before, but no rung applies today',
    input: base({ daysSinceLastLog: 5 }),
    rung: 'education',
    templateId: TEMPLATE.educational,
    slots: {},
    confidence: 'plain',
  },
]

describe('every cycle-mode canvas state', () => {
  for (const scenario of SCENARIOS) {
    test(`${scenario.state} — ${scenario.why}`, () => {
      const subject = selectSubject(scenario.input, RULES)
      expect(subject).toEqual({
        rung: scenario.rung,
        templateId: scenario.templateId,
        slots: scenario.slots,
        confidence: scenario.confidence,
      })
    })
  }
})

// ── The ladder ─────────────────────────────────────────────────────────────────────────

describe('priority ladder', () => {
  /** Everything applicable at once, the day PRD Edge case 4 describes. */
  const everything = base({
    cycle: { ...ESTIMATED, daysPastPredictedPeriod: 2 },
    daysSinceLastLog: 0,
    redFlag: { code: 'reduced_fetal_movement', loggedAt: `${TODAY}T07:45:00Z` },
    signals: [
      signal({ localDate: TODAY, mood: 2, sleep: 2 }),
      signal({ localDate: YESTERDAY, mood: 2, sleep: 2 }),
      signal({ localDate: TWO_DAYS_AGO, mood: 2, sleep: 2 }),
    ],
    upcomingAppointments: [APPOINTMENT_TOMORROW],
    profileComplete: true,
    nutritionSetUp: true,
    todayTotals: { caloriesRemaining: 420, proteinG: 58, waterMl: 1200, activityMin: 35 },
  })

  test('all six conditions true at once: exactly one rung wins (PRD Edge case 4)', () => {
    expect(selectSubject(everything, RULES)).toEqual({
      rung: 'flag',
      templateId: TEMPLATE.redFlag,
      slots: { loggedAt: `${TODAY}T07:45:00Z` },
      confidence: 'plain',
    })
  })

  /**
   * Peel one rung off at a time and the next one down answers. This is the case that
   * fails if the ladder is reordered — which is the failure a table of independent
   * fixtures cannot see, because each of those has only one rung applicable.
   */
  test('removing the winning condition hands the day to the next rung down', () => {
    const noFlag = { ...everything, redFlag: null }
    expect(selectSubject(noFlag, RULES).templateId).toBe(TEMPLATE.moodPattern)

    // One log today instead of a three-day run: still rung 2, but the late period is
    // the more consequential thing to say, so it leads.
    const noRun = { ...noFlag, signals: [signal({ localDate: TODAY, mood: 2, sleep: 2 })] }
    expect(selectSubject(noRun, RULES).templateId).toBe(TEMPLATE.latePeriod)

    // Not late any more: her own log still outranks the phase.
    const notLate = { ...noRun, cycle: ESTIMATED }
    expect(selectSubject(notLate, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase)

    // Nothing logged in the window: phase context. The appointment is still there, which
    // is the point — cycle mode has no rung-3 template, so rung 3 cannot outrank it.
    const noSignals = { ...notLate, signals: [], daysSinceLastLog: 3 }
    expect(selectSubject(noSignals, RULES).templateId).toBe(TEMPLATE.phaseEnergy)

    // Below C11's gate: the phase rung still answers, without a phase.
    const learning = { ...noSignals, cycle: LEARNING }
    expect(selectSubject(learning, RULES).templateId).toBe(TEMPLATE.stillLearning)

    // No cycle data at all, but she has logged something before: the fallback.
    const nothing = { ...learning, cycle: NO_CYCLE }
    expect(selectSubject(nothing, RULES).templateId).toBe(TEMPLATE.educational)
  })

  test("an escalation does not wait on another rung's configuration", () => {
    // Rung 1 is deterministic and bypasses everything (PRD §Calendar Other req. 5). It is
    // evaluated before rung 2 asks for its rule, so a missing #26 config cannot suppress
    // a red flag.
    expect(selectSubject(everything, { pattern: null }).templateId).toBe(TEMPLATE.redFlag)
  })

  test("an upcoming appointment selects nothing in cycle mode — rung 3 is D10's", () => {
    const withAppointment = base({
      cycle: ESTIMATED,
      daysSinceLastLog: 3,
      upcomingAppointments: [APPOINTMENT_TOMORROW],
    })
    expect(selectSubject(withAppointment, RULES).rung).toBe('phase')
  })

  test('a mode this slice has no rules for falls back, it does not borrow cycle content', () => {
    // `LATE` as well as `ESTIMATED`, because a fixture with neither a lateness count nor
    // a signal only ever reaches rung 4 — which is what let rung 2's missing mode gate
    // sit here unseen.
    for (const mode of ['planning', 'pregnancy', 'postpartum', 'loss'] as const) {
      for (const cycle of [ESTIMATED, LATE]) {
        const subject = selectSubject(base({ mode, cycle, daysSinceLastLog: 3 }), RULES)
        expect(subject.templateId).toBe(TEMPLATE.educational)
      }
    }
  })

  test("rung 2's two cycle-only cards are gated on mode, exactly as rung 4 is", () => {
    // `late_period` and `signal_overrides_phase` are `mode: 'cycle'` in `content/`, and a
    // cycle estimate is still carried in the other four modes. Ungated, a user in loss
    // mode two days past a predicted period was shown "Your period is later than
    // predicted", with *Log period* and *Log test* under it — days after a pregnancy
    // loss. This is the case that fails if either gate is removed.
    for (const mode of ['planning', 'pregnancy', 'postpartum', 'loss'] as const) {
      expect(
        selectSubject(base({ mode, cycle: LATE, daysSinceLastLog: 0 }), RULES).templateId,
      ).toBe(TEMPLATE.educational)

      const logged = base({
        mode,
        cycle: ESTIMATED,
        daysSinceLastLog: 0,
        signals: [signal({ localDate: TODAY, energy: 1, sleep: 2 })],
      })
      const subject = selectSubject(logged, RULES)
      expect(subject.templateId).toBe(TEMPLATE.signalsToday)
      expect(subject.slots).toEqual({})
    }
  })

  test("and the other two are not — `mode: 'any'` means every mode", () => {
    // `mood_pattern` and `signals_today` are about what she logged rather than about a
    // cycle, which is as relevant in one mode as in another. The gate above is two cards
    // wide, not the whole rung: widening it would be silence where there is something to
    // say. What `signals_today` currently says is not true of everyone routed to it —
    // that is #177 and `dashboard-copy.test.ts`, and it is a copy problem, not this
    // gate's.
    for (const mode of ['cycle', 'planning', 'pregnancy', 'postpartum', 'loss'] as const) {
      const run = base({
        mode,
        cycle: LATE,
        daysSinceLastLog: 0,
        signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
          signal({ localDate, mood: 2, sleep: 2 }),
        ),
      })
      expect(selectSubject(run, RULES).templateId).toBe(TEMPLATE.moodPattern)

      const oneDay = { ...run, signals: [signal({ localDate: TODAY, energy: 1 })] }
      expect(selectSubject(oneDay, RULES).templateId).toBe(
        mode === 'cycle' ? TEMPLATE.latePeriod : TEMPLATE.signalsToday,
      )
    }
  })
})

// ── Observed data outranks predicted data ──────────────────────────────────────────────

describe('observed data outranks predicted data', () => {
  test("the PRD's two worked examples: the same day, with and without a log", () => {
    const day13 = base({ cycle: ESTIMATED, daysSinceLastLog: 0 })

    expect(selectSubject({ ...day13, daysSinceLastLog: 3 }, RULES).templateId).toBe(
      TEMPLATE.phaseEnergy,
    )

    const logged = {
      ...day13,
      signals: [signal({ localDate: TODAY, energy: 1, sleep: 2 })],
    }
    expect(selectSubject(logged, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase)
  })

  test('a log older than 24 h does not displace the phase', () => {
    const stale = base({
      cycle: ESTIMATED,
      daysSinceLastLog: 2,
      signals: [signal({ localDate: TWO_DAYS_AGO, energy: 1 })],
    })
    expect(selectSubject(stale, RULES).templateId).toBe(TEMPLATE.phaseEnergy)
  })

  test('an entry she opened but reported nothing in is not a log', () => {
    const opened = base({
      cycle: ESTIMATED,
      daysSinceLastLog: 0,
      signals: [emptyDay(TODAY)],
    })
    expect(selectSubject(opened, RULES).templateId).toBe(TEMPLATE.phaseEnergy)
  })

  test('signals with no speakable phase never mention one', () => {
    for (const cycle of [NO_CYCLE, LEARNING, IRREGULAR]) {
      const subject = selectSubject(
        base({
          cycle,
          daysSinceLastLog: 0,
          signals: [signal({ localDate: TODAY, energy: 1 })],
        }),
        RULES,
      )
      expect(subject.templateId).toBe(TEMPLATE.signalsToday)
      expect(subject.slots).toEqual({})
    }
  })
})

// ── C11's confidence gate ──────────────────────────────────────────────────────────────

describe('the phase is spoken only when C11 says it may be', () => {
  test('a withheld estimate selects a no-phase subject, never a hedged phase', () => {
    const withheld = base({
      cycle: { ...ESTIMATED, phase: { code: 'follicular', confidence: 'none' } },
      daysSinceLastLog: 3,
    })
    const subject = selectSubject(withheld, RULES)
    expect(subject.templateId).not.toBe(TEMPLATE.phaseEnergy)
    expect(subject.templateId).toBe(TEMPLATE.educational)
    expect(subject.slots.phase).toBeUndefined()
  })

  test("C11's two gates hold even if an estimate arrives anyway", () => {
    const belowGate = base({
      cycle: { ...ESTIMATED, enoughCyclesForEstimates: false, countedCycles: 2 },
      daysSinceLastLog: 3,
    })
    expect(selectSubject(belowGate, RULES)).toEqual({
      rung: 'phase',
      templateId: TEMPLATE.stillLearning,
      slots: { cycleCount: 2 },
      confidence: 'hedged',
    })

    const irregular = base({
      cycle: { ...ESTIMATED, irregularity: 'cycles-vary' },
      daysSinceLastLog: 3,
    })
    expect(selectSubject(irregular, RULES).templateId).toBe(TEMPLATE.irregular)
  })

  /**
   * **`home_c` is selected for one of C11's two irregularity answers, not for both** (#190).
   *
   * Its line reads "Your recent cycle lengths vary significantly". C11 also withholds when
   * the spread rests entirely on a single interval it could not count — one missed period
   * start merges two cycles, and the interval keeps the band closed for six further counted
   * cycles — and for that user every counted cycle is the same length, so the sentence is
   * false for the whole of it.
   *
   * The pair is the assertion. The first half alone would pass if rung 4 stopped selecting
   * `home_c` at all, which would be a different bug; the second says the card is still
   * reachable for the user it is true of. Neither half says anything about the *gate*: both
   * inputs withhold the phase, which is `speakablePhase`'s job and is asserted below.
   */
  test('an unreadable cycle does not select the card that says her cycles vary (#190)', () => {
    const unreadable = base({
      cycle: { ...ESTIMATED, irregularity: 'uncountable-cycle' },
      daysSinceLastLog: 3,
    })
    expect(selectSubject(unreadable, RULES).templateId).not.toBe(TEMPLATE.irregular)
    // No phase card either — the gate is C11's and this changes none of it. What she gets
    // is the fallback, because the card that would explain it is not drawn (#177).
    expect(selectSubject(unreadable, RULES)).toEqual({
      rung: 'education',
      templateId: TEMPLATE.educational,
      slots: {},
      confidence: 'plain',
    })

    const varying = base({
      cycle: { ...ESTIMATED, irregularity: 'cycles-vary' },
      daysSinceLastLog: 3,
    })
    expect(selectSubject(varying, RULES).templateId).toBe(TEMPLATE.irregular)
  })

  /** Every irregularity answer but `none` withholds the phase, which is the half #190 must
   *  not have moved: the reason changed, the gate did not. */
  test('both irregularity answers withhold the phase, and only the reason differs', () => {
    for (const irregularity of ['cycles-vary', 'uncountable-cycle'] as const) {
      const input = base({
        cycle: { ...ESTIMATED, irregularity, phase: { code: 'follicular', confidence: 'wide' } },
        daysSinceLastLog: 3,
      })
      expect(`${irregularity}: ${selectSubject(input, RULES).templateId}`).not.toBe(
        `${irregularity}: ${TEMPLATE.phaseEnergy}`,
      )
    }
  })

  test('both gates at once: too few cycles is what the card says (PRD cold start 2)', () => {
    // Below C11's gate there are not enough cycles to call variation irregular in the
    // first place, so "still learning" is the honest answer even when the flag is set —
    // "With fewer than 3 logged cycles the card does not estimate a phase. It states what
    // is needed instead." Nothing else in this file puts both gates up at once, and
    // without this case the two branches can be swapped and the suite stays green.
    const both = base({
      cycle: {
        countedCycles: 2,
        enoughCyclesForEstimates: false,
        irregularity: 'cycles-vary',
        cycleDay: 9,
        phase: null,
        daysPastPredictedPeriod: null,
      },
      daysSinceLastLog: 0,
    })
    expect(selectSubject(both, RULES)).toEqual({
      rung: 'phase',
      templateId: TEMPLATE.stillLearning,
      slots: { cycleCount: 2 },
      confidence: 'hedged',
    })
  })

  test('below the gate there is no phase slot at all', () => {
    for (const cycle of [LEARNING, IRREGULAR]) {
      const subject = selectSubject(base({ cycle, daysSinceLastLog: 0 }), RULES)
      expect(subject.slots.phase).toBeUndefined()
      expect(subject.confidence).toBe('hedged')
    }
  })

  test('both estimated bands hedge — v1 has no confirmed-ovulation path', () => {
    for (const band of ['wide', 'narrow'] as const) {
      const subject = selectSubject(
        base({
          cycle: { ...ESTIMATED, phase: { code: 'follicular', confidence: band } },
          daysSinceLastLog: 3,
        }),
        RULES,
      )
      expect(subject.confidence).toBe('hedged')
    }
  })
})

// ── Rung 4's one card, and the phases it is true of (#184) ─────────────────────────────

describe('the phase card is selected only for the phase its words are true of', () => {
  /**
   * `phase_energy` is rung 4's only phase card, and its words are fixed: "Cycle day
   * {cycleDay} · likely approaching ovulation" over "Many women notice higher energy around
   * now". It used to be selected for every phase C11 lets the card speak, and two reviewers
   * were shown it on cycle day 2 (menstrual) and day 21 (luteal) — a kicker naming the wrong
   * phase over a title asserting the opposite of the tendency.
   *
   * The set is not read off the copy here. `dashboard-copy.test.ts` holds each string to a
   * claim — the kicker to the follicular phase, the title to follicular or ovulation — and a
   * card is as true as its least true line, so the rung selects it where both hold. Every
   * other phase falls through the rest of the ladder, which has nothing else to say, so it
   * lands on the educational card.
   *
   * `Record<PhaseCode, …>` makes "all four" something the compiler checks: a fifth code fails
   * `bun run typecheck` here until someone decides which card it gets. Each row is a coherent
   * day of a regular 28-day cycle under #181's boundaries (menstrual 1–4, follicular 5–9, the
   * window 10–16), with the logging gap that day implies — flow is not a body signal, so
   * nothing reaches rung 2.
   */
  test('all four phases: only follicular reaches home_d, the other three fall through', () => {
    const fallback: Subject = {
      rung: 'education',
      templateId: TEMPLATE.educational,
      slots: {},
      confidence: 'plain',
    }
    type Day = { cycleDay: number; daysSinceLastLog: number; subject: Subject }
    const days: Record<PhaseCode, Day> = {
      menstrual: { cycleDay: 2, daysSinceLastLog: 0, subject: fallback },
      follicular: {
        cycleDay: 8,
        daysSinceLastLog: 4,
        subject: {
          rung: 'phase',
          templateId: TEMPLATE.phaseEnergy,
          slots: { cycleDay: 8, phase: 'follicular' },
          confidence: 'hedged',
        },
      },
      ovulation: { cycleDay: 13, daysSinceLastLog: 9, subject: fallback },
      luteal: { cycleDay: 21, daysSinceLastLog: 17, subject: fallback },
    }

    // One comparison over the whole table, so a failure shows every phase that is wrong
    // rather than stopping at the first. Both bands, because the narrowing is on the phase
    // and must not lean on the band.
    type Band = 'wide' | 'narrow'
    const codes = Object.keys(days) as PhaseCode[]
    const table = (pick: (code: PhaseCode, band: Band, counted: number) => Subject) =>
      Object.fromEntries(
        (
          [
            ['wide', 4],
            ['narrow', 6],
          ] as const
        ).map(([band, counted]) => [
          band,
          Object.fromEntries(codes.map((code) => [code, pick(code, band, counted)])),
        ]),
      )

    const selected = table((code, band, countedCycles) =>
      selectSubject(
        base({
          cycle: {
            ...ESTIMATED,
            countedCycles,
            cycleDay: days[code].cycleDay,
            phase: { code, confidence: band },
          },
          daysSinceLastLog: days[code].daysSinceLastLog,
        }),
        RULES,
      ),
    )
    expect(selected).toEqual(table((code) => days[code].subject))
  })
})

// ── Rung 2 ─────────────────────────────────────────────────────────────────────────────

describe("rung 2 is inert until #26's rule is configured", () => {
  const day = SCENARIOS.find((s) => s.state === 'home_h')!.input

  test('an unset rule throws a named error', () => {
    expect(() => selectSubject(day, { pattern: null })).toThrow(PatternRuleUnsetError)
    try {
      selectSubject(day, { pattern: null })
      expect.unreachable()
    } catch (error) {
      expect((error as Error).name).toBe('PatternRuleUnsetError')
    }
  })

  test('it is never silently skipped — a day that would answer at rung 4 throws too', () => {
    const phaseDay = base({ cycle: ESTIMATED, daysSinceLastLog: 3 })
    expect(selectSubject(phaseDay, RULES).templateId).toBe(TEMPLATE.phaseEnergy)
    expect(() => selectSubject(phaseDay, { pattern: null })).toThrow(PatternRuleUnsetError)
  })

  test('a rule that cannot match is refused rather than run', () => {
    for (const broken of [
      { ...PATTERN_RULE, lowSignalDays: 0 },
      { ...PATTERN_RULE, lowAtOrBelow: 0 },
      { ...PATTERN_RULE, severeSymptomDays: 1.5 },
    ]) {
      expect(() => selectSubject(day, { pattern: broken })).toThrow(PatternRuleUnsetError)
    }
  })

  test('and so is one that cannot help but match', () => {
    // The quieter half of the same rule, and the half the check missed. Ratings are whole
    // numbers from 1 to 5 (`parseRating`, `index.ts`), so `lowAtOrBelow: 5` calls every
    // answered rating low: anyone who logs a mood and a sleep three days running gets the
    // pattern card, whatever she logged, and nothing surfaces it. It passed the
    // positive-integer check, because nothing looked at the top of the scale.
    const everyRatingFine = base({
      daysSinceLastLog: 0,
      signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
        signal({ localDate, mood: 5, sleep: 5 }),
      ),
    })
    expect(selectSubject(everyRatingFine, RULES).templateId).toBe(TEMPLATE.signalsToday)
    expect(() =>
      selectSubject(everyRatingFine, { pattern: { ...PATTERN_RULE, lowAtOrBelow: 5 } }),
    ).toThrow(PatternRuleUnsetError)

    // 4 is the top of the usable range and is still a rule rather than a tautology: a 5
    // is not low at 4.
    expect(
      selectSubject(everyRatingFine, { pattern: { ...PATTERN_RULE, lowAtOrBelow: 4 } }).templateId,
    ).toBe(TEMPLATE.signalsToday)
  })

  test('and so is a day count past the copy it can describe', () => {
    // The two day counts are bounded above too (#178): the card's own sentences
    // ("consecutive days", "the last few days") stop being true past 14, so a larger
    // count is a rule that matches a span no drawn copy describes — the same "looks
    // live and is not" failure as a zero, arriving from the other end.
    expect(() => selectSubject(day, { pattern: { ...PATTERN_RULE, lowSignalDays: 15 } })).toThrow(
      PatternRuleUnsetError,
    )
    expect(() =>
      selectSubject(day, { pattern: { ...PATTERN_RULE, severeSymptomDays: 15 } }),
    ).toThrow(PatternRuleUnsetError)

    // 14 is the top of the usable range and is still a rule rather than a runaway.
    expect(() =>
      selectSubject(day, { pattern: { ...PATTERN_RULE, lowSignalDays: 14 } }),
    ).not.toThrow()
    expect(() =>
      selectSubject(day, { pattern: { ...PATTERN_RULE, severeSymptomDays: 14 } }),
    ).not.toThrow()
  })

  test('the thresholds come from the config, not from the code', () => {
    // Two consecutive low days, and nothing else applicable.
    const twoDays = base({
      daysSinceLastLog: 0,
      signals: [
        signal({ localDate: TODAY, mood: 2, sleep: 2 }),
        signal({ localDate: YESTERDAY, mood: 2, sleep: 2 }),
      ],
    })
    expect(selectSubject(twoDays, RULES).templateId).toBe(TEMPLATE.signalsToday)
    expect(
      selectSubject(twoDays, { pattern: { ...PATTERN_RULE, lowSignalDays: 2 } }).templateId,
    ).toBe(TEMPLATE.moodPattern)

    // The level is configuration too: mood 3 is not low at 2, and is at 3.
    const threes = base({
      daysSinceLastLog: 0,
      signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
        signal({ localDate, mood: 3, sleep: 3 }),
      ),
    })
    expect(selectSubject(threes, RULES).templateId).toBe(TEMPLATE.signalsToday)
    expect(
      selectSubject(threes, { pattern: { ...PATTERN_RULE, lowAtOrBelow: 3 } }).templateId,
    ).toBe(TEMPLATE.moodPattern)
  })

  test('the run must be consecutive, and must reach today', () => {
    const gap = base({
      daysSinceLastLog: 0,
      signals: [
        signal({ localDate: TODAY, mood: 2, sleep: 2 }),
        signal({ localDate: TWO_DAYS_AGO, mood: 2, sleep: 2 }),
        signal({ localDate: '2026-09-13', mood: 2, sleep: 2 }),
      ],
    })
    expect(selectSubject(gap, RULES).templateId).toBe(TEMPLATE.signalsToday)

    const endedYesterday = base({
      daysSinceLastLog: 1,
      signals: [YESTERDAY, TWO_DAYS_AGO, '2026-09-13'].map((localDate) =>
        signal({ localDate, mood: 2, sleep: 2 }),
      ),
    })
    expect(selectSubject(endedYesterday, RULES).templateId).toBe(TEMPLATE.educational)
  })

  /**
   * The card is a sentence about her, and the predicate has to be the same statement.
   * `mood_pattern` reads "You've logged low mood for three consecutive days" and "Sleep has
   * also been below your usual level during the same period" — the canvas carries that
   * second line verbatim, so it is the specification. Every fixture below produced that
   * card under the old any-of-energy-mood-sleep predicate, and in every one of them at
   * least one of those two sentences was false about her own data.
   */
  test('the run is low mood *and* low sleep, on every day of it', () => {
    const threeDays = (over: Partial<SignalEntry>) =>
      base({
        daysSinceLastLog: 0,
        signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
          signal({ localDate, ...over }),
        ),
      })

    // Low energy, mood and sleep both 5 — and she is told she logged low mood and poor
    // sleep. Energy is in no card's words and is not in the predicate at all.
    expect(selectSubject(threeDays({ energy: 1, mood: 5, sleep: 5 }), RULES).templateId).toBe(
      TEMPLATE.signalsToday,
    )

    // Low mood, sleep fine: the second sentence would be false.
    expect(selectSubject(threeDays({ mood: 2, sleep: 5 }), RULES).templateId).toBe(
      TEMPLATE.signalsToday,
    )

    // Low sleep, mood fine: the first one would be.
    expect(selectSubject(threeDays({ mood: 5, sleep: 2 }), RULES).templateId).toBe(
      TEMPLATE.signalsToday,
    )

    // Not answered is not low — `events.ts` is careful that a null is not a 3.
    expect(selectSubject(threeDays({ mood: 2 }), RULES).templateId).toBe(TEMPLATE.signalsToday)

    // Both low, every day: the card is true of her, and it is the one she gets.
    expect(selectSubject(threeDays({ mood: 2, sleep: 2 }), RULES).templateId).toBe(
      TEMPLATE.moodPattern,
    )
  })

  test('the days of the run must agree — one low signal each was not a pattern', () => {
    // Low sleep today, low energy yesterday, low mood the day before satisfied the old
    // `.some()`, and "for three consecutive days" then described nothing that happened.
    const disagreeing = base({
      daysSinceLastLog: 0,
      signals: [
        signal({ localDate: TODAY, mood: 5, sleep: 2 }),
        signal({ localDate: YESTERDAY, energy: 1, mood: 5, sleep: 5 }),
        signal({ localDate: TWO_DAYS_AGO, mood: 2, sleep: 5 }),
      ],
    })
    expect(selectSubject(disagreeing, RULES).templateId).toBe(TEMPLATE.signalsToday)
  })

  test('a severe-symptom run selects no pattern card, because it has none to select', () => {
    // A32's second arm fell into the same `return` as the first, so severe cramps three
    // days running — mood 5, sleep 5 — selected "You've logged low mood for three
    // consecutive days". The card it actually needs is `symptom_pattern`; writing it is
    // D2's, not a rule this slice may invent. Until then the run falls through to
    // `signals_today` — which reads "You logged low energy and a headache today" and is
    // no truer of her (#177). This case pins the routing, not the card's honesty;
    // `dashboard-copy.test.ts` is where that is recorded.
    const severeRun = base({
      daysSinceLastLog: 0,
      signals: [TODAY, YESTERDAY, TWO_DAYS_AGO].map((localDate) =>
        signal({
          localDate,
          mood: 5,
          sleep: 5,
          symptoms: [{ code: 'cramps', severity: 'severe' }],
        }),
      ),
    })
    expect(selectSubject(severeRun, RULES).templateId).toBe(TEMPLATE.signalsToday)

    // Its dose is still refused when it cannot match, so the day D2 writes the card, the
    // number behind it is already known good.
    expect(() =>
      selectSubject(severeRun, { pattern: { ...PATTERN_RULE, severeSymptomDays: 0 } }),
    ).toThrow(PatternRuleUnsetError)
  })

  test('the predicted day itself is not late', () => {
    // `0` means the prediction is *today*. "Your period is later than predicted" on the
    // day the calendar predicts contradicts the calendar — and this is rung 2, so it
    // outranked what she logged this morning in order to do it.
    const onTheDay = base({
      cycle: { ...LATE, daysPastPredictedPeriod: 0 },
      daysSinceLastLog: 0,
      signals: [signal({ localDate: TODAY, energy: 1 })],
    })
    expect(selectSubject(onTheDay, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase)

    // A day later it is late, and then it is the card.
    expect(
      selectSubject({ ...onTheDay, cycle: { ...LATE, daysPastPredictedPeriod: 1 } }, RULES)
        .templateId,
    ).toBe(TEMPLATE.latePeriod)
  })
})

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
  signal: true,
  symptom: true,
}

const everySubject = (): Subject[] => [
  ...SCENARIOS.map((scenario) => selectSubject(scenario.input, RULES)),
  selectSubject(
    base({ redFlag: { code: 'reduced_fetal_movement', loggedAt: `${TODAY}T07:45:00Z` } }),
    RULES,
  ),
]

describe('the output is a subject, not a message', () => {
  test('four fields, and nothing else', () => {
    for (const subject of everySubject()) {
      expect(Object.keys(subject).sort()).toEqual(['confidence', 'rung', 'slots', 'templateId'])
    }
  })

  test('the only strings are a template id and slot values', () => {
    for (const subject of everySubject()) {
      expect(Object.values(TEMPLATE)).toContain(subject.templateId)
      for (const [key, value] of Object.entries(subject.slots)) {
        expect(EVERY_SLOT[key as Slot]).toBe(true)
        expect(['string', 'number']).toContain(typeof value)
      }
    }
  })

  test('no score, no streak, no comparison — and no field that could become one', () => {
    // PRD tone rule 4. The logging gap is an input and never leaves as a slot; `Slot`
    // has no key for it, so this case is a statement of what the type already enforces.
    const banned = [
      'streak',
      'score',
      'rank',
      'percentile',
      'daysSinceLastLog',
      'consecutiveDays',
      'comparison',
    ]
    for (const subject of everySubject()) {
      for (const key of banned) {
        expect(subject).not.toHaveProperty(key)
        expect(subject.slots).not.toHaveProperty(key)
      }
    }
    for (const key of banned) {
      expect(EVERY_SLOT).not.toHaveProperty(key)
    }
  })

  test('the logging gap never reaches the card, even when it is what decided it', () => {
    // `home_a` is chosen *because* nothing has been logged; the number behind that must
    // not turn up as something to read.
    const coldStart = selectSubject(base({ daysSinceLastLog: null }), RULES)
    expect(coldStart.slots).toEqual({})
    const gap = selectSubject(base({ daysSinceLastLog: 11 }), RULES)
    expect(Object.values(gap.slots)).not.toContain(11)
  })

  test('the same inputs answer the same way, and the inputs come back unchanged', () => {
    // PRD Other requirements 3: the card does not change between opens. The cache is
    // D3's; determinism is what makes the cache honest.
    for (const scenario of SCENARIOS) {
      const before = JSON.stringify(scenario.input)
      const first = selectSubject(scenario.input, RULES)
      const second = selectSubject(scenario.input, RULES)
      expect(second).toEqual(first)
      expect(JSON.stringify(scenario.input)).toBe(before)
    }
  })
})

// ── Sex events (PRD Edge case 6) ───────────────────────────────────────────────────────

describe('sex events are not an input', () => {
  test('the input type has no channel for one', () => {
    // @ts-expect-error — there is no event list and no event type here, so hiding Sex in
    // Settings needs no branch in the rules layer. This line is the pin: it stops
    // compiling the day someone adds one, which is where that should be argued.
    const withSex: DashboardInput = { ...base(), sexEvents: [{ localDate: TODAY }] }
    expect(withSex).toBeDefined()

    // @ts-expect-error — nor on the one logged-data shape the module does take.
    const entry: SignalEntry = { ...signal({ localDate: TODAY }), sex: true }
    expect(entry).toBeDefined()
  })

  /**
   * The whole input surface, pinned — **against the type, not against this file's
   * factories.**
   *
   * Enumerating `Object.keys(base())` pinned the fixture rather than the interface: an
   * optional `sexLogged?: boolean` on `DashboardInput` left the key list, the typecheck and
   * every case here untouched, so PRD Edge case 6 was held shut by nothing. `Record<keyof
   * …, true>` is exhaustive in both directions — a key added to the interface is a missing
   * property here, a key removed is an excess one — and optionality does not enter into it,
   * because `keyof` does not care. It fails under `bun run typecheck`, not at run time,
   * which is why the `expect`s below exist as well: they are what keeps the factories
   * honest about the type they claim to build.
   */
  test('the whole input surface, pinned', () => {
    const everyInput: Record<keyof DashboardInput, true> = {
      cycle: true,
      daysSinceLastLog: true,
      mode: true,
      now: true,
      nutritionSetUp: true,
      profileComplete: true,
      redFlag: true,
      signals: true,
      today: true,
      todayTotals: true,
      upcomingAppointments: true,
    }
    const everySignalField: Record<keyof SignalEntry, true> = {
      energy: true,
      localDate: true,
      loggedAt: true,
      mood: true,
      sleep: true,
      symptoms: true,
    }

    expect(Object.keys(base()).sort()).toEqual(Object.keys(everyInput).sort())
    expect(Object.keys(signal({ localDate: TODAY })).sort()).toEqual(
      Object.keys(everySignalField).sort(),
    )
  })
})

// ── Instants ───────────────────────────────────────────────────────────────────────────

describe('times are instants, not wall clocks', () => {
  test('a wall-clock string is refused rather than quietly ignored', () => {
    const wallClock = base({
      cycle: ESTIMATED,
      daysSinceLastLog: 0,
      signals: [signal({ localDate: TODAY, energy: 1, loggedAt: `${TODAY}T08:00:00` })],
    })
    expect(() => selectSubject(wallClock, RULES)).toThrow(InvalidTimeError)

    expect(() => selectSubject(base({ now: '2026-09-16 09:00' }), RULES)).toThrow(InvalidTimeError)
  })

  test('a malformed local date is refused, not quietly unmatched', () => {
    // A `today` the run cannot land on would make rung 2 match nothing — a rule that
    // looks live and is not, which is the failure this slice is written against.
    const badToday = base({
      today: '16/09/2026',
      daysSinceLastLog: 0,
      signals: [signal({ localDate: TODAY, mood: 2, sleep: 2 })],
    })
    expect(() => selectSubject(badToday, RULES)).toThrow(InvalidTimeError)

    // The right *shape*, and still not a date. `Date.UTC(2026, 12, 45)` rolls over to
    // 2027-02-14 rather than refusing, so the run searched days nothing can carry and
    // rung 2 matched nothing — which is exactly the failure above, arriving past the
    // check written to stop it.
    expect(() => selectSubject({ ...badToday, today: '2026-13-45' }, RULES)).toThrow(
      InvalidTimeError,
    )

    // A two-digit year rolls the same way: `Date.UTC(26, 8, 16)` is 1926.
    expect(() => selectSubject({ ...badToday, today: '0026-09-16' }, RULES)).toThrow(
      InvalidTimeError,
    )

    // The leap day is the pair that shows this is a check and not a wall: 2024 has a
    // 29 February and 2026 does not, and only the round trip can tell them apart.
    expect(selectSubject({ ...badToday, today: '2024-02-29' }, RULES)).toBeDefined()
    expect(() => selectSubject({ ...badToday, today: '2026-02-29' }, RULES)).toThrow(
      InvalidTimeError,
    )
  })

  test('a malformed instant the ladder would ignore does not fail the whole card', () => {
    // Six days old, outside every window rung 2 reads. Parsing every entry before
    // filtering meant one bad stored row threw for the card as a whole — and `GET
    // /me/today` then answered for that user with an error every day until the row was
    // fixed, over an entry that could never have been selected.
    const staleRow = base({
      cycle: ESTIMATED,
      daysSinceLastLog: 0,
      signals: [
        signal({ localDate: TODAY, energy: 1, sleep: 2 }),
        signal({ localDate: '2026-09-10', mood: 1, loggedAt: 'not-an-instant' }),
      ],
    })
    expect(selectSubject(staleRow, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase)

    // A malformed instant on a day the window *does* cover is still loud: reading it as
    // "nothing logged" would drop her own report, which is the failure the error is for.
    expect(() =>
      selectSubject(
        { ...staleRow, signals: [signal({ localDate: TODAY, energy: 1, loggedAt: 'x' })] },
        RULES,
      ),
    ).toThrow(InvalidTimeError)
  })

  test('an offset other than Z works, and the window is measured from `now`', () => {
    const input = base({
      cycle: ESTIMATED,
      daysSinceLastLog: 0,
      now: '2026-09-16T11:00:00+02:00',
      signals: [signal({ localDate: TODAY, energy: 1, loggedAt: '2026-09-16T10:30:00+02:00' })],
    })
    expect(selectSubject(input, RULES).templateId).toBe(TEMPLATE.signalOverridesPhase)

    // 25 hours earlier, same wall-clock date on the entry: outside the window.
    const stale = {
      ...input,
      signals: [signal({ localDate: TODAY, energy: 1, loggedAt: '2026-09-15T08:00:00Z' })],
    }
    expect(selectSubject(stale, RULES).templateId).toBe(TEMPLATE.phaseEnergy)
  })
})

// ── Purity ─────────────────────────────────────────────────────────────────────────────

const importInABareProcess = async (modulePath: string) => {
  const proc = Bun.spawn(['bun', '--eval', `await import(${JSON.stringify(modulePath)})`], {
    // Outside `api/`, so Bun does not auto-load `api/.env`: the case is a process
    // holding no configuration and no credential at all.
    cwd: tmpdir(),
    env: { PATH: process.env.PATH ?? '' },
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [exitCode, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
  return { exitCode, stderr }
}

describe('the module reaches nothing', () => {
  test('it imports in a process with no environment and no credentials', async () => {
    const { exitCode, stderr } = await importInABareProcess(
      `${import.meta.dir}/../src/dashboard-rules.ts`,
    )
    expect(stderr).toBe('')
    expect(exitCode).toBe(0)
  }, 10_000)

  test('and a module that does touch Firestore fails there, which is what makes that a test', async () => {
    const { exitCode, stderr } = await importInABareProcess(`${import.meta.dir}/../src/content.ts`)
    expect(exitCode).not.toBe(0)
    expect(stderr).toContain('Missing required env var')
  }, 10_000)

  test('its only import is a type import, and nothing in it reaches the network', async () => {
    const source = await Bun.file(`${import.meta.dir}/../src/dashboard-rules.ts`).text()
    const imports = source.match(/^import .*$/gm) ?? []
    expect(imports).toEqual(["import type { Confidence, Slot } from './content'"])
    // `fetch` and a URL are in this list because the import scan above is **import-time
    // only**: the two cases above spawn the module and watch it load, which a call made
    // inside `selectSubject` never reaches. A `fetch(...)` as the first line of the
    // function left all 44 cases green — from the one module holding cycle day, phase,
    // ratings, symptom codes and the red-flag code together (GUARDRAILS 12, 32, 34).
    //
    // Comments are stripped before the scan. A source URL in a doc comment reaches
    // nothing, and the next citation (C11's FIGO/Wilcox references, #176, one module
    // over) must not turn this red; a `fetch(` or `https://` in *code* still does.
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')
    for (const forbidden of [
      './firebase',
      './users',
      './events',
      './config',
      'fetch(',
      'https://',
    ]) {
      expect(code).not.toContain(forbidden)
    }
  })
})

// ── The content store agrees ───────────────────────────────────────────────────────────

describe('every subject names a template the content store actually has', () => {
  test('rung, confidence and slots match the seeded template', async () => {
    // Imported here rather than at the top of the file: the seed pulls in `content.ts`,
    // and with it Firestore's Admin SDK. Nothing above this line may do that.
    const { TEMPLATES } = await import('../scripts/seed-content')

    const byState = new Map(TEMPLATES.map((template) => [template.state, template]))

    for (const scenario of SCENARIOS) {
      const template = byState.get(scenario.state)
      expect(template).toBeDefined()
      if (!template) continue

      const subject = selectSubject(scenario.input, RULES)
      expect(subject.templateId).toBe(template.id as TemplateId)
      expect(subject.rung).toBe(template.rung as Rung)
      expect(subject.confidence).toBe(template.confidence)
      expect(template.status).toBe('active')
      expect(['cycle', 'any']).toContain(template.mode)

      // Never a slot the template does not declare.
      const emitted = Object.keys(subject.slots)
      for (const slot of emitted) expect(template.slots).toContain(slot as Slot)

      // And every slot it does declare is filled — with two known exceptions, pinned
      // here rather than waved at. `home_edu`'s two slots describe the *article*, and
      // choosing an article is not this slice's job, nor D3's. `home_e`'s and
      // `home_g`'s `signal` is filled by `resolveSignals` in `today.ts` (#200), not by
      // the ladder: its value is reviewed copy (`content/` vocabulary) plus `refdata/`
      // labels, which the pure, text-free ladder cannot read. If any of that changes,
      // this line is what fails.
      const unfilled = template.slots.filter((slot) => !emitted.includes(slot)).sort()
      expect(unfilled).toEqual(
        scenario.state === 'home_edu'
          ? ['category', 'readMinutes']
          : scenario.state === 'home_e' || scenario.state === 'home_g'
            ? ['signal']
            : [],
      )
    }
  })

  test("rung 1's mode seam: a cycle-mode red flag names a pregnancy template", async () => {
    const { TEMPLATES } = await import('../scripts/seed-content')
    const flag = TEMPLATES.find((template) => template.id === TEMPLATE.redFlag)

    // #96 said this seam was "pinned by a test" and it was not: the ladder cases pin only
    // that a red flag wins in cycle mode, and the content cross-check above walks
    // `SCENARIOS`, which deliberately excludes the red-flag subject. So the half that
    // matters — that the template rung 1 names is `mode: 'pregnancy'` — was recorded
    // nowhere.
    //
    // It is not a bug today: `redFlag` is `null` in every mode until D10 supplies the
    // trigger mapping, and narrowing rung 1 here would be this slice deciding D10's rule.
    // It is written down so D10 cannot land that mapping without meeting it.
    expect(flag?.state).toBe('home_flag')
    expect(flag?.mode).toBe('pregnancy')
    expect(
      selectSubject(base({ mode: 'cycle', redFlag: { code: 'severe_pain', loggedAt: NOW } }), RULES)
        .templateId,
    ).toBe(TEMPLATE.redFlag)
  })
})

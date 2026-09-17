import type { CycleEstimate, PhaseCode, PhaseConfidence } from './dashboard-rules'
import type { Profile } from './users'

/**
 * The cycle maths (C11, slice of #11): logged flow days in, counted cycles, a next-period
 * date, a fertile window and a confidence band out.
 *
 * PRD §Predictions in Cycle mode (A25–A27, decided 2026-08-30 with sources): *"These are
 * the initial values of the config-driven constants that Calendar slice C11 reads; the code
 * fails loudly if any is unset, and none is hard-coded."* Every number this file uses
 * arrives in `CycleRules`. There is no literal in the arithmetic below and no default
 * anywhere — `requireCycleRules` refuses to answer without them, the way
 * `dashboard-rules.ts` refuses to evaluate rung 2 without A32's thresholds.
 *
 * **Pure, and that is the design rather than a property of it.** No Firestore, no clock, no
 * `fetch`, no logging — `today` is an argument like everything else, and the caller does the
 * gathering. That is what lets the health-critical gates be exercised against fixtures for
 * states no real account has reached, and it is pinned by a source scan in the test file
 * rather than left to review.
 *
 * **Every gate fails closed** (#176 Risks). A bug that suppresses a window is acceptable;
 * one that draws a window over irregular data is not. So there is no prediction below
 * `minCyclesForEstimate` counted cycles, none when the variation is over the user's FIGO
 * band, and none when her age is unknown or implausible and the variation is over the
 * *tightest* band. The same principle decides which intervals the variation reads: the
 * median's sample is the counted cycles, and the gate's window is every interval between
 * them — see `analyzeCycles`, where the divergence from A25's literal wording is argued.
 *
 * **Nothing here is a measurement.** The 14-day luteal phase is a calendar convention
 * (Wilcox AJ, Dunson D, Baird DD, BMJ 2000;321:1259), not an observation, and v1 has no
 * confirmed-ovulation path — which is why the band this returns is `wide` or `narrow` and
 * never `confirmed`, and why `dashboard-rules.ts` renders both as hedged wording
 * (GUARDRAILS 35).
 *
 * Never log a cycle day, a flow level or a predicted date: this is health data
 * (GUARDRAILS 12). This module writes no log line at all, which is the simplest way to
 * keep that true.
 */

// ── What a caller hands in ─────────────────────────────────────────────────────────────

/**
 * One logged `cycle` entry, as this module needs it — a date (`localDate`, the user's local
 * `YYYY-MM-DD`: a calendar label, never an instant), which marker it carries, and whether
 * she marked her period as ending on it.
 *
 * `spotting` is a separate marker and not a fourth flow level (#23, `events.ts`), and the
 * distinction is load-bearing here: **a spotting day never starts a cycle** (A25 item 1).
 * It still belongs to a period, though, which is what A25 item 6 settles — so a run of
 * logged days that opens with spotting has its *first flow day* inside it, and the spotting
 * days before that belong to the previous cycle.
 *
 * `periodEnd` is #75's explicit "my period ended" mark. It can sit only on a flow day, for
 * the reason `CyclePayload` gives in `events.ts` — a period cannot end on a day that records
 * no bleeding — and the arms below keep that true here too. It is read for one thing only:
 * whether later flow continues the period she marked (`loggedPeriods`, #186).
 */
export type CycleDay =
  | { localDate: string; kind: 'flow'; periodEnd?: true }
  | { localDate: string; kind: 'spotting'; periodEnd?: never }

export interface CycleInput {
  /** Every live `cycle` entry the caller read, in any order. Soft-deleted entries are the
   *  caller's to exclude — `events.ts` already does, and a deleted period is not a period. */
  days: readonly CycleDay[]
  /** The user's local date, `YYYY-MM-DD`. What "today" and `cycleDay` are measured against. */
  today: string
  /**
   * The profile the age band is read from, or `null` when there is none.
   *
   * **Read through `bandForAge` and nowhere else.** #81 replaces `profile.age` with
   * `dateOfBirth`; when it lands, that one function changes and nothing else here does.
   * This module reads exactly one field of the profile and stores none of it.
   */
  profile: Profile | null
}

// ── Configuration (A25–A27) ────────────────────────────────────────────────────────────

/**
 * The FIGO band for one age group: over this many days of shortest-to-longest variation is
 * irregular. *Source: FIGO AUB System 1 — Munro MG et al., Int J Gynecol Obstet
 * 2018;143:393–408.* Three bands, because that is how System 1 defines them — the *edges*
 * are configuration like the doses, so a revision to the source is a configuration change.
 */
export interface IrregularityBands {
  /** Inclusive upper age of the youngest band. A25: 18–25. */
  youngMaxAge: number
  /** Inclusive upper age of the middle band. A25: 26–41. */
  midMaxAge: number
  /** A25: more than 9 days at 18–25. */
  youngVariationDays: number
  /** A25: more than 7 days at 26–41. */
  midVariationDays: number
  /** A25: more than 9 days at 42 and over. */
  olderVariationDays: number
}

/** Every number the maths uses, and the complete list of them. `config.ts` is where these
 *  come from; nothing here has a default, because a default is a clinical constant chosen
 *  by whoever typed it. */
export interface CycleRules {
  /** A25: a cycle is counted only if it is at least this long. */
  minCycleLengthDays: number
  /** A25: …and at most this long. Outside the range is "unusual length", never dropped. */
  maxCycleLengthDays: number
  /** #186: this many consecutive days with nothing logged separate two periods; one fewer
   *  is a missed day inside one. How logged days are grouped — not a clinical claim. */
  minPeriodGapDays: number
  /** A25: the median and the variation are taken over the last this-many counted cycles. */
  historyCycles: number
  /** A26: a prediction is shown only with this many counted cycles or more. */
  minCyclesForEstimate: number
  /** A27: the tighter band starts here; below it the band is wide. */
  narrowBandMinCycles: number
  /** A26: ovulation = next period − this many days. The fixed-luteal convention. */
  lutealPhaseDays: number
  /** A26: the fertile window opens this many days before ovulation. */
  fertileDaysBeforeOvulation: number
  /** A26: …and closes this many days after it. */
  fertileDaysAfterOvulation: number
  /** A26: peak fertility is this many days before ovulation, through ovulation day. */
  peakDaysBeforeOvulation: number
  irregularity: IrregularityBands
}

/** Thrown when the maths is asked for an answer without its constants, or with constants it
 *  cannot use. Its own class so a caller can tell a missing configuration from a bug, so the
 *  route can answer "unavailable" rather than "error", and so the refusal is greppable —
 *  exactly `PatternRuleUnsetError`'s job for rung 2. */
export class CycleRulesUnsetError extends Error {
  constructor(reason = 'no constants are configured') {
    super(`the cycle maths cannot be evaluated: ${reason}`)
    this.name = 'CycleRulesUnsetError'
  }
}

/** Thrown when a date is not `YYYY-MM-DD`. Loud rather than lenient: a date silently read as
 *  "no data" would drop a logged period, and a period the maths cannot see is a prediction
 *  drawn from the wrong anchor. Carries the field name and the shape expected — never the
 *  value (GUARDRAILS 12). */
export class InvalidCycleDateError extends Error {
  constructor(field: string) {
    super(`the cycle maths' ${field} must be a YYYY-MM-DD calendar date`)
    this.name = 'InvalidCycleDateError'
  }
}

/** One thing wrong with a set of constants: which field, and what would have been valid.
 *  Returned rather than thrown so `config.ts` can name the *environment variable* in its
 *  boot failure while this module names the field — one implementation of the rules, two
 *  vocabularies for reporting it. */
export interface CycleRulesProblem {
  field: string
  message: string
}

/** Every member of `CycleRules` that is a number in its own right. `fertileDaysAfterOvulation`
 *  is deliberately absent: it is the one value zero is a real setting for. */
type PositiveRule = Exclude<keyof CycleRules, 'irregularity' | 'fertileDaysAfterOvulation'>

const POSITIVE: readonly PositiveRule[] = [
  'minCycleLengthDays',
  'maxCycleLengthDays',
  // Zero is not a looser grouping: every logged day would open a period of its own.
  'minPeriodGapDays',
  'historyCycles',
  'minCyclesForEstimate',
  'narrowBandMinCycles',
  'lutealPhaseDays',
  'fertileDaysBeforeOvulation',
  'peakDaysBeforeOvulation',
]

const BAND_POSITIVE: readonly (keyof IrregularityBands)[] = [
  'youngMaxAge',
  'midMaxAge',
  'youngVariationDays',
  'midVariationDays',
  'olderVariationDays',
]

/**
 * What is wrong with these constants, or `null` if nothing is.
 *
 * **One implementation, called from two places on purpose.** `config.ts` runs it at boot so
 * an operator is told at startup, and `requireCycleRules` runs it on every evaluation so a
 * set assembled in code — a test fixture, a future remote config — cannot get past it. Two
 * copies of a safety check on health-critical constants is the drift this exists to
 * prevent.
 *
 * The cross-field clauses are not style: each one is a configuration that would produce a
 * *plausible-looking* wrong answer rather than an obvious failure. A luteal phase longer
 * than the shortest countable cycle puts ovulation before the cycle it belongs to; a peak
 * window wider than the fertile window puts peak days outside the window that contains
 * them; inverted age edges silently apply the wrong FIGO band; a period gap as long as the
 * shortest countable cycle reads two periods that far apart as one, so that cycle can never
 * be seen — even between two one-day periods, whose gap is the cycle less one day.
 */
export const cycleRulesProblem = (rules: CycleRules | null): CycleRulesProblem | null => {
  if (!rules) return { field: 'rules', message: 'no constants are configured' }

  for (const field of POSITIVE) {
    const value = rules[field]
    // A zero or a fraction is not a quieter setting, it is arithmetic nobody chose.
    if (typeof value !== 'number' || !Number.isInteger(value) || value < 1) {
      return { field, message: 'must be a positive integer' }
    }
  }
  // The only one that may legitimately be zero: a window that closes on ovulation day.
  const after = rules.fertileDaysAfterOvulation
  if (typeof after !== 'number' || !Number.isInteger(after) || after < 0) {
    return { field: 'fertileDaysAfterOvulation', message: 'must be a non-negative integer' }
  }
  for (const field of BAND_POSITIVE) {
    const value = rules.irregularity?.[field]
    if (typeof value !== 'number' || !Number.isInteger(value) || value < 1) {
      return { field: `irregularity.${field}`, message: 'must be a positive integer' }
    }
  }

  if (rules.minCycleLengthDays > rules.maxCycleLengthDays) {
    return {
      field: 'maxCycleLengthDays',
      message: `must be at least minCycleLengthDays (${rules.minCycleLengthDays})`,
    }
  }
  if (rules.minPeriodGapDays >= rules.minCycleLengthDays) {
    return {
      field: 'minPeriodGapDays',
      message: `must be less than minCycleLengthDays (${rules.minCycleLengthDays}), or two periods the shortest countable cycle apart always read as one`,
    }
  }
  if (rules.lutealPhaseDays >= rules.minCycleLengthDays) {
    return {
      field: 'lutealPhaseDays',
      message: `must be less than minCycleLengthDays (${rules.minCycleLengthDays}), or ovulation falls outside the cycle it belongs to`,
    }
  }
  if (rules.peakDaysBeforeOvulation > rules.fertileDaysBeforeOvulation) {
    return {
      field: 'peakDaysBeforeOvulation',
      message: `must be at most fertileDaysBeforeOvulation (${rules.fertileDaysBeforeOvulation}), or peak days fall outside the fertile window`,
    }
  }
  if (rules.minCyclesForEstimate < 2) {
    return {
      field: 'minCyclesForEstimate',
      message: 'must be at least 2: a shortest-to-longest variation needs two cycles',
    }
  }
  if (rules.narrowBandMinCycles < rules.minCyclesForEstimate) {
    return {
      field: 'narrowBandMinCycles',
      message: `must be at least minCyclesForEstimate (${rules.minCyclesForEstimate}), or the wide band is unreachable`,
    }
  }
  if (rules.historyCycles < rules.minCyclesForEstimate) {
    return {
      field: 'historyCycles',
      message: `must be at least minCyclesForEstimate (${rules.minCyclesForEstimate}), or the gate counts cycles the median never sees`,
    }
  }
  if (rules.irregularity.youngMaxAge >= rules.irregularity.midMaxAge) {
    return {
      field: 'irregularity.midMaxAge',
      message: `must be greater than irregularity.youngMaxAge (${rules.irregularity.youngMaxAge})`,
    }
  }
  return null
}

/** The constants, or a refusal. Mirrors `requirePatternRule` in `dashboard-rules.ts`. */
const requireCycleRules = (rules: CycleRules | null): CycleRules => {
  const problem = cycleRulesProblem(rules)
  if (problem) throw new CycleRulesUnsetError(`${problem.field} ${problem.message}`)
  return rules as CycleRules
}

// ── Dates ──────────────────────────────────────────────────────────────────────────────

const LOCAL_DATE = /^\d{4}-\d{2}-\d{2}$/

/** `YYYY-MM-DD` as whole days since the epoch, in UTC so the arithmetic cannot pick up the
 *  process timezone. Local dates are calendar labels here, not instants. */
const dateFor = (day: number): string => new Date(day * 86_400_000).toISOString().slice(0, 10)

const dayNumber = (localDate: string, field: string): number => {
  if (!LOCAL_DATE.test(localDate)) throw new InvalidCycleDateError(field)
  const parsed = Date.parse(`${localDate}T00:00:00.000Z`)
  if (Number.isNaN(parsed)) throw new InvalidCycleDateError(field)
  const day = Math.round(parsed / 86_400_000)
  // The round trip, because `Date.parse` rolls a day that does not exist forward rather
  // than refusing it: `2026-02-30` is 2 March, two days from where it was written, and a
  // period start moved two days moves every cycle length around it. `isCalendarDate` at
  // the route edge already refuses one, so nothing stored through the API reaches here —
  // this is the floor under a hand-edited document, held to the same standard.
  if (dateFor(day) !== localDate) throw new InvalidCycleDateError(field)
  return day
}

// ── Counted cycles (A25 item 1) ────────────────────────────────────────────────────────

/** Why a cycle is not counted. One value today; it is a union so the reason stays legible
 *  in the output when there is a second one, rather than collapsing to a boolean. */
export type CycleExclusion = 'unusual-length'

/**
 * One interval between successive first flow days.
 *
 * **Out-of-range intervals are returned too, flagged** (A25 item 1: "excluded from
 * estimates and shown as 'unusual length' in Cycle history, **never silently dropped**").
 * Excluding one from the estimate while omitting it from this list would pass every
 * estimate test and is precisely the bug that rule forbids, so both halves are pinned.
 */
export interface ObservedCycle {
  /** The first flow day that opened it. */
  startDate: string
  /** The next first flow day, which closed it. */
  endDate: string
  /** Whole days from `startDate` to `endDate`. */
  lengthDays: number
  /** Whether it counts toward the median, the variation and the ≥N gate. */
  counted: boolean
  /** Why not, when `counted` is false; `null` when it is. */
  excluded: CycleExclusion | null
}

/** One period as she logged it, in whole days: the first flow day that opened it, and the
 *  last logged day of its run. The end is used for the menstrual phase only. */
interface LoggedPeriod {
  start: number
  end: number
}

/**
 * Every period she has logged, oldest first.
 *
 * A period is a run of logged days — flow *or* spotting — and it starts on the earliest day
 * in that run carrying flow. That is A25 items 1 and 6 together: a spotting day never starts
 * a cycle, and the spotting days before a first flow day belong to the previous cycle. A run
 * of spotting alone starts nothing.
 *
 * **What ends a run is `minPeriodGapDays` days in a row with nothing logged (#186)**; one
 * fewer is a missed tap inside one period. The app logs one day at a time and back-fills
 * nothing, and a run used to end on *any* unlogged day — so a period logged 1, 2, 4, 5 read
 * as two, and the phantom three-day interval between them withheld her prediction, her
 * window and her phase behind a reason that was not true (#180, #190). The two ways of being
 * wrong are not equally quiet, and #186 chose between them: merging two genuinely close
 * episodes shows as one long period, while splitting one invents a short cycle nobody sees.
 *
 * **"Nothing logged", not "no flow"**: a logged spotting day keeps the run open, as it did
 * before #186. The PRD's "first day with no flow logged" predates spotting being split out of
 * the flow picker (#23, which said only that spotting starts nothing), and reading it the
 * other way would make flow, spotting, spotting, flow two periods four days apart — the
 * silent split #186 exists to avoid.
 *
 * **#75's period-end mark is read here, for one decision only: whether a later flow day
 * continues the period she marked as ended.** Her mark says the days after it are not her
 * period, so a logged spotting day after it no longer carries the run to the next flow day.
 * From a marked flow day, every day until the next flow counts toward the gap. Flow within
 * `minPeriodGapDays` of the mark means the period had not ended — the mark is stale, and the
 * run continues exactly as it would unmarked. Flow at or beyond it opens a new period, and
 * the mark stands. Only the run's *latest* flow day is asked: once flow has continued past a
 * mark, that mark decides nothing. The mark is never an end date, a period length or a cycle
 * length — `end` is the run as she logged it, marked or not.
 */
const loggedPeriods = (days: readonly CycleDay[], minGapDays: number): LoggedPeriod[] => {
  const byDay = new Map<number, { flow: boolean; periodEnd: boolean }>()
  for (const entry of days) {
    const day = dayNumber(entry.localDate, 'localDate')
    const seen = byDay.get(day)
    if (entry.kind === 'flow') {
      // Flow wins a day that somehow carries both markers: `events.ts` stores one entry per
      // day and its payload makes "both at once" unrepresentable, so this is a floor under a
      // hand-edited document, taken in the direction that keeps a real period visible. Two
      // flow entries on one day are the same floor, and there the mark holds only if both
      // carry it — the answer cannot depend on the order the entries arrive in, and a mark
      // taken on half the evidence could only ever split a period.
      const marked = entry.periodEnd === true
      byDay.set(day, { flow: true, periodEnd: seen?.flow ? seen.periodEnd && marked : marked })
    } else if (seen === undefined) {
      byDay.set(day, { flow: false, periodEnd: false })
    }
  }

  const periods: LoggedPeriod[] = []
  let previous: number | null = null
  // The run's latest flow day. A later flow day replaces it, which is what makes an earlier
  // mark stale.
  let lastFlow: { day: number; periodEnd: boolean } | null = null
  let open: LoggedPeriod | null = null
  for (const day of [...byDay.keys()].sort((a, b) => a - b)) {
    const { flow, periodEnd } = byDay.get(day)!
    const gapBefore = previous !== null && day - previous - 1 >= minGapDays
    const pastMark =
      flow && lastFlow !== null && lastFlow.periodEnd && day - lastFlow.day - 1 >= minGapDays
    if (gapBefore || pastMark) {
      open = null
      lastFlow = null
    }
    previous = day
    if (open !== null) open.end = day
    if (!flow) continue
    lastFlow = { day, periodEnd }
    if (open === null) {
      open = { start: day, end: day }
      periods.push(open)
    }
  }
  return periods
}

const toCycles = (starts: readonly number[], rules: CycleRules): ObservedCycle[] =>
  starts.slice(0, -1).map((start, index) => {
    const end = starts[index + 1]!
    const lengthDays = end - start
    const counted =
      lengthDays >= rules.minCycleLengthDays && lengthDays <= rules.maxCycleLengthDays
    return {
      startDate: dateFor(start),
      endDate: dateFor(end),
      lengthDays,
      counted,
      excluded: counted ? null : ('unusual-length' as const),
    }
  })

// ── The median and the variation (A25 item 2, A26 item 3) ──────────────────────────────

/**
 * The median cycle length, rounded to a whole day.
 *
 * **Median, not mean** (A26): one mislogged period start inside the 21–45 range moves a
 * mean and barely moves a median, and the mean's answer would be a date nothing in her data
 * supports. Rounding is a consequence of dates being whole days, not a tuning constant —
 * an even-sized sample's median is the mean of the two middle values, and half a day is not
 * a date.
 */
const median = (lengths: readonly number[]): number | null => {
  if (lengths.length === 0) return null
  const sorted = [...lengths].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  const value =
    sorted.length % 2 === 1 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2
  return Math.round(value)
}

/**
 * The ages this function will read a band for. Outside it, the stored value is not an age
 * and is treated as absent.
 *
 * It is `parseProfile`'s own range (`index.ts`, `inRange(age, 13, 99)`) rather than a
 * second opinion about it, and it is a floor under a hand-edited document exactly as the
 * date round-trip in `dayNumber` is: nothing stored through the API can be outside it, and
 * an `age` of 200 that arrived some other way must not be *trusted more* than a missing
 * one. It is not a clinical constant — it decides nothing about the maths, only whether
 * the field is an age at all — which is why it is not in `CycleRules`.
 */
const PLAUSIBLE_AGE_YEARS = { min: 13, max: 99 }

/**
 * The FIGO band for an age, and the age it was chosen for.
 *
 * **The one place age is read** (#176 Risks; #81 replaces `profile.age` with `dateOfBirth`
 * and changes this function alone).
 *
 * **Age unknown → the tightest band.** Not the youngest band and not a permissive one:
 * suppressing more is the safe direction, and a fallback that happened to be lenient would
 * draw a window over data the same user's known age would have refused. The tightest is
 * computed from the configured bands rather than named, so it cannot drift if a band is
 * re-tuned to be tighter than the one written down here.
 *
 * **And an age that is not one counts as unknown**, for the same reason and in the same
 * direction. A stored `200`, `1e9`, `2.5` or `5` used to fall through to a real band — and
 * the bands at both ends are the permissive ones, so a corrupted age was trusted *more*
 * than an absent one. That is the inverse of the rule this paragraph is named for.
 */
export const bandForAge = (
  profile: Profile | null,
  rules: CycleRules,
): { ageYears: number | null; maxVariationDays: number } => {
  const bands = rules.irregularity
  const raw = profile?.age
  const ageYears =
    typeof raw === 'number' &&
    Number.isFinite(raw) &&
    raw >= PLAUSIBLE_AGE_YEARS.min &&
    raw <= PLAUSIBLE_AGE_YEARS.max
      ? raw
      : null
  if (ageYears === null) {
    return {
      ageYears: null,
      maxVariationDays: Math.min(
        bands.youngVariationDays,
        bands.midVariationDays,
        bands.olderVariationDays,
      ),
    }
  }
  if (ageYears <= bands.youngMaxAge) {
    return { ageYears, maxVariationDays: bands.youngVariationDays }
  }
  if (ageYears <= bands.midMaxAge) {
    return { ageYears, maxVariationDays: bands.midVariationDays }
  }
  return { ageYears, maxVariationDays: bands.olderVariationDays }
}

// ── What the maths answers with ────────────────────────────────────────────────────────

/** Why there is no prediction. **In the output rather than inferred from a null** (#176
 *  acceptance criteria), so C12 can explain a window that vanished after one mislogged
 *  period start instead of leaving the user to guess. */
export type EstimateWithheld = 'no-flow-logged' | 'too-few-counted-cycles' | 'irregular-cycles'

/** Ovulation − `fertileDaysBeforeOvulation` through ovulation + `fertileDaysAfterOvulation`,
 *  with peak fertility inside it (A26). Estimated from the fixed-luteal convention, never
 *  observed — and never a contraceptive method, which C12 states where it is drawn. */
export interface FertileWindow {
  from: string
  to: string
  /** `peakDaysBeforeOvulation` days before ovulation… */
  peakFrom: string
  /** …through ovulation day itself. */
  peakTo: string
}

export interface CyclePrediction {
  /** The estimated next first flow day: the last one plus the median counted length. */
  nextPeriodStart: string
  /** `nextPeriodStart` − `lutealPhaseDays`. A calendar convention, not a measurement. */
  ovulation: string
  fertileWindow: FertileWindow
  /** A27: `wide` below `narrowBandMinCycles` counted cycles, `narrow` at or above it.
   *  Never `confirmed` — v1 has no confirmed-ovulation path. */
  confidence: Exclude<PhaseConfidence, 'none'>
}

export interface CycleAnalysis {
  /** The local date this was computed for, carried so `toCycleEstimate` cannot be handed a
   *  different one. `cycleDay` is measured against it, and a phase or a lateness count
   *  measured against another day would be an estimate that disagrees with itself. */
  today: string
  /** Every interval between successive first flow days, oldest first — out-of-range ones
   *  included and flagged (A25 item 1). Cycle history draws this list. */
  cycles: readonly ObservedCycle[]
  /** How many of them count. The number `home_b` says "of 3". */
  countedCycles: number
  /** A26's ≥N gate, answered once here so nothing downstream re-decides it. */
  enoughCountedCycles: boolean
  /** Median length of the last `historyCycles` counted cycles, or `null`. */
  medianCycleLengthDays: number | null
  /** Shortest-to-longest spread over *every* interval spanned by those cycles — the
   *  out-of-range ones included — or `null` below two intervals. Wider than the median's
   *  sample on purpose: `analyzeCycles` says why, and it is what keeps the gate closed for
   *  a user whose intervals alternate short and long. */
  variationDays: number | null
  /** Whether that spread is over this user's FIGO band. */
  irregular: boolean
  /** The band applied, and the age it was chosen for — `null` age means the tightest band. */
  band: { ageYears: number | null; maxVariationDays: number }
  /** The most recent first flow day, or `null` when no flow has been logged. */
  lastPeriodStart: string | null
  /** The last day of the period run that opened the current cycle, as she logged it — a
   *  missed day inside the run does not end it (#186). */
  currentPeriodEnd: string | null
  /** Today's cycle day, counted from `lastPeriodStart` (A25 item 6). */
  cycleDay: number | null
  /** `null` whenever a gate withheld it; `withheld` then says which one. */
  prediction: CyclePrediction | null
  withheld: EstimateWithheld | null
}

// ── The maths ──────────────────────────────────────────────────────────────────────────

/**
 * The whole of C11: cycles in, the estimate out.
 *
 * Deterministic and total — the same input always produces the same answer, and the answer
 * is computed here rather than cached anywhere, which is what makes A25 item 5 ("recomputed
 * on every edit to a flow entry… never a nightly batch") a property of the design instead of
 * a job someone has to remember to run. The caller reads, this derives.
 *
 * Throws `CycleRulesUnsetError` when the constants are missing or unusable, and
 * `InvalidCycleDateError` when a date is not `YYYY-MM-DD`. Both are refusals rather than
 * failures: an answer past either would be a prediction that looks live and is not.
 */
export const analyzeCycles = (input: CycleInput, rules: CycleRules | null): CycleAnalysis => {
  const settings = requireCycleRules(rules)
  const today = dayNumber(input.today, 'today')
  const band = bandForAge(input.profile, settings)

  const periods = loggedPeriods(input.days, settings.minPeriodGapDays)
  const cycles = toCycles(periods.map((period) => period.start), settings)
  const countedAt = cycles.flatMap((cycle, index) => (cycle.counted ? [index] : []))
  const countedCycles = countedAt.length
  // The median's sample: the last `historyCycles` *counted* cycles, so a 60-day interval
  // cannot drag the predicted date (A26 item 3, and the point of the range filter).
  const recentAt = countedAt.slice(-settings.historyCycles)
  const recent = recentAt.map((index) => cycles[index]!.lengthDays)
  const medianCycleLengthDays = median(recent)

  // **The variation's window is wider than the median's sample, on purpose.** It runs from
  // the oldest cycle the median reads through the newest interval and takes *every*
  // interval in between — the out-of-range ones included.
  //
  // A25's own wording is "over the last 6 counted cycles", and reading it literally makes
  // the gate fail *open* on the shape this product exists for: intervals alternating 28 and
  // 60 days leave three counted cycles, all of them 28, so the variation is 0, nothing is
  // irregular, and an oligomenorrhoeic user is handed a fertile window and a phase. That
  // contradicts §Phase 1 rules 4 ("if cycle length varies by more than 7-9 days, no window
  // is shown" — hers varies by 32) and 5 ("a confident window must never be drawn over
  // irregular data"), and it is the one fail-open path #176's Risks name as unacceptable.
  //
  // So an interval the range filter rejected is not an absence of evidence about
  // regularity — it *is* evidence of irregularity: FIGO's own AUB System 1, the source
  // behind these bands, classifies a cycle of 38 days or more as infrequent menstruation.
  // The estimate still ignores it; the gate does not.
  const windowFrom = recentAt[0] ?? Math.max(0, cycles.length - settings.historyCycles)
  const spanned = cycles.slice(windowFrom).map((cycle) => cycle.lengthDays)
  const variationDays =
    spanned.length >= 2 ? Math.max(...spanned) - Math.min(...spanned) : null
  const irregular = variationDays !== null && variationDays > band.maxVariationDays

  const current = periods.at(-1) ?? null
  const lastStart = current?.start ?? null
  const lastPeriodStart = current === null ? null : dateFor(current.start)
  const currentPeriodEnd = current === null ? null : dateFor(current.end)
  // A25 item 6: day 1 is the first flow day itself. A date before it is not a cycle day —
  // which a caller can reach by asking about a day earlier than anything she has logged.
  const cycleDay = lastStart === null || today < lastStart ? null : today - lastStart + 1

  const base = {
    today: input.today,
    cycles,
    countedCycles,
    enoughCountedCycles: countedCycles >= settings.minCyclesForEstimate,
    medianCycleLengthDays,
    variationDays,
    irregular,
    band,
    lastPeriodStart,
    currentPeriodEnd,
    cycleDay,
  }

  // The gates, in the order the PRD states them, each failing closed. Every `return` below
  // hands back `prediction: null` — there is no path on which a withheld reason and a
  // window are both present.
  if (lastStart === null) {
    return { ...base, prediction: null, withheld: 'no-flow-logged' }
  }
  if (!base.enoughCountedCycles || medianCycleLengthDays === null) {
    return { ...base, prediction: null, withheld: 'too-few-counted-cycles' }
  }
  if (irregular) {
    return { ...base, prediction: null, withheld: 'irregular-cycles' }
  }

  const nextPeriod = lastStart + medianCycleLengthDays
  const ovulation = nextPeriod - settings.lutealPhaseDays
  return {
    ...base,
    prediction: {
      nextPeriodStart: dateFor(nextPeriod),
      ovulation: dateFor(ovulation),
      fertileWindow: {
        from: dateFor(ovulation - settings.fertileDaysBeforeOvulation),
        to: dateFor(ovulation + settings.fertileDaysAfterOvulation),
        peakFrom: dateFor(ovulation - settings.peakDaysBeforeOvulation),
        peakTo: dateFor(ovulation),
      },
      confidence: countedCycles >= settings.narrowBandMinCycles ? 'narrow' : 'wide',
    },
    withheld: null,
  }
}

// ── The shape D1 consumes ──────────────────────────────────────────────────────────────

/**
 * Today's phase, or `null`.
 *
 * Four codes, and every boundary between them comes from A26's own constants or from what
 * she logged — none is invented here:
 *  - **menstrual** while today is inside the period run that opened this cycle. Observed,
 *    not estimated: Eva knows the days she logged and claims nothing past the last of them.
 *    The unlogged days it does count are missed ones *between* two logged days, which #186
 *    reads as part of the period.
 *  - **ovulation** across the fertile window (A26: ovulation − 5 through ovulation + 1).
 *  - **follicular** before that window, **luteal** after it.
 *
 * A withheld prediction means no phase at all. That is the gate doing its job: every phase
 * but the observed one is read off an estimated ovulation date, so a phase without a
 * prediction would be an estimate wearing no confidence band.
 */
const phaseOn = (analysis: CycleAnalysis, today: number): PhaseCode | null => {
  // `today` is `analysis.today` as a day number; the caller has already parsed it once.
  if (analysis.prediction === null || analysis.cycleDay === null) return null
  const periodEnd = analysis.currentPeriodEnd
  if (periodEnd !== null && today <= dayNumber(periodEnd, 'currentPeriodEnd')) return 'menstrual'
  const window = analysis.prediction.fertileWindow
  if (today < dayNumber(window.from, 'fertileWindow.from')) return 'follicular'
  if (today <= dayNumber(window.to, 'fertileWindow.to')) return 'ovulation'
  return 'luteal'
}

/**
 * C11's answers in the vocabulary D1 already consumes (`dashboard-rules.ts`'s
 * `CycleEstimate`) — the seam #98 left a hardcoded no-knowledge fixture behind.
 *
 * A projection and nothing more: every gate was decided in `analyzeCycles`, so there is no
 * second threshold here that could drift from the one Cycle history draws. `phase` is
 * `null` exactly when `prediction` is, which is what makes D1's `speakablePhase` — three
 * independent checks of C11's own answers — agree with this one by construction.
 */
export const toCycleEstimate = (analysis: CycleAnalysis): CycleEstimate => {
  const day = dayNumber(analysis.today, 'today')
  const code = phaseOn(analysis, day)
  const predicted =
    analysis.prediction === null
      ? null
      : dayNumber(analysis.prediction.nextPeriodStart, 'nextPeriodStart')
  return {
    countedCycles: analysis.countedCycles,
    enoughCyclesForEstimates: analysis.enoughCountedCycles,
    irregular: analysis.irregular,
    cycleDay: analysis.cycleDay,
    phase:
      code === null || analysis.prediction === null
        ? null
        : { code, confidence: analysis.prediction.confidence },
    // A count, not a judgement: whether a prediction exists at all is the gate above.
    daysPastPredictedPeriod: predicted !== null && day > predicted ? day - predicted : null,
  }
}

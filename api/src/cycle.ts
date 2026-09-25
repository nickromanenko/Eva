import type { CycleEstimate, Irregularity, PhaseCode, PhaseConfidence } from './dashboard-rules'
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
   * **Read through `bandForAge` and nowhere else.** #81 replaced `profile.age` with
   * `dateOfBirth` and that one function is what changed — which is the whole reason the
   * rule was written down before there was a second reader to break. This module reads
   * exactly one field of the profile, derives the age from it against `today`, and stores
   * none of it.
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

/**
 * Thrown when the derived age is below Eva's account floor (#187).
 *
 * **It fails rather than clamping, and that is the point of it.** Everything else in this
 * file treats an age it cannot use as *unknown* and falls to the tightest band — the right
 * answer for a fact that is missing, and the wrong one for a fact that is impossible. Eva
 * is 18+ (A12) and `parseProfile` refuses a date of birth under it, so an age below the
 * floor did not arrive through the API. It is a bug of ours, or a minor who got past the
 * account check, and neither is a condition to smooth over into a slightly safer number.
 *
 * Deliberately **not** re-exported from `today.ts`, so it is not one of the route's `503`
 * refusals: nothing about this resolves by retrying later, and there is no configuration to
 * set. It lands in `app.onError` as a `500` with a `ref` and no detail — the same place
 * `InvalidCycleDateError` lands, for the same reason.
 *
 * Names the floor, which is a constant of ours, and never her age or her date of birth
 * (GUARDRAILS 12).
 */
export class ImpossibleAgeError extends Error {
  constructor(minYears: number) {
    super(`the cycle maths was given an age below Eva's floor of ${minYears}`)
    this.name = 'ImpossibleAgeError'
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

/** The day number for a `YYYY-MM-DD` calendar date, or `null` when the string is not one.
 *
 *  Split out of `dayNumber` for `bandForAge`, which is the one reader that must *not*
 *  throw on a bad date: a stored date of birth it cannot parse is an unknown age, and an
 *  unknown age is a band rather than a refusal. Every other reader wants the throw. */
const dayNumberOrNull = (localDate: string): number | null => {
  if (!LOCAL_DATE.test(localDate)) return null
  const parsed = Date.parse(`${localDate}T00:00:00.000Z`)
  if (Number.isNaN(parsed)) return null
  const day = Math.round(parsed / 86_400_000)
  // The round trip, because `Date.parse` rolls a day that does not exist forward rather
  // than refusing it: `2026-02-30` is 2 March, two days from where it was written, and a
  // period start moved two days moves every cycle length around it. `isCalendarDate` at
  // the route edge already refuses one, so nothing stored through the API reaches here —
  // this is the floor under a hand-edited document, held to the same standard.
  return dateFor(day) === localDate ? day : null
}

const dayNumber = (localDate: string, field: string): number => {
  const day = dayNumberOrNull(localDate)
  if (day === null) throw new InvalidCycleDateError(field)
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
    const counted = lengthDays >= rules.minCycleLengthDays && lengthDays <= rules.maxCycleLengthDays
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
 * Eva's account floor, in years (A12, #81). An age below it is refused outright — see
 * `ImpossibleAgeError` for why this end fails where the other end falls back.
 *
 * It is `parseProfile`'s own floor (`index.ts`, `MIN_ACCOUNT_AGE_YEARS`) rather than a
 * second opinion about it, and it is the floor under a hand-edited document exactly as the
 * date round-trip in `dayNumber` is: nothing stored through the API can be under it.
 * `cycle.ts` imports only types, so the two literals cannot be one constant — `the account
 * floor is one number` in `cycle.test.ts` reads both files and pins them equal instead.
 *
 * It is not a clinical constant. The FIGO bands happen to start at 18 too, and that is a
 * coincidence of two different decisions rather than one fact: A25's youngest band is
 * sourced from FIGO AUB System 1, and this is Eva's own line under GDPR Article 8 and the
 * App Store age rating. Neither may be re-tuned by editing the other, which is why this is
 * here and not in `CycleRules`.
 */
const MIN_ACCOUNT_AGE_YEARS = 18

/**
 * Past this, the stored date of birth is not a date of birth and is treated as absent.
 *
 * **The asymmetry with the floor above is deliberate.** Nothing enforces an upper bound
 * anywhere — a woman of 104 is unlikely, not impossible, and no route refuses her — so a
 * derived age of 200 is evidence the field is corrupt, not evidence of a broken invariant.
 * Corrupt reads as unknown and takes the tightest band, because a corrupted age must never
 * be *trusted more* than a missing one. Under 18 is the opposite case: it contradicts a
 * check that did run, so it stops.
 */
const MAX_PLAUSIBLE_AGE_YEARS = 99

/**
 * Whole years from a date of birth to a date, both `YYYY-MM-DD` calendar labels.
 *
 * Calendar parts rather than the day numbers everything else here counts in, because a
 * difference in days is not an age: 18 years is 6574 days or 6575 depending on how many
 * leap days fell inside it, and dividing by 365.25 puts the boundary hours away from
 * midnight on somebody's birthday.
 *
 * A 29 February birth date has its birthday on 1 March in a non-leap year, which is the
 * strict reading — a day later rather than a day earlier — and the direction an age floor
 * should err in.
 *
 * `dateOfBirth` is the caller's to check (`bandForAge` does, with `dayNumberOrNull`, because
 * a date it cannot read is an unknown age rather than a refusal). `today` is not: a `today`
 * that is not a calendar date is the caller's bug on every path in this file, and throws.
 *
 * **Exported, and the only reason it is.** `parseProfile` enforces Eva's 18+ floor at the
 * route edge and needs the same arithmetic, and it reaches it through `today.ts` for the
 * reason that file's re-export block gives. Two implementations of "how old is she" is not
 * a theoretical drift: the obvious `Date.UTC(year - years, …)` spelling disagrees with this
 * one on 29 February, admitting somebody a day under the floor once every four years, and a
 * second copy is where that lands. This function decides no policy — the floor itself is
 * declared on each side, because one is a clinical band's edge and the other is a legal line.
 */
export const ageYearsOn = (dateOfBirth: string, today: string): number => {
  dayNumber(today, 'today')
  const [birthYear, birthMonth, birthDay] = dateOfBirth.split('-').map(Number)
  const [year, month, day] = today.split('-').map(Number)
  const hadBirthday = month! > birthMonth! || (month === birthMonth && day! >= birthDay!)
  return year! - birthYear! - (hadBirthday ? 0 : 1)
}

/**
 * The FIGO band for an age, and the age it was chosen for.
 *
 * **The one place age is read** (#176 Risks). #81 replaced `profile.age` with
 * `dateOfBirth` and this function is the whole of the change: the age is derived here,
 * against the caller's own `today`, and nowhere else.
 *
 * **Age unknown → the tightest band.** Not the youngest band and not a permissive one:
 * suppressing more is the safe direction, and a fallback that happened to be lenient would
 * draw a window over data the same user's known age would have refused. The tightest is
 * computed from the configured bands rather than named, so it cannot drift if a band is
 * re-tuned to be tighter than the one written down here.
 *
 * **And a date of birth that is not one counts as unknown**, for the same reason and in the
 * same direction. A stored `null`, `""`, `2026-02-30` or a date that makes her 200 falls
 * here rather than into a real band — and the bands at both ends are the permissive ones,
 * so a corrupted value trusted as an age would be trusted *more* than an absent one. That
 * is the inverse of the rule this paragraph is named for.
 *
 * **Under 18 throws** (#187), and is the one case that does not resolve to a band at all.
 * A25's youngest band is *18*–25, so reading it from 13 handed a 13-to-17-year-old the most
 * permissive 9-day tolerance at the age when cycles are least regular — the inverse of
 * every other decision in this file. The fix is not an adolescent band, which FIGO's cited
 * table does not supply, and not a clamp either: Eva is 18+ and `parseProfile` enforces it
 * where the date is captured, so nothing under the floor can have come through the API.
 * See `ImpossibleAgeError`.
 */
export const bandForAge = (
  profile: Profile | null,
  rules: CycleRules,
  today: string,
): { ageYears: number | null; maxVariationDays: number } => {
  const bands = rules.irregularity
  const dateOfBirth = profile?.dateOfBirth
  // Parsed before it is used, so a stored value that is not a real calendar day reads as an
  // absent one rather than throwing out of `ageYearsOn` — the same "corrupt is unknown"
  // direction the paragraph above argues, applied one step earlier.
  const derived =
    typeof dateOfBirth === 'string' && dayNumberOrNull(dateOfBirth) !== null
      ? ageYearsOn(dateOfBirth, today)
      : null
  if (derived !== null && derived < MIN_ACCOUNT_AGE_YEARS) {
    throw new ImpossibleAgeError(MIN_ACCOUNT_AGE_YEARS)
  }
  const ageYears = derived !== null && derived <= MAX_PLAUSIBLE_AGE_YEARS ? derived : null
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

/**
 * Why there is no prediction. **In the output rather than inferred from a null** (#176
 * acceptance criteria), so C12 can explain a window that vanished after one mislogged
 * period start instead of leaving the user to guess.
 *
 * **`uncountable-cycle` is the fourth, and it exists because the third was being told to
 * women it was not true of** (#190). `irregular-cycles` reaches the client as "your cycle
 * lengths vary too much to estimate from" — a statement about her body — and it was
 * answered for a woman whose counted cycles were all 28 days and who had missed one period
 * start, for the six cycles it takes that interval to leave the window. The two facts are
 * not interchangeable and only one of them is about her, so they are not one value.
 *
 * Both withhold. Neither is a finding, and `uncountable-cycle` is deliberately **not** an
 * accusation of mislogging either: Eva cannot tell a missed tap from one genuinely long
 * cycle, and the honest sentence behind this name is "one of your recent cycles is outside
 * the range Eva estimates from", which is true of both.
 */
export type EstimateWithheld =
  | 'no-flow-logged'
  | 'too-few-counted-cycles'
  | 'irregular-cycles'
  | 'uncountable-cycle'

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
  /** Whether that spread is over this user's FIGO band — and when it is, whether the
   *  evidence is in her own counted cycles or in a single interval the range filter could
   *  not read (#190). `none` is the only value that leaves a prediction possible; see
   *  `Irregularity` for why the difference between the other two is not cosmetic. */
  irregularity: Irregularity
  /** The band applied, and the age it was chosen for — `null` age means the tightest band. */
  band: { ageYears: number | null; maxVariationDays: number }
  /** The most recent first flow day, or `null` when no flow has been logged. */
  lastPeriodStart: string | null
  /** The last day of the period run that opened the current cycle, as she logged it — a
   *  missed day inside the run does not end it (#186). */
  currentPeriodEnd: string | null
  /** The grouping constant this answer was computed with (#186), carried so the phase can
   *  apply to the dry days *after* that run the same rule the grouping applied to the dry
   *  days inside it (#197) — see `phaseOn`. An input kept in the output for the reason
   *  `today` is: a projection that had to be handed the number again could be handed a
   *  different one, and two readings of what one period is is the drift #186 removed. */
  minPeriodGapDays: number
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
 *
 * And `ImpossibleAgeError` (#187) when the profile's date of birth puts her under Eva's
 * account floor. That one is not a refusal in the same sense — it says an invariant the
 * account check is supposed to hold has not held, and there is nothing to answer.
 */
export const analyzeCycles = (input: CycleInput, rules: CycleRules | null): CycleAnalysis => {
  const settings = requireCycleRules(rules)
  const today = dayNumber(input.today, 'today')
  const band = bandForAge(input.profile, settings, input.today)

  const periods = loggedPeriods(input.days, settings.minPeriodGapDays)
  const cycles = toCycles(
    periods.map((period) => period.start),
    settings,
  )
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
  const windowCycles = cycles.slice(windowFrom)
  const spanned = windowCycles.map((cycle) => cycle.lengthDays)
  const spread = (lengths: readonly number[]): number | null =>
    lengths.length >= 2 ? Math.max(...lengths) - Math.min(...lengths) : null
  const overBand = (days: number | null): boolean => days !== null && days > band.maxVariationDays
  const variationDays = spread(spanned)

  // **Which of the two facts the spread is, when it is over the band** (#190).
  //
  // The paragraph above is why an out-of-range interval closes the gate; it is not a reason
  // to tell her that her cycles vary. For a woman logging 28 days who misses one period
  // start, two cycles merge into one 56-day interval: every cycle Eva counted is still 28,
  // the spread over the window is 28 because of that one interval, and the card said "Your
  // recent cycle lengths vary significantly" for the six further counted cycles it takes
  // the interval to leave the window. Her cycle lengths did not vary at all.
  //
  // So the same spread is asked a second question — is the evidence in the cycles Eva
  // *counted*? — and one exception is carved for the case where it is not:
  //
  //  - the counted intervals inside this same window are within her band, **and**
  //  - exactly one interval in it fell outside the countable range.
  //
  // **One, because two is a pattern and this is the direction that must not be got wrong.**
  // FIGO AUB System 1 (Munro et al. 2018), the source behind these bands, classifies a cycle
  // of 38 days or more as infrequent menstruation; a woman whose intervals alternate 28 and
  // 60 has three such intervals in the window and is oligomenorrhoeic, not a woman who
  // mislogged three times. Calling *that* an unreadable log is the same class of falsehood
  // as the one this fixes, pointed the other way, and it is the worse one — `irregular-cycles`
  // is the reason whose card points at care. Erring toward it is the safe direction, so
  // anything but exactly one lands there.
  //
  // **This changes no gate.** Both values withhold the prediction, the window and the
  // phase; #181's fail-closed path is untouched and `[28, 60, 28, 60, 28, 60]` is refused
  // here exactly as it was. What is decided is only which true sentence she is told.
  const countedInWindow = windowCycles.filter((cycle) => cycle.counted)
  const uncountableCycles = windowCycles.length - countedInWindow.length
  const countedVariation = spread(countedInWindow.map((cycle) => cycle.lengthDays))
  const oneUnreadableCycle = uncountableCycles === 1 && !overBand(countedVariation)
  const irregularity: Irregularity = !overBand(variationDays)
    ? 'none'
    : oneUnreadableCycle
      ? 'uncountable-cycle'
      : 'cycles-vary'

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
    irregularity,
    band,
    lastPeriodStart,
    currentPeriodEnd,
    minPeriodGapDays: settings.minPeriodGapDays,
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
  // One gate, two reasons (#190). The gate is on `!== 'none'` rather than on either name, so
  // a reason added to `Irregularity` later withholds by default; the mapping below then reads
  // it as `irregular-cycles`, which is the suppressing, care-pointing direction and the one to
  // be wrong in. Neither half of this is a compile error, which is why it is written down.
  if (irregularity !== 'none') {
    return {
      ...base,
      prediction: null,
      withheld: irregularity === 'uncountable-cycle' ? 'uncountable-cycle' : 'irregular-cycles',
    }
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
 * Whether today is inside the period run that opened the current cycle — the menstrual
 * boundary `phaseOn` draws (#197), and the one definition of it.
 *
 * Days with nothing logged since the run's last logged day, today included, are counted
 * exactly as `loggedPeriods` counts them between two logged days, which is why it reads `<`
 * against the same constant. Negative inside the run, where the answer was never in
 * question. A run that opens *after* today (an entry on tomorrow's date, which the readers'
 * one-day lookahead can see) is not today's period.
 */
const periodRunOpenOn = (analysis: CycleAnalysis, today: number): boolean => {
  if (analysis.lastPeriodStart === null || analysis.currentPeriodEnd === null) return false
  if (today < dayNumber(analysis.lastPeriodStart, 'lastPeriodStart')) return false
  return (
    today - dayNumber(analysis.currentPeriodEnd, 'currentPeriodEnd') < analysis.minPeriodGapDays
  )
}

/**
 * Whether her logged period is still running today (#100, D5's contextual "Log period").
 *
 * **Observed, never estimated, and therefore not behind the prediction gate.** `phaseOn`
 * withholds every phase — menstrual included — when there is no prediction, because a phase
 * is a statement to her about where she is in a cycle. This is not a phase and reaches no
 * card: it is what the Dashboard's first shortcut is labelled, and its only evidence is flow
 * she logged herself, carried at most `minPeriodGapDays - 1` dry days past the last one —
 * the bound #197 set. Gating it would leave a woman in her first three cycles, logging her
 * period every morning, with a shortcut that never offers to log it.
 *
 * The same boundary as the menstrual phase by construction (`periodRunOpenOn`), so the
 * shortcut and the card cannot disagree about when a period ended whenever both answer.
 * #75's period-end mark does not end it early, for the reason `loggedPeriods` gives: the mark
 * is never an end date.
 */
export const periodOngoing = (analysis: CycleAnalysis): boolean =>
  periodRunOpenOn(analysis, dayNumber(analysis.today, 'today'))

/**
 * Today's phase, or `null`.
 *
 * Four codes, and every boundary between them comes from A26's own constants or from what
 * she logged — none is invented here:
 *  - **menstrual** while today is inside the period run that opened this cycle, and while
 *    the days since it are still too few to have ended that run (#197).
 *  - **ovulation** across the fertile window (A26: ovulation − 5 through ovulation + 1).
 *  - **follicular** before that window, **luteal** after it.
 *
 * **The menstrual boundary is `minPeriodGapDays`, the same number that groups her days
 * (#186, #197).** It used to be the run's last logged day, which meant a woman bleeding on
 * cycle day 3 *who had not logged that day yet* was follicular — and `dashboard-rules.ts`'s
 * follicular-only rung 4 then told her, correctly by its own rule, that she was likely
 * approaching ovulation and might consider a harder training session. That is the sentence
 * #184 was filed to stop, reached one layer down, and it was the normal state of a morning:
 * `LogCycleStep.swift` logs one day at a time and nothing back-fills. If one dry day does
 * not end a period for counting, it does not end it for the phase either — so the run is
 * over once `minPeriodGapDays` days in a row carry nothing, today included, which is the
 * grouping predicate applied to the trailing edge rather than a second rule.
 *
 * **The bound on the opposite failure — telling a woman she is menstruating when her period
 * ended days ago — is exactly that constant**: never more than `minPeriodGapDays - 1` days
 * past the last day she logged, which is one day at the configured 2, and `cycleRulesProblem`
 * already refuses a gap at or above the shortest countable cycle, so the grace can never
 * span a cycle. Still observed rather than estimated: every day it counts is a day adjacent
 * to one she logged, and the moment she logs flow, that day is inside the run anyway.
 *
 * A withheld prediction means no phase at all. That is the gate doing its job: every phase
 * but the observed one is read off an estimated ovulation date, so a phase without a
 * prediction would be an estimate wearing no confidence band.
 */
const phaseOn = (analysis: CycleAnalysis, today: number): PhaseCode | null => {
  // `today` is `analysis.today` as a day number; the caller has already parsed it once.
  if (analysis.prediction === null || analysis.cycleDay === null) return null
  if (periodRunOpenOn(analysis, today)) return 'menstrual'
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
    // Carried across whole, not re-derived from `withheld`: the two disagree by design when
    // the ≥N gate closes first, and D1 asks that gate before this one (#190).
    irregularity: analysis.irregularity,
    cycleDay: analysis.cycleDay,
    phase:
      code === null || analysis.prediction === null
        ? null
        : { code, confidence: analysis.prediction.confidence },
    // A count, not a judgement: whether a prediction exists at all is the gate above.
    daysPastPredictedPeriod: predicted !== null && day > predicted ? day - predicted : null,
  }
}

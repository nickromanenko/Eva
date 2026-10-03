import type { Mode, PhaseConfidence, PhaseEstimate } from './dashboard-rules'
import type {
  ActivityBand,
  DailyTargets,
  NutritionGoal,
  NutritionPlan,
  TargetRefusal,
} from './nutrition'
import type { FocusAreaCode } from './nutrition-profile'
import type { ConditionCode } from './users'

/**
 * The cycle-phase and mode adjustment (S12, #224): the luteal +5% (A30) applied **on top of**
 * #222's engine and never inside it, and A28's inversion of the mode adjustments.
 *
 * `planDailyTargets` takes no phase and no mode — "cycle-agnostic" is a property of its type.
 * This module is the wrapper: it takes the engine's answer and the phase the cycle maths
 * already projected, and it never re-derives either. The tempting wrong fix — a `phase`
 * parameter on the engine — is exactly the drift this file exists to prevent, because the
 * day one lands, a second phase rule is one more line from arriving inside the maths.
 *
 * Pure, like the engine: no Firestore, no clock, no fetch. Every value it needs is passed in.
 */

/** The adjustment applied on top of the engine's targets, when one applies. */
export interface NutritionAdjustment {
  /** The calorie target the UI shows — `targets.calorieTargetKcal` plus the luteal 5% when the
   *  phase is luteal. The macros stay #222's: the PRD raises the calorie number, not the split. */
  calorieTargetKcal: number
  /** The one-line explanation as data: a reason id the copy store resolves, never a generated
   *  sentence. `null` when nothing adjusted. */
  reasonId: string | null
  /** The phase confidence that travelled with the adjustment (GUARDRAILS 35), so a number
   *  derived from a wide-band phase is never presented as a fact. `null` when nothing
   *  adjusted — A27's vocabulary, never a second one. */
  confidence: PhaseConfidence | null
}

/** The plan as the route serves it: the engine's answer, plus the adjustment — or, under A28
 *  (Pregnancy Mode, and six weeks after a delivery or a loss), no numbers at all. */
export type ServedNutritionPlan =
  | { kind: 'refused'; refusal: TargetRefusal }
  | { kind: 'qualitative' }
  | { kind: 'targets'; targets: DailyTargets; adjustment: NutritionAdjustment }

/** The luteal constant is unset, so the adjustment cannot be computed — a refusal, not a
 *  default. The route maps this to `503`, the same shape as `CycleRulesUnsetError` (#181). */
export class NutritionAdjustmentUnsetError extends Error {
  constructor() {
    super('the luteal adjustment is not configured')
    this.name = 'NutritionAdjustmentUnsetError'
  }
}

/** The reason id the copy store resolves to "your target is a little higher right now, to
 *  match where you are in your cycle" — framed as a need, never a reward (`tLuteal`: no
 *  "earned", "allowed" or "burn it off"). */
export const LUTEAL_REASON = 'luteal_adjustment' as const

/** A28's "first six weeks", in days: the window after the event that began the mode — the
 *  delivery for `postpartum`, the loss for `loss` (#367) — during which no number is served.
 *  One constant for both, so the two windows cannot drift apart. Day 0 is the day of the
 *  event; day 41 is the window's last day, and numbers return on day 42. */
export const QUALITATIVE_WINDOW_DAYS = 42

/**
 * Whether the mode withholds every number (A28). Pregnancy Mode always does. `postpartum`
 * and `loss` do for the window after the event that began them — and when that day is not
 * known (`null`), or is not a day at all, they do too: a number is withheld until the day
 * proves the window is over, never served because the day is missing. That is today's case
 * for every user, since nothing stores a delivery or loss date until D10 (#107).
 */
const withholdsNumbers = (mode: Mode, daysSinceModeEvent: number | null): boolean => {
  if (mode === 'pregnancy') return true
  if (mode !== 'postpartum' && mode !== 'loss') return false
  return !(daysSinceModeEvent !== null && daysSinceModeEvent >= QUALITATIVE_WINDOW_DAYS)
}

/**
 * Applies the cycle-phase and mode adjustment to the engine's plan.
 *
 * **No phase, no adjustment.** `phase` is `null` exactly when C11 withheld the prediction
 * (under three counted cycles, over the FIGO band, or no flow logged) — `toCycleEstimate`'s
 * contract. A null phase is not "no luteal"; it is "no number may be adjusted", so the target
 * is served unadjusted and the reason carries none.
 *
 * **A28.** While Pregnancy Mode is on, and for the first six weeks postpartum — and, by the
 * owner's decision on #367 (2026-10-03), for the first six weeks after a pregnancy loss — the
 * output carries no calorie and no macronutrient number at all, only S3's qualitative
 * projection. `daysSinceModeEvent` is whole local days since the delivery or the loss; it is
 * read only for those two modes, and `null` keeps the window closed (`withholdsNumbers`).
 * After the window numbers return, and her own `hideNumbers` still decides whether the
 * client shows them, exactly as in every other mode. Planning keeps numbers, and the luteal
 * adjustment is unaffected.
 */
export const adjustNutritionPlan = (
  plan: NutritionPlan,
  phase: PhaseEstimate | null,
  mode: Mode,
  daysSinceModeEvent: number | null,
  lutealPercent: number | null,
): ServedNutritionPlan => {
  if (lutealPercent === null) throw new NutritionAdjustmentUnsetError()
  if (plan.kind === 'refused') return plan
  if (withholdsNumbers(mode, daysSinceModeEvent)) return { kind: 'qualitative' }

  const targets = plan.targets
  if (phase?.code === 'luteal') {
    const adjusted = Math.round(targets.calorieTargetKcal * (1 + lutealPercent / 100))
    return {
      kind: 'targets',
      targets,
      adjustment: {
        calorieTargetKcal: adjusted,
        reasonId: LUTEAL_REASON,
        confidence: phase.confidence,
      },
    }
  }
  return {
    kind: 'targets',
    targets,
    adjustment: { calorieTargetKcal: targets.calorieTargetKcal, reasonId: null, confidence: null },
  }
}

// ── Recalculation triggers (PRD lines 815–825) ─────────────────────────────────────────

/**
 * The five causes PRD line 817 lists, as the reason ids a notification names — one each,
 * in the PRD's own order, which is also the precedence `recalculationReason` applies when
 * two move between the same pair of reads. Ids, never sentences: the copy store resolves
 * them (`tRecalc`: "One calm notification per change, stating the cause. Higher and lower
 * are framed neutrally"), so none of them says which way the number went.
 */
export const RECALCULATION_REASONS = [
  'weight_updated',
  'goal_changed',
  'cycle_phase_changed',
  'calendar_mode_changed',
  'activity_band_changed',
] as const

export type RecalculationReason = (typeof RECALCULATION_REASONS)[number]

/**
 * What a served plan was computed from — exactly the inputs a trigger names, and nothing
 * the engine reads that no trigger does (height, age and focus areas move no notification).
 *
 * `adjustingPhase` is whether the phase *moved the number*, not the phase itself: only the
 * luteal phase adjusts (A30), so follicular → ovulation recalculates nothing she would be
 * told about, and a notification for it would be the nagging `tRecalc` forbids. A withheld
 * phase (`null` from `toCycleEstimate`) is `false` — no phase, no adjustment.
 */
export interface PlanBasis {
  weightKg: number
  goal: NutritionGoal
  /** `null` for the goals that carry none (PRD line 745). */
  targetWeightKg: number | null
  adjustingPhase: boolean
  mode: Mode
  /** The band the engine's activity factor was read for. Today that is her questionnaire
   *  answer; PRD trigger 5's source — logged activity over four weeks shifting it by one —
   *  does not exist yet, and when it does it changes this field, not this rule. */
  activityBand: ActivityBand
}

/** `PlanBasis.adjustingPhase` from the phase the cycle maths projected. */
export const isAdjustingPhase = (phase: PhaseEstimate | null): boolean =>
  phase?.code === 'luteal'

/**
 * Why the target was recalculated between two reads — **exactly one** reason, or `null`.
 *
 * `null` when nothing a trigger names moved (a read with no cause produces no reason, and so
 * no notification), and `null` for the first plan she is ever served: that is a plan, not a
 * recalculation, and there is nothing it changed *from*. When several moved at once the
 * first in `RECALCULATION_REASONS` wins, because the notification is one sentence (PRD
 * line 825), not a list.
 */
export const recalculationReason = (
  previous: PlanBasis | null,
  current: PlanBasis,
): RecalculationReason | null => {
  if (previous === null) return null
  const moved: Record<RecalculationReason, boolean> = {
    weight_updated: previous.weightKg !== current.weightKg,
    goal_changed:
      previous.goal !== current.goal || previous.targetWeightKg !== current.targetWeightKg,
    cycle_phase_changed: previous.adjustingPhase !== current.adjustingPhase,
    calendar_mode_changed: previous.mode !== current.mode,
    activity_band_changed: previous.activityBand !== current.activityBand,
  }
  return RECALCULATION_REASONS.find((reason) => moved[reason]) ?? null
}

// ── Iron prioritisation during menstruation (PRD line 800) ─────────────────────────────

/** What the iron rule reads: whether she is menstruating, her focus areas, her declared
 *  conditions. Nothing inferred — PRD line 945: the adviser "may support a diagnosis the user
 *  already has" and never infers one, so the rule reads focus area 3 or an `anaemia` she
 *  declared at Sign Up, and no symptom. */
export interface IronContext {
  /** An *observed* period — C11's `periodOngoing`, from flow she logged — rather than the
   *  predicted `menstrual` phase, which the irregular-cycle gate withholds from a woman who
   *  is bleeding today. */
  menstruating: boolean
  focusAreas: readonly FocusAreaCode[]
  conditions: readonly ConditionCode[]
}

/** Whether iron-rich suggestions go first today (PRD line 800). */
export const prioritisesIron = (context: IronContext): boolean =>
  context.menstruating &&
  (context.focusAreas.includes('ironDeficiencyAnaemia') || context.conditions.includes('anaemia'))

/**
 * The suggestions in the order they are offered: iron-rich first when `prioritisesIron`,
 * each group in its original order; otherwise the order she was given.
 *
 * **Ordering and nothing else.** The result is a permutation of `suggestions` — the same
 * items, the same objects, none added, none removed, none rewritten — so this rule cannot
 * introduce a supplement, a dose or a statement that she is deficient (PRD lines 945–946):
 * it has no words to introduce them with. Generic over the suggestion, because what is
 * suggested is the catalogue's to define; the rule needs only whether an item is iron-rich.
 */
export const orderSuggestions = <T>(
  suggestions: readonly T[],
  isIronRich: (suggestion: T) => boolean,
  context: IronContext,
): T[] => {
  if (!prioritisesIron(context)) return [...suggestions]
  return [
    ...suggestions.filter((suggestion) => isIronRich(suggestion)),
    ...suggestions.filter((suggestion) => !isIronRich(suggestion)),
  ]
}

import type { Mode, PhaseConfidence, PhaseEstimate } from './dashboard-rules'
import type { DailyTargets, NutritionPlan, TargetRefusal } from './nutrition'

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

/** The plan as the route serves it: the engine's answer, plus the adjustment — or, under A28,
 *  no numbers at all. */
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

/**
 * Applies the cycle-phase and mode adjustment to the engine's plan.
 *
 * **No phase, no adjustment.** `phase` is `null` exactly when C11 withheld the prediction
 * (under three counted cycles, over the FIGO band, or no flow logged) — `toCycleEstimate`'s
 * contract. A null phase is not "no luteal"; it is "no number may be adjusted", so the target
 * is served unadjusted and the reason carries none.
 *
 * **A28.** While Pregnancy Mode is on, and for the first six weeks postpartum, the output
 * carries no calorie and no macronutrient number at all — only S3's qualitative projection.
 * The "first six weeks" boundary is D10's (nothing stores a delivery date yet), so any
 * `postpartum` mode is qualitative here; Planning keeps numbers, and the luteal adjustment is
 * unaffected.
 */
export const adjustNutritionPlan = (
  plan: NutritionPlan,
  phase: PhaseEstimate | null,
  mode: Mode,
  lutealPercent: number | null,
): ServedNutritionPlan => {
  if (lutealPercent === null) throw new NutritionAdjustmentUnsetError()
  if (plan.kind === 'refused') return plan
  if (mode === 'pregnancy' || mode === 'postpartum') return { kind: 'qualitative' }

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

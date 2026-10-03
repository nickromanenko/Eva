import { describe, expect, test } from 'bun:test'
import type { PhaseEstimate } from '../src/dashboard-rules'
import {
  planDailyTargets,
  type DailyTargets,
  type NutritionInput,
  type NutritionPlan,
  type NutritionRules,
} from '../src/nutrition'
import {
  LUTEAL_REASON,
  NutritionAdjustmentUnsetError,
  QUALITATIVE_WINDOW_DAYS,
  RECALCULATION_REASONS,
  adjustNutritionPlan,
  isAdjustingPhase,
  orderSuggestions,
  prioritisesIron,
  recalculationReason,
  type IronContext,
  type PlanBasis,
  type RecalculationReason,
  type ServedNutritionPlan,
} from '../src/nutrition-adjustment'

/**
 * The cycle-phase and mode adjustment (S12, #224): the luteal +5% applied on top of #222's
 * engine, A28's no-numbers-in-pregnancy/postpartum (and, #367, after a loss), the confidence that travels with the
 * number, the five recalculation triggers, and the iron ordering. Pure — the engine's answer
 * and the phase are fixtures, so this file makes no round trip and sets no timeout. The
 * route-level half (the irregular fixture through to the plan, the 503s, the log silence)
 * is in `nutrition-profile.test.ts`.
 */

const targets = (calorieTargetKcal: number): DailyTargets => ({
  bmrKcal: 1400,
  tdeeKcal: 1800,
  calorieFloorKcal: 1200,
  calorieTargetKcal,
  boundBy: null,
  macros: { proteinG: 90, fatG: 50, carbG: 200, fibreG: 25, proteinLimitedByEnergy: false },
  weightPlan: { targetWeightKg: 60, timelineWeeks: 20, paceKgPerWeek: -0.25 },
})

const plan = (calorieTargetKcal: number): NutritionPlan => ({
  kind: 'targets',
  targets: targets(calorieTargetKcal),
})

const phase = (code: PhaseEstimate['code'], confidence: PhaseEstimate['confidence']): PhaseEstimate => ({
  code,
  confidence,
})

/** The served plan, insisting it carries numbers — a case whose subject is the adjustment
 *  must fail on any other arm rather than return early and pass with no assertion run. */
const numbersOf = (served: ServedNutritionPlan) => {
  if (served.kind !== 'targets') throw new Error(`expected targets, got ${served.kind}`)
  return served
}

describe('adjustNutritionPlan', () => {
  test('the luteal phase raises the calorie target by the configured percentage', () => {
    const result = numbersOf(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'cycle', null, 5))
    expect(result.adjustment.calorieTargetKcal).toBe(2100)
    expect(result.adjustment.reasonId).toBe(LUTEAL_REASON)
    expect(result.targets.calorieTargetKcal).toBe(2000) // the engine's answer is untouched
  })

  test('the confidence class travels with the adjustment', () => {
    for (const confidence of ['wide', 'narrow'] as const) {
      const result = numbersOf(
        adjustNutritionPlan(plan(2000), phase('luteal', confidence), 'cycle', null, 5),
      )
      expect(result.adjustment.confidence).toBe(confidence)
    }
  })

  test('a phase other than luteal leaves the target unadjusted and the reason empty', () => {
    for (const code of ['menstrual', 'follicular', 'ovulation'] as const) {
      const result = numbersOf(adjustNutritionPlan(plan(2000), phase(code, 'narrow'), 'cycle', null, 5))
      expect(result.adjustment).toEqual({ calorieTargetKcal: 2000, reasonId: null, confidence: null })
    }
  })

  test('no phase is no adjustment — the target is served unadjusted', () => {
    // `toCycleEstimate`'s `phase` is null exactly when C11 withheld the prediction; a null
    // phase is not "no luteal", it is "no number may be adjusted".
    const result = numbersOf(adjustNutritionPlan(plan(2000), null, 'cycle', null, 5))
    expect(result.adjustment).toEqual({ calorieTargetKcal: 2000, reasonId: null, confidence: null })
  })

  test('A28: pregnancy carries no calorie or macronutrient number', () => {
    expect(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'pregnancy', null, 5)).toEqual({
      kind: 'qualitative',
    })
  })

  test('A28: postpartum with no delivery date carries none either — the window stays closed', () => {
    // Nothing stores a delivery date until D10, so this is every postpartum user today.
    expect(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'postpartum', null, 5)).toEqual({
      kind: 'qualitative',
    })
  })

  test('the window is six weeks, in days', () => {
    expect(QUALITATIVE_WINDOW_DAYS).toBe(42)
  })

  test('#367: the first six weeks after a loss carry no number — day 0 through day 41', () => {
    for (const day of [0, 1, 41]) {
      expect(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'loss', day, 5)).toEqual({
        kind: 'qualitative',
      })
    }
  })

  test('#367: from day 42 after a loss the numbers return, luteal adjustment included', () => {
    for (const day of [42, 43, 365]) {
      const result = numbersOf(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'loss', day, 5))
      expect(result.targets.calorieTargetKcal).toBe(2000)
      expect(result.adjustment).toEqual({
        calorieTargetKcal: 2100,
        reasonId: LUTEAL_REASON,
        confidence: 'wide',
      })
    }
  })

  test('#367: a loss with no date, or a day that is not one, withholds rather than serves', () => {
    // A missing or malformed day never opens the window: the number waits until a whole day
    // count proves it is over. A fractional day is malformed — the input is whole local days.
    for (const day of [null, Number.NaN, -1, Number.POSITIVE_INFINITY, 41.5, 42.5]) {
      expect(adjustNutritionPlan(plan(2000), null, 'loss', day, 5)).toEqual({ kind: 'qualitative' })
    }
  })

  test('postpartum and loss share one window — the same day, the same arm', () => {
    for (const day of [0, 41, 42, 100]) {
      const postpartum = adjustNutritionPlan(plan(2000), null, 'postpartum', day, 5)
      const loss = adjustNutritionPlan(plan(2000), null, 'loss', day, 5)
      expect(loss).toEqual(postpartum)
      expect(loss.kind).toBe(day < QUALITATIVE_WINDOW_DAYS ? 'qualitative' : 'targets')
    }
  })

  test('the day is read only for postpartum and loss — pregnancy never shows a number', () => {
    for (const day of [null, 0, 42, 400]) {
      expect(adjustNutritionPlan(plan(2000), null, 'pregnancy', day, 5)).toEqual({
        kind: 'qualitative',
      })
      // …and cycle and planning keep theirs whatever the day says.
      for (const mode of ['cycle', 'planning'] as const) {
        expect(adjustNutritionPlan(plan(2000), null, mode, day, 5).kind).toBe('targets')
      }
    }
  })

  test('the qualitative arm served for a loss has no field beyond its kind', () => {
    const served = adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'loss', 0, 5)
    expect(Object.keys(served)).toEqual(['kind'])
    expect(JSON.stringify(served)).not.toMatch(/\d/)
  })

  test('A28, by the type: the qualitative arm has no field a number could be in', () => {
    const qualitative: ServedNutritionPlan = { kind: 'qualitative' }
    // @ts-expect-error — a target on the qualitative arm is a compile error, not a screen's `if`
    const withNumber: ServedNutritionPlan = { kind: 'qualitative', targets: targets(2000) }
    expect(Object.keys(qualitative)).toEqual(['kind'])
    expect(withNumber.kind).toBe('qualitative')
  })

  test('Planning mode keeps numbers, and the luteal adjustment is unaffected by A28', () => {
    const result = numbersOf(
      adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'planning', null, 5),
    )
    expect(result.adjustment.calorieTargetKcal).toBe(2100)
    expect(result.adjustment.reasonId).toBe(LUTEAL_REASON)
  })

  test('a guard-refused plan in a no-numbers mode is qualitative — no weight figure leaks', () => {
    // The refusal carries `lowestSupportedWeightKg`; the qualitative mode shows no weight
    // target either (#223), so A28 wins over the guard's answer.
    for (const reason of ['below-bmi-floor', 'below-plan-cap'] as const) {
      const refused: NutritionPlan = {
        kind: 'refused',
        refusal: { reason, lowestSupportedWeightKg: 52.2 },
      }
      for (const [mode, day] of [
        ['pregnancy', null],
        ['postpartum', null],
        ['loss', 10],
      ] as const) {
        const served = adjustNutritionPlan(refused, phase('luteal', 'wide'), mode, day, 5)
        expect(served).toEqual({ kind: 'qualitative' })
        expect(JSON.stringify(served)).not.toMatch(/\d/)
      }
      // After the window the refusal is hers to see again, untouched.
      expect(adjustNutritionPlan(refused, null, 'loss', 42, 5)).toEqual(refused)
    }
  })

  test('a refused plan is served refused, untouched', () => {
    const refused: NutritionPlan = {
      kind: 'refused',
      refusal: { reason: 'below-bmi-floor', lowestSupportedWeightKg: 52.2 },
    }
    expect(adjustNutritionPlan(refused, phase('luteal', 'wide'), 'cycle', null, 5)).toEqual(refused)
  })

  test('an unset luteal percentage is a refusal, not a default', () => {
    expect(() => adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'cycle', null, null)).toThrow(
      NutritionAdjustmentUnsetError,
    )
  })

  test('unset is a refusal on every arm — a guard-refused plan included, never a 200', () => {
    // The check sits before the `refused` early return: an unconfigured deployment answers
    // 503 whatever the plan, rather than 200 for the plans that happen not to need the number.
    const refused: NutritionPlan = {
      kind: 'refused',
      refusal: { reason: 'below-plan-cap', lowestSupportedWeightKg: 55 },
    }
    for (const mode of ['cycle', 'pregnancy', 'loss'] as const) {
      expect(() => adjustNutritionPlan(refused, null, mode, null, null)).toThrow(
        NutritionAdjustmentUnsetError,
      )
    }
  })
})

/**
 * **The adjustment is outside #222's engine** — the issue's second criterion, against the
 * real engine rather than a fixture of its answer.
 */
describe('the engine stays cycle-agnostic', () => {
  /** A30's values, as `scripts/ci-api.sh` carries them (`nutrition.test.ts` pins that). */
  const RULES: NutritionRules = {
    basalRate: { perKg: 10, perCm: 6.25, perYear: 5, offset: 161 },
    activityFactors: { mostlySitting: 1.2, lightlyActive: 1.375, active: 1.55, veryActive: 1.725 },
    goalAdjustment: { lose: -0.15, gain: 0.15, buildMuscle: 0.1 },
    proteinGramsPerKg: { lose: 1.6, buildMuscle: 1.8, other: 1.2 },
    fatMinFraction: 0.2,
    fibreGrams: 25,
    fibreGramsRaised: 30,
    minBmi: 18.5,
    maxPlanLossFraction: 0.15,
    maxLossKgPerWeek: 0.5,
    maxLossFractionPerWeek: 0.01,
    minCalorieKcal: 1200,
    kcalPerKgBodyMass: 7700,
  }
  const HER: NutritionInput = {
    weightKg: 73,
    heightCm: 168,
    ageYears: 35,
    activityBand: 'active',
    focusAreas: [],
    goal: 'lose',
    targetWeightKg: 65,
  }

  test('the unadjusted target is the same for the same inputs, whatever the phase and mode', () => {
    const engine = planDailyTargets(HER, RULES)
    if (engine.kind !== 'targets') throw new Error('fixture should plan')
    for (const p of [null, phase('luteal', 'wide'), phase('follicular', 'narrow')]) {
      for (const mode of ['cycle', 'planning'] as const) {
        const served = numbersOf(adjustNutritionPlan(planDailyTargets(HER, RULES), p, mode, null, 5))
        expect(served.targets).toEqual(engine.targets)
      }
    }
  })

  test('its signature takes no phase and no mode', () => {
    // Two parameters — the input and the rules — and the input type refuses a phase.
    expect(planDailyTargets.length).toBe(2)
    // @ts-expect-error — `NutritionInput` has no `phase`; adding one is the wrong fix #224 names
    const withPhase: NutritionInput = { ...HER, phase: 'luteal' }
    // @ts-expect-error — nor a `mode`
    const withMode: NutritionInput = { ...HER, mode: 'pregnancy' }
    expect([withPhase, withMode]).toHaveLength(2)
  })
})

/**
 * PRD lines 815–825: five triggers, one test each, each yielding **exactly one** reason —
 * and a read with no cause yielding none. The return type is a single reason or `null`, so
 * "exactly one" is the type; each case asserts *which* one.
 */
describe('recalculationReason', () => {
  const BASIS: PlanBasis = {
    weightKg: 64,
    goal: 'lose',
    targetWeightKg: 60,
    adjustingPhase: false,
    mode: 'cycle',
    activityBand: 'mostlySitting',
  }
  const after = (over: Partial<PlanBasis>) => recalculationReason(BASIS, { ...BASIS, ...over })

  test('1. weight updated', () => {
    expect(after({ weightKg: 63.4 })).toBe('weight_updated')
  })

  test('2. goal or target weight changed', () => {
    expect(after({ goal: 'maintain', targetWeightKg: null })).toBe('goal_changed')
    expect(after({ targetWeightKg: 58 })).toBe('goal_changed')
  })

  test('3. cycle phase changed — into the luteal phase, and out of it', () => {
    expect(after({ adjustingPhase: true })).toBe('cycle_phase_changed')
    expect(
      recalculationReason({ ...BASIS, adjustingPhase: true }, { ...BASIS, adjustingPhase: false }),
    ).toBe('cycle_phase_changed')
  })

  test('4. calendar mode changed', () => {
    expect(after({ mode: 'planning' })).toBe('calendar_mode_changed')
  })

  test('5. the activity band shifted', () => {
    expect(after({ activityBand: 'lightlyActive' })).toBe('activity_band_changed')
  })

  test('a read with no cause produces no reason', () => {
    expect(recalculationReason(BASIS, { ...BASIS })).toBeNull()
  })

  test('the first plan she is served is not a recalculation', () => {
    expect(recalculationReason(null, BASIS)).toBeNull()
  })

  test('a phase change that moves no number is not a cause', () => {
    // follicular → ovulation adjusts nothing (only luteal does), so it is not news to her —
    // through `recalculationReason`, from bases built off the real phases.
    const on = (p: PhaseEstimate | null): PlanBasis => ({ ...BASIS, adjustingPhase: isAdjustingPhase(p) })
    expect(recalculationReason(on(phase('follicular', 'narrow')), on(phase('ovulation', 'narrow')))).toBeNull()
    expect(recalculationReason(on(phase('menstrual', 'narrow')), on(phase('follicular', 'narrow')))).toBeNull()
    expect(recalculationReason(on(null), on(phase('follicular', 'wide')))).toBeNull()
    // …and one that does move it is.
    expect(recalculationReason(on(phase('ovulation', 'narrow')), on(phase('luteal', 'narrow')))).toBe(
      'cycle_phase_changed',
    )
    expect(recalculationReason(on(phase('luteal', 'wide')), on(null))).toBe('cycle_phase_changed')
  })

  test('several causes at once still yield one reason, in the PRD order', () => {
    expect(after({ activityBand: 'active', weightKg: 63, mode: 'planning' })).toBe(
      'weight_updated',
    )
    expect(after({ activityBand: 'active', adjustingPhase: true })).toBe('cycle_phase_changed')
    // Each adjacent pair, so swapping any two in the order fails here.
    expect(after({ weightKg: 63, targetWeightKg: 58 })).toBe('weight_updated')
    expect(after({ targetWeightKg: 58, adjustingPhase: true })).toBe('goal_changed')
    expect(after({ adjustingPhase: true, mode: 'planning' })).toBe('cycle_phase_changed')
    expect(after({ mode: 'planning', activityBand: 'active' })).toBe('calendar_mode_changed')
  })

  test('there are exactly five reasons, one per PRD trigger', () => {
    expect(RECALCULATION_REASONS).toHaveLength(5)
    expect(new Set<RecalculationReason>(RECALCULATION_REASONS).size).toBe(5)
  })
})

/**
 * PRD line 800, bounded by lines 945–946: iron-rich suggestions go first during
 * menstruation when focus area 3 is chosen or anaemia was declared — and the rule changes
 * the **order** of what she is offered and nothing else.
 */
describe('iron prioritisation', () => {
  interface Suggestion {
    id: string
    ironRich: boolean
  }
  const SUGGESTIONS: readonly Suggestion[] = [
    { id: 'oats', ironRich: false },
    { id: 'lentils', ironRich: true },
    { id: 'yoghurt', ironRich: false },
    { id: 'spinach', ironRich: true },
  ]
  const isIronRich = (s: Suggestion) => s.ironRich
  const NONE: IronContext = { menstruating: false, focusAreas: [], conditions: [] }

  test('during menstruation with focus area 3, iron-rich first, each group in its order', () => {
    const ordered = orderSuggestions(SUGGESTIONS, isIronRich, {
      ...NONE,
      menstruating: true,
      focusAreas: ['ironDeficiencyAnaemia'],
    })
    expect(ordered.map((s) => s.id)).toEqual(['lentils', 'spinach', 'oats', 'yoghurt'])
  })

  test('during menstruation with anaemia declared at Sign Up, likewise', () => {
    const context: IronContext = { ...NONE, menstruating: true, conditions: ['anaemia'] }
    expect(prioritisesIron(context)).toBe(true)
    expect(orderSuggestions(SUGGESTIONS, isIronRich, context)[0]!.id).toBe('lentils')
  })

  test('otherwise the order is the one she was given', () => {
    for (const context of [
      NONE,
      { ...NONE, menstruating: true }, // menstruating, but neither trigger
      { ...NONE, focusAreas: ['ironDeficiencyAnaemia'] as const }, // trigger, not menstruating
      { ...NONE, conditions: ['anaemia'] as const },
    ]) {
      expect(prioritisesIron(context)).toBe(false)
      expect(orderSuggestions(SUGGESTIONS, isIronRich, context)).toEqual([...SUGGESTIONS])
    }
  })

  test('ordering and nothing else: the same items, the same objects, none added or rewritten', () => {
    const context: IronContext = { ...NONE, menstruating: true, conditions: ['anaemia'] }
    const ordered = orderSuggestions(SUGGESTIONS, isIronRich, context)
    expect(ordered).toHaveLength(SUGGESTIONS.length)
    for (const item of ordered) expect(SUGGESTIONS).toContain(item) // by reference
    expect(new Set(ordered).size).toBe(SUGGESTIONS.length)
    // The input is not reordered in place either.
    expect(SUGGESTIONS.map((s) => s.id)).toEqual(['oats', 'lentils', 'yoghurt', 'spinach'])
  })
})

/** The module's code with comments removed — prose that *names* a forbidden word (to forbid
 *  it) is not code that says it. */
const moduleCode = async () =>
  (await Bun.file(`${import.meta.dir}/../src/nutrition-adjustment.ts`).text())
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/gm, '')

describe('what the adjustment says, and what it never does', () => {
  /** Canvas `tLuteal`: "no 'earned', 'allowed' or 'burn it off'". */
  const REWARD = /\bearn(ed|s)?\b|\ballow(ed|s)?\b|\bburn(ed|s)?\b|\bdeserve|\breward|\btreat\b/i

  test('every reason id is framed as a need, never a reward', () => {
    for (const id of [LUTEAL_REASON, ...RECALCULATION_REASONS]) {
      expect({ id, reward: REWARD.test(id.replaceAll('_', ' ')) }).toEqual({ id, reward: false })
    }
  })

  test('the module writes no user-facing sentence, and no reward word anywhere in its code', async () => {
    const code = await moduleCode()
    expect(REWARD.test(code)).toBe(false)
    // Every string literal in it is an id or a code: lower-case, no spaces, no sentence.
    // The refusal's own `Error` message is the one exception: it never reaches a body (the
    // route answers its constant 503 message) and is developer-facing.
    const served = code.replace(/super\('[^']*'\)/g, '')
    const literals = [...served.matchAll(/'([^'\n]*)'/g)].map((m) => m[1]!)
    for (const literal of literals) {
      if (literal.startsWith('./')) continue // an import path
      expect({ literal, sentence: /\s/.test(literal) }).toEqual({ literal, sentence: false })
    }
  })

  test('no supplement, dose or deficiency statement can come from it (PRD 945–946)', async () => {
    // Focus area 3's permanent code names the condition she chose; it is read, never said.
    const code = (await moduleCode()).replaceAll("'ironDeficiencyAnaemia'", '')
    expect(/supplement|\bdose|\bmg\b|deficien/i.test(code)).toBe(false)
  })

  test('it logs nothing — no phase, no target, no mode (GUARDRAILS 12)', async () => {
    expect(/\bconsole\./.test(await moduleCode())).toBe(false)
  })
})

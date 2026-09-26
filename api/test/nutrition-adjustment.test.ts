import { describe, expect, test } from 'bun:test'
import type { PhaseEstimate } from '../src/dashboard-rules'
import type { DailyTargets, NutritionPlan } from '../src/nutrition'
import {
  LUTEAL_REASON,
  NutritionAdjustmentUnsetError,
  adjustNutritionPlan,
} from '../src/nutrition-adjustment'

/**
 * The cycle-phase and mode adjustment (S12, #224): the luteal +5% applied on top of #222's
 * engine, A28's no-numbers-in-pregnancy/postpartum, and the confidence that travels with the
 * number. Pure — the engine's answer and the phase are fixtures.
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

describe('adjustNutritionPlan', () => {
  test('the luteal phase raises the calorie target by the configured percentage', () => {
    const result = adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'cycle', 5)

    expect(result.kind).toBe('targets')
    if (result.kind !== 'targets') return
    expect(result.adjustment.calorieTargetKcal).toBe(2100)
    expect(result.adjustment.reasonId).toBe(LUTEAL_REASON)
    expect(result.targets.calorieTargetKcal).toBe(2000) // the engine's answer is untouched
  })

  test('the confidence class travels with the adjustment', () => {
    const result = adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'cycle', 5)
    if (result.kind !== 'targets') return
    expect(result.adjustment.confidence).toBe('wide')
  })

  test('a phase other than luteal leaves the target unadjusted and the reason empty', () => {
    const result = adjustNutritionPlan(plan(2000), phase('follicular', 'narrow'), 'cycle', 5)
    if (result.kind !== 'targets') return
    expect(result.adjustment.calorieTargetKcal).toBe(2000)
    expect(result.adjustment.reasonId).toBeNull()
    expect(result.adjustment.confidence).toBeNull()
  })

  test('no phase is no adjustment — the target is served unadjusted', () => {
    // `toCycleEstimate`'s `phase` is null exactly when C11 withheld the prediction; a null
    // phase is not "no luteal", it is "no number may be adjusted".
    const result = adjustNutritionPlan(plan(2000), null, 'cycle', 5)
    if (result.kind !== 'targets') return
    expect(result.adjustment.calorieTargetKcal).toBe(2000)
    expect(result.adjustment.reasonId).toBeNull()
  })

  test('A28: pregnancy carries no calorie or macronutrient number', () => {
    expect(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'pregnancy', 5)).toEqual({
      kind: 'qualitative',
    })
  })

  test('A28: the first six postpartum weeks carry none either', () => {
    expect(adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'postpartum', 5)).toEqual({
      kind: 'qualitative',
    })
  })

  test('Planning mode keeps numbers, and the luteal adjustment is unaffected by A28', () => {
    const result = adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'planning', 5)
    if (result.kind !== 'targets') return
    expect(result.adjustment.calorieTargetKcal).toBe(2100)
    expect(result.adjustment.reasonId).toBe(LUTEAL_REASON)
  })

  test('a refused plan is served refused, untouched', () => {
    const refused: NutritionPlan = {
      kind: 'refused',
      refusal: { reason: 'below-bmi-floor', lowestSupportedWeightKg: 52.2 },
    }
    expect(adjustNutritionPlan(refused, phase('luteal', 'wide'), 'cycle', 5)).toEqual(refused)
  })

  test('an unset luteal percentage is a refusal, not a default', () => {
    expect(() => adjustNutritionPlan(plan(2000), phase('luteal', 'wide'), 'cycle', null)).toThrow(
      NutritionAdjustmentUnsetError,
    )
  })
})

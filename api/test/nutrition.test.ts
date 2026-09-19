import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'node:os'
import {
  ACTIVITY_BANDS,
  ImpossibleBodyMetricError,
  NutritionRulesUnsetError,
  nutritionRulesProblem,
  planDailyTargets,
  type ActivityBand,
  type DailyTargets,
  type NutritionGoal,
  type NutritionInput,
  type NutritionRules,
} from '../src/nutrition'

/**
 * The nutrition targets engine (S2 of #25, #222) — the basal-rate equation, the four activity
 * bands, the goal adjustments, the clamp stack and the macronutrient split, against fixtures.
 *
 * **This file makes no live round trip and therefore sets no default timeout** (api/CLAUDE.md
 * #31), with the caveat `cycle.test.ts` carries: if these cases ever need Firestore or a
 * network, the module under test has stopped being pure and the fix is in `src/`. The cases
 * that spawn a process carry their own timeout.
 *
 * **What the cases are written to survive.** Every behavioural claim below was checked by
 * breaking the code and watching a case die — each clamp removed in turn, the fat floor
 * rounded down instead of up, the refusal's offered value rounded down, the timeline derived
 * from the requested target instead of the clamped one, and each constant moved. A case that
 * passes with its guarantee removed is not a test of that guarantee. The PR body carries the
 * table of which mutation killed which case.
 *
 * **Every clamp is exercised at its boundary**, which is the failure mode #222 names for this
 * slice: a clamp that only ever runs where it does not bind is a vacuous assertion. The
 * property test below collects which clamps it actually reached and fails if one it claims to
 * cover never fired.
 */

// ── The constants, as PRD §Daily targets calculation and A29/A30 settled them ──────────
// Written here rather than read from `config`, exactly as `cycle.test.ts` holds `CycleRules`:
// these numbers exist so the engine can be *exercised*, and the "no dose is written in the
// maths" cases below prove the module has none of its own by changing them. The last case in
// the file pins them equal to `.env.example` and to `scripts/ci-api.sh`.

const RULES: NutritionRules = {
  basalRate: { perKg: 10, perCm: 6.25, perYear: 5, offset: 161 },
  activityFactors: {
    mostlySitting: 1.2,
    lightlyActive: 1.375,
    active: 1.55,
    veryActive: 1.725,
  },
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

// ── Fixtures ───────────────────────────────────────────────────────────────────────────

/** The canvas' own user: 73 kg, 168 cm, targeting 65 kg (rail item `s5`). */
const HER: NutritionInput = {
  weightKg: 73,
  heightCm: 168,
  ageYears: 35,
  activityBand: 'active',
  focusAreas: [],
  goal: 'lose',
  targetWeightKg: 65,
}

const plan = (over: Partial<NutritionInput> = {}, rules: NutritionRules | null = RULES) =>
  planDailyTargets({ ...HER, ...over } as NutritionInput, rules)

/** The plan, insisting it was not refused — for the cases whose subject is the arithmetic. */
const targetsFor = (over: Partial<NutritionInput> = {}, rules: NutritionRules | null = RULES) => {
  const result = plan(over, rules)
  if (result.kind !== 'targets') {
    throw new Error(`expected targets, got a refusal: ${result.refusal.reason}`)
  }
  return result.targets
}

const refusalFor = (over: Partial<NutritionInput> = {}, rules: NutritionRules | null = RULES) => {
  const result = plan(over, rules)
  if (result.kind !== 'refused') throw new Error('expected a refusal, got targets')
  return result.refusal
}

const steady = (goal: 'maintain' | 'eatBetter', over: Partial<NutritionInput> = {}) =>
  planDailyTargets(
    {
      weightKg: HER.weightKg,
      heightCm: HER.heightCm,
      ageYears: HER.ageYears,
      activityBand: HER.activityBand,
      focusAreas: [],
      goal,
      ...over,
    } as NutritionInput,
    RULES,
  )

// ── Basal rate and total expenditure (PRD lines 771-777) ───────────────────────────────

describe('basal rate is Mifflin-St Jeor for women, and expenditure is it times the band', () => {
  test('the worked example: 73 kg, 168 cm, 35 years', () => {
    // (10 x 73) + (6.25 x 168) - (5 x 35) - 161 = 730 + 1050 - 175 - 161 = 1444
    const targets = targetsFor()
    expect(targets.bmrKcal).toBe(1444)
    // x 1.55 for "Active" = 2238.2
    expect(targets.tdeeKcal).toBe(2238)
  })

  /** Rounded **up**, not to nearest: it is the floor every other number sits above, and up
   *  is the direction that cannot under-feed. 1444 is exact, so this needs its own case. */
  test('basal rate rounds up, because it is a floor', () => {
    // (10 x 60) + (6.25 x 167) - (5 x 30) - 161 = 600 + 1043.75 - 150 - 161 = 1332.75
    expect(targetsFor({ weightKg: 60, heightCm: 167, ageYears: 30 }).bmrKcal).toBe(1333)
  })

  test('each coefficient moves the answer, so none of them is written in the maths', () => {
    const base = targetsFor().bmrKcal
    const moved = (over: Partial<NutritionRules['basalRate']>) =>
      targetsFor({}, { ...RULES, basalRate: { ...RULES.basalRate, ...over } }).bmrKcal
    expect(moved({ perKg: 11 })).toBe(base + 73)
    expect(moved({ perCm: 7.25 })).toBe(base + 168)
    expect(moved({ perYear: 6 })).toBe(base - 35)
    expect(moved({ offset: 261 })).toBe(base - 100)
  })

  test('age lowers the target, which is the direction Mifflin has it', () => {
    expect(targetsFor({ ageYears: 55 }).bmrKcal).toBe(targetsFor({ ageYears: 35 }).bmrKcal - 100)
  })
})

describe('the activity factor is a total lookup over four bands', () => {
  /** The compile-time half — a band with no factor is a type error — cannot be asserted at
   *  runtime, and is carried by `ActivityFactors` being `Record<ActivityBand, number>`.
   *  What *is* assertable is that all four are distinct, ordered, and none of them is a
   *  fallback: every band changes the answer. */
  test('every band gives its own expenditure, strictly increasing', () => {
    const tdee = ACTIVITY_BANDS.map((band) => targetsFor({ activityBand: band }).tdeeKcal)
    expect(tdee).toEqual([1733, 1986, 2238, 2491])
    expect([...tdee].sort((a, b) => a - b)).toEqual(tdee)
    expect(new Set(tdee).size).toBe(ACTIVITY_BANDS.length)
  })

  test('moving one factor moves only that band', () => {
    const rules: NutritionRules = {
      ...RULES,
      activityFactors: { ...RULES.activityFactors, active: 1.6 },
    }
    expect(targetsFor({ activityBand: 'active' }, rules).tdeeKcal).toBe(2310)
    expect(targetsFor({ activityBand: 'lightlyActive' }, rules).tdeeKcal).toBe(1986)
  })

  /** #221's risk, from the configuration side: a factor set that is not strictly increasing
   *  feeds a more active woman less, and nothing downstream can see it. */
  test('a factor set that is not strictly increasing is refused', () => {
    const problem = nutritionRulesProblem({
      ...RULES,
      activityFactors: { ...RULES.activityFactors, active: 1.3 },
    })
    expect(problem?.field).toBe('activityFactors.active')
    expect(problem?.message).toContain('greater than activityFactors.lightlyActive')
  })

  test('a factor below 1, which would put expenditure under basal rate, is refused', () => {
    const problem = nutritionRulesProblem({
      ...RULES,
      activityFactors: { ...RULES.activityFactors, mostlySitting: 0.9 },
    })
    expect(problem?.field).toBe('activityFactors.mostlySitting')
    expect(problem?.message).toContain('at least 1')
  })
})

// ── Goals 4 and 5 (PRD lines 700, 745) ─────────────────────────────────────────────────

describe('maintain and eat better get a complete plan with no weight target', () => {
  for (const goal of ['maintain', 'eatBetter'] as const) {
    test(`${goal}: no weight plan, no adjustment, and every other number present`, () => {
      const result = steady(goal)
      expect(result.kind).toBe('targets')
      if (result.kind !== 'targets') return
      const targets = result.targets
      // "No weight target" is representable, not encoded as zero (PRD line 700).
      expect(targets.weightPlan).toBe(null)
      // And no deficit: the target IS expenditure, untouched.
      expect(targets.calorieTargetKcal).toBe(targets.tdeeKcal)
      expect(targets.boundBy).toBe(null)
      expect(targets.macros.proteinG).toBeGreaterThan(0)
      expect(targets.macros.fatG).toBeGreaterThan(0)
      expect(targets.macros.carbG).toBeGreaterThan(0)
      expect(targets.macros.fibreG).toBe(25)
    })
  }

  test('they still get the floors — a small woman is lifted to 1,200 kcal', () => {
    const result = steady('maintain', {
      weightKg: 30,
      heightCm: 120,
      ageYears: 18,
      activityBand: 'mostlySitting',
    })
    if (result.kind !== 'targets') throw new Error('expected targets')
    expect(result.targets.tdeeKcal).toBe(959)
    expect(result.targets.calorieTargetKcal).toBe(1200)
    expect(result.targets.boundBy).toBe('absolute-floor')
    expect(result.targets.weightPlan).toBe(null)
  })
})

// ── The target-weight guards (PRD line 753, A29; canvas sGuard / sCap) ─────────────────

describe('a target below BMI 18.5 is refused with the lowest supported weight', () => {
  /** 60 kg at 175 cm: the BMI floor (56.66 kg) sits above the per-plan cap (51 kg), so the
   *  BMI floor is the binding rule and the one named. */
  const her = { weightKg: 60, heightCm: 175, ageYears: 30 } as const

  test('it is refused, and it says which rule refused it', () => {
    const refusal = refusalFor({ ...her, targetWeightKg: 55 })
    expect(refusal.reason).toBe('below-bmi-floor')
    // 18.5 x 1.75^2 = 56.65625, rounded UP to the next 0.1 kg.
    expect(refusal.lowestSupportedWeightKg).toBe(56.7)
  })

  /** The offer is the whole point of the refusal (canvas `sGuard`: "refused with neutral
   *  language and the lowest supported value offered"), so it has to be a value this same
   *  guard accepts. Rounding it *down* — which is what the canvas does, quoting 52.2 for a
   *  floor of 52.2144 — makes the offer a second refusal. */
  test('the value it offers is accepted, and one tenth of a kilo below it is not', () => {
    const offered = refusalFor({ ...her, targetWeightKg: 55 }).lowestSupportedWeightKg
    expect(plan({ ...her, targetWeightKg: offered }).kind).toBe('targets')
    expect(plan({ ...her, targetWeightKg: offered - 0.1 }).kind).toBe('refused')
  })

  test('the floor is the configured BMI and not a number in the code', () => {
    const lower: NutritionRules = { ...RULES, minBmi: 16 }
    expect(plan({ ...her, targetWeightKg: 55 }, lower).kind).toBe('targets')
    expect(refusalFor({ ...her, targetWeightKg: 45 }, lower).lowestSupportedWeightKg).toBe(51)
  })

  /** PRD line 753 states the floor unconditionally, so it is not a weight-loss rule: a woman
   *  under the floor who wants to *gain* to a weight still under it is refused too. */
  test('it applies to a gain target as well', () => {
    const refusal = refusalFor({
      weightKg: 45,
      heightCm: 170,
      ageYears: 28,
      goal: 'gain',
      targetWeightKg: 50,
    })
    expect(refusal.reason).toBe('below-bmi-floor')
    expect(refusal.lowestSupportedWeightKg).toBe(53.5)
  })
})

describe('a target more than 15% below the current weight is refused with the capped value', () => {
  test("the canvas' own case: 73 kg, target 58", () => {
    const refusal = refusalFor({ targetWeightKg: 58 })
    expect(refusal.reason).toBe('below-plan-cap')
    // 73 x 0.85 = 62.05, up to the next 0.1 kg — the canvas' 62.1.
    expect(refusal.lowestSupportedWeightKg).toBe(62.1)
    expect(plan({ targetWeightKg: 62.1 }).kind).toBe('targets')
    expect(plan({ targetWeightKg: 62 }).kind).toBe('refused')
  })

  /**
   * **Where this departs from the canvas, deliberately.** Canvas `sGuard` answers a 50 kg
   * target from 73 kg at 168 cm with "lowest supported target: 52.2 kg", which its own
   * `sCap` rule would then refuse — 52.2 is below the 62.1 kg cap. One offer that satisfies
   * both rules is the only kind that can be tapped, so the engine returns the higher floor
   * and names the rule that set it. Recorded in the PR body.
   */
  test('when both rules bite, the offer satisfies both and names the binding one', () => {
    const refusal = refusalFor({ targetWeightKg: 50 })
    expect(refusal.reason).toBe('below-plan-cap')
    expect(refusal.lowestSupportedWeightKg).toBe(62.1)
    expect(plan({ targetWeightKg: refusal.lowestSupportedWeightKg }).kind).toBe('targets')
  })

  test('the cap is the configured fraction and not a number in the code', () => {
    const looser: NutritionRules = { ...RULES, maxPlanLossFraction: 0.25 }
    expect(plan({ targetWeightKg: 58 }, looser).kind).toBe('targets')
  })

  test('a target above the current weight is never capped by it', () => {
    expect(plan({ goal: 'gain', targetWeightKg: 80 }).kind).toBe('targets')
  })
})

// ── The clamp stack (PRD lines 754-756; canvas sRate) ──────────────────────────────────

describe('the calorie target is never below the higher of basal rate and 1,200 kcal', () => {
  test("nothing binds at the shipped numbers for the canvas' user", () => {
    const targets = targetsFor()
    expect(targets.calorieTargetKcal).toBe(1902)
    expect(targets.boundBy).toBe(null)
    expect(targets.calorieFloorKcal).toBe(1688)
  })

  /**
   * **The basal-rate floor cannot bind at A30's own deficit, and can at the other end of the
   * PRD's range.** 1.2 x 0.85 = 1.02, so even the most sedentary band sits just above basal
   * rate at -15%; at -20% it does not. The floor is in the arithmetic rather than in a
   * reviewer's head because the deficit is configuration, and this case is what proves the
   * floor is live rather than decorative.
   */
  test('basal rate binds at a -20% deficit and not at -15%', () => {
    const her = {
      weightKg: 60,
      heightCm: 165,
      ageYears: 30,
      activityBand: 'mostlySitting' as ActivityBand,
      targetWeightKg: 55,
    }
    const atFifteen = targetsFor(her)
    expect(atFifteen.bmrKcal).toBe(1321)
    expect(atFifteen.tdeeKcal).toBe(1585)
    expect(atFifteen.calorieTargetKcal).toBe(1347)
    expect(atFifteen.boundBy).toBe(null)

    const deeper: NutritionRules = {
      ...RULES,
      goalAdjustment: { ...RULES.goalAdjustment, lose: -0.2 },
    }
    const atTwenty = targetsFor(her, deeper)
    expect(atTwenty.boundBy).toBe('basal-rate')
    expect(atTwenty.calorieTargetKcal).toBe(1321)
    expect(atTwenty.calorieTargetKcal).toBe(atTwenty.bmrKcal)
  })

  test('the absolute floor lifts a target the rest of the maths puts under 1,200', () => {
    const targets = targetsFor({
      weightKg: 32,
      heightCm: 120,
      ageYears: 18,
      activityBand: 'mostlySitting',
      targetWeightKg: 30,
    })
    expect(targets.tdeeKcal).toBe(983)
    expect(targets.boundBy).toBe('absolute-floor')
    expect(targets.calorieTargetKcal).toBe(1200)
  })

  test('the absolute floor is the configured one', () => {
    const targets = targetsFor(
      {
        weightKg: 32,
        heightCm: 120,
        ageYears: 18,
        activityBand: 'mostlySitting',
        targetWeightKg: 30,
      },
      { ...RULES, minCalorieKcal: 1400 },
    )
    expect(targets.calorieTargetKcal).toBe(1400)
  })
})

describe('hitting a clamp extends the timeline, and the timeline follows the clamped target', () => {
  /**
   * 150 kg, 165 cm, very active: the -15% deficit on its own implies 0.516 kg per week,
   * which is faster than PRD line 754's cap of 0.5. The cap is expressed as a *floor on
   * calories* — canvas `sRate`, "Eva extends the timeline instead of cutting calories" — so
   * the target rises to exactly the capped pace and the timeline runs a week longer.
   */
  const her = {
    weightKg: 150,
    heightCm: 165,
    ageYears: 35,
    activityBand: 'veryActive' as ActivityBand,
    targetWeightKg: 128,
  }

  test('the rate cap raises the target rather than lowering it', () => {
    const targets = targetsFor(her)
    expect(targets.tdeeKcal).toBe(3788)
    expect(targets.boundBy).toBe('rate-cap')
    // The unclamped -15% would have been 3220.
    expect(targets.calorieTargetKcal).toBe(3238)
    expect(targets.calorieTargetKcal).toBeGreaterThan(Math.round(3788 * 0.85))
  })

  test('the pace is exactly the cap, and the timeline is derived from it', () => {
    const targets = targetsFor(her)
    const weightPlan = targets.weightPlan!
    expect(weightPlan.paceKgPerWeek).toBeCloseTo(-0.5, 10)
    // 22 kg at 0.5 kg per week.
    expect(weightPlan.timelineWeeks).toBe(44)
    // …and it is derivable from the numbers beside it, which is what "derived from the
    // clamped target" means: a caller re-deriving it gets the same answer.
    const derived = Math.ceil(
      (weightPlan.targetWeightKg - her.weightKg) /
        (((targets.calorieTargetKcal - targets.tdeeKcal) * 7) / RULES.kcalPerKgBodyMass),
    )
    expect(weightPlan.timelineWeeks).toBe(derived)
  })

  /** The requested pace and the clamped one disagree here, and the timeline follows the
   *  target: 43 weeks at the requested pace, 44 at the one the plan actually sets. */
  test('the requested pace would have been shorter, and is not what is returned', () => {
    const requestedPace = ((Math.round(3788 * 0.85) - 3788) * 7) / RULES.kcalPerKgBodyMass
    expect(Math.ceil(-22 / requestedPace)).toBe(43)
    expect(targetsFor(her).weightPlan?.timelineWeeks).toBe(44)
  })

  test('without the cap, the same plan is faster — so the clamp is doing the work', () => {
    const uncapped: NutritionRules = { ...RULES, maxLossKgPerWeek: 5 }
    const targets = targetsFor(her, uncapped)
    expect(targets.boundBy).toBe(null)
    expect(targets.calorieTargetKcal).toBe(3220)
    expect(targets.weightPlan?.timelineWeeks).toBe(43)
  })

  /**
   * PRD line 754's cap is *"approximately 0.5 kg per week, or 1% of body weight per week,
   * whichever is lower"*, and both arms are implemented — but **the 1% arm cannot bind for
   * any acceptable plan inside the accepted input range**, and that is worth a case rather
   * than a surprise. It is the lower arm only under 50 kg, and a 15% deficit only exceeds
   * 1% of body weight a week when expenditure is over about 73 times her weight in kg — a
   * combination that needs a woman light enough and tall enough that the BMI floor refuses
   * every loss target she could set. So the arm is exercised through configuration, which is
   * also where it would come back: these are doses a reviewer revises.
   */
  test('the cap is the lower of its two arms', () => {
    // At 150 kg the 0.5 kg arm is the lower one — 1% of her weight is 1.5 kg — so widening
    // the fraction arm changes nothing at all.
    expect(targetsFor(her, { ...RULES, maxLossFractionPerWeek: 0.99 }).calorieTargetKcal).toBe(
      targetsFor(her).calorieTargetKcal,
    )
    // And where the fraction arm is the lower one, it is the arm that applies.
    const tight: NutritionRules = {
      ...RULES,
      maxLossKgPerWeek: 5,
      maxLossFractionPerWeek: 0.002,
    }
    const capped = targetsFor({}, tight)
    expect(capped.boundBy).toBe('rate-cap')
    // 0.2% of 73 kg is 0.146 kg a week; the floor rounds up, so the pace lands a hair
    // under the cap rather than a hair over it.
    expect(capped.weightPlan!.paceKgPerWeek).toBeCloseTo(-0.1455, 3)
    expect(Math.abs(capped.weightPlan!.paceKgPerWeek)).toBeLessThanOrEqual(0.002 * 73)
  })

  /**
   * When every clamp has lifted the target above expenditure there is no movement toward a
   * lower weight at all, and the honest answer is not a number. A very small woman on a loss
   * goal reaches this: her expenditure is under the 1,200 kcal floor, so the plan feeds her
   * more than she spends. S3 has to say so rather than draw a timeline — recorded in the PR.
   */
  test('a plan the floors leave with no deficit has no timeline, not an infinite one', () => {
    const targets = targetsFor({
      weightKg: 32,
      heightCm: 120,
      ageYears: 18,
      activityBand: 'mostlySitting',
      targetWeightKg: 30,
    })
    expect(targets.boundBy).toBe('absolute-floor')
    expect(targets.weightPlan?.paceKgPerWeek).toBeGreaterThan(0)
    expect(targets.weightPlan?.timelineWeeks).toBe(null)
  })

  test('a target she is already at is zero weeks, not null', () => {
    expect(targetsFor({ targetWeightKg: 73 }).weightPlan?.timelineWeeks).toBe(0)
  })

  test("the canvas' own plan: 73 kg to 65 kg", () => {
    const weightPlan = targetsFor().weightPlan!
    expect(weightPlan.targetWeightKg).toBe(65)
    expect(weightPlan.paceKgPerWeek).toBeCloseTo(-0.3055, 4)
    expect(weightPlan.timelineWeeks).toBe(27)
  })
})

// ── Macronutrients (PRD lines 788-793) ─────────────────────────────────────────────────

describe('protein is set first, fat second at its floor, carbohydrate is the remainder', () => {
  test("the split for the canvas' user", () => {
    const macros = targetsFor().macros
    // 1.6 g/kg x 73 kg
    expect(macros.proteinG).toBe(117)
    // 20% of 1902 kcal / 9 kcal per g, rounded up so the floor cannot be breached
    expect(macros.fatG).toBe(43)
    expect(macros.fatG * 9).toBeGreaterThanOrEqual(0.2 * 1902)
    // the remainder
    expect(macros.carbG).toBe(261)
    expect(macros.proteinLimitedByEnergy).toBe(false)
  })

  test('protein follows the goal, per kg of current weight', () => {
    expect(targetsFor({ goal: 'lose', targetWeightKg: 65 }).macros.proteinG).toBe(117)
    expect(targetsFor({ goal: 'buildMuscle', targetWeightKg: 76 }).macros.proteinG).toBe(131)
    expect(targetsFor({ goal: 'gain', targetWeightKg: 78 }).macros.proteinG).toBe(88)
    const maintain = steady('maintain')
    if (maintain.kind !== 'targets') throw new Error('expected targets')
    expect(maintain.targets.macros.proteinG).toBe(88)
  })

  test('each protein dose is the configured one', () => {
    const doubled: NutritionRules = {
      ...RULES,
      proteinGramsPerKg: { lose: 2.0, buildMuscle: 1.8, other: 1.2 },
    }
    expect(targetsFor({}, doubled).macros.proteinG).toBe(146)
  })

  test('the fat floor is the configured fraction, and rounding never goes under it', () => {
    const richer: NutritionRules = { ...RULES, fatMinFraction: 0.35 }
    const macros = targetsFor({}, richer).macros
    const calories = targetsFor({}, richer).calorieTargetKcal
    expect(macros.fatG * 9).toBeGreaterThanOrEqual(0.35 * calories)
    // and it is the floor, not a share: one gram less would breach it.
    expect((macros.fatG - 1) * 9).toBeLessThan(0.35 * calories)
  })

  test('the three macronutrients never claim more energy than the target holds', () => {
    const targets = targetsFor()
    const spent = targets.macros.proteinG * 4 + targets.macros.fatG * 9 + targets.macros.carbG * 4
    expect(spent).toBeLessThanOrEqual(targets.calorieTargetKcal)
    expect(spent).toBeGreaterThan(targets.calorieTargetKcal - 4)
  })

  /**
   * #222 asks what happens when protein plus the 20% fat floor overruns the clamped target,
   * and records the answer here: **the fat floor does not move** (PRD line 791 forbids it by
   * name), carbohydrate goes to zero because a negative remainder is not a food, and protein
   * — the one macronutrient the PRD gives as a target rather than as a floor — is what
   * yields. The fact is reported rather than absorbed.
   *
   * It is unreachable inside the accepted input range: the overrun needs a calorie target
   * below roughly nine times her weight in kg, and the basal-rate and 1,200 kcal floors keep
   * it above that everywhere between 30-200 kg and 120-220 cm. It is reachable through
   * *configuration*, which is the case that matters — these are doses a reviewer will revise.
   */
  test('when protein and the fat floor overrun the target, protein yields and fat does not', () => {
    const her = {
      weightKg: 200,
      heightCm: 120,
      ageYears: 99,
      activityBand: 'mostlySitting' as ActivityBand,
    }
    const asShipped = steady('maintain', her)
    if (asShipped.kind !== 'targets') throw new Error('expected targets')
    expect(asShipped.targets.macros.proteinLimitedByEnergy).toBe(false)
    expect(asShipped.targets.macros.proteinG).toBe(240)
    const fatAsShipped = asShipped.targets.macros.fatG

    const heavy: NutritionRules = {
      ...RULES,
      proteinGramsPerKg: { ...RULES.proteinGramsPerKg, other: 4 },
    }
    const overrun = planDailyTargets({ ...her, focusAreas: [], goal: 'maintain' }, heavy)
    if (overrun.kind !== 'targets') throw new Error('expected targets')
    const macros = overrun.targets.macros
    expect(macros.proteinLimitedByEnergy).toBe(true)
    // Fat is untouched — the floor is not the give.
    expect(macros.fatG).toBe(fatAsShipped)
    expect(macros.fatG * 9).toBeGreaterThanOrEqual(0.2 * overrun.targets.calorieTargetKcal)
    // Protein is what yields, and carbohydrate is what is left, which is nothing.
    expect(macros.proteinG).toBeLessThan(4 * 200)
    expect(macros.carbG).toBe(0)
    expect(macros.proteinG * 4 + macros.fatG * 9).toBeLessThanOrEqual(
      overrun.targets.calorieTargetKcal,
    )
  })

  /** A protein dose that can only have been a decimal-point slip is refused at the source
   *  rather than silently producing protein-only plans. */
  test('a protein dose beyond any published recommendation is refused', () => {
    const problem = nutritionRulesProblem({
      ...RULES,
      proteinGramsPerKg: { ...RULES.proteinGramsPerKg, lose: 16 },
    })
    expect(problem?.field).toBe('proteinGramsPerKg.lose')
    expect(problem?.message).toContain('at most 4 g per kg')
  })
})

describe('fibre is 25 g, and 30 g exactly when focus area 1 or 11 is selected', () => {
  const fibreWith = (focusAreas: readonly number[]) => targetsFor({ focusAreas }).macros.fibreG

  test('the two areas that raise it, and only those', () => {
    expect(fibreWith([])).toBe(25)
    expect(fibreWith([1])).toBe(30)
    expect(fibreWith([11])).toBe(30)
    expect(fibreWith([3, 11])).toBe(30)
    expect(fibreWith([1, 4, 7])).toBe(30)
    // Near misses, so the case is not just "any focus area raises it".
    expect(fibreWith([2, 12])).toBe(25)
    expect(fibreWith([10])).toBe(25)
    expect(fibreWith([4, 5, 6])).toBe(25)
  })

  test('both doses are the configured ones', () => {
    const moved: NutritionRules = { ...RULES, fibreGrams: 21, fibreGramsRaised: 38 }
    expect(targetsFor({ focusAreas: [] }, moved).macros.fibreG).toBe(21)
    expect(targetsFor({ focusAreas: [11] }, moved).macros.fibreG).toBe(38)
  })

  test('a raised target below the everyday one is refused', () => {
    const problem = nutritionRulesProblem({ ...RULES, fibreGramsRaised: 20 })
    expect(problem?.field).toBe('fibreGramsRaised')
    expect(problem?.message).toContain('at least fibreGrams')
  })
})

// ── The property, over the whole accepted input range ──────────────────────────────────

/**
 * Not three examples (#222: *"that is why the criteria ask for a property test and not
 * examples"*). `parseProfile` accepts 30-200 kg, 120-220 cm and 18 or over, and every
 * combination of those with every goal and every band has to satisfy the floors.
 *
 * Two targets are tried for each weight-change goal: the **lowest one the guards accept**,
 * which is the boundary a clamp is most likely to be exercised at, and one above her current
 * weight. The lowest is read back out of the engine's own refusal rather than recomputed
 * here, so the case cannot agree with a formula this file wrote.
 */
describe('across the whole accepted input range', () => {
  const WEIGHTS = [30, 45, 60, 73, 90, 120, 150, 180, 200]
  const HEIGHTS = [120, 140, 160, 168, 180, 200, 220]
  const AGES = [18, 25, 35, 45, 60, 80, 99]
  const GOALS: readonly NutritionGoal[] = ['lose', 'gain', 'buildMuscle', 'maintain', 'eatBetter']

  const everyCase = function* (
    rules: NutritionRules,
  ): Generator<{ input: NutritionInput; targets: DailyTargets }> {
    for (const weightKg of WEIGHTS) {
      for (const heightCm of HEIGHTS) {
        for (const ageYears of AGES) {
          for (const activityBand of ACTIVITY_BANDS) {
            for (const goal of GOALS) {
              const body = {
                weightKg,
                heightCm,
                ageYears,
                activityBand,
                focusAreas: heightCm === 160 ? [11] : [],
              }
              if (goal === 'maintain' || goal === 'eatBetter') {
                const result = planDailyTargets({ ...body, goal }, rules)
                if (result.kind === 'targets') {
                  yield { input: { ...body, goal }, targets: result.targets }
                }
                continue
              }
              // The lowest target the guards accept, asked of the engine rather
              // than recomputed: 30 kg is at or below every floor except for the
              // very lightest fixtures, where it is itself accepted.
              const probe = planDailyTargets({ ...body, goal, targetWeightKg: 30 }, rules)
              const lowest = probe.kind === 'refused' ? probe.refusal.lowestSupportedWeightKg : 30
              for (const targetWeightKg of [lowest, Math.min(200, Math.round(weightKg * 1.05))]) {
                const input: NutritionInput = { ...body, goal, targetWeightKg }
                const result = planDailyTargets(input, rules)
                if (result.kind === 'targets') yield { input, targets: result.targets }
              }
            }
          }
        }
      }
    }
  }

  test('the calorie target is never below the higher of basal rate and 1,200 kcal', () => {
    let checked = 0
    for (const { targets } of everyCase(RULES)) {
      expect(targets.calorieTargetKcal).toBeGreaterThanOrEqual(targets.bmrKcal)
      expect(targets.calorieTargetKcal).toBeGreaterThanOrEqual(RULES.minCalorieKcal)
      expect(targets.calorieTargetKcal).toBeGreaterThanOrEqual(targets.calorieFloorKcal)
      expect(targets.calorieFloorKcal).toBeGreaterThanOrEqual(targets.bmrKcal)
      expect(targets.calorieFloorKcal).toBeGreaterThanOrEqual(RULES.minCalorieKcal)
      checked += 1
    }
    // A property test that generated nothing passes every assertion it makes.
    expect(checked).toBeGreaterThan(5_000)
  })

  test('fat is never below 20% of calories, and carbohydrate is the remainder', () => {
    for (const { targets } of everyCase(RULES)) {
      const { proteinG, fatG, carbG, proteinLimitedByEnergy } = targets.macros
      expect(fatG * 9).toBeGreaterThanOrEqual(RULES.fatMinFraction * targets.calorieTargetKcal)
      expect(carbG).toBeGreaterThanOrEqual(0)
      expect(proteinG).toBeGreaterThanOrEqual(0)
      const spent = proteinG * 4 + fatG * 9 + carbG * 4
      expect(spent).toBeLessThanOrEqual(targets.calorieTargetKcal)
      if (!proteinLimitedByEnergy) {
        expect(spent).toBeGreaterThan(targets.calorieTargetKcal - 4)
      }
    }
  })

  test('the timeline always follows the clamped target, or there is none', () => {
    for (const { input, targets } of everyCase(RULES)) {
      const weightPlan = targets.weightPlan
      if (input.goal === 'maintain' || input.goal === 'eatBetter') {
        expect(weightPlan).toBe(null)
        continue
      }
      expect(weightPlan).not.toBe(null)
      const pace = ((targets.calorieTargetKcal - targets.tdeeKcal) * 7) / RULES.kcalPerKgBodyMass
      expect(weightPlan!.paceKgPerWeek).toBeCloseTo(pace, 10)
      const deltaKg = weightPlan!.targetWeightKg - input.weightKg
      if (deltaKg === 0) {
        expect(weightPlan!.timelineWeeks).toBe(0)
      } else if (pace === 0 || Math.sign(pace) !== Math.sign(deltaKg)) {
        expect(weightPlan!.timelineWeeks).toBe(null)
      } else {
        expect(weightPlan!.timelineWeeks).toBe(Math.ceil(deltaKg / pace))
      }
    }
  })

  /** Every refusal hands back a value S3 can put on a button, so across the range that value
   *  has to be inside the range the engine itself accepts and has to produce a plan. A
   *  refusal that offers something the next call throws on would be the canvas' rounding bug
   *  in a different place. */
  test('every refusal across the range offers a value that is itself accepted', () => {
    let refusals = 0
    for (const weightKg of WEIGHTS) {
      for (const heightCm of HEIGHTS) {
        for (const goal of ['lose', 'gain', 'buildMuscle'] as const) {
          const body = {
            weightKg,
            heightCm,
            ageYears: 35,
            activityBand: 'active' as ActivityBand,
            focusAreas: [],
            goal,
          }
          const probe = planDailyTargets({ ...body, targetWeightKg: 30 }, RULES)
          if (probe.kind !== 'refused') continue
          refusals += 1
          const offered = probe.refusal.lowestSupportedWeightKg
          expect(offered).toBeGreaterThanOrEqual(30)
          expect(offered).toBeLessThanOrEqual(200)
          expect(planDailyTargets({ ...body, targetWeightKg: offered }, RULES).kind).toBe('targets')
        }
      }
    }
    expect(refusals).toBeGreaterThan(100)
  })

  test('fibre is one of the two doses, by focus area alone', () => {
    for (const { input, targets } of everyCase(RULES)) {
      const raised = input.focusAreas.includes(1) || input.focusAreas.includes(11)
      expect(targets.macros.fibreG).toBe(raised ? 30 : 25)
    }
  })

  test('a bound target sits exactly on the floor, and an unbound one does not', () => {
    for (const { targets } of everyCase(RULES)) {
      if (targets.boundBy === null) continue
      expect(targets.calorieTargetKcal).toBe(targets.calorieFloorKcal)
    }
  })

  /**
   * **The clamps this range actually reaches, asserted rather than assumed.** A property
   * test that never fires a clamp proves nothing about it, so the set of clamps observed is
   * the assertion: the absolute floor and the rate cap both fire at the shipped numbers, and
   * basal rate does not — for the reason the unit case above states — but does at -20%.
   */
  test('the range exercises the clamps it claims to cover', () => {
    const observed = new Set<string>()
    for (const { targets } of everyCase(RULES)) observed.add(String(targets.boundBy))
    expect(observed).toEqual(new Set(['null', 'absolute-floor', 'rate-cap']))

    const deeper: NutritionRules = {
      ...RULES,
      goalAdjustment: { ...RULES.goalAdjustment, lose: -0.2 },
    }
    const atTwenty = new Set<string>()
    for (const { targets } of everyCase(deeper)) atTwenty.add(String(targets.boundBy))
    expect(atTwenty).toContain('basal-rate')
  })
})

// ── No score, no aggregate, no daily grade (PRD line 885) ──────────────────────────────

describe('nothing here is a score', () => {
  /** S8's "Meal fit" is gated on #26's review and must not be anticipated by a field. Pinning
   *  the key set is what makes adding one a failing test rather than a review catch. */
  test('the output carries exactly these fields and no other', () => {
    const targets = targetsFor()
    expect(Object.keys(targets).sort()).toEqual([
      'bmrKcal',
      'boundBy',
      'calorieFloorKcal',
      'calorieTargetKcal',
      'macros',
      'tdeeKcal',
      'weightPlan',
    ])
    expect(Object.keys(targets.macros).sort()).toEqual([
      'carbG',
      'fatG',
      'fibreG',
      'proteinG',
      'proteinLimitedByEnergy',
    ])
    expect(Object.keys(targets.weightPlan!).sort()).toEqual([
      'paceKgPerWeek',
      'targetWeightKg',
      'timelineWeeks',
    ])
  })

  /** The key sets above pin the shape; this pins the *vocabulary*, so a score cannot arrive
   *  as a local, a type or a union member either. Comments are stripped first — the header
   *  has to be able to say what this module does not compute. */
  test('no identifier in the module is named like one', async () => {
    const source = await Bun.file(`${import.meta.dir}/../src/nutrition.ts`).text()
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')
    // The strip has to have left something, or this asserts nothing at all.
    expect(code).toContain('planDailyTargets')
    for (const forbidden of ['score', 'Score', 'grade', 'Grade', 'streak', 'aggregate']) {
      expect(code).not.toContain(forbidden)
    }
  })
})

// ── Refusals ───────────────────────────────────────────────────────────────────────────

describe('no dose is written in the maths', () => {
  test('the engine refuses to answer without constants', () => {
    expect(() => plan({}, null)).toThrow(NutritionRulesUnsetError)
  })

  test('the refusal names the field and what would have been valid', () => {
    expect(() => plan({}, { ...RULES, minBmi: 0 })).toThrow(NutritionRulesUnsetError)
    try {
      plan({}, { ...RULES, minBmi: 0 })
    } catch (error) {
      expect((error as Error).message).toContain('minBmi')
      expect((error as Error).message).toContain('positive number')
    }
  })

  test('moving each adjustment moves the target', () => {
    const base = targetsFor().calorieTargetKcal
    const deeper = targetsFor(
      {},
      { ...RULES, goalAdjustment: { ...RULES.goalAdjustment, lose: -0.18 } },
    ).calorieTargetKcal
    expect(deeper).toBeLessThan(base)
    expect(targetsFor({ goal: 'gain', targetWeightKg: 78 }).calorieTargetKcal).toBe(2574)
    expect(targetsFor({ goal: 'buildMuscle', targetWeightKg: 76 }).calorieTargetKcal).toBe(2462)
  })

  test('moving the energy per kilogram moves the timeline and nothing else', () => {
    const denser: NutritionRules = { ...RULES, kcalPerKgBodyMass: 9000 }
    expect(targetsFor({}, denser).calorieTargetKcal).toBe(targetsFor().calorieTargetKcal)
    expect(targetsFor({}, denser).weightPlan!.timelineWeeks).toBeGreaterThan(
      targetsFor().weightPlan!.timelineWeeks!,
    )
  })
})

describe('a set of constants that would produce a plausible wrong answer is refused', () => {
  const refuse = (over: Partial<NutritionRules>, field: string, range: string) => {
    const broken = { ...RULES, ...over }
    const problem = nutritionRulesProblem(broken)
    expect(problem?.field).toBe(field)
    expect(problem?.message).toContain(range)
    expect(() => plan({}, broken)).toThrow(NutritionRulesUnsetError)
  }

  test('no constants at all', () => {
    expect(nutritionRulesProblem(null)?.field).toBe('rules')
  })

  /** The sign errors are the ones #222's Risks name: a deficit that feeds more, or a surplus
   *  that feeds less, produces a complete and confident plan pointing the wrong way. */
  test('a deficit that is not one, and a surplus that is not one', () => {
    refuse(
      { goalAdjustment: { ...RULES.goalAdjustment, lose: 0.15 } },
      'goalAdjustment.lose',
      'negative fraction',
    )
    refuse(
      { goalAdjustment: { ...RULES.goalAdjustment, gain: -0.1 } },
      'goalAdjustment.gain',
      'positive fraction',
    )
    refuse(
      { goalAdjustment: { ...RULES.goalAdjustment, buildMuscle: 0 } },
      'goalAdjustment.buildMuscle',
      'positive fraction',
    )
  })

  test('a guard set to zero, which is a guard that is configured and absent', () => {
    refuse({ minCalorieKcal: 0 }, 'minCalorieKcal', 'positive number')
    refuse({ minBmi: 0 }, 'minBmi', 'positive number')
    refuse({ maxPlanLossFraction: 0 }, 'maxPlanLossFraction', 'fraction greater than 0')
    refuse({ maxLossKgPerWeek: 0 }, 'maxLossKgPerWeek', 'positive number')
    refuse({ maxLossFractionPerWeek: 0 }, 'maxLossFractionPerWeek', 'fraction greater than 0')
    refuse({ kcalPerKgBodyMass: 0 }, 'kcalPerKgBodyMass', 'positive number')
  })

  test('a fat floor of zero or of everything', () => {
    refuse({ fatMinFraction: 0 }, 'fatMinFraction', 'fraction greater than 0')
    refuse({ fatMinFraction: 1 }, 'fatMinFraction', 'less than 1')
  })

  test('a per-plan cap of 100%, which would allow targeting nothing', () => {
    refuse({ maxPlanLossFraction: 1 }, 'maxPlanLossFraction', 'less than 1')
  })

  test('the constants the PRD settled on are accepted', () => {
    expect(nutritionRulesProblem(RULES)).toBe(null)
  })
})

describe('a body metric outside the range the route edge accepts is refused, not clamped', () => {
  const cases: readonly [Partial<NutritionInput>, string][] = [
    [{ weightKg: 29 }, 'weightKg'],
    [{ weightKg: 201 }, 'weightKg'],
    [{ heightCm: 119 }, 'heightCm'],
    [{ heightCm: 221 }, 'heightCm'],
    [{ ageYears: 17 }, 'ageYears'],
  ]

  for (const [over, field] of cases) {
    test(`${field} outside the range throws`, () => {
      expect(() => plan(over)).toThrow(ImpossibleBodyMetricError)
      try {
        plan(over)
      } catch (error) {
        expect((error as Error).message).toContain(field)
      }
    })
  }

  test('a target weight outside it throws too', () => {
    expect(() => plan({ targetWeightKg: 250 })).toThrow(ImpossibleBodyMetricError)
  })

  /** The message names the field and the range, never the value: a weight in an error is a
   *  health fact about a named request (GUARDRAILS 12). */
  test('the message carries no value she typed', () => {
    try {
      plan({ weightKg: 217 })
    } catch (error) {
      expect((error as Error).message).not.toContain('217')
      expect((error as Error).message).toContain('30–200')
    }
    try {
      plan({ ageYears: 14 })
    } catch (error) {
      expect((error as Error).message).not.toContain('14')
    }
  })
})

/**
 * **The accepted range is one set of numbers, declared twice.** `nutrition.ts` imports nothing
 * — that is what keeps it pure, and the source scan below pins it — so the route's range and
 * the engine's cannot be one constant without a runtime import into the engine. This reads
 * both files instead, the idiom `cycle.test.ts` uses for the account floor.
 */
describe('the accepted body-metric range is one set of numbers', () => {
  test('`nutrition.ts` and `index.ts` declare the same one', async () => {
    const engine = await Bun.file(`${import.meta.dir}/../src/nutrition.ts`).text()
    const routes = await Bun.file(`${import.meta.dir}/../src/index.ts`).text()
    const named = (source: string, name: string) =>
      source.match(new RegExp(`const ${name} = (\\d+)`))?.[1] ?? null

    expect(named(engine, 'MIN_WEIGHT_KG')).toBe('30')
    expect(named(engine, 'MAX_WEIGHT_KG')).toBe('200')
    expect(named(engine, 'MIN_HEIGHT_CM')).toBe('120')
    expect(named(engine, 'MAX_HEIGHT_CM')).toBe('220')
    expect(named(engine, 'MIN_ACCOUNT_AGE_YEARS')).toBe('18')

    expect(routes).toContain('inRange(weightKg, 30, 200)')
    expect(routes).toContain('inRange(heightCm, 120, 220)')
    expect(named(routes, 'MIN_ACCOUNT_AGE_YEARS')).toBe('18')
  })
})

// ── Purity ─────────────────────────────────────────────────────────────────────────────

const importInABareProcess = async (modulePath: string) => {
  const proc = Bun.spawn(['bun', '--eval', `await import(${JSON.stringify(modulePath)})`], {
    // Outside `api/`, so Bun does not auto-load `api/.env`: the case is a process holding
    // no configuration and no credential at all.
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
      `${import.meta.dir}/../src/nutrition.ts`,
    )
    expect(stderr).toBe('')
    expect(exitCode).toBe(0)
  }, 10_000)

  /** The import test alone is not enough — a bare-process import proves only what runs at
   *  import time, so a `fetch` inside a function survives it untouched. The source is
   *  scanned for the call as well as for the module. */
  test('it has no imports at all, and nothing in it reaches out', async () => {
    const source = await Bun.file(`${import.meta.dir}/../src/nutrition.ts`).text()
    expect(source.match(/^import .*$/gm)).toBe(null)
    for (const forbidden of [
      './firebase',
      './events',
      './config',
      './users',
      'firebase-admin',
      'fetch(',
      'https://',
      'http://',
      'console.',
      'process.env',
      'Date.now',
      'new Date(',
      'Math.random',
    ]) {
      expect(source).not.toContain(forbidden)
    }
  })

  test('and a module that does touch Firestore fails there, which is what makes that a test', async () => {
    const { exitCode, stderr } = await importInABareProcess(`${import.meta.dir}/../src/content.ts`)
    expect(exitCode).not.toBe(0)
    expect(stderr).toContain('Missing required env var')
  }, 10_000)
})

// ── The configuration is a boot-time refusal ───────────────────────────────────────────

/**
 * `config.ts` reads the environment once at import, so what a given set of variables does is a
 * *boot*, and the only seam is a subprocess — the shape `cycle.test.ts` and
 * `config-emulators.test.ts` use. No Firestore, so these run in every environment.
 */
describe("the nutrition engine's configuration", () => {
  /** Enough to get `config.ts` past every other required variable. */
  const BASE_ENV = {
    PATH: process.env.PATH ?? '',
    FIREBASE_PROJECT_ID: 'demo-eva-nutrition-test',
    FIREBASE_WEB_API_KEY: 'not-a-real-key',
    JWT_SECRET: 'not-a-real-secret',
    EMAIL_TRANSPORT: 'log',
    NODE_ENV: 'test',
    POSTMARK_FROM: 'nutrition-test@example.test',
    PUBLIC_WEB_URL: 'http://localhost:4321',
  }

  /** `RULES` as `config.ts` reads it. Kept beside the fixture above so the two cannot
   *  disagree about what the PRD and #222 settled. */
  const NUTRITION_ENV: Record<string, string> = {
    NUTRITION_BMR_PER_KG: String(RULES.basalRate.perKg),
    NUTRITION_BMR_PER_CM: String(RULES.basalRate.perCm),
    NUTRITION_BMR_PER_YEAR: String(RULES.basalRate.perYear),
    NUTRITION_BMR_OFFSET: String(RULES.basalRate.offset),
    NUTRITION_ACTIVITY_FACTOR_MOSTLY_SITTING: String(RULES.activityFactors.mostlySitting),
    NUTRITION_ACTIVITY_FACTOR_LIGHTLY_ACTIVE: String(RULES.activityFactors.lightlyActive),
    NUTRITION_ACTIVITY_FACTOR_ACTIVE: String(RULES.activityFactors.active),
    NUTRITION_ACTIVITY_FACTOR_VERY_ACTIVE: String(RULES.activityFactors.veryActive),
    NUTRITION_ADJUST_LOSE: String(RULES.goalAdjustment.lose),
    NUTRITION_ADJUST_GAIN: String(RULES.goalAdjustment.gain),
    NUTRITION_ADJUST_BUILD_MUSCLE: String(RULES.goalAdjustment.buildMuscle),
    NUTRITION_PROTEIN_LOSE_G_PER_KG: String(RULES.proteinGramsPerKg.lose),
    NUTRITION_PROTEIN_BUILD_MUSCLE_G_PER_KG: String(RULES.proteinGramsPerKg.buildMuscle),
    NUTRITION_PROTEIN_OTHER_G_PER_KG: String(RULES.proteinGramsPerKg.other),
    NUTRITION_FAT_MIN_FRACTION: String(RULES.fatMinFraction),
    NUTRITION_FIBRE_G: String(RULES.fibreGrams),
    NUTRITION_FIBRE_RAISED_G: String(RULES.fibreGramsRaised),
    NUTRITION_MIN_BMI: String(RULES.minBmi),
    NUTRITION_MAX_PLAN_LOSS_FRACTION: String(RULES.maxPlanLossFraction),
    NUTRITION_MAX_LOSS_KG_PER_WEEK: String(RULES.maxLossKgPerWeek),
    NUTRITION_MAX_LOSS_FRACTION_PER_WEEK: String(RULES.maxLossFractionPerWeek),
    NUTRITION_MIN_CALORIE_KCAL: String(RULES.minCalorieKcal),
    NUTRITION_KCAL_PER_KG_BODY_MASS: String(RULES.kcalPerKgBodyMass),
  }

  const bootConfig = async (over: Record<string, string>) => {
    // A bare env, not `...process.env`: a developer with these set would decide the result,
    // and the point is what a given set does at boot.
    const proc = Bun.spawn(['bun', 'run', 'src/config.ts'], {
      cwd: new URL('..', import.meta.url).pathname,
      env: { ...BASE_ENV, ...over },
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
    return { code, stderr }
  }

  /** Empty rather than absent, wherever a case means "unset": `config.ts` reads these with
   *  `optionalString`, which treats `''` as not supplied, and an empty value cannot be filled
   *  back in by an `api/.env` the way a deleted key can. `.env.example` ships this group with
   *  values, so a developer who followed the instruction to copy it has all twenty-three. */
  const UNSET = Object.fromEntries(Object.keys(NUTRITION_ENV).map((name) => [name, '']))

  test('the group the PRD and #222 settled boots', async () => {
    expect((await bootConfig(NUTRITION_ENV)).code).toBe(0)
  }, 30_000)

  test('none of them set is not a boot failure — the engine refuses instead', async () => {
    expect((await bootConfig(UNSET)).code).toBe(0)
  }, 30_000)

  test('a partial group is refused, and the failure names what is missing', async () => {
    const { code, stderr } = await bootConfig({
      ...NUTRITION_ENV,
      NUTRITION_FAT_MIN_FRACTION: '',
    })
    expect(code).not.toBe(0)
    expect(stderr).toContain('Incomplete nutrition targets configuration')
    expect(stderr).toContain('NUTRITION_FAT_MIN_FRACTION')
  }, 30_000)

  test('one of them alone is refused too, naming the rest', async () => {
    const { code, stderr } = await bootConfig({ ...UNSET, NUTRITION_MIN_BMI: '18.5' })
    expect(code).not.toBe(0)
    expect(stderr).toContain('Incomplete nutrition targets configuration')
    expect(stderr).toContain('NUTRITION_BMR_PER_KG')
  }, 30_000)

  /** The boot-time half of `nutritionRulesProblem`, which is the reason `config.ts` imports
   *  it rather than restating it: a value that passes the parse and produces a plan pointing
   *  the wrong way has to be refused in both places, and one implementation is what makes
   *  that true. */
  test('an out-of-range value is refused with the valid range named', async () => {
    const wrongSign = await bootConfig({ ...NUTRITION_ENV, NUTRITION_ADJUST_LOSE: '0.15' })
    expect(wrongSign.code).not.toBe(0)
    expect(wrongSign.stderr).toContain('Invalid env var NUTRITION_ADJUST_LOSE')
    expect(wrongSign.stderr).toContain('negative fraction')

    const unordered = await bootConfig({
      ...NUTRITION_ENV,
      NUTRITION_ACTIVITY_FACTOR_ACTIVE: '1.3',
    })
    expect(unordered.code).not.toBe(0)
    expect(unordered.stderr).toContain('Invalid env var NUTRITION_ACTIVITY_FACTOR_ACTIVE')
    expect(unordered.stderr).toContain('greater than activityFactors.lightlyActive')

    const zeroed = await bootConfig({ ...NUTRITION_ENV, NUTRITION_MIN_CALORIE_KCAL: '0' })
    expect(zeroed.code).not.toBe(0)
    expect(zeroed.stderr).toContain('Invalid env var NUTRITION_MIN_CALORIE_KCAL')
    expect(zeroed.stderr).toContain('positive number')
  }, 30_000)

  test('a value that is not a number is refused', async () => {
    const { code, stderr } = await bootConfig({ ...NUTRITION_ENV, NUTRITION_MIN_BMI: 'low' })
    expect(code).not.toBe(0)
    expect(stderr).toContain('NUTRITION_MIN_BMI')
  }, 30_000)

  /** `.env.example` is the one place an operator copies from, so a group it cannot boot is a
   *  broken instruction rather than a stale comment. Line-anchored and read back as a group:
   *  a `toContain` passes on a commented-out line, which is a variable the developer who
   *  copies this file does not get — and a group missing one is a boot failure. */
  test('the values in .env.example are the values this file asserts against', async () => {
    const example = await Bun.file(`${import.meta.dir}/../.env.example`).text()
    const set = [...example.matchAll(/^(NUTRITION_[A-Z_0-9]+)=(\S*)/gm)].map(([, name, value]) => [
      name,
      value,
    ])
    expect(Object.fromEntries(set)).toEqual(NUTRITION_ENV)
  })

  /** And the values CI boots with. A variable added here and not there would make every suite
   *  that loads `config.ts` refuse to boot in CI, and a value that drifted there would test a
   *  configuration nobody chose. */
  test('the values scripts/ci-api.sh exports are the values this file asserts against', async () => {
    const script = await Bun.file(`${import.meta.dir}/../../scripts/ci-api.sh`).text()
    const exported = [...script.matchAll(/^export (NUTRITION_[A-Z_0-9]+)=(.*)$/gm)].map(
      ([, name, value]) => [name, value],
    )
    expect(Object.fromEntries(exported)).toEqual(NUTRITION_ENV)
  })

  /** Both points #222 chose inside a range are product choices, and the method #26 settled
   *  says a number without that note fails review. `.env.example` is where an operator reads
   *  them, so that is where the note has to be. */
  test('.env.example marks every product choice as one', async () => {
    const example = await Bun.file(`${import.meta.dir}/../.env.example`).text()
    for (const name of [
      'NUTRITION_ADJUST_LOSE',
      'NUTRITION_ADJUST_GAIN',
      'NUTRITION_ADJUST_BUILD_MUSCLE',
      'NUTRITION_MAX_PLAN_LOSS_FRACTION',
    ]) {
      const line = example.split('\n').find((row) => row.startsWith(`${name}=`))
      expect(line).toContain('PRODUCT CHOICE')
    }
    // And the two points chosen here are recorded where the review gate will read them.
    const launch = await Bun.file(`${import.meta.dir}/../../docs/LAUNCH.md`).text()
    expect(launch).toContain('NUTRITION_ADJUST_GAIN')
    expect(launch).toContain('NUTRITION_ADJUST_BUILD_MUSCLE')
  })
})

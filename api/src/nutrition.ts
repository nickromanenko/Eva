/**
 * The nutrition targets engine (S2 of #25, #222): her body metrics, her goal, her target
 * weight and her focus areas in — the day's calorie target, the macronutrient split, the
 * clamp that bound the target and the timeline that follows from it out.
 *
 * PRD §Nutrition coach → Daily targets calculation and Step 5, with the values A29 and A30
 * settled on 2026-08-30. PRD line 942: *"All calculation constants … are server-configurable,
 * not hardcoded."* Every dose this file uses arrives in `NutritionRules` from `config.ts`;
 * there is no default anywhere, and `requireNutritionRules` refuses to answer without them,
 * exactly as `analyzeCycles` refuses without `CycleRules` (#176, #181).
 *
 * **Pure, and that is the design rather than a property of it.** No Firestore, no clock, no
 * `fetch`, no log line, and no import at all — not even an `import type`. The caller gathers
 * and hands in, which is what lets every clamp be exercised at its boundary against fixtures
 * for states no real account has reached, and it is pinned by a source scan in the test file
 * rather than left to review.
 *
 * **Cycle-agnostic by signature, not by promise.** `NutritionInput` carries no cycle phase
 * and no calendar mode, so the luteal adjustment and the pregnancy/postpartum adjustments
 * (S12, #224) cannot arrive here as a `phase?:` parameter with a default — they wrap this
 * module, they do not reach inside it. That is the same mechanism `toCycleEstimate` uses
 * from the other direction (#179, #205): a projection carrying no `cycles` field cannot be
 * read for a fact it was not meant to carry. PRD line 757's rule that weight-change goals
 * are unavailable in Pregnancy and the first six postpartum weeks is therefore **not**
 * enforced here — this module cannot see the mode by construction, and the rule belongs
 * where the goal is chosen (S3) and where the mode adjustment lives (S12).
 *
 * **Every clamp points the same way: up.** PRD lines 751–757 are a stack of floors, and
 * canvas `sRate` says what they do — *"When the requested pace is too fast, Eva extends the
 * timeline instead of cutting calories"* and *"Calorie floor is the higher of BMR and 1,200
 * kcal; hitting it also extends the timeline."* So the rate cap is expressed here as a
 * *floor on calories* rather than as a ceiling on the pace: the only lever a plan has is
 * food, and refusing to cut it is what lengthens the timeline. #25 says why erring the other
 * way is not caution: *"Erring low on an energy target is not automatically the safe
 * direction here — under-feeding is its own harm in this population."*
 *
 * **The timeline is derived from the clamped target, never from the requested one.** A
 * target and a timeline that disagree is the defect; deriving one from the other means it
 * cannot be constructed, and `DailyTargets.boundBy` hands S3's `sGuard` / `sCap` / `sRate`
 * cards the clamp that bound it instead of making them re-derive it and get a different
 * answer.
 *
 * **Nothing here is a measurement.** Mifflin-St Jeor is a predictive equation for a
 * population, not an observation of this user; the energy density behind the timeline is a
 * planning convention that is known to overstate long-run change. Both say so at their
 * values. GUARDRAILS 35 is satisfied by S3's *"How this is calculated"* sheet, and this
 * module is what that sheet describes.
 *
 * **No score, no aggregate, no daily grade** — PRD line 885: *"Scores are never aggregated
 * into a daily grade for the user herself. Meals are scored; people are not."* The "Meal
 * fit" score is S8, gated on #26's review; there is no weighting here and no field to put
 * one in.
 *
 * Never log a goal, a target weight or a calorie target: all of it is a health fact about a
 * named request (GUARDRAILS 12). This module writes no log line at all, which is the
 * simplest way to keep that true.
 */

// ── What a caller hands in ─────────────────────────────────────────────────────────────

/**
 * The four activity bands the Sign Up questionnaire already asks (A8, #25 Q4), as codes.
 *
 * **Declared once, here, and read by both this lookup and S1's validator (#221).** The
 * factor table below is a `Record<ActivityBand, number>`, so adding a band without giving it
 * a factor is a compile error and a band that validates but has no factor cannot exist. That
 * is the whole defence against the one-liner #221 names as the tempting wrong fix —
 * `FACTORS[profile.lifestyle] ?? 1.2` compiles, reads fine, and lands every unmapped label
 * on the sedentary factor, which is the most-chosen band and therefore invisible in
 * production and in review. There is no default branch anywhere in this file.
 *
 * The order is the questionnaire's own, lowest to highest, and `nutritionRulesProblem` reads
 * it as an order: a factor set that is not strictly increasing across these four would feed a
 * more active woman less than a less active one, silently.
 *
 * PRD lines 772–777 name the bands *Sedentary / Lightly active / Moderately active / Very
 * active*; the questionnaire's wording is *Mostly sitting / Lightly active / Active / Very
 * active* and these codes follow the questionnaire, because that is what the profile stores.
 * "Extremely active" (1.9) is dropped — #25 Q4, with the cost stated there.
 */
export const ACTIVITY_BANDS = ['mostlySitting', 'lightlyActive', 'active', 'veryActive'] as const

export type ActivityBand = (typeof ACTIVITY_BANDS)[number]

/** The three goals that carry a target weight (PRD Step 1, options 1–3). */
export type WeightChangeGoal = 'lose' | 'gain' | 'buildMuscle'

/**
 * The two that do not (PRD Step 1, options 4 and 5 — *"Maintain my weight"*, *"Eat better
 * without changing my weight"*).
 *
 * First-class, not a residue: PRD line 700 — *"Options 4 and 5 must be present and must be
 * as visually prominent as the others."* Step 5 is skipped entirely for them (line 745), so
 * they carry no target weight **in the type**, which is what makes a plan that needs one
 * unbuildable rather than a plan whose target weight happens to be zero.
 */
export type SteadyGoal = 'maintain' | 'eatBetter'

export type NutritionGoal = WeightChangeGoal | SteadyGoal

/** The body metrics every goal needs. Metric, always — ARCHITECTURE §5 (#82): the profile
 *  stores `weightKg` and `heightCm` whatever the device displays, and the conversion happens
 *  where she types, not here. */
interface BodyMetrics {
  /** Her current weight, 30–200 kg — `parseProfile`'s own accepted range. */
  weightKg: number
  /** Her height, 120–220 cm — likewise. */
  heightCm: number
  /**
   * Whole years, 18 or over.
   *
   * **Derived by the caller, not here**, and the caller derives it with `ageYearsOn`
   * (`cycle.ts`, re-exported through `today.ts`) so that Eva has exactly one implementation
   * of "how old is she" — #81's reason, which is that the obvious second spelling disagrees
   * with the first on 29 February. Taking the years rather than the date of birth is also
   * what keeps this module free of dates: it has no `today`, so it has nothing that could
   * become a clock.
   */
  ageYears: number
  activityBand: ActivityBand
  /**
   * The focus-area numbers she selected (PRD Step 2, at most three). Read for one thing
   * only: whether the fibre target is raised. Anything else in the list is ignored — focus
   * areas change the wording of the notes, not the maths (canvas `s2`).
   */
  focusAreas: readonly number[]
}

/**
 * Everything the day's targets are computed from.
 *
 * **It does not take `Profile`.** `Profile.lifestyle` is a bare `string` until #221 lands,
 * and accepting it here would force exactly the lookup with a fallback that #221 exists to
 * remove. S3 assembles this shape from the profile and the nutrition profile, the way
 * `today.ts` assembles `DashboardInput` from three modules.
 *
 * **And it takes no cycle phase and no calendar mode.** Not a phase it ignores — an argument
 * that does not exist. See the header.
 */
export type WeightChangeInput = BodyMetrics & {
  goal: WeightChangeGoal
  targetWeightKg: number
}

export type NutritionInput =
  | WeightChangeInput
  | (BodyMetrics & { goal: SteadyGoal; targetWeightKg?: never })

// ── Configuration (A29, A30) ───────────────────────────────────────────────────────────

/**
 * Mifflin-St Jeor, female form: `(perKg × kg) + (perCm × cm) − (perYear × age) − offset`.
 *
 * *Source: Mifflin MD, St Jeor ST, Hill LA, Scott BJ, Daugherty SA, Koh YO. A new predictive
 * equation for resting energy expenditure in healthy individuals. Am J Clin Nutr
 * 1990;51:241–7.* PRD line 771.
 *
 * The coefficients are configuration for the reason the FIGO band edges are (`cycle.ts`):
 * they are a published finding, and a revision to the source is a configuration change
 * rather than a code change. They are **not** a dose — nobody tunes them to make a plan
 * gentler — and `nutritionRulesProblem` refuses a set that would put basal rate below zero
 * in the accepted range.
 */
export interface BasalRateCoefficients {
  perKg: number
  perCm: number
  perYear: number
  /** Subtracted. The female constant, 161 — the male form subtracts −5, which is why this
   *  equation is written out per sex rather than parameterised by one. */
  offset: number
}

/** PRD line 772 item 2: total daily energy expenditure = basal rate × the band's factor.
 *  A `Record` over the closed union, so a band with no factor is a compile error. */
export type ActivityFactors = Record<ActivityBand, number>

/**
 * PRD line 778 item 3, the goal adjustment applied to total expenditure, as a fraction.
 *
 * Three members, not five: *"Maintain / eat better — no adjustment"* (PRD line 780) is the
 * absence of a dose rather than a dose of zero, so there is nothing for an operator to
 * configure and nothing for a reviewer to sign. `adjustmentFor` writes those two as `0`.
 */
export interface GoalAdjustments {
  /** Negative. A30: −15%, the safer end of PRD line 779's −15 to 20%; a product choice. */
  lose: number
  /** Positive. The point inside PRD line 781's +10 to 15%; a product choice (#222). */
  gain: number
  /** Positive. The point inside PRD line 782's +5 to 10%; a product choice (#222). */
  buildMuscle: number
}

/**
 * PRD lines 788–790, grams of protein per kg of *current* body weight — current, because
 * that is the body the food is for, and because a target weight is absent for two of the
 * five goals while protein is set for all five.
 *
 * *Within Phillips SM & Van Loon LJC, J Sports Sci 2011;29(S1):S29–38 and the ISSN position
 * stand, Jäger R et al., JISSN 2017;14:20.* The points are A30's.
 */
export interface ProteinPerKg {
  lose: number
  buildMuscle: number
  /** PRD line 790: "All other goals" — gain, maintain and eat better. */
  other: number
}

/** Every number the maths uses, and the complete list of them. `config.ts` is where these
 *  come from; nothing here has a default, because a default is a dietary constant chosen by
 *  whoever typed it and signed by nobody (#26's process note). */
export interface NutritionRules {
  basalRate: BasalRateCoefficients
  activityFactors: ActivityFactors
  goalAdjustment: GoalAdjustments
  proteinGramsPerKg: ProteinPerKg
  /** PRD line 791: fat must not fall below this fraction of total calories. **A hard floor,
   *  never shaved** — see `macrosFor`. */
  fatMinFraction: number
  /** PRD line 793 / A30: the everyday fibre target, in grams. */
  fibreGrams: number
  /** …and what it is raised to when focus area 1 or 11 is selected. */
  fibreGramsRaised: number
  /** A29: the WHO underweight threshold. No plan may target a weight below it. */
  minBmi: number
  /** A29: a single plan may not target more than this fraction below her current weight.
   *  **A product choice, not a finding** — A29 says so in those words. */
  maxPlanLossFraction: number
  /** PRD line 754: the rate of loss is capped at this many kg per week… */
  maxLossKgPerWeek: number
  /** …or this fraction of body weight per week, whichever is lower. */
  maxLossFractionPerWeek: number
  /** PRD line 756: the absolute calorie floor. Below it the timeline extends instead. */
  minCalorieKcal: number
  /** The energy equivalent of a kilogram of body mass, used for the timeline only. A
   *  planning convention rather than a measurement — see `KCAL_PER_G_FAT` for the company
   *  it keeps, and `.env.example` for its source and its known limits. */
  kcalPerKgBodyMass: number
}

/**
 * Thrown when the engine is asked for a plan without its constants, or with constants it
 * cannot use.
 *
 * Its own class so a caller can tell a missing configuration from a bug, so the route can
 * answer "unavailable" rather than "error", and so the refusal is greppable — exactly
 * `CycleRulesUnsetError`'s job for the cycle maths and `PatternRuleUnsetError`'s for rung 2.
 *
 * **Whatever route first serves a target maps this to `503 SERVICE_UNAVAILABLE`**, the way
 * `GET /me/today` maps `CycleRulesUnsetError` (#181). No route serves a target yet — S3 and
 * S4 are out of #222's scope — so there is nothing to map it on today; the route that adds
 * the capability adds the mapping in the same PR, or an unset group turns a 503 into a 500
 * on the day it becomes reachable.
 */
export class NutritionRulesUnsetError extends Error {
  constructor(reason = 'no constants are configured') {
    super(`the nutrition targets cannot be computed: ${reason}`)
    this.name = 'NutritionRulesUnsetError'
  }
}

/**
 * Thrown when a body metric is outside the range `parseProfile` accepts (#222).
 *
 * **It fails rather than clamping**, for `ImpossibleAgeError`'s reason (#187): the route
 * edge already refuses 29 kg, 221 cm and 17 years (GUARDRAILS 13), so a value outside the
 * range did not arrive through the API. It is a bug of ours or a hand-edited document, and
 * neither is a condition to smooth over into a slightly safer number — least of all here,
 * where "slightly safer" means a smaller calorie target.
 *
 * `targetWeightKg` is held to the same range, and that is a division of labour rather than a
 * second guard: S3 validates what she types at the route edge with `parseProfile`'s own
 * 30–200, so a typed 25 kg is a `400 VALIDATION` naming the field and never reaches here.
 * Everything *inside* that range is the guards' business, and comes back as a refusal with a
 * value to offer rather than as a throw — which is also why an offered value is always one
 * this same check accepts: it is only ever produced for a target the range already admitted,
 * and it is above that target.
 *
 * Carries the field name and the range expected, never the value (GUARDRAILS 12): a weight
 * in an error message is a health fact about a named request.
 */
export class ImpossibleBodyMetricError extends Error {
  constructor(field: string, expected: string) {
    super(`the nutrition targets engine's ${field} must be ${expected}`)
    this.name = 'ImpossibleBodyMetricError'
  }
}

/** One thing wrong with a set of constants: which field, and what would have been valid.
 *  Returned rather than thrown so `config.ts` can name the *environment variable* in its
 *  boot failure while this module names the field — one implementation of the rules, two
 *  vocabularies for reporting it. `cycle.ts`'s `CycleRulesProblem` is the shape. */
export interface NutritionRulesProblem {
  field: string
  message: string
}

/**
 * A protein dose beyond any published recommendation. Not a dose of ours and not a clinical
 * opinion — a bound on a *typo*: `16` typed for `1.6` is a plausible-looking configuration
 * that produces protein-only plans through the energy cap in `macrosFor` rather than an
 * obvious failure. PRD line 789's own widest range tops out at 2.2 g/kg.
 */
const MAX_PROTEIN_G_PER_KG = 4

const finite = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value)

const positive = (field: string, value: unknown): NutritionRulesProblem | null =>
  finite(value) && value > 0 ? null : { field, message: 'must be a positive number' }

const nonNegative = (field: string, value: unknown): NutritionRulesProblem | null =>
  finite(value) && value >= 0 ? null : { field, message: 'must be a number of at least 0' }

/** For a value that is a share of something: strictly between 0 and 1. At 0 the rule it
 *  governs never fires, at 1 it consumes everything — both are a switched-off guard that
 *  looks configured. */
const fraction = (field: string, value: unknown): NutritionRulesProblem | null =>
  finite(value) && value > 0 && value < 1
    ? null
    : { field, message: 'must be a fraction greater than 0 and less than 1' }

const firstProblem = (
  ...problems: readonly (NutritionRulesProblem | null)[]
): NutritionRulesProblem | null => problems.find((problem) => problem !== null) ?? null

/**
 * What is wrong with these constants, or `null` if nothing is.
 *
 * **One implementation, called from two places on purpose**, exactly as `cycleRulesProblem`
 * is: `config.ts` runs it at boot so an operator is told at startup, and
 * `requireNutritionRules` runs it on every evaluation so a set assembled in code — a test
 * fixture, a future remote config — cannot get past it. Two copies of a safety check on
 * constants that decide how much a woman is told to eat is the drift this exists to prevent.
 *
 * The cross-field clauses are not style. Each one is a configuration that would produce a
 * *plausible-looking wrong answer* rather than an obvious failure, and #222's own Risks name
 * the direction: *"a bug that lowers a target reads as caution and is not."*
 *
 *  - An activity factor below 1 puts total expenditure under basal rate, so the basal floor
 *    binds for everyone and the band silently stops mattering.
 *  - Factors that do not strictly increase feed a more active woman less than a less active
 *    one — a sign error nothing downstream can see.
 *  - A positive `lose` adjustment, or a negative `gain` / `buildMuscle` one, is the same sign
 *    error one layer up, and it produces a complete, confident plan pointing the wrong way.
 *  - A raised fibre target below the everyday one means selecting *"Eat more vegetables and
 *    fibre"* lowers her fibre target.
 *  - A `minBmi`, `minCalorieKcal` or `maxPlanLossFraction` of zero is a guard that is present
 *    in the configuration and absent from the arithmetic.
 */
export const nutritionRulesProblem = (
  rules: NutritionRules | null,
): NutritionRulesProblem | null => {
  if (!rules) return { field: 'rules', message: 'no constants are configured' }

  const shape = firstProblem(
    positive('basalRate.perKg', rules.basalRate?.perKg),
    positive('basalRate.perCm', rules.basalRate?.perCm),
    nonNegative('basalRate.perYear', rules.basalRate?.perYear),
    nonNegative('basalRate.offset', rules.basalRate?.offset),
    ...ACTIVITY_BANDS.map((band) => {
      const value = rules.activityFactors?.[band]
      return finite(value) && value >= 1
        ? null
        : {
            field: `activityFactors.${band}`,
            message: 'must be at least 1, or expenditure falls below basal rate',
          }
    }),
    positive('proteinGramsPerKg.lose', rules.proteinGramsPerKg?.lose),
    positive('proteinGramsPerKg.buildMuscle', rules.proteinGramsPerKg?.buildMuscle),
    positive('proteinGramsPerKg.other', rules.proteinGramsPerKg?.other),
    fraction('fatMinFraction', rules.fatMinFraction),
    positive('fibreGrams', rules.fibreGrams),
    positive('fibreGramsRaised', rules.fibreGramsRaised),
    positive('minBmi', rules.minBmi),
    fraction('maxPlanLossFraction', rules.maxPlanLossFraction),
    positive('maxLossKgPerWeek', rules.maxLossKgPerWeek),
    fraction('maxLossFractionPerWeek', rules.maxLossFractionPerWeek),
    positive('minCalorieKcal', rules.minCalorieKcal),
    positive('kcalPerKgBodyMass', rules.kcalPerKgBodyMass),
  )
  if (shape) return shape

  for (const [field, value] of [
    ['lose', rules.proteinGramsPerKg.lose],
    ['buildMuscle', rules.proteinGramsPerKg.buildMuscle],
    ['other', rules.proteinGramsPerKg.other],
  ] as const) {
    if (value > MAX_PROTEIN_G_PER_KG) {
      return {
        field: `proteinGramsPerKg.${field}`,
        message: `must be at most ${MAX_PROTEIN_G_PER_KG} g per kg, beyond any published recommendation`,
      }
    }
  }

  for (let index = 1; index < ACTIVITY_BANDS.length; index += 1) {
    const band = ACTIVITY_BANDS[index]!
    const previous = ACTIVITY_BANDS[index - 1]!
    if (rules.activityFactors[band] <= rules.activityFactors[previous]) {
      return {
        field: `activityFactors.${band}`,
        message: `must be greater than activityFactors.${previous} (${rules.activityFactors[previous]}), or a more active band is fed less`,
      }
    }
  }

  if (!(rules.goalAdjustment?.lose < 0 && rules.goalAdjustment.lose > -1)) {
    return {
      field: 'goalAdjustment.lose',
      message: 'must be a negative fraction greater than -1: a deficit, and not the whole target',
    }
  }
  for (const field of ['gain', 'buildMuscle'] as const) {
    const value = rules.goalAdjustment[field]
    if (!(finite(value) && value > 0 && value < 1)) {
      return {
        field: `goalAdjustment.${field}`,
        message: 'must be a positive fraction less than 1: a surplus, and not a doubling',
      }
    }
  }

  if (rules.fibreGramsRaised < rules.fibreGrams) {
    return {
      field: 'fibreGramsRaised',
      message: `must be at least fibreGrams (${rules.fibreGrams}), or a fibre focus area lowers her fibre target`,
    }
  }
  return null
}

/** The constants, or a refusal. Mirrors `requireCycleRules` in `cycle.ts`. */
const requireNutritionRules = (rules: NutritionRules | null): NutritionRules => {
  const problem = nutritionRulesProblem(rules)
  if (problem) throw new NutritionRulesUnsetError(`${problem.field} ${problem.message}`)
  return rules as NutritionRules
}

// ── Conversions, which are not doses ───────────────────────────────────────────────────
// Everything below is a unit conversion or a calendar fact. None of it is configurable, for
// the reason `cycle.ts` hardcodes the milliseconds in a day: a constant nobody could tune to
// make a plan gentler is not a dose, and putting it in the environment would invite someone
// to try. The one energy constant that *is* an empirical assumption — kcal per kg of body
// mass — is configuration, and it is in `NutritionRules` above.

/** The Atwater general factors. *Source: FAO, Food energy — methods of analysis and
 *  conversion factors (FAO Food and Nutrition Paper 77, 2003), §3.1.* */
const KCAL_PER_G_PROTEIN = 4
const KCAL_PER_G_CARB = 4
const KCAL_PER_G_FAT = 9

const DAYS_PER_WEEK = 7
const CM_PER_M = 100

/**
 * `parseProfile`'s own accepted ranges (`index.ts`), restated because this module imports
 * nothing — the same shape as `MIN_ACCOUNT_AGE_YEARS` in `cycle.ts`, and pinned equal by a
 * case in `nutrition.test.ts` that reads both files.
 *
 * They are not doses and not a second opinion: they are the range the route edge already
 * enforces, held as the floor under a hand-edited document. Anything outside them throws
 * rather than computing — see `ImpossibleBodyMetricError`.
 */
const MIN_WEIGHT_KG = 30
const MAX_WEIGHT_KG = 200
const MIN_HEIGHT_CM = 120
const MAX_HEIGHT_CM = 220
const MIN_ACCOUNT_AGE_YEARS = 18

/**
 * The focus areas that raise the fibre target: 1 *"Eat more vegetables and fibre"* and 11
 * *"Reduce bloating, improve digestion"* (PRD line 793, A30).
 *
 * **Deliberately not configurable, and it must not become so** — the same rule, and the same
 * reason, as `PatternRule`'s "which signals count" in `dashboard-rules.ts`: these two numbers
 * are not a dose, they are *which question she answered*. A rule that could be pointed at
 * focus area 9 would raise her fibre target because she asked about alcohol. The two doses,
 * 25 g and 30 g, are configuration; which areas reach for them is meaning.
 */
const FIBRE_FOCUS_AREAS: readonly number[] = [1, 11]

// ── What the engine answers with ───────────────────────────────────────────────────────

/**
 * Which floor lifted the calorie target above the one the goal adjustment asked for, or
 * `null` when none did.
 *
 * **In the output rather than inferred by the caller.** S3's plan summary and the `sRate`
 * card have to say *why* the timeline is longer than the arithmetic suggests, and a caller
 * that re-derived it from the numbers could reach a different answer than the one that was
 * actually applied.
 */
export type CalorieClamp = 'basal-rate' | 'absolute-floor' | 'rate-cap'

export interface MacroTargets {
  proteinG: number
  /** Never below `fatMinFraction` of the calorie target. PRD line 791: *"This is a hard
   *  floor, not a default."* */
  fatG: number
  /** The remainder (PRD line 792), and never negative. */
  carbG: number
  fibreG: number
  /**
   * Whether protein was reduced below `proteinGramsPerKg × weight` because the fat floor and
   * the clamped calorie target left no room for it.
   *
   * **The fat floor is what does not move.** PRD line 791 says why in the same breath as the
   * floor itself: *"Sustained low fat intake is associated with menstrual disruption, and an
   * adviser built for women must not produce a plan that causes it."* Carbohydrate is the
   * remainder and a negative remainder is not a food, so protein — the one macronutrient the
   * PRD gives as a target rather than as a floor — is what yields, and the fact is reported
   * rather than absorbed. See `macrosFor` for when this is reachable.
   */
  proteinLimitedByEnergy: boolean
}

export interface WeightPlan {
  targetWeightKg: number
  /**
   * Whole weeks to reach the target at the pace the **clamped** calorie target implies,
   * rounded up — never promise sooner than the arithmetic says.
   *
   * `null` when the plan does not move toward the target at all: every clamp is a floor, so a
   * deficit can be clamped away entirely (a very small woman whose expenditure is under the
   * absolute calorie floor), and a goal whose target sits the other side of her current
   * weight never approaches it. Both are honest answers and neither is a number.
   */
  timelineWeeks: number | null
  /** Signed kg per week the clamped target implies: negative while losing. Derived from
   *  `calorieTargetKcal − tdeeKcal`, so it cannot disagree with the target. */
  paceKgPerWeek: number
}

export interface DailyTargets {
  /** Mifflin-St Jeor, rounded **up** — an estimate for a population, not a measurement of
   *  her, and up is the direction that cannot under-feed. */
  bmrKcal: number
  /** `bmrKcal × the band's factor`. */
  tdeeKcal: number
  /** The highest floor that applies, whether or not it binds: the higher of basal rate, the
   *  absolute floor, and (for a loss goal) the calories the rate cap leaves. */
  calorieFloorKcal: number
  /** Never below `calorieFloorKcal`. This is the number every other field follows from. */
  calorieTargetKcal: number
  /** Which floor lifted it, or `null` when the goal adjustment's own number stood. */
  boundBy: CalorieClamp | null
  macros: MacroTargets
  /** `null` for *Maintain my weight* and *Eat better without changing my weight* — PRD line
   *  745 skips Step 5 for them, so there is no weight target and no deficit to describe. */
  weightPlan: WeightPlan | null
}

/** Why a target weight was not accepted. Both refusals carry a value to offer — canvas
 *  `sCap`: *"a message and an offered value, not a lock"*. */
export type TargetRefusalReason = 'below-bmi-floor' | 'below-plan-cap'

export interface TargetRefusal {
  reason: TargetRefusalReason
  /**
   * The lowest weight this plan may target: the **higher** of the BMI floor and the per-plan
   * cap, rounded up to 0.1 kg.
   *
   * One number rather than one per rule, because an offer the guard would itself refuse is
   * not an offer. Canvas `sGuard` offers 52.2 kg to a 73 kg woman at 168 cm — below her
   * 62.1 kg per-plan cap, so tapping it would be refused again — and rounds 52.2144 down,
   * below the BMI floor it is quoting. `reason` says which rule set the number, so S3 still
   * chooses between `sGuard`'s copy and `sCap`'s; the value it offers is always one that is
   * accepted.
   */
  lowestSupportedWeightKg: number
}

export type NutritionPlan =
  | { kind: 'refused'; refusal: TargetRefusal }
  | { kind: 'targets'; targets: DailyTargets }

// ── The maths ──────────────────────────────────────────────────────────────────────────

const requireRange = (field: string, value: number, min: number, max: number): void => {
  if (!(finite(value) && value >= min && value <= max)) {
    throw new ImpossibleBodyMetricError(field, `${min}–${max}`)
  }
}

/** Her target weight, or `null` for the two goals that have none — the one place the input
 *  union is taken apart, so PRD line 745's "Step 5 is skipped" is a narrowing rather than a
 *  condition repeated at every use. A predicate rather than `?? null`, so a weight-change
 *  goal arriving without a target reaches `requireRange` and throws, instead of quietly
 *  becoming a plan with no weight target at all. */
const isWeightChange = (input: NutritionInput): input is WeightChangeInput =>
  input.goal !== 'maintain' && input.goal !== 'eatBetter'

const targetWeightOf = (input: NutritionInput): number | null =>
  isWeightChange(input) ? input.targetWeightKg : null

const basalRateKcal = (input: NutritionInput, rules: NutritionRules): number => {
  const { perKg, perCm, perYear, offset } = rules.basalRate
  return perKg * input.weightKg + perCm * input.heightCm - perYear * input.ageYears - offset
}

/** PRD line 780: maintain and eat better take **no adjustment**, which is the absence of a
 *  dose rather than a configured zero. Total over the closed goal union — no default branch,
 *  so a sixth goal is a compile error and never a silently unadjusted plan. */
const adjustmentFor = (goal: NutritionGoal, rules: NutritionRules): number => {
  const adjustments: Record<NutritionGoal, number> = {
    lose: rules.goalAdjustment.lose,
    gain: rules.goalAdjustment.gain,
    buildMuscle: rules.goalAdjustment.buildMuscle,
    maintain: 0,
    eatBetter: 0,
  }
  return adjustments[goal]
}

const proteinPerKgFor = (goal: NutritionGoal, rules: NutritionRules): number => {
  const perKg: Record<NutritionGoal, number> = {
    lose: rules.proteinGramsPerKg.lose,
    buildMuscle: rules.proteinGramsPerKg.buildMuscle,
    gain: rules.proteinGramsPerKg.other,
    maintain: rules.proteinGramsPerKg.other,
    eatBetter: rules.proteinGramsPerKg.other,
  }
  return perKg[goal]
}

/**
 * The lowest weight a single plan may target, and which of A29's two rules set it.
 *
 * Both rules are checked for every weight-change goal, not only for *lose*: PRD line 753
 * states the BMI floor unconditionally, and a woman already under it who wants to gain to a
 * weight that is still under it is exactly the case a "loss only" reading would miss. The
 * per-plan cap can only bind downward, so it is inert for a target above her current weight
 * without needing a branch to say so.
 */
const lowestSupportedWeight = (
  input: NutritionInput,
  rules: NutritionRules,
): { exactKg: number; offeredKg: number; reason: TargetRefusalReason } => {
  const heightM = input.heightCm / CM_PER_M
  const bmiFloorKg = rules.minBmi * heightM * heightM
  const planCapKg = input.weightKg * (1 - rules.maxPlanLossFraction)
  const exactKg = Math.max(bmiFloorKg, planCapKg)
  return {
    exactKg,
    // Up to the next 0.1 kg, never down: a value rounded down is a value this same guard
    // refuses, which is how an offer becomes a second refusal.
    offeredKg: Math.ceil(exactKg * 10) / 10,
    reason: bmiFloorKg >= planCapKg ? 'below-bmi-floor' : 'below-plan-cap',
  }
}

/**
 * The floors on the calorie target, each with the clamp it is.
 *
 * The order is not by value — it is the order `planDailyTargets` reads when two floors tie,
 * which puts the one that is about her body ahead of the two that are about the product. Every
 * tied floor is binding; only the naming differs.
 *
 * **The rate cap is a floor on calories, not a ceiling on the pace.** PRD line 754 caps the
 * rate of loss at 0.5 kg per week or 1% of body weight, whichever is lower; the only lever a
 * plan has is food, so respecting that cap means *raising* the target and letting the
 * timeline run longer — canvas `sRate`, *"Eva extends the timeline instead of cutting
 * calories"*. It applies to loss alone, which is what PRD line 754 caps.
 *
 * **Two of the three floors cannot bind at A30's own numbers, and that is worth knowing
 * rather than discovering.** At −15% and the lowest configured factor the target is
 * `1.2 × 0.85 = 1.02` of basal rate, so basal rate sits just below it; at −20%, the other
 * end of PRD line 779's range, it binds. And the rate cap's *1% of body weight* arm is the
 * lower of its two arms only under 50 kg, while a 15% deficit only outruns 1% a week when
 * expenditure is over about 73 times her weight in kg — a combination that needs someone
 * light and tall enough that the BMI floor refuses every loss target she could set. Both
 * floors live in the arithmetic rather than in a reviewer's head precisely because the doses
 * around them are configuration, and `nutrition.test.ts` exercises each of them through the
 * configuration that makes it bind.
 */
const calorieFloors = (
  input: NutritionInput,
  rules: NutritionRules,
  bmrKcal: number,
  tdeeKcal: number,
): readonly { kcal: number; clamp: CalorieClamp }[] => {
  const floors: { kcal: number; clamp: CalorieClamp }[] = [
    { kcal: bmrKcal, clamp: 'basal-rate' },
    { kcal: Math.ceil(rules.minCalorieKcal), clamp: 'absolute-floor' },
  ]
  if (input.goal === 'lose') {
    const kgPerWeek = Math.min(
      rules.maxLossKgPerWeek,
      rules.maxLossFractionPerWeek * input.weightKg,
    )
    floors.push({
      kcal: Math.ceil(tdeeKcal - (kgPerWeek * rules.kcalPerKgBodyMass) / DAYS_PER_WEEK),
      clamp: 'rate-cap',
    })
  }
  return floors
}

/**
 * Protein by body weight, fat at its floor, carbohydrate as the remainder, fibre by focus
 * area — PRD lines 788–793, in that order, because the order is the rule.
 *
 * Every gram is a whole number and every rounding goes the way that cannot breach a floor:
 * fat rounds **up** so `fatG × 9` is never under the fat minimum, and carbohydrate rounds
 * **down** so the three macronutrients never claim more energy than the target holds.
 *
 * **When protein plus the fat floor would overrun the target, protein yields.** Within the
 * accepted input range that cannot happen — the overrun needs a calorie target below about
 * nine times her weight in kg, and the basal-rate and 1,200 kcal floors keep it above that
 * everywhere between 30–200 kg and 120–220 cm. It is reachable through *configuration*,
 * which is the point: these are doses a reviewer will revise, and the behaviour at the edge
 * is a decision (#222) rather than a rounding accident. Shaving the fat floor is the
 * tempting fix and PRD line 791 forbids it by name.
 */
const macrosFor = (
  input: NutritionInput,
  rules: NutritionRules,
  calorieTargetKcal: number,
): MacroTargets => {
  const fatG = Math.ceil((rules.fatMinFraction * calorieTargetKcal) / KCAL_PER_G_FAT)
  const wantedProteinG = Math.round(proteinPerKgFor(input.goal, rules) * input.weightKg)
  const energyLeftForProtein = Math.max(0, calorieTargetKcal - fatG * KCAL_PER_G_FAT)
  const proteinG = Math.min(wantedProteinG, Math.floor(energyLeftForProtein / KCAL_PER_G_PROTEIN))
  const remainderKcal = Math.max(
    0,
    calorieTargetKcal - proteinG * KCAL_PER_G_PROTEIN - fatG * KCAL_PER_G_FAT,
  )
  return {
    proteinG,
    fatG,
    carbG: Math.floor(remainderKcal / KCAL_PER_G_CARB),
    fibreG: input.focusAreas.some((area) => FIBRE_FOCUS_AREAS.includes(area))
      ? rules.fibreGramsRaised
      : rules.fibreGrams,
    proteinLimitedByEnergy: proteinG < wantedProteinG,
  }
}

/**
 * The whole of S2: her metrics and her goal in, the day's targets out.
 *
 * Deterministic and total — the same input always produces the same answer, and the answer is
 * computed here rather than cached anywhere, which is what makes PRD §Recalculation triggers
 * a property of the design instead of a job someone has to remember to run. The caller reads,
 * this derives.
 *
 * Throws `NutritionRulesUnsetError` when the constants are missing or unusable, and
 * `ImpossibleBodyMetricError` when a metric is outside the range the route edge already
 * enforces. Neither is a refusal the user can act on; an unsupported *target weight* is, and
 * that comes back as `{ kind: 'refused' }` with the value to offer her.
 */
export const planDailyTargets = (
  input: NutritionInput,
  rules: NutritionRules | null,
): NutritionPlan => {
  const settings = requireNutritionRules(rules)
  requireRange('weightKg', input.weightKg, MIN_WEIGHT_KG, MAX_WEIGHT_KG)
  requireRange('heightCm', input.heightCm, MIN_HEIGHT_CM, MAX_HEIGHT_CM)
  if (!(finite(input.ageYears) && input.ageYears >= MIN_ACCOUNT_AGE_YEARS)) {
    throw new ImpossibleBodyMetricError('ageYears', `at least ${MIN_ACCOUNT_AGE_YEARS}`)
  }

  // Narrowed once, here, rather than branched on five times: `targetWeightOf` is the only
  // place the two-armed input is taken apart, so "goals 4 and 5 have no weight target" is
  // read off the type instead of re-tested.
  const targetWeightKg = targetWeightOf(input)
  if (targetWeightKg !== null) {
    requireRange('targetWeightKg', targetWeightKg, MIN_WEIGHT_KG, MAX_WEIGHT_KG)
    const lowest = lowestSupportedWeight(input, settings)
    if (targetWeightKg < lowest.exactKg) {
      return {
        kind: 'refused',
        refusal: { reason: lowest.reason, lowestSupportedWeightKg: lowest.offeredKg },
      }
    }
  }

  const bmrKcal = Math.ceil(basalRateKcal(input, settings))
  const tdeeKcal = Math.round(bmrKcal * settings.activityFactors[input.activityBand])
  const requestedKcal = Math.round(tdeeKcal * (1 + adjustmentFor(input.goal, settings)))

  // The highest floor wins, and ties are broken by the order `calorieFloors` returns —
  // deterministic, and it names the one that is about her body before the two that are
  // about the product. Every one of them is binding when they tie; only the naming differs.
  const floors = calorieFloors(input, settings, bmrKcal, tdeeKcal)
  const calorieFloorKcal = Math.max(...floors.map((floor) => floor.kcal))
  const calorieTargetKcal = Math.max(requestedKcal, calorieFloorKcal)
  const boundBy =
    calorieTargetKcal > requestedKcal
      ? floors.find((floor) => floor.kcal === calorieFloorKcal)!.clamp
      : null

  // The pace the **clamped** target implies, and the timeline that follows from it. Nothing
  // downstream re-derives either from the requested number, which is what makes "the
  // timeline extends instead of the target dropping" unconstructably true rather than
  // remembered.
  const paceKgPerWeek =
    ((calorieTargetKcal - tdeeKcal) * DAYS_PER_WEEK) / settings.kcalPerKgBodyMass
  const weightPlan =
    targetWeightKg === null
      ? null
      : {
          targetWeightKg,
          paceKgPerWeek,
          timelineWeeks: weeksTo(targetWeightKg - input.weightKg, paceKgPerWeek),
        }

  return {
    kind: 'targets',
    targets: {
      bmrKcal,
      tdeeKcal,
      calorieFloorKcal,
      calorieTargetKcal,
      boundBy,
      macros: macrosFor(input, settings, calorieTargetKcal),
      weightPlan,
    },
  }
}

/** Whole weeks, rounded up, or `null` when this pace never gets there — see `WeightPlan`. */
const weeksTo = (deltaKg: number, paceKgPerWeek: number): number | null => {
  if (deltaKg === 0) return 0
  if (paceKgPerWeek === 0 || Math.sign(paceKgPerWeek) !== Math.sign(deltaKg)) return null
  return Math.ceil(deltaKg / paceKgPerWeek)
}

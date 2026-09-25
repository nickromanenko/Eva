import { FieldValue } from 'firebase-admin/firestore'
import { firestore } from './firebase'
import type { NutritionGoal, SteadyGoal, WeightChangeGoal } from './nutrition'

/**
 * The nutrition profile (S1 of #25, #221): her answers to the Nutrition coach's setup flow,
 * and how far through it she is. The only module that touches `users/{uid}/nutrition/`.
 *
 * **Its own document, not a map on `users/{uid}`** — decided on #221. `GET /me` serves
 * `User` verbatim, so a goal and a target weight on that document would reach every caller
 * of `/me`, including the one that only wanted an address; the `tokenVersion` precedent
 * (ARCHITECTURE §4) is the argument for a fact with its own owner and its own route.
 *
 * **The field list is exactly the setup answers, and that is a rule rather than a
 * snapshot**: goal (PRD Step 1), focus areas (Step 2), meal pattern (Step 3), target weight
 * (Step 5), the hide-numbers preference (#212, decided onto this document by #221), and the
 * setup-progress marker Edge case 1 needs. Step 4 stores nothing here — body metrics are the
 * Sign Up profile's, confirmed rather than re-asked. There is **no field for disordered
 * eating** (#212: Eva holds none) and **none for the "Meal fit" score** (S8, gated on #26);
 * `nutrition-profile.test.ts` pins the key set so that one added by reflex fails the suite.
 *
 * **Partial is a first-class state, and it is never readable as complete.** PRD line 677:
 * *"Nothing is calculated, displayed or suggested from partial data."* Edge case 1: *"progress
 * is saved and the user resumes where she left off."* The two are one field apart, so
 * completeness has exactly one definition — `completedSetup` — and the served `complete` flag
 * is that function's answer rather than a stored boolean anything could set.
 *
 * Never log the document, a goal, a focus area or a target weight: each is a health fact
 * about a named request (GUARDRAILS 12). This module writes no log line at all.
 */

// ── The vocabulary: codes, not labels, and permanent ───────────────────────────────────
//
// The rule `users.ts` states for medications and conditions, and for the same reason: the
// client renders a label, the document stores a code, and editing the wording must never be
// a data migration. A code is never reused for a different meaning; one that stops being
// offered is retired by the client, never deleted from here while a document can hold it.

/**
 * The goal (PRD Step 1), as the engine's own `NutritionGoal` codes — one vocabulary for the
 * answer and the arithmetic, so S3 hands the stored code to `planDailyTargets` untranslated.
 *
 * | Code | PRD Step 1 |
 * |---|---|
 * | `lose` | 1. Lose weight |
 * | `gain` | 2. Gain weight |
 * | `buildMuscle` | 3. Build muscle |
 * | `maintain` | 4. Maintain my weight |
 * | `eatBetter` | 5. Eat better without changing my weight |
 */
export const NUTRITION_GOAL_CODES = [
  'lose',
  'gain',
  'buildMuscle',
  'maintain',
  'eatBetter',
] as const satisfies readonly NutritionGoal[]

/** Compile-time: every goal the engine knows is a code the route accepts. `satisfies` above
 *  catches a code the engine does not know; this catches the reverse — a goal added to
 *  `nutrition.ts` and not here fails the constraint. */
type Unlisted<T extends never> = T
export type UnlistedGoal = Unlisted<Exclude<NutritionGoal, (typeof NUTRITION_GOAL_CODES)[number]>>

/** PRD Step 1 options 1–3: the goals Step 5 asks a target weight for (line 745). */
export const WEIGHT_CHANGE_GOAL_CODES = [
  'lose',
  'gain',
  'buildMuscle',
] as const satisfies readonly WeightChangeGoal[]

export const isWeightChangeGoal = (goal: NutritionGoal): goal is WeightChangeGoal =>
  (WEIGHT_CHANGE_GOAL_CODES as readonly string[]).includes(goal)

/**
 * The focus areas (PRD Step 2), in the PRD's order. The number is the PRD's item number,
 * and `FOCUS_AREA_PRD_ITEM` below holds it as data — the engine reads focus areas by that
 * number (`FIBRE_FOCUS_AREAS` in `nutrition.ts`), so the mapping is a total table rather
 * than an array index a later insertion could shift.
 *
 * |  # | Code | PRD Step 2 |
 * |---|---|---|
 * |  1 | `vegetablesAndFibre` | Eat more vegetables and fibre |
 * |  2 | `lessUltraProcessed` | Eat less fast food and ultra-processed food |
 * |  3 | `ironDeficiencyAnaemia` | Fight iron deficiency anaemia |
 * |  4 | `moreProtein` | Eat more protein |
 * |  5 | `lessSugar` | Cut down on sugar |
 * |  6 | `regularMeals` | Eat more regularly, stop skipping meals |
 * |  7 | `moreWater` | Drink more water |
 * |  8 | `lessCaffeine` | Reduce caffeine |
 * |  9 | `lessAlcohol` | Reduce alcohol |
 * | 10 | `boneHealth` | Support bone health (calcium and vitamin D) |
 * | 11 | `digestion` | Reduce bloating, improve digestion |
 * | 12 | `pmsCravings` | Manage PMS cravings |
 * | 13 | `eatEnoughOnPeriod` | Eat enough around my period |
 * | 14 | `lessSalt` | Reduce salt |
 * | 15 | `vegetarianVeganBalance` | Balance a vegetarian or vegan diet |
 * | 16 | `steadyEnergy` | Improve energy, reduce afternoon crashes |
 * | 17 | `skin` | Support skin |
 *
 * Item 18, *"Support pregnancy nutrition"*, is offered only in Pregnancy mode, which S12
 * owns; it is added here — as a new code, never a reused one — when that mode exists.
 */
export const FOCUS_AREA_CODES = [
  'vegetablesAndFibre',
  'lessUltraProcessed',
  'ironDeficiencyAnaemia',
  'moreProtein',
  'lessSugar',
  'regularMeals',
  'moreWater',
  'lessCaffeine',
  'lessAlcohol',
  'boneHealth',
  'digestion',
  'pmsCravings',
  'eatEnoughOnPeriod',
  'lessSalt',
  'vegetarianVeganBalance',
  'steadyEnergy',
  'skin',
] as const

export type FocusAreaCode = (typeof FOCUS_AREA_CODES)[number]

/** Each focus area's PRD item number — what `nutrition.ts` reads focus areas as. A `Record`
 *  over the codes, so a code added without its number is a compile error. */
export const FOCUS_AREA_PRD_ITEM: Readonly<Record<FocusAreaCode, number>> = {
  vegetablesAndFibre: 1,
  lessUltraProcessed: 2,
  ironDeficiencyAnaemia: 3,
  moreProtein: 4,
  lessSugar: 5,
  regularMeals: 6,
  moreWater: 7,
  lessCaffeine: 8,
  lessAlcohol: 9,
  boneHealth: 10,
  digestion: 11,
  pmsCravings: 12,
  eatEnoughOnPeriod: 13,
  lessSalt: 14,
  vegetarianVeganBalance: 15,
  steadyEnergy: 16,
  skin: 17,
}

/**
 * PRD line 726: *"The 3-item cap is deliberate."* Enforced as a refusal at the route edge,
 * never as a truncation — canvas `s2`: *"Eva never silently swaps the oldest choice out"*.
 */
export const MAX_FOCUS_AREAS = 3

/** PRD Step 3 item 1: *"Meals per day: 2 / 3 / 4 / 5"* — values, not labels. */
export const MEALS_PER_DAY = [2, 3, 4, 5] as const

export type MealsPerDay = (typeof MEALS_PER_DAY)[number]

/**
 * The setup-progress marker (Edge case 1): the step she resumes at, as a code. The PRD's
 * five steps in order, then `done` — the one value that asserts the setup is finished, and
 * which `saveNutritionProfile` refuses while any required answer is missing.
 *
 * A code rather than a step number so S3 can reorder or insert a screen — the hide-numbers
 * question (#212) is asked somewhere on the path and has no screen of its own yet — without
 * the stored marker changing meaning.
 */
export const SETUP_STEP_CODES = [
  'goal',
  'focusAreas',
  'mealPattern',
  'bodyMetrics',
  'targetWeight',
  'done',
] as const

export type SetupStep = (typeof SETUP_STEP_CODES)[number]

// ── The shapes ─────────────────────────────────────────────────────────────────────────

/** PRD Step 3. `mealTimes` is item 3, optional: one `HH:mm` wall clock per meal, used later
 *  for reminders and spacing advice — a wall clock, never an instant, as event times are. */
export interface MealPattern {
  mealsPerDay: MealsPerDay
  snacks: boolean
  mealTimes: string[] | null
}

/**
 * The nutrition profile as served. Every answer is `null` until she gives it — `focusAreas`
 * excepted, which is optional in the PRD and so is `[]` both unanswered and answered "none".
 *
 * `complete` is derived, never stored: `completedSetup(…) !== null`. See the header.
 */
export interface NutritionProfile {
  goal: NutritionGoal | null
  focusAreas: FocusAreaCode[]
  mealPattern: MealPattern | null
  /** Kilograms, always (ARCHITECTURE §5, #82). Only ever set with a weight-change goal. */
  targetWeightKg: number | null
  /**
   * The hide-numbers preference (#212, placed here by #221): hide calorie totals, macro
   * grams, weight targets and deficit language. `null` until she has answered it.
   *
   * **Only she changes it**, through the setup route. A request that does not mention it
   * leaves it exactly as it was, so no write can silently turn the numbers back on — #212's
   * "the worst version of this".
   */
  hideNumbers: boolean | null
  step: SetupStep
  complete: boolean
}

/** The answers a PATCH carries, already validated at the route edge. An absent key leaves
 *  the stored answer alone; `null` clears an answer that can be un-given. */
export interface NutritionProfilePatch {
  goal?: NutritionGoal | null
  focusAreas?: FocusAreaCode[]
  mealPattern?: MealPattern | null
  targetWeightKg?: number | null
  hideNumbers?: boolean
  step?: SetupStep
}

/** The fields of the profile a refusal can name. */
export type NutritionProfileField = keyof Omit<NutritionProfile, 'complete'>

/**
 * A finished setup, in the shape the targets engine takes it — the only place a goal and a
 * target weight come out *paired*. Goals 4 and 5 carry no target weight in the type, exactly
 * as `NutritionInput` has it, so S3 cannot assemble an engine input from a partial profile
 * without first getting one of these.
 */
export type CompletedNutritionSetup = {
  focusAreas: FocusAreaCode[]
  mealPattern: MealPattern
  hideNumbers: boolean
} & (
  | { goal: WeightChangeGoal; targetWeightKg: number }
  | { goal: SteadyGoal; targetWeightKg?: never }
)

// ── Completeness: one definition ───────────────────────────────────────────────────────

/** The first required answer she has not given, or `null` when there is none — the same
 *  rule `completedSetup` applies, spelled so a refusal can name the field; the test file
 *  pins the two against every combination. Focus areas are optional (PRD Step 2) and the
 *  target weight is required only for goals 1–3. */
export const firstMissingAnswer = (
  profile: Omit<NutritionProfile, 'complete'>,
): NutritionProfileField | null => {
  if (profile.goal === null) return 'goal'
  if (profile.mealPattern === null) return 'mealPattern'
  if (isWeightChangeGoal(profile.goal) && profile.targetWeightKg === null) return 'targetWeightKg'
  if (profile.hideNumbers === null) return 'hideNumbers'
  return null
}

/**
 * The setup as the engine may read it, or `null` while it is partial — **the** definition
 * of complete. She has marked it `done` *and* every required answer is present; either alone
 * is not enough, so a hand-edited `step` cannot promote four answers of five.
 */
export const completedSetup = (
  profile: Omit<NutritionProfile, 'complete'>,
): CompletedNutritionSetup | null => {
  if (profile.step !== 'done') return null
  const { goal, focusAreas, mealPattern, targetWeightKg, hideNumbers } = profile
  if (goal === null || mealPattern === null || hideNumbers === null) return null
  const shared = { focusAreas, mealPattern, hideNumbers }
  if (isWeightChangeGoal(goal)) {
    return targetWeightKg === null ? null : { ...shared, goal, targetWeightKg }
  }
  return { ...shared, goal }
}

// ── Storage ────────────────────────────────────────────────────────────────────────────

const PROFILE_DOC = 'profile'

const documents = (uid: string) => firestore.collection('users').doc(uid).collection('nutrition')

const isOneOf = <T extends string | number>(value: unknown, codes: readonly T[]): value is T =>
  (codes as readonly unknown[]).includes(value)

/**
 * A stored document read as *this* schema. Fails closed, field by field: a value that is not
 * in the vocabulary is served as unanswered, so a hand-edited or future-schema document can
 * only ever read as *less* complete than it claims — never more. Keys beyond the list are
 * not served.
 */
const toProfile = (data: FirebaseFirestore.DocumentData): NutritionProfile => {
  const pattern = data.mealPattern
  const mealPattern: MealPattern | null =
    pattern !== null &&
    typeof pattern === 'object' &&
    isOneOf(pattern.mealsPerDay, MEALS_PER_DAY) &&
    typeof pattern.snacks === 'boolean'
      ? {
          mealsPerDay: pattern.mealsPerDay,
          snacks: pattern.snacks,
          mealTimes: Array.isArray(pattern.mealTimes) ? [...pattern.mealTimes] : null,
        }
      : null
  const answers: Omit<NutritionProfile, 'complete'> = {
    goal: isOneOf(data.goal, NUTRITION_GOAL_CODES) ? data.goal : null,
    focusAreas: Array.isArray(data.focusAreas)
      ? data.focusAreas.filter((area: unknown): area is FocusAreaCode =>
          isOneOf(area, FOCUS_AREA_CODES),
        )
      : [],
    mealPattern,
    targetWeightKg:
      typeof data.targetWeightKg === 'number' && Number.isFinite(data.targetWeightKg)
        ? data.targetWeightKg
        : null,
    hideNumbers: typeof data.hideNumbers === 'boolean' ? data.hideNumbers : null,
    step: isOneOf(data.step, SETUP_STEP_CODES) ? data.step : 'goal',
  }
  return { ...answers, complete: completedSetup(answers) !== null }
}

/** Her nutrition profile, or `null` when she has not started setup. */
export const getNutritionProfile = async (uid: string): Promise<NutritionProfile | null> => {
  const snapshot = await documents(uid).doc(PROFILE_DOC).get()
  return snapshot.exists ? toProfile(snapshot.data()!) : null
}

export type SaveNutritionProfileResult =
  | { ok: true; profile: NutritionProfile }
  /**
   * Refused on what is *stored*, which the route edge cannot see — the one kind of rule this
   * module decides, the way `events.ts` decides "this day is already logged":
   *
   * - `required` — `step: 'done'` with that answer missing, or an edit that would leave a
   *   finished setup missing it. A finished setup stays finished, or it is not finished.
   * - `not-for-goal` — a target weight sent while the goal is one that has none, or is not
   *   chosen yet (PRD line 745: Step 5 is skipped entirely for goals 4 and 5).
   */
  | { ok: false; field: NutritionProfileField; rule: 'required' | 'not-for-goal' }

/**
 * Applies one step's answers to her nutrition profile, creating it on the first write.
 *
 * An absent key is left alone; the result is checked whole, against what was already
 * stored, in a transaction — so two devices answering different steps cannot each pass a
 * check the other then breaks. Nothing is written when the answer is a refusal.
 *
 * **Changing the goal to one with no target weight — or clearing it — clears the stored
 * target weight.** Step 5 is skipped for goals 4 and 5, so a target left behind would be an
 * answer to a question she was not asked; switching back to a weight-change goal asks it
 * again.
 */
export const saveNutritionProfile = async (
  uid: string,
  patch: NutritionProfilePatch,
): Promise<SaveNutritionProfileResult> => {
  const ref = documents(uid).doc(PROFILE_DOC)
  return firestore.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref)
    const { complete: _, ...before } = snapshot.exists ? toProfile(snapshot.data()!) : toProfile({})
    const after: Omit<NutritionProfile, 'complete'> = { ...before, ...patch }

    if (after.goal === null || !isWeightChangeGoal(after.goal)) {
      if (patch.targetWeightKg !== undefined && patch.targetWeightKg !== null) {
        return { ok: false, field: 'targetWeightKg', rule: 'not-for-goal' }
      }
      after.targetWeightKg = null
    }
    if (after.step === 'done') {
      const missing = firstMissingAnswer(after)
      if (missing !== null) return { ok: false, field: missing, rule: 'required' }
    }

    tx.set(
      ref,
      {
        ...after,
        updatedAt: FieldValue.serverTimestamp(),
        ...(snapshot.exists ? {} : { createdAt: FieldValue.serverTimestamp() }),
      },
      { merge: true },
    )
    return { ok: true, profile: { ...after, complete: completedSetup(after) !== null } }
  })
}

/** Firestore's ceiling on a batched write, as `events.ts` and `today.ts` use it. */
const DELETE_BATCH = 500

/**
 * Hard-deletes her nutrition profile — its half of account deletion (#8). Every document in
 * the subcollection, not only `profile`, so a document a later slice adds here cannot be
 * the one thing that outlives the account. Before the user document goes, for the reason
 * `DELETE /me` gives: a subcollection outlives its parent in Firestore.
 */
export const deleteNutritionProfile = async (uid: string): Promise<number> => {
  let removed = 0
  for (;;) {
    const snapshot = await documents(uid).limit(DELETE_BATCH).get()
    if (snapshot.empty) return removed
    const batch = firestore.batch()
    for (const doc of snapshot.docs) batch.delete(doc.ref)
    await batch.commit()
    removed += snapshot.size
  }
}

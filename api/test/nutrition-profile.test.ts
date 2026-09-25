import {
  afterAll,
  afterEach,
  beforeEach,
  describe,
  expect,
  setDefaultTimeout,
  spyOn,
  test,
} from 'bun:test'
import { Timestamp } from 'firebase-admin/firestore'
import { mintToken } from '../src/auth'
import { adminAuth, firestore } from '../src/firebase'
import { default as server } from '../src/index'
import { ACTIVITY_BANDS, type ActivityFactors } from '../src/nutrition'
import {
  FOCUS_AREA_CODES,
  FOCUS_AREA_PRD_ITEM,
  completedSetup,
  firstMissingAnswer,
  type MealPattern,
  type NutritionProfile,
} from '../src/nutrition-profile'
import { ACTIVITY_BAND_CODES, type ActivityBand, storedLifestyle } from '../src/users'
import { isRequestLine } from './support/request-line'
import { testEmail } from './support/test-email'

/**
 * Nutrition S1 (#221): the activity band as a code, and the nutrition profile document.
 *
 * Every route is driven **in-process** through `server.fetch`, against the real Firestore —
 * the seam `account-deletion.test.ts` uses — so this file binds no port. Accounts are written
 * directly rather than signed up: what is under test is the profile, not how the account got
 * there, and a sign-up would spend the shared per-IP budget and send an email.
 */
setDefaultTimeout(20_000)

const SRC = `${import.meta.dir}/../src`

/** Every `.ts` file under `src/`, at any depth, as `[relative path, source]`. */
const sources = async (): Promise<[string, string][]> => {
  const out: [string, string][] = []
  for await (const file of new Bun.Glob('**/*.ts').scan(SRC)) {
    out.push([file, await Bun.file(`${SRC}/${file}`).text()])
  }
  return out
}

const stripComments = (source: string): string =>
  source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')

const createdUids: string[] = []

const userDoc = (uid: string) => firestore.collection('users').doc(uid)
const nutritionDoc = (uid: string) => userDoc(uid).collection('nutrition').doc('profile')

/** An activated account with a collect consent on record (#86), and a session for it. With
 *  `auth`, a real Auth user too — `DELETE /me` asks Auth for the address, and since #117 every
 *  route that serves `User` (`GET /me`, `PUT /me/questionnaire`) reads Auth's federated
 *  providers beside the document and answers 401 without an Auth user. */
const account = async (
  opts: { consent?: boolean; profile?: Record<string, unknown> | null; auth?: boolean } = {},
): Promise<{ uid: string; token: string }> => {
  const email = testEmail()
  const uid = opts.auth
    ? (await adminAuth.createUser({ email, password: 'correct-horse-8', emailVerified: true })).uid
    : `e2e-nutrition-${crypto.randomUUID()}`
  createdUids.push(uid)
  await userDoc(uid).set({
    email,
    authProviders: ['password'],
    questionnaireCompleted: opts.profile != null,
    profile: opts.profile ?? null,
    activatedAt: Timestamp.now(),
    consent:
      opts.consent === false
        ? {}
        : { collect: { version: '2026-08-30', at: Timestamp.now(), withdrawnAt: null } },
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
  })
  return { uid, token: await mintToken(uid, email, 0) }
}

const call = async (token: string, method: string, path: string, body?: unknown) => {
  const res = await server.fetch(
    new Request(`http://api.test${path}`, {
      method,
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
  )
  return { status: res.status, body: (await res.json()) as Record<string, any> }
}

const patch = (token: string, body: unknown) => call(token, 'PATCH', '/me/nutrition/profile', body)
const read = (token: string) => call(token, 'GET', '/me/nutrition/profile')

afterAll(async () => {
  for (const uid of createdUids) {
    for (const doc of await userDoc(uid).collection('nutrition').listDocuments()) {
      await doc.delete().catch(() => {})
    }
    await userDoc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
})

/** Every console line written while a case runs. GUARDRAILS 12: a goal, a focus area or a
 *  target weight in a log line is a health fact about a named request — and nothing on
 *  these routes has any reason to log at all, so the assertion is "nothing", not "nothing
 *  that looks sensitive". The one exception is the server edge's own per-request line
 *  (#263), which every route writes and none of these controls; `isRequestLine` admits it
 *  only in its exact five-field shape. */
let logged: string[] = []
const spies: ReturnType<typeof spyOn>[] = []
beforeEach(() => {
  logged = []
  for (const method of ['log', 'info', 'warn', 'error', 'debug'] as const) {
    spies.push(
      spyOn(console, method).mockImplementation((...args: unknown[]) => {
        const line = args.map(String).join(' ')
        if (!isRequestLine(line)) logged.push(line)
      }),
    )
  }
})
afterEach(() => {
  for (const spy of spies.splice(0)) spy.mockRestore()
})

// ── The activity band ──────────────────────────────────────────────────────────────────

const questionnaire = (lifestyle: unknown) => ({
  dateOfBirth: '1995-06-15',
  weightKg: 64,
  heightCm: 168,
  goals: ['Energy'],
  conditions: ['noneOfThese'],
  medications: 'none',
  lifestyle,
  sports: ['Yoga'],
  timeZone: 'UTC',
})

describe('lifestyle is one of four codes (#221)', () => {
  test('the codes are the engine’s own union — one declaration, not a copy', () => {
    // Identity, not equality: a second array with the same four strings is exactly the
    // drift this pins against, because it can gain a member the factor table never heard of.
    expect(ACTIVITY_BAND_CODES).toBe(ACTIVITY_BANDS)
    expect([...ACTIVITY_BAND_CODES]).toEqual([
      'mostlySitting',
      'lightlyActive',
      'active',
      'veryActive',
    ])
  })

  test('every code is accepted and stored as the code', async () => {
    const { uid, token } = await account({ auth: true })
    for (const code of ACTIVITY_BAND_CODES) {
      const res = await call(token, 'PUT', '/me/questionnaire', questionnaire(code))
      expect(res.status).toBe(200)
      expect(res.body.user.profile.lifestyle).toBe(code)
      expect((await userDoc(uid).get()).data()!.profile.lifestyle).toBe(code)
    }
  })

  test('a label, or anything else, is 400 VALIDATION naming the field and not the value', async () => {
    const { uid, token } = await account()
    for (const value of ['Active', 'Mostly sitting', 'Sofa-bound-7731', '', ' ', 3, false, []]) {
      const res = await call(token, 'PUT', '/me/questionnaire', questionnaire(value))
      expect(res.status).toBe(400)
      expect(res.body.error.code).toBe('VALIDATION')
      expect(res.body.error.message).toStartWith('lifestyle ')
    }
    // The message lists the codes, so it is only a fair test of "no echo" for a value that is
    // not a substring of one: "Active" is inside "lightlyActive".
    const sentinel = await call(token, 'PUT', '/me/questionnaire', questionnaire('Sofa-bound-7731'))
    expect(sentinel.body.error.message).not.toContain('Sofa-bound-7731')
    // Nothing was written by any of the refusals.
    expect((await userDoc(uid).get()).data()!.profile).toBe(null)
    expect(logged).toEqual([])
  })

  test('unanswered — null or absent — is accepted and stored as null', async () => {
    // Every profile editor re-sends the whole profile, so an account with no band (new, or a
    // legacy label read as absent) must still be able to save its goals and sports.
    const { uid, token } = await account({ auth: true })
    for (const body of [
      questionnaire(null),
      (({ lifestyle: _, ...rest }) => rest)(questionnaire(null)),
    ]) {
      const res = await call(token, 'PUT', '/me/questionnaire', body)
      expect(res.status).toBe(200)
      expect(res.body.user.profile.lifestyle).toBe(null)
      // Stored as null — the key present, so a later read cannot mistake it for a pre-#221
      // document with a label on it.
      const stored = (await userDoc(uid).get()).data()!.profile
      expect('lifestyle' in stored).toBe(true)
      expect(stored.lifestyle).toBe(null)
    }
  })

  test('a profile with no band round-trips, and answering it later is a code', async () => {
    const { token } = await account({ auth: true })
    const saved = await call(token, 'PUT', '/me/questionnaire', questionnaire(null))
    expect(saved.status).toBe(200)
    // What an editor does: read the profile back and re-send it whole, band still unanswered.
    const served = (await call(token, 'GET', '/me')).body.user.profile
    expect(served.lifestyle).toBe(null)
    const resent = await call(token, 'PUT', '/me/questionnaire', {
      ...served,
      sports: ['Running'],
      timeZone: 'UTC',
    })
    expect(resent.status).toBe(200)
    expect(resent.body.user.profile).toEqual({ ...served, sports: ['Running'] })
    expect(resent.body.user.questionnaireCompleted).toBe(true)

    const answered = await call(token, 'PUT', '/me/questionnaire', questionnaire('veryActive'))
    expect(answered.body.user.profile.lifestyle).toBe('veryActive')
    expect(logged).toEqual([])
  })

  test('every activity-factor lookup is total: no default branch returns a factor', async () => {
    // The compile-time half: a factor table missing a band is a type error, so the next line
    // fails `bun run typecheck` the day `ActivityFactors` stops being total.
    // @ts-expect-error — `veryActive` has no factor, and a table without one must not compile.
    const partial: ActivityFactors = { mostlySitting: 1.2, lightlyActive: 1.375, active: 1.55 }
    void partial

    // The runtime half is a scan: `FACTORS[band] ?? 1.2` compiles against a total table too,
    // and reads as a correct answer for the most-chosen band. Every file under `src/`, at any
    // depth, comments stripped first (`nutrition.ts` quotes the wrong fix in its own header):
    // no mention of a factor table is followed, inside the same expression, by `??`, `||`, or
    // an `as any` / `as unknown` cast — the three ways a lookup gets a default or gets out of
    // the `Record`'s totality. What it does not catch: a fallback more than 160 characters
    // from the table's name, or a table not named `…factor(s)`; review owns those.
    for (const [file, source] of await sources()) {
      const fallback = /factors?\b[^;{}]{0,160}?(\?\?|\|\||\bas\s+(any|unknown)\b)/i.exec(
        stripComments(source),
      )
      expect({ file, fallback: fallback?.[0] ?? null }).toEqual({ file, fallback: null })
    }
  })

  test('the factor scan would see each shape it names', () => {
    // A scan that matches nothing proves nothing; these are the shapes it exists to refuse.
    const scan = /factors?\b[^;{}]{0,160}?(\?\?|\|\||\bas\s+(any|unknown)\b)/i
    for (const wrong of [
      'const f = FACTORS[profile.lifestyle] ?? 1.2',
      'const f = rules.activityFactors[band] || 1.2',
      'const f = rules.activityFactors?.[band] ?? 1.2',
      'const f = (rules.activityFactors as any)[label]',
      'const f = (settings.activityFactors as unknown as Record<string, number>)[x]',
      'const f = activityFactors[\n  input.activityBand\n] ?? 1.2',
    ]) {
      expect({ wrong, caught: scan.test(wrong) }).toEqual({ wrong, caught: true })
    }
    expect(scan.test('const tdee = bmr * settings.activityFactors[input.activityBand]')).toBe(false)
  })
})

describe('the four stored labels map to codes on read, and nothing else does (#221)', () => {
  const LABELS: [string, ActivityBand][] = [
    ['Mostly sitting', 'mostlySitting'],
    ['Lightly active', 'lightlyActive'],
    ['Active', 'active'],
    ['Very active', 'veryActive'],
  ]

  test('the table: each label to exactly one code, each code from exactly one label', () => {
    for (const [label, code] of LABELS) expect(storedLifestyle(label)).toBe(code)
    expect(new Set(LABELS.map(([label]) => storedLifestyle(label))).size).toBe(4)
    for (const code of ACTIVITY_BAND_CODES) expect(storedLifestyle(code)).toBe(code)
  })

  test('any other string is absent — never the nearest band', () => {
    for (const other of [
      'mostly sitting',
      'Active ',
      'Sedentary',
      'Moderately active',
      'Extremely active',
      'Sehr aktiv',
      '',
      'constructor',
      'toString',
    ]) {
      expect(storedLifestyle(other)).toBe(null)
    }
    for (const notAString of [undefined, null, 1.2, ['Active'], { active: true }]) {
      expect(storedLifestyle(notAString)).toBe(null)
    }
  })

  test('GET /me serves the code, and the stored document is not rewritten', async () => {
    const cases: [stored: string, served: ActivityBand | null][] = [
      ...LABELS,
      ['Couch potato', null],
    ]
    for (const [stored, served] of cases) {
      const { uid, token } = await account({
        auth: true,
        profile: {
          dateOfBirth: '1995-06-15',
          weightKg: 64,
          heightCm: 168,
          goals: [],
          conditions: ['noneOfThese'],
          medications: 'none',
          lifestyle: stored,
          sports: [],
        },
      })
      const before = await userDoc(uid).get()
      const res = await call(token, 'GET', '/me')
      expect(res.status).toBe(200)
      expect(res.body.user.profile.lifestyle).toBe(served)
      // An absent band does not take the profile down with it: she is still onboarded, and
      // it is nutrition setup that asks.
      expect(res.body.user.questionnaireCompleted).toBe(true)

      const after = await userDoc(uid).get()
      expect(after.data()!.profile.lifestyle).toBe(stored)
      expect(after.updateTime!.isEqual(before.updateTime!)).toBe(true)
    }
  })
})

// ── The nutrition profile ──────────────────────────────────────────────────────────────

const EXACT_FIELDS = [
  'complete',
  'focusAreas',
  'goal',
  'hideNumbers',
  'mealPattern',
  'step',
  'targetWeightKg',
]

const MEALS: MealPattern = { mealsPerDay: 3, snacks: true, mealTimes: ['08:00', '13:00', '19:30'] }

describe('the nutrition profile (#221)', () => {
  test('not started is 404 NOT_FOUND', async () => {
    const { token } = await account()
    const res = await read(token)
    expect(res.status).toBe(404)
    expect(res.body.error.code).toBe('NOT_FOUND')
  })

  test('its field list is exactly the setup answers — no disordered-eating field, no score', async () => {
    const { uid, token } = await account()
    const res = await patch(token, { goal: 'maintain' })
    expect(res.status).toBe(200)
    expect(Object.keys(res.body.nutritionProfile).sort()).toEqual(EXACT_FIELDS)
    expect(Object.keys((await read(token)).body.nutritionProfile).sort()).toEqual(EXACT_FIELDS)

    // Stored: the answers and the two audit instants, nothing else.
    const stored = Object.keys((await nutritionDoc(uid).get()).data()!).sort()
    expect(stored).toEqual(
      [...EXACT_FIELDS.filter((f) => f !== 'complete'), 'createdAt', 'updatedAt'].sort(),
    )
  })

  test('an unknown key is refused, and nothing is stored for it', async () => {
    const { uid, token } = await account()
    await patch(token, { goal: 'eatBetter' })
    const before = await nutritionDoc(uid).get()
    for (const body of [
      { disorderedEating: true },
      { mealFit: 78 },
      { goal: 'maintain', qualitativeOnly: true },
      { mealPattern: { ...MEALS, calories: 1800 } },
    ]) {
      const res = await patch(token, body)
      expect(res.status).toBe(400)
      expect(res.body.error.code).toBe('VALIDATION')
      expect(res.body.error.message).not.toContain('disorderedEating')
    }
    const after = await nutritionDoc(uid).get()
    expect(after.updateTime!.isEqual(before.updateTime!)).toBe(true)
    expect((await read(token)).body.nutritionProfile.goal).toBe('eatBetter')
  })

  test('a fourth focus area is refused at the edge, and the stored list is unchanged', async () => {
    const { token } = await account()
    const three = ['vegetablesAndFibre', 'moreProtein', 'moreWater']
    expect((await patch(token, { focusAreas: three })).status).toBe(200)

    const res = await patch(token, { focusAreas: [...three, 'skin'] })
    expect(res.status).toBe(400)
    expect(res.body.error.code).toBe('VALIDATION')
    expect(res.body.error.message).toContain('focusAreas')
    // Refused, not truncated to the first three and not the oldest swapped out.
    expect((await read(token)).body.nutritionProfile.focusAreas).toEqual(three)
  })

  test('focus areas are codes: an unknown one or a repeat is refused', async () => {
    const { token } = await account()
    expect((await patch(token, { focusAreas: ['Eat more protein'] })).status).toBe(400)
    expect((await patch(token, { focusAreas: [4] })).status).toBe(400)
    expect((await patch(token, { focusAreas: ['skin', 'skin'] })).status).toBe(400)
    expect((await patch(token, { focusAreas: [] })).status).toBe(200)
  })

  test('a partial setup is stored and served as partial, and no target is derivable', async () => {
    const { uid, token } = await account()
    // Four answers of five: everything but the target weight a `lose` goal needs.
    const saved = await patch(token, {
      goal: 'lose',
      focusAreas: ['ironDeficiencyAnaemia'],
      mealPattern: MEALS,
      hideNumbers: false,
      step: 'targetWeight',
    })
    expect(saved.status).toBe(200)

    const served = (await read(token)).body.nutritionProfile as NutritionProfile
    expect(served.complete).toBe(false)
    expect(served.step).toBe('targetWeight')
    expect(served.goal).toBe('lose')
    // The only way a goal and a target come out paired for the engine is `completedSetup`,
    // and it has nothing to give.
    expect(completedSetup(served)).toBe(null)

    // And she cannot declare it finished with the answer missing.
    const done = await patch(token, { step: 'done' })
    expect(done.status).toBe(400)
    expect(done.body.error).toEqual({
      code: 'VALIDATION',
      message: 'targetWeightKg is required before setup is done',
    })
    expect((await read(token)).body.nutritionProfile.complete).toBe(false)

    // A document that says `done` over a missing answer — hand-edited, or a future bug —
    // still reads as partial: completeness is derived, not stored.
    await nutritionDoc(uid).update({ step: 'done' })
    const forged = (await read(token)).body.nutritionProfile as NutritionProfile
    expect(forged.step).toBe('done')
    expect(forged.complete).toBe(false)
    expect(completedSetup(forged)).toBe(null)
    expect(logged).toEqual([])
  })

  test('a finished setup is complete, resumable and pairs the goal with its target', async () => {
    const { token } = await account()
    await patch(token, { goal: 'lose', step: 'focusAreas' })
    await patch(token, { focusAreas: ['vegetablesAndFibre'], step: 'mealPattern' })
    await patch(token, { mealPattern: MEALS, step: 'bodyMetrics' })
    await patch(token, { step: 'targetWeight' })
    // Resuming: what a second device, or the app after a kill, reads back.
    expect((await read(token)).body.nutritionProfile.step).toBe('targetWeight')
    const done = await patch(token, { targetWeightKg: 61.5, hideNumbers: true, step: 'done' })
    expect(done.status).toBe(200)
    expect(done.body.nutritionProfile.complete).toBe(true)

    const served = (await read(token)).body.nutritionProfile as NutritionProfile
    expect(served.complete).toBe(true)
    expect(completedSetup(served)).toEqual({
      goal: 'lose',
      targetWeightKg: 61.5,
      focusAreas: ['vegetablesAndFibre'],
      mealPattern: MEALS,
      hideNumbers: true,
    })

    // A finished setup stays finished: an edit that would leave an answer missing is refused.
    const broken = await patch(token, { mealPattern: null })
    expect(broken.status).toBe(400)
    expect(broken.body.error.message).toBe('mealPattern is required before setup is done')
    expect(logged).toEqual([])
  })

  test('goals 4 and 5 carry no target weight', async () => {
    const { token } = await account()
    const refused = await patch(token, { goal: 'maintain', targetWeightKg: 60 })
    expect(refused.status).toBe(400)
    expect(refused.body.error.message).toBe('targetWeightKg is only asked for a weight-change goal')
    expect((await read(token)).status).toBe(404)

    // Switching away from a weight-change goal clears the target she gave for it.
    await patch(token, { goal: 'gain', targetWeightKg: 66 })
    const switched = await patch(token, { goal: 'eatBetter' })
    expect(switched.body.nutritionProfile.targetWeightKg).toBe(null)

    // And a steady goal completes without one.
    const done = await patch(token, { mealPattern: MEALS, hideNumbers: false, step: 'done' })
    expect(done.status).toBe(200)
    expect(done.body.nutritionProfile.complete).toBe(true)
    expect(completedSetup(done.body.nutritionProfile)).toEqual({
      goal: 'eatBetter',
      focusAreas: [],
      mealPattern: MEALS,
      hideNumbers: false,
    })
  })

  test('the hide-numbers preference only changes when she says so', async () => {
    const { token } = await account()
    await patch(token, { hideNumbers: true })
    // A later step that does not mention it leaves it on — no write re-enables the numbers.
    await patch(token, { goal: 'maintain', step: 'mealPattern' })
    expect((await read(token)).body.nutritionProfile.hideNumbers).toBe(true)
    // It cannot be un-answered…
    expect((await patch(token, { hideNumbers: null })).status).toBe(400)
    expect((await read(token)).body.nutritionProfile.hideNumbers).toBe(true)
    // …and turning it off is her own act, and reversible.
    await patch(token, { hideNumbers: false })
    expect((await read(token)).body.nutritionProfile.hideNumbers).toBe(false)
  })

  test('refusals name the field and never the value', async () => {
    const { token } = await account()
    const cases: [Record<string, unknown>, string, string][] = [
      [{ goal: 'Lose-weight-8842' }, 'goal ', 'Lose-weight-8842'],
      [{ targetWeightKg: 217.3 }, 'targetWeightKg ', '217'],
      [{ targetWeightKg: '61' }, 'targetWeightKg ', '61'],
      [{ step: 'finished-5521' }, 'step ', 'finished-5521'],
      [{ focusAreas: ['Iron-9913'] }, 'focusAreas ', 'Iron-9913'],
      [{ mealPattern: { mealsPerDay: 7, snacks: true } }, 'mealPattern.mealsPerDay ', '7,'],
      [{ mealPattern: { mealsPerDay: 2, snacks: 'no' } }, 'mealPattern.snacks ', 'no'],
      [
        { mealPattern: { mealsPerDay: 2, snacks: true, mealTimes: ['25:61', '12:00'] } },
        'mealPattern.mealTimes ',
        '25:61',
      ],
      [{ hideNumbers: 'yes' }, 'hideNumbers ', 'yes'],
    ]
    for (const [body, field, value] of cases) {
      const res = await patch(token, body)
      expect({ body, status: res.status, code: res.body.error.code }).toEqual({
        body,
        status: 400,
        code: 'VALIDATION',
      })
      expect(res.body.error.message).toStartWith(field)
      expect(res.body.error.message).not.toContain(value)
    }
    expect((await read(token)).status).toBe(404)
    expect(logged).toEqual([])
  })

  test('targetWeightKg is 30–200 kg, both ends inclusive', async () => {
    const { token } = await account()
    await patch(token, { goal: 'lose' })
    for (const [target, status] of [
      [29.9, 400],
      [30, 200],
      [200, 200],
      [200.1, 400],
    ] as const) {
      const res = await patch(token, { targetWeightKg: target })
      expect({ target, status: res.status }).toEqual({ target, status })
      if (status === 200) expect(res.body.nutritionProfile.targetWeightKg).toBe(target)
      else expect(res.body.error.code).toBe('VALIDATION')
    }
    // The refusals wrote nothing: the last accepted value stands.
    expect((await read(token)).body.nutritionProfile.targetWeightKg).toBe(200)
  })

  test('mealsPerDay is 2–5, and mealTimes carries one time per meal', async () => {
    const { token } = await account()
    for (const [mealsPerDay, status] of [
      [1, 400],
      [2, 200],
      [5, 200],
      [6, 400],
      [3.5, 400],
    ] as const) {
      const res = await patch(token, { mealPattern: { mealsPerDay, snacks: false } })
      expect({ mealsPerDay, status: res.status }).toEqual({ mealsPerDay, status })
    }
    for (const mealTimes of [['08:00', '13:00'], ['08:00', '13:00', '18:00', '21:00'], []]) {
      const res = await patch(token, { mealPattern: { mealsPerDay: 3, snacks: true, mealTimes } })
      expect({ mealTimes, status: res.status }).toEqual({ mealTimes, status: 400 })
      expect(res.body.error.message).toStartWith('mealPattern.mealTimes ')
    }
    const exact = await patch(token, {
      mealPattern: { mealsPerDay: 3, snacks: true, mealTimes: ['08:00', '13:00', '19:30'] },
    })
    expect(exact.status).toBe(200)
    expect(exact.body.nutritionProfile.mealPattern.mealTimes).toEqual(['08:00', '13:00', '19:30'])
  })

  test('both routes need a session: no token, or a bad one, is 401', async () => {
    for (const authorization of [null, 'Bearer not-a-jwt']) {
      for (const [method, body] of [
        ['GET', undefined],
        ['PATCH', { goal: 'lose' }],
      ] as const) {
        const res = await server.fetch(
          new Request('http://api.test/me/nutrition/profile', {
            method,
            headers: {
              'content-type': 'application/json',
              ...(authorization ? { authorization } : {}),
            },
            body: body === undefined ? undefined : JSON.stringify(body),
          }),
        )
        expect({ method, authorization, status: res.status }).toEqual({
          method,
          authorization,
          status: 401,
        })
        expect(((await res.json()) as { error: { code: string } }).error.code).toBe('UNAUTHORIZED')
      }
    }
  })

  test('writing it needs the collect consent (#86); reading it does not', async () => {
    const { token } = await account({ consent: false })
    const res = await patch(token, { goal: 'lose' })
    expect(res.status).toBe(403)
    expect(res.body.error.code).toBe('CONSENT_REQUIRED')
    expect((await read(token)).status).toBe(404)
  })

  test('nothing about her reaches a log line', async () => {
    const { token } = await account()
    await patch(token, {
      goal: 'lose',
      focusAreas: ['pmsCravings'],
      mealPattern: MEALS,
      targetWeightKg: 58.7,
      hideNumbers: true,
      step: 'done',
    })
    await read(token)
    await patch(token, { focusAreas: ['a', 'b', 'c', 'd'] })
    expect(logged).toEqual([])
  })

  test('DELETE /me takes the nutrition profile with the account', async () => {
    const { uid, token } = await account({ auth: true })
    await patch(token, { goal: 'lose', targetWeightKg: 59 })
    expect((await nutritionDoc(uid).get()).exists).toBe(true)

    const res = await call(token, 'DELETE', '/me')
    expect(res.status).toBe(200)
    // Ids, never the references: a failing `toEqual` on a `DocumentReference` serializes the
    // whole Firestore client behind it (see `account-deletion.test.ts`).
    const left = (await userDoc(uid).collection('nutrition').listDocuments()).map((d) => d.id)
    expect(left).toEqual([])
    expect((await userDoc(uid).get()).exists).toBe(false)
  })
})

describe('completeness has one definition', () => {
  test('`completedSetup` and the save path’s refusal agree on every combination', () => {
    // Pure, so exhaustive: every answer present or missing, every goal kind, both ends of the
    // progress marker. Complete means marked `done` *and* nothing required is missing — and
    // `firstMissingAnswer` is what the PATCH refusal names, so the two must never disagree.
    for (const goal of [null, 'lose', 'buildMuscle', 'maintain', 'eatBetter'] as const)
      for (const mealPattern of [null, MEALS])
        for (const targetWeightKg of [null, 60])
          for (const hideNumbers of [null, true, false])
            for (const step of ['targetWeight', 'done'] as const) {
              const answers = {
                goal,
                focusAreas: [],
                mealPattern,
                targetWeightKg,
                hideNumbers,
                step,
              }
              const complete = completedSetup(answers) !== null
              expect({ answers, complete }).toEqual({
                answers,
                complete: step === 'done' && firstMissingAnswer(answers) === null,
              })
            }
  })
})

describe('focus-area codes and the engine’s item numbers', () => {
  test('the table is the PRD’s order, one number per code', () => {
    expect(FOCUS_AREA_CODES.map((code) => FOCUS_AREA_PRD_ITEM[code])).toEqual(
      Array.from({ length: 17 }, (_, i) => i + 1),
    )
    // The two the fibre rule reads (PRD line 793): vegetables and fibre, and digestion.
    expect(FOCUS_AREA_PRD_ITEM.vegetablesAndFibre).toBe(1)
    expect(FOCUS_AREA_PRD_ITEM.digestion).toBe(11)
  })
})

describe('one owning module (GUARDRAILS 10)', () => {
  /** A Firestore reference to the collection: `collection('nutrition')` or
   *  `collectionGroup('nutrition')`, a `.doc(…)`/`.collection(…)` string starting with a
   *  `nutrition` segment, or any path string with one (`'users/…/nutrition/profile'`, template
   *  literals included — a string starting `/` or `.` is a route or an import, not a path).
   *  What it does not catch: a path assembled by concatenation (`'users/' + uid +
   *  '/nutrition'`) or from pieces at runtime; review owns those. */
  const REFERENCE =
    /collection(Group)?\(\s*['"`]nutrition['"`]\s*\)|\.(doc|collection|collectionGroup)\(\s*['"`]nutrition\b|['"`](?![./])[^'"`\n]*\/nutrition\b[^'"`\n]*['"`]/

  test('only nutrition-profile.ts references the collection, at any depth, and it logs nothing', async () => {
    for (const [file, source] of await sources()) {
      const names = REFERENCE.test(stripComments(source))
      expect({ file, names }).toEqual({ file, names: file === 'nutrition-profile.ts' })
    }
    const module = await Bun.file(`${SRC}/nutrition-profile.ts`).text()
    expect(module).not.toContain('console.')
  })

  test('the reference scan would see each shape it names', () => {
    for (const reference of [
      "firestore.collection('users').doc(uid).collection('nutrition')",
      'firestore.collectionGroup("nutrition")',
      'firestore.doc(`users/${uid}/nutrition/profile`)',
      'firestore.collection(`users/${uid}/nutrition`)',
      "firestore.doc('nutrition/profile')",
    ]) {
      expect({ reference, caught: REFERENCE.test(reference) }).toEqual({ reference, caught: true })
    }
    // A route path and a module import are not Firestore references.
    expect(REFERENCE.test("app.get('/me/nutrition/profile', h)")).toBe(false)
    expect(REFERENCE.test("import { planDailyTargets } from './nutrition'")).toBe(false)
  })
})

describe('hideNumbers is never inferred (A31, #212, #283)', () => {
  /**
   * A31 is "self-declared only": the hide-numbers preference changes because she asked, never
   * because Eva concluded something from her logs, her weight or her profile. #252's scan
   * pinned that for the retired user-document field; this is the same guard for the live
   * one. Two halves:
   *
   * - `saveNutritionProfile` is named only by its module and by `index.ts`, whose one call is
   *   `PATCH /me/nutrition/profile`. Any other module that could reach it — an import, an
   *   alias, a re-export — fails. (A direct Firestore write to `nutrition/` from elsewhere is
   *   already the one-owner scan's failure above.)
   * - No other module builds a `hideNumbers` value: an object key, a shorthand property, an
   *   assignment or a quoted field name. Reading it (`profile.hideNumbers`, destructuring)
   *   stays allowed, because the screens that hide numbers will have to. A type member
   *   `hideNumbers: boolean` is not a write and is allowed too.
   *
   * What it does not catch: a key assembled at runtime (`['hide' + 'Numbers']`), or a write
   * through `index.ts` itself from something other than the route; review owns those.
   */
  const WRITER = /\bsaveNutritionProfile\b/
  const BUILDS =
    /\bhideNumbers\s*\??:(?!\s*(boolean|null)\b)|[{,]\s*hideNumbers\s*[,}](?!\s*=)|\bhideNumbers\s*=(?![=>])|\[\s*['"`]hideNumbers['"`]\s*\]|['"`]hideNumbers['"`]\s*:/

  test('saveNutritionProfile is named only by its module and by the route', async () => {
    for (const [file, source] of await sources()) {
      const names = WRITER.test(stripComments(source))
      expect({ file, names }).toEqual({
        file,
        names: file === 'nutrition-profile.ts' || file === 'index.ts',
      })
    }
  })

  test('no module but the owner and the route builds a hideNumbers value', async () => {
    for (const [file, source] of await sources()) {
      if (file === 'nutrition-profile.ts' || file === 'index.ts') continue
      const built = BUILDS.exec(stripComments(source))
      expect({ file, built: built?.[0] ?? null }).toEqual({ file, built: null })
    }
  })

  test('the scans would see each shape they name, and pass the reads', () => {
    for (const wrong of [
      'await saveNutritionProfile(uid, { hideNumbers: true })',
      'await saveNutritionProfile(uid, { goal, hideNumbers })',
      'const patch = { hideNumbers: logs.length < 3 }',
      'patch.hideNumbers = true',
      "tx.update(ref, { 'hideNumbers': true })",
      "patch['hideNumbers'] = true",
    ]) {
      expect({ wrong, caught: BUILDS.test(wrong) }).toEqual({ wrong, caught: true })
    }
    expect(WRITER.test("import { saveNutritionProfile as save } from './nutrition-profile'")).toBe(
      true,
    )
    for (const read of [
      'if (profile.hideNumbers) return withoutCalories(card)',
      'const { goal, hideNumbers } = profile',
      'profile.hideNumbers === true',
      'interface Card { hideNumbers: boolean }',
      'interface Card { hideNumbers?: boolean | null }',
    ]) {
      expect({ read, caught: BUILDS.test(read) }).toEqual({ read, caught: false })
    }
  })
})

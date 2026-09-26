import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { Timestamp } from 'firebase-admin/firestore'
import {
  applyContent,
  applySignalVocabulary,
  contentVersion,
  invalidateContentCache,
  retireContent,
  type Review,
} from '../src/content'
import * as todayModule from '../src/today'
import {
  PatternRuleUnsetError,
  TemplatePhraser,
  TemplateUnavailableError,
  formatLoggedAt,
  getToday,
  type Phraser,
  type PhrasedText,
} from '../src/today'
import { config } from '../src/config'
import { CycleRulesUnsetError } from '../src/cycle'
import type { Subject } from '../src/dashboard-rules'
import type { Template } from '../src/content'
import type { DashboardRules } from '../src/dashboard-rules'
import { adminAuth, firestore } from '../src/firebase'
import { lastUserChangeAt, NO_SESSION } from '../src/users'
import { deleteNutritionProfile, saveNutritionProfile } from '../src/nutrition-profile'
import type { Banner } from '../src/content'
import { BANNERS, TEMPLATES, VOCABULARY, REVIEW as SEED_REVIEW } from '../scripts/seed-content'
import { bootApi } from './support/boot-api'
import { signUpActivated } from './support/session'
import { testEmail } from './support/test-email'

/**
 * The Today card (#98, slice D3 of #10): `GET /me/today`, the daily cache, and the
 * template phraser.
 *
 * Three kinds of case, deliberately separated because they can be trusted to different
 * degrees:
 *
 *  - **`TemplatePhraser`** is pure. No Firestore, no server, runs everywhere, and is where
 *    the confidence and slot rules are actually pinned.
 *  - **The cache rules** run in-process against Firestore through `getToday`, so the test
 *    can hand in its own rules and its own phraser, and can invalidate the content cache
 *    between calls — which is what makes "new copy does not regenerate" a case that can
 *    fail rather than one that passes because the server never saw the new copy.
 *  - **The route** runs against a server this file boots with the pattern rung configured,
 *    because `config.ts` is read at boot and a test process cannot reach into another
 *    process's configuration. For the same reason the two refusal cases boot their *own*
 *    servers — one with the rung unconfigured, one against an emptied `content/` — since
 *    each 503 branch is only reachable on a server that cannot produce the other.
 *  - **The configuration itself** is a boot, so it is checked by running `config.ts` in a
 *    subprocess and reading its exit code, as `config-emulators.test.ts` does.
 *
 * **Most of it needs a seeded `content/`, which is emulator-only.** #97 refuses to seed the
 * real project without a reviewer, and writing the three documents the API serves from a
 * test would be worse. So the card-producing cases are `skipIf(!onEmulators)` and run under
 * `scripts/ci-api.sh`; what a local `bun run verify` covers instead is the honest behaviour
 * against an **empty** store, which is what a real device hits today.
 */

/** Live round trips to Firestore and a spawned API on most cases (#31). */
setDefaultTimeout(20_000)

const onEmulators = Boolean(
  process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.FIRESTORE_EMULATOR_HOST,
)

const PASSWORD = 'correct-horse-8'
const email = testEmail()

/**
 * The pattern rung's thresholds, for this file only.
 *
 * Chosen here rather than read from `config`, and emphatically not a default proposed for
 * #26: these numbers exist so the ladder can be *exercised*, and nothing outside this file
 * and the spawned server below sees them.
 */
const RULES: DashboardRules = {
  pattern: { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 2 },
}

/** `RULES` as `config.ts` reads it, for the servers this file boots. */
const PATTERN_ENV = {
  DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: String(RULES.pattern!.lowSignalDays),
  DASHBOARD_PATTERN_LOW_AT_OR_BELOW: String(RULES.pattern!.lowAtOrBelow),
  DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: String(RULES.pattern!.severeSymptomDays),
}

/**
 * The same three, unset.
 *
 * Empty rather than absent: `config.ts` reads them with `optionalString`, which treats `''`
 * as "not supplied", and an empty value cannot be filled back in by an `api/.env` the way a
 * deleted key can. This is the configuration every environment actually runs today.
 */
const NO_PATTERN_ENV = {
  DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: '',
  DASHBOARD_PATTERN_LOW_AT_OR_BELOW: '',
  DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: '',
}

/**
 * The cycle maths' fifteen, unset — the same "empty, not absent" trick, for the group
 * `config.ts` treats as all-or-nothing (#176).
 *
 * All fifteen, because a *partial* group is a boot failure rather than an unconfigured
 * capability: leaving one set would spawn a server that never answers instead of one that
 * refuses, and the case below would then be about `bootApi` timing out.
 *
 * Listed here rather than derived from `config.ts`'s own table, deliberately: a variable
 * renamed there must fail this file rather than be silently emptied under its new name.
 */
const NO_CYCLE_ENV = Object.fromEntries(
  [
    'CYCLE_MIN_LENGTH_DAYS',
    'CYCLE_MAX_LENGTH_DAYS',
    'CYCLE_MIN_PERIOD_GAP_DAYS',
    'CYCLE_HISTORY_CYCLES',
    'CYCLE_MIN_CYCLES_FOR_ESTIMATE',
    'CYCLE_NARROW_BAND_MIN_CYCLES',
    'CYCLE_LUTEAL_PHASE_DAYS',
    'CYCLE_FERTILE_DAYS_BEFORE_OVULATION',
    'CYCLE_FERTILE_DAYS_AFTER_OVULATION',
    'CYCLE_PEAK_DAYS_BEFORE_OVULATION',
    'CYCLE_IRREGULAR_YOUNG_MAX_AGE',
    'CYCLE_IRREGULAR_MID_MAX_AGE',
    'CYCLE_IRREGULAR_YOUNG_VARIATION_DAYS',
    'CYCLE_IRREGULAR_MID_VARIATION_DAYS',
    'CYCLE_IRREGULAR_OLDER_VARIATION_DAYS',
  ].map((name) => [name, '']),
)

/**
 * The constants the cycle fixtures below are built for — A25–A27's values, which are what
 * `api/.env.example` carries and what `scripts/ci-api.sh` exports into this run.
 *
 * **Asserted rather than assumed** (the first case in that describe). Every fixture date is
 * placed inside a phase boundary these numbers draw — a period gap of two days, a fourteen-
 * day luteal phase, a window opening five days before ovulation — so a run configured
 * differently would land a fixture in another phase and assert the wrong card while looking
 * green. This process and the server it spawned share an environment, so what is read here
 * is what that server is running.
 */
const CYCLE_RULES = {
  minCycleLengthDays: 21,
  maxCycleLengthDays: 45,
  minPeriodGapDays: 2,
  historyCycles: 6,
  minCyclesForEstimate: 3,
  narrowBandMinCycles: 6,
  lutealPhaseDays: 14,
  fertileDaysBeforeOvulation: 5,
  fertileDaysAfterOvulation: 1,
  peakDaysBeforeOvulation: 2,
  irregularity: {
    youngMaxAge: 25,
    midMaxAge: 41,
    youngVariationDays: 9,
    midVariationDays: 7,
    olderVariationDays: 9,
  },
}

const REVIEW: Review = {
  reviewedBy: 'today.test.ts',
  reviewedAt: '2026-09-16',
  source: 'docs/design/Eva App.dc.html — Dashboard card',
}

let token = ''
let uid = ''
/** The API this file boots, with the pattern rung configured. */
let base = ''
let child: ReturnType<typeof Bun.spawn> | null = null
const seeded: string[] = []

const apiAt = (at: string, path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${at}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
      ...(init?.headers ?? {}),
    },
  })

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  apiAt(base, path, init)

/** The port range this file's API processes draw from. Deliberately disjoint from the suite
 *  server's window (`EVA_API_PORT..+10`, the lowest of which is 3003), and from
 *  `events.test.ts`'s 3100–3299, so two files booting in one run cannot draw each other's
 *  ports by construction rather than by the draw's own refusal. */
const PORT_RANGE: [number, number] = [3400, 3599]

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>

interface TodayBody {
  date: string
  generatedAt: string
  contentVersion: string
  card: Record<string, unknown>
  banners: Record<string, unknown>[]
  mode: string
  periodOngoing: boolean | null
  nutritionSetUp: boolean | null
}
interface ErrorBody {
  error: { code: string; message: string }
}

const todayIn = (timeZone: string): string => {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date())
  const part = (name: string) => parts.find((p) => p.type === name)!.value
  return `${part('year')}-${part('month')}-${part('day')}`
}

/** A slot placeholder the phraser left behind. `{"state":…}` is JSON punctuation and does
 *  not match; `{cycleDay}` does, which is the thing that must never reach a card. */
const UNFILLED = /\{[A-Za-z]\w*\}/

/** `YYYY-MM-DD` shifted by whole days in UTC — a calendar label, as everywhere else here. */
const shiftDays = (day: string, by: number): string =>
  new Date(Date.parse(`${day}T00:00:00.000Z`) + by * 86_400_000).toISOString().slice(0, 10)

const sportOn = (localDate: string) => ({
  type: 'sport',
  localDate,
  payload: { activity: 'run', durationMin: 30, intensity: 'light' },
  timeZone: 'UTC',
})

const todayDocs = () => firestore.collection('users').doc(uid).collection('today')

/**
 * D2's banner rows with an article behind each (#102) — every tag the rail reads is the
 * seed's own; only the URL is supplied, because the seed has none yet and a row without one
 * is never served. `example.org` is reserved for fixtures (RFC 2606).
 */
const RAIL: Banner[] = BANNERS.map((b) => ({ ...b, url: `https://example.org/articles/${b.id}` }))

/**
 * A questionnaire payload for someone exactly this old in UTC today (#81 — the profile
 * stores a date of birth and `bandForAge` derives the age from it).
 *
 * Her birthday is today, so the payload sits on the boundary the derivation has to get
 * right, and `timeZone: "UTC"` takes `resolveClock`'s slack to zero — without it the 18+
 * floor is measured a day earlier than this computes and an exactly-18 fixture would be
 * refused.
 */
const profileAged = (years: number) => {
  const today = todayIn('UTC')
  return {
    dateOfBirth: `${Number(today.slice(0, 4)) - years}${today.slice(4)}`,
    weightKg: 62,
    heightCm: 170,
    goals: ['energy'],
    conditions: [],
    medications: 'none',
    lifestyle: 'active',
    sports: ['running'],
    timeZone: 'UTC',
  }
}
const storedDays = async () => (await todayDocs().get()).docs
const eventDocs = () => firestore.collection('users').doc(uid).collection('events')

/** Hard-removes every entry, soft-deleted ones included. A case about *which* card the
 *  ladder chose has to start from a known account rather than from whatever ran before it,
 *  and a soft delete is still a row `lastEventChangeAt` can see. */
const clearEvents = async () => {
  const snapshot = await eventDocs()
    .get()
    .catch(() => null)
  for (const doc of snapshot?.docs ?? []) await doc.ref.delete().catch(() => {})
}

beforeAll(async () => {
  // Boot our own API, because the pattern rung is configuration and `config.ts` reads it
  // once at boot. A server started by `verify-api.sh` has it unset — which is the correct
  // production default (#26) and useless for exercising the ladder.
  const spawned = await bootApi({ env: PATTERN_ENV, range: PORT_RANGE, label: 'today.test.ts' })
  base = spawned.base
  child = spawned.child

  const account = await signUpActivated(base, email, PASSWORD)
  token = account.token
  uid = account.uid

  if (onEmulators) {
    await applyContent('templates', TEMPLATES, REVIEW, { rewrite: true })
    seeded.push('templates')
    // #200: `signals_today`/`signal_overrides_phase` fill `{signal}` from the vocabulary,
    // so a seeded `content/` without it would leave those titles unfilled and answer 503.
    await applySignalVocabulary(VOCABULARY, REVIEW)
    seeded.push('vocabulary')
    // Before the spawned server's first `GET /me/today`, so its 60s content cache holds the
    // rail from the start — the route case in "the banner rail" reads it from there.
    await applyContent('banners', RAIL, REVIEW, { rewrite: true })
    seeded.push('banners')
    invalidateContentCache()
  }
}, 60_000)

afterAll(async () => {
  for (const doc of await todayDocs()
    .get()
    .then((s) => s.docs)
    .catch(() => [])) {
    await doc.ref.delete().catch(() => {})
  }
  await clearEvents()
  if (uid)
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
  // And the Auth account, which this file used to leave behind. A live Auth user whose
  // `users/{uid}` is gone is exactly the orphan `account-deletion.test.ts` exists to rule
  // out, and every other suite that signs up deletes it (`events.test.ts:121`,
  // `events-retention.test.ts:144`). Against the real project that orphan is permanent.
  if (uid) await deleteNutritionProfile(uid).catch(() => {})
  if (uid) await adminAuth.deleteUser(uid).catch(() => {})
  for (const id of seeded)
    await firestore
      .collection('content')
      .doc(id)
      .delete()
      .catch(() => {})
  child?.kill()
})

// ── The phraser ────────────────────────────────────────────────────────────────────────
// Pure: these are the cases that pin the tone rules, and they run in every environment.

describe('TemplatePhraser', () => {
  const phraser = new TemplatePhraser()

  const template = (over: Partial<Template>): Template => ({
    id: 'phase_energy',
    rung: 'phase',
    mode: 'cycle',
    state: 'home_d',
    confidence: 'hedged',
    title: 'Many women notice higher energy around now',
    actions: ['View cycle details'],
    slots: [],
    status: 'active',
    order: 0,
    ...over,
  })

  const subject = (over: Partial<Subject>): Subject => ({
    rung: 'phase',
    templateId: 'phase_energy',
    slots: {},
    confidence: 'hedged',
    ...over,
  })

  test('substitutes slot values into every line that carries one', () => {
    const text = phraser.phrase(subject({ slots: { cycleDay: 15, phase: 'follicular' } }), [
      template({ kicker: 'Cycle day {cycleDay} · likely {phase}', line2: 'day {cycleDay}' }),
    ])
    expect(text.kicker).toBe('Cycle day 15 · likely follicular')
    expect(text.line2).toBe('day 15')
    expect(text.state).toBe('home_d')
  })

  test('a hedged subject is rendered by the hedged template', () => {
    const text = phraser.phrase(subject({ confidence: 'hedged' }), [
      template({ confidence: 'hedged', title: 'likely approaching ovulation' }),
    ])
    expect(text.title).toBe('likely approaching ovulation')
  })

  /**
   * PRD §Dashboard: "the wording must reflect that rather than asserting the phase as
   * fact". The plain copy for the same card exists in the store and must be unreachable
   * at the hedged class — not merely unpreferred.
   */
  test('the plain variant is unreachable at the hedged class', () => {
    expect(() =>
      phraser.phrase(subject({ confidence: 'hedged' }), [
        template({ confidence: 'plain', title: 'You are in your follicular phase' }),
      ]),
    ).toThrow(TemplateUnavailableError)
  })

  test('and the hedged variant is unreachable at the plain class', () => {
    expect(() =>
      phraser.phrase(subject({ confidence: 'plain' }), [template({ confidence: 'hedged' })]),
    ).toThrow(TemplateUnavailableError)
  })

  test("given both, it picks the one matching the subject's class", () => {
    const text = phraser.phrase(subject({ confidence: 'hedged' }), [
      template({ confidence: 'plain', title: 'plain copy', order: 0 }),
      template({ confidence: 'hedged', title: 'hedged copy', order: 1 }),
    ])
    expect(text.title).toBe('hedged copy')
  })

  /**
   * D1 leaves `home_edu`'s `category` and `readMinutes` unfilled on purpose — no slice
   * owns choosing the article. The card must therefore drop its meta line rather than
   * render `{category}` or invent a placeholder.
   */
  test('an unfilled slot removes its line and leaves the rest of the card', () => {
    const text = phraser.phrase(subject({ templateId: 'educational', confidence: 'plain' }), [
      template({
        id: 'educational',
        confidence: 'plain',
        state: 'home_edu',
        kicker: 'Today’s read',
        title: 'Why sleep can affect appetite more than willpower',
        meta: '{category} · {readMinutes} min read',
      }),
    ])
    expect(text.meta).toBeUndefined()
    expect(text.kicker).toBe('Today’s read')
    expect(text.title).toBe('Why sleep can affect appetite more than willpower')
    expect(JSON.stringify(text)).not.toMatch(UNFILLED)
  })

  /**
   * The other half of that rule, and the half with consequences. `meta` is dropped;
   * `title` cannot be — a card with no title is not a card — so a title whose slot has no
   * value is a refusal rather than a raw string.
   *
   * Driven from the *seeded* copy, because that is what makes it more than a unit test:
   * four templates carry a slot in their title — two `{appointmentAt}` (rung 3, inert until
   * D10 wires it) and two `{signal}` (#200, filled by `resolveSignals`, never by the
   * ladder). This guard is the only thing between a wiring mistake and
   * "Your anatomy scan is scheduled for tomorrow, {appointmentAt}" or a raw "{signal}"
   * reaching a user.
   */
  test('a title with an unfilled slot is refused, not rendered raw', () => {
    const withSlotInTitle = TEMPLATES.filter((candidate) => UNFILLED.test(candidate.title))
    expect(withSlotInTitle.length).toBeGreaterThan(0)
    for (const seeded of withSlotInTitle) {
      // `Template.id` is an open string and `Subject.templateId` is D1's union; these
      // two ids are in it, and the cast is what lets the case be driven from the copy
      // rather than from a hand-written duplicate of it.
      const named = subject({ templateId: seeded.id as Subject['templateId'] })
      expect(() => phraser.phrase({ ...named, confidence: seeded.confidence }, [seeded])).toThrow(
        TemplateUnavailableError,
      )
    }
  })

  test('a retired template is never selected, even ahead of an active copy', () => {
    const retired = template({ status: 'retired', order: 0, title: 'Withdrawn words' })
    const active = template({ status: 'active', order: 1, title: 'Active words' })

    expect(phraser.phrase(subject({}), [retired, active]).title).toBe('Active words')
    expect(() => phraser.phrase(subject({}), [template({ status: 'retired' })])).toThrow(
      TemplateUnavailableError,
    )
  })

  test('an unseeded store refuses rather than inventing a card', () => {
    expect(() => phraser.phrase(subject({}), [])).toThrow(TemplateUnavailableError)
  })
})

// ── The red-flag kicker's clock (#201) ─────────────────────────────────────────────────

describe("the red-flag kicker's clock", () => {
  const phraser = new TemplatePhraser()
  const flag = TEMPLATES.find((t) => t.id === 'red_flag')!

  const flagSubject = (loggedAt: string): Subject => ({
    rung: 'flag',
    templateId: 'red_flag',
    slots: { loggedAt },
    confidence: 'plain',
  })

  test("renders a wall-clock time in the caller's zone, not the raw instant", () => {
    // 08:00 UTC is 17:00 in Asia/Tokyo (UTC+9, no DST) — the time she saw.
    const clocked = formatLoggedAt(flagSubject('2026-09-13T08:00:00Z'), 'Asia/Tokyo')
    expect(clocked.slots.loggedAt).toBe('17:00')
    expect(phraser.phrase(clocked, [flag]).kicker).toBe('Logged 17:00')
  })

  test("the display zone is the caller's, not the instant's own offset", () => {
    // An instant stamped +02:00 is 06:00 UTC; a New York user in September (EDT, UTC-4)
    // reads it at 02:00 — the offset is how it was stored, not where she is.
    const clocked = formatLoggedAt(flagSubject('2026-09-13T08:00:00+02:00'), 'America/New_York')
    expect(clocked.slots.loggedAt).toBe('02:00')
  })

  test('a non-flag subject is left untouched', () => {
    const other: Subject = {
      rung: 'pattern',
      templateId: 'signals_today',
      slots: { signal: 'low energy' },
      confidence: 'plain',
    }
    expect(formatLoggedAt(other, 'Asia/Almaty')).toBe(other)
  })
})

// ── The cache rules ────────────────────────────────────────────────────────────────────

describe.skipIf(!onEmulators)('the daily cache', () => {
  const date = () => todayIn('UTC')
  const request = () => ({ date: date(), timeZone: 'UTC' })

  test('an empty account gets the cold-start card, with no slot values', async () => {
    const today = await getToday(uid, NO_SESSION, request(), RULES)
    expect(today.card.templateId).toBe('cold_start')
    expect(today.card.state).toBe('home_a')
    expect(today.card.rung).toBe('setup')
    // Nothing personalised, because there is nothing to personalise from (PRD
    // Confidence and cold start 4).
    expect(JSON.stringify(today.card)).not.toMatch(UNFILLED)
    const seededCopy = TEMPLATES.find((t) => t.id === 'cold_start')!
    expect(today.card.title).toBe(seededCopy.title)
  })

  /**
   * New data changes the card; new copy does not. The content cache is invalidated
   * between the two calls on purpose — without that the server would be serving a stale
   * bundle and this case would pass even if regeneration were unconditional.
   */
  test('a change to content/ alone does not regenerate an existing day', async () => {
    const first = await getToday(uid, NO_SESSION, request(), RULES)

    const rewritten = TEMPLATES.map((t) =>
      t.id === 'cold_start' ? { ...t, title: 'Rewritten by today.test.ts' } : t,
    )
    await applyContent('templates', rewritten, REVIEW, { rewrite: true })
    invalidateContentCache()
    try {
      // The store really does hold different words now, so a regeneration would show.
      expect(contentVersion({ templates: rewritten, banners: [], nudges: [] })).not.toBe(
        first.contentVersion,
      )

      const second = await getToday(uid, NO_SESSION, request(), RULES)
      expect(second.generatedAt).toBe(first.generatedAt)
      expect(second.contentVersion).toBe(first.contentVersion)
      expect(second.card.title).toBe(first.card.title)
      expect(second.card.title).not.toBe('Rewritten by today.test.ts')
    } finally {
      await applyContent('templates', TEMPLATES, REVIEW, { rewrite: true })
      invalidateContentCache()
    }
  })

  /**
   * PRD §Dashboard: "the message subject is never free-generated".
   *
   * This phraser **tries**. It returns a `templateId` and a `rung` of its own, and it
   * names `flag` — the one rung that must never be reachable without the ladder. The
   * return value is assembled dynamically on purpose: `PhrasedText` not carrying those
   * keys stops an object *literal* and nothing else, and D9's model phraser (#106) will
   * build its answer exactly this way. What actually holds the line is `buildCard`
   * writing the subject's two fields after spreading the text.
   */
  test('the phraser cannot change the template id or the rung', async () => {
    await todayDocs().doc(date()).delete()
    const rogue: Phraser = {
      id: 'rogue',
      phrase: (): PhrasedText => {
        const named: Record<string, unknown> = {
          state: 'home_flag',
          title: 'a subject the ladder never chose',
          actions: [],
          templateId: 'late_period',
          rung: 'flag',
        }
        return named as unknown as PhrasedText
      },
    }
    const today = await getToday(uid, NO_SESSION, request(), RULES, rogue)
    // The words are the phraser's; the subject is not its to name.
    expect(today.card.title).toBe('a subject the ladder never chose')
    expect(today.card.templateId).toBe('cold_start')
    expect(today.card.rung).toBe('setup')

    // And the *stored* card is the ladder's too — that is the one served tomorrow.
    const stored = (await todayDocs().doc(date()).get()).data()!.card as Record<string, unknown>
    expect(stored.templateId).toBe('cold_start')
    expect(stored.rung).toBe('setup')
    await todayDocs().doc(date()).delete()
  })

  test('an unconfigured pattern rung is a refusal, not an answer', async () => {
    await expect(getToday(uid, NO_SESSION, request(), { pattern: null })).rejects.toThrow(
      PatternRuleUnsetError,
    )
  })

  /**
   * Rung 2, driven end to end — the only card in this file that the ladder reaches by
   * reading her logs rather than by finding none.
   *
   * Three consecutive days at or below the configured level, today included, which is
   * exactly `lowSignalDays`. The window `today.ts` reads signals over is *derived* from
   * that rule rather than fixed, and this is why: a shorter window makes the rung
   * unmatchable while the configuration still looks live, which is the failure #26's
   * process note exists to prevent.
   */
  test('three consecutive low days reach the pattern card', async () => {
    await clearEvents()
    const day = date()
    for (const on of [shiftDays(day, -2), shiftDays(day, -1), day]) {
      const logged = await api(`/me/body-signals/${on}`, {
        method: 'PUT',
        body: JSON.stringify({ mood: 1, sleep: 1, timeZone: 'UTC' }),
      })
      expect(logged.status).toBe(200)
    }
    await todayDocs().doc(day).delete()

    const today = await getToday(uid, NO_SESSION, request(), RULES)
    expect(today.card.rung).toBe('pattern')
    expect(today.card.templateId).toBe('mood_pattern')
    expect(today.card.title).toBe(TEMPLATES.find((t) => t.id === 'mood_pattern')!.title)
    expect(JSON.stringify(today.card)).not.toMatch(UNFILLED)
  })

  /**
   * The stored stamp is the *data's* instant, not this process's clock: `getToday` reads
   * `changedAt` before it gathers, and writes that rather than `generatedAt`.
   *
   * The failure it prevents is a server clock running ahead of Firestore's. She logs a
   * moment after the card was built; her entry's `updatedAt` sorts below the stamped
   * `now`, the card never looks stale again, and her log is invisible on Today for the
   * rest of the day. The skew is manufactured here rather than waited for — writing the
   * entry's `updatedAt` directly is the only way to make it deterministic.
   */
  test("the card is stamped with the data's instant, not the server's clock", async () => {
    await clearEvents()
    const day = date()
    await todayDocs().doc(day).delete()
    const created = await json<{ event: { id: string } }>(
      await api('/me/events', { method: 'POST', body: JSON.stringify(sportOn(day)) }),
    )
    const entry = eventDocs().doc(created.event.id)

    // Put the newest thing in her data a clear second behind this process's clock,
    // which is what a Cloud Run instance ahead of Firestore looks like from here.
    const userAt = Date.parse((await lastUserChangeAt(uid))!)
    const dataAt = Math.max(userAt + 1, Date.now() - 1_000)
    await entry.update({ updatedAt: Timestamp.fromMillis(dataAt) })

    const first = await getToday(uid, NO_SESSION, request(), RULES)
    const stored = (await todayDocs().doc(day).get()).data()!
    expect(stored.dataChangedAt).toBe(new Date(dataAt).toISOString())
    // There really is a gap, so what follows is about the stamp and not about rounding.
    expect(Date.parse(stored.generatedAt)).toBeGreaterThan(dataAt + 1)

    // Her log: one millisecond after the instant the card was built from, and still
    // well below `generatedAt`. Stamped with the data's instant it is newer and the
    // card regenerates; stamped with the clock it is older and she never sees it.
    await entry.update({ updatedAt: Timestamp.fromMillis(dataAt + 1) })
    const second = await getToday(uid, NO_SESSION, request(), RULES)
    expect(second.generatedAt).not.toBe(first.generatedAt)
  })

  /**
   * A deleted entry is not a log. `lastLoggedDate` filters on `deletedAt === null`;
   * without that filter `daysSinceLastLog` reads `0` for a day whose only entry she just
   * removed, D1 stops treating this as a first open, and she is handed a card that
   * implies she logged something that is gone.
   */
  test('an entry logged and then deleted leaves her on the cold-start card', async () => {
    await clearEvents()
    const day = date()
    const created = await json<{ event: { id: string } }>(
      await api('/me/events', { method: 'POST', body: JSON.stringify(sportOn(day)) }),
    )
    expect((await api(`/me/events/${created.event.id}`, { method: 'DELETE' })).status).toBe(200)

    await todayDocs().doc(day).delete()
    const today = await getToday(uid, NO_SESSION, request(), RULES)
    expect(today.card.templateId).toBe('cold_start')
    expect(today.card.rung).toBe('setup')
  })

  test('the stored card carries no raw signal value and no event', async () => {
    await todayDocs().doc(date()).delete()
    await api(`/me/body-signals/${date()}`, {
      method: 'PUT',
      body: JSON.stringify({ energy: 1, mood: 1, sleep: 1, timeZone: 'UTC' }),
    })
    await getToday(uid, NO_SESSION, request(), RULES)

    const stored = (await todayDocs().doc(date()).get()).data()!
    const card = stored.card as Record<string, unknown>
    const allowed = [
      'templateId',
      'rung',
      'state',
      'tone',
      'kicker',
      'title',
      'line2',
      'line3',
      'meta',
      'actions',
      'phraser',
    ]
    expect(Object.keys(card).filter((key) => !allowed.includes(key))).toEqual([])
    // The ratings she logged are not on the card; only the words the reviewed copy
    // carries. `sex` cannot reach here at all — D1 receives body signals and nothing
    // else — so this is a floor under that, not the guarantee itself.
    const serialised = JSON.stringify(card)
    expect(serialised).not.toContain('energy":')
    expect(serialised).not.toContain('payload')
    expect(serialised).not.toContain('sex')
  })
})

// ── The banner rail (D7, #102) ─────────────────────────────────────────────────────────
// *Which* rows `selectBanners` picks is pinned against fixtures and the seed in
// `dashboard-rules.test.ts`, where it runs everywhere. What only the join can show is here:
// that the rail is chosen with the card and stored with it, that it excludes the subject the
// ladder actually chose, that it is ranked by a *finished* setup's focus areas (and that
// saving one is new data), and that an unsigned banner document reaches no rail. All of it
// needs a seeded `content/`, so all of it is emulator-only.

describe.skipIf(!onEmulators)('the banner rail', () => {
  const date = () => todayIn('UTC')
  const request = () => ({ date: date(), timeZone: 'UTC' })
  const rebuild = async () => {
    await todayDocs().doc(date()).delete()
    return getToday(uid, NO_SESSION, request(), RULES)
  }
  const restoreRail = async () => {
    // `applyContent` refuses to merge into an unsigned document with items in it — the
    // gate this file is not here to get round — so a case that wrote one deletes it first.
    await firestore.collection('content').doc('banners').delete()
    await applyContent('banners', RAIL, REVIEW, { rewrite: true })
    invalidateContentCache()
  }

  // Every case starts from the seeded rail and no nutrition profile, and is put back after
  // itself whether it passed or not: a case that rewrote `content/banners` and then failed
  // must not hand the next case — or the route cases below, through the spawned server's
  // content cache — a store it did not expect.
  const reset = async () => {
    await restoreRail()
    await deleteNutritionProfile(uid)
  }
  beforeAll(async () => {
    await clearEvents()
    await reset()
  })
  afterEach(reset)

  test('the rail is stored with the card: the same items on every call that day', async () => {
    const first = await rebuild()
    expect(first.banners.length).toBeGreaterThan(0)
    expect((await todayDocs().doc(date()).get()).data()!.banners).toEqual(first.banners)

    // Retire the first row served. A rail recomputed per call would drop it; the stored one
    // keeps it for the day, exactly as new copy does not change the card (D3's rule).
    const [served] = first.banners
    expect(await retireContent('banners', served!.id)).toBe(true)

    const second = await getToday(uid, NO_SESSION, request(), RULES)
    expect(second.banners).toEqual(first.banners)
    expect(second.generatedAt).toBe(first.generatedAt)

    // And a day built after the retirement does not select it (#146).
    const rebuilt = await rebuild()
    expect(rebuilt.banners.map((b) => b.id)).not.toContain(served!.id)
  })

  test('the rail never carries a row tagged with the card the ladder chose that day', async () => {
    const card = (await rebuild()).card.templateId
    // Tag the store's first row of today's mode with today's card, and nothing else about
    // it: if the join handed `selectBanners` any other subject, this row would lead the rail.
    const tagged = RAIL.map((b) => (b.id === 'cycle_appetite' ? { ...b, subjects: [card] } : b))
    await firestore.collection('content').doc('banners').delete()
    await applyContent('banners', tagged, REVIEW, { rewrite: true })
    invalidateContentCache()

    const today = await rebuild()
    expect(today.card.templateId).toBe(card)
    expect(today.banners.length).toBeGreaterThan(0)
    expect(today.banners.map((b) => b.id)).not.toContain('cycle_appetite')
    await restoreRail()
    expect((await rebuild()).banners.map((b) => b.id)).toContain('cycle_appetite')
  })

  test('only a finished setup’s focus areas rank it — and saving one is new data', async () => {
    const plain = await rebuild()
    expect(plain.banners[0]?.id).toBe('cycle_appetite')
    expect(plain.nutritionSetUp).toBe(false)

    // Declared, but setup is not finished: PRD §Nutrition coach, nothing suggested from
    // partial data. The save still regenerates — it is her data — and ranks nothing.
    await saveNutritionProfile(uid, NO_SESSION, {
      focusAreas: ['ironDeficiencyAnaemia'],
      step: 'mealPattern',
    })
    const partial = await getToday(uid, NO_SESSION, request(), RULES)
    expect(partial.generatedAt).not.toBe(plain.generatedAt)
    expect(partial.banners[0]?.id).toBe('cycle_appetite')
    // The shortcut reads the same "finished" the rail does (#100): partial is not set up.
    expect(partial.nutritionSetUp).toBe(false)

    // Finished. No `rebuild()`: the stored day must go stale on this write alone.
    await saveNutritionProfile(uid, NO_SESSION, {
      goal: 'maintain',
      mealPattern: { mealsPerDay: 3, snacks: false, mealTimes: null },
      hideNumbers: false,
      step: 'done',
    })
    const complete = await getToday(uid, NO_SESSION, request(), RULES)
    expect(complete.generatedAt).not.toBe(partial.generatedAt)
    expect(complete.banners[0]?.id).toBe('cycle_iron')
    expect(complete.nutritionSetUp).toBe(true)
  })

  /**
   * Written past `applyContent`, as the console can: the same rows, under no signature and
   * under a partial one. `reviewProblems` needs all three fields, so a document carrying a
   * reviewer's name and nothing else is as unsigned as one carrying nothing — the case a
   * check on `reviewedBy` alone would pass.
   */
  for (const [label, signature] of [
    ['no signature', {}],
    ['only a reviewer, no date or source', { reviewedBy: 'someone' }],
  ] as const) {
    test(`a banner document with ${label} reaches no rail`, async () => {
      await firestore
        .collection('content')
        .doc('banners')
        .set({ items: RAIL, ...signature })
      invalidateContentCache()
      const today = await rebuild()
      expect(today.banners).toEqual([])
      // The card is unaffected: only the rail's own document is judged.
      expect(today.card.templateId).toBeDefined()
      // And the same rows, signed, do reach it — so the empty rail above is the signature.
      await restoreRail()
      expect((await rebuild()).banners.length).toBeGreaterThan(0)
    })
  }

  test('a day stored before the rail existed is served with an empty one, not rebuilt', async () => {
    const built = await rebuild()
    const ref = todayDocs().doc(date())
    const { banners: _, ...legacy } = (await ref.get()).data()!
    await ref.set(legacy)
    const served = await getToday(uid, NO_SESSION, request(), RULES)
    expect(served.banners).toEqual([])
    expect(served.generatedAt).toBe(built.generatedAt)
  })

  test('a day stored before the shortcuts row existed is read as such, not rebuilt (#100)', async () => {
    const built = await rebuild()
    expect(built.mode).toBe('cycle')
    expect(built.periodOngoing).toBe(false)
    expect(built.nutritionSetUp).toBe(false)
    const ref = todayDocs().doc(date())
    const { mode: _m, periodOngoing: _p, nutritionSetUp: _n, ...legacy } = (await ref.get()).data()!
    await ref.set(legacy)
    const served = await getToday(uid, NO_SESSION, request(), RULES)
    expect(served.generatedAt).toBe(built.generatedAt)
    // Its mode is known — every card before D10 was built in `cycle` — and the other two are
    // not, so they are `null` rather than an invented `false`.
    expect(served.mode).toBe('cycle')
    expect(served.periodOngoing).toBe(null)
    expect(served.nutritionSetUp).toBe(null)
  })

  test('GET /me/today carries the rail, each item exactly { id, title, meta, url }', async () => {
    await todayDocs().doc(date()).delete()
    const res = await api('/me/today?timeZone=UTC')
    expect(res.status).toBe(200)
    const body = await json<TodayBody>(res)
    expect(Object.keys(body)).toEqual([
      'date',
      'generatedAt',
      'contentVersion',
      'card',
      'banners',
      'nudge',
      'mode',
      'periodOngoing',
      'nutritionSetUp',
    ])
    expect(body.banners.length).toBeGreaterThan(0)
    expect(body.banners.length).toBeLessThanOrEqual(3)
    for (const item of body.banners) {
      expect(Object.keys(item)).toEqual(['id', 'title', 'meta', 'url'])
      const seeded = RAIL.find((b) => b.id === item.id)!
      expect(item).toEqual({
        id: seeded.id,
        title: seeded.title,
        meta: seeded.meta,
        url: seeded.url,
      })
    }
  })
})

// ── The route ──────────────────────────────────────────────────────────────────────────

describe('GET /me/today', () => {
  test('needs a session', async () => {
    expect((await api('/me/today', { token: null })).status).toBe(401)
  })

  test('refuses a time zone that is not one', async () => {
    const res = await api('/me/today?timeZone=Mars/Olympus')
    expect(res.status).toBe(400)
    expect((await json<ErrorBody>(res)).error.code).toBe('VALIDATION')
  })

  /**
   * What a real device hits today. `content/` is unseeded in every environment — #97
   * refuses to seed it without a reviewer — so the card cannot be filled and the route
   * says so as an unavailable capability rather than a 500 or an empty card.
   */
  test.skipIf(onEmulators)('answers 503 against an empty content store', async () => {
    const res = await api('/me/today?timeZone=UTC')
    expect(res.status).toBe(503)
    expect((await json<ErrorBody>(res)).error.code).toBe('SERVICE_UNAVAILABLE')
    // And nothing was cached: a refusal is not a card.
    expect((await storedDays()).length).toBe(0)
  })
})

describe.skipIf(!onEmulators)('GET /me/today, served', () => {
  const post = (body: unknown) => api('/me/events', { method: 'POST', body: JSON.stringify(body) })

  const sport = sportOn

  const fetchToday = async () => {
    const res = await api('/me/today?timeZone=UTC')
    expect(res.status).toBe(200)
    return { body: await res.text(), parsed: null as TodayBody | null }
  }

  beforeAll(async () => {
    for (const doc of await storedDays()) await doc.ref.delete()
  })

  /**
   * PRD Other requirements 3 and Edge case 5 — the card "does not change between opens".
   * Byte-identical, not merely equivalent: `generatedAt` advancing is exactly the failure
   * this is here to catch, and D4's "does not change on refresh" rests on it.
   */
  test('two calls with no new data return byte-identical bodies and one document', async () => {
    const first = await fetchToday()
    const second = await fetchToday()
    expect(second.body).toBe(first.body)
    expect((await storedDays()).length).toBe(1)
  })

  test('a new event regenerates it; a refresh after that does not', async () => {
    const before = await fetchToday()
    const created = await post(sport(todayIn('UTC')))
    expect(created.status).toBe(201)

    const after = await fetchToday()
    expect(after.body).not.toBe(before.body)
    const parsedBefore = JSON.parse(before.body) as TodayBody
    const parsedAfter = JSON.parse(after.body) as TodayBody
    expect(parsedAfter.generatedAt > parsedBefore.generatedAt).toBe(true)
    expect((await storedDays()).length).toBe(1)

    // and it settles: nothing changed since, so the next open is the same document
    expect((await fetchToday()).body).toBe(after.body)
  })

  test('an edit, a delete, a restore and a body-signals upsert each regenerate it', async () => {
    const date = todayIn('UTC')
    const created = await json<{ event: { id: string } }>(await post(sport(date)))
    const id = created.event.id

    const afterCreate = await fetchToday()

    const patched = await api(`/me/events/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ type: 'sport', localDate: date, note: 'edited', timeZone: 'UTC' }),
    })
    expect(patched.status).toBe(200)
    const afterEdit = await fetchToday()
    expect(afterEdit.body).not.toBe(afterCreate.body)

    expect((await api(`/me/events/${id}`, { method: 'DELETE' })).status).toBe(200)
    const afterDelete = await fetchToday()
    expect(afterDelete.body).not.toBe(afterEdit.body)

    const restored = await api(`/me/events/${id}/restore`, { method: 'POST' })
    expect(restored.status).toBe(200)
    const afterRestore = await fetchToday()
    expect(afterRestore.body).not.toBe(afterDelete.body)

    const upserted = await api(`/me/body-signals/${date}`, {
      method: 'PUT',
      body: JSON.stringify({ energy: 2, timeZone: 'UTC' }),
    })
    expect(upserted.status).toBe(200)
    const afterSignals = await fetchToday()
    expect(afterSignals.body).not.toBe(afterRestore.body)

    expect((await storedDays()).length).toBe(1)
  })

  test('saving the questionnaire regenerates it', async () => {
    const before = await fetchToday()
    const saved = await api('/me/questionnaire', {
      method: 'PUT',
      body: JSON.stringify(profileAged(30)),
    })
    expect(saved.status).toBe(200)
    expect((await fetchToday()).body).not.toBe(before.body)
  })

  /**
   * "Today" is the caller's, never the server's — the same rule `localDate` follows.
   * Pacific/Kiritimati (UTC+14) and Pacific/Midway (UTC-11) are 25 hours apart, so their
   * local dates always differ and a server deriving the day from its own clock would have
   * to get one of them wrong.
   */
  test("the request's time zone decides which day this is", async () => {
    const east = todayIn('Pacific/Kiritimati')
    const west = todayIn('Pacific/Midway')
    expect(east).not.toBe(west)

    const eastCard = await json<TodayBody>(await api('/me/today?timeZone=Pacific/Kiritimati'))
    const westCard = await json<TodayBody>(await api('/me/today?timeZone=Pacific/Midway'))
    expect(eastCard.date).toBe(east)
    expect(westCard.date).toBe(west)

    // Two days, two documents, each stored under the date its caller was on.
    const ids = (await storedDays()).map((doc) => doc.id)
    expect(ids).toContain(east)
    expect(ids).toContain(west)
  })

  test('omitting the time zone falls back to UTC, as events do', async () => {
    const card = await json<TodayBody>(await api('/me/today'))
    expect(card.date).toBe(todayIn('UTC'))
  })

  /**
   * The zone decides more than which day it is. A stored `loggedAt` is a wall clock in
   * *her* zone, and `today.ts` turns it into an instant using the zone the route passes
   * down — the caller's, not UTC. Read as UTC, an entry made a minute ago in
   * Pacific/Kiritimati (UTC+14) lands fourteen hours in the future, and D1 discards it as
   * something that has not happened yet. So the card she gets changes, not just its date:
   * rung 2 speaks to her log, or the educational fallback stands in for it.
   */
  test("the caller's zone is the one stored wall clocks are read in", async () => {
    await clearEvents()
    for (const doc of await storedDays()) await doc.ref.delete()
    const zone = 'Pacific/Kiritimati'
    const day = todayIn(zone)

    // Not low: `lowAtOrBelow` is 2, so this is an observed signal and not a pattern —
    // which keeps the case about the conversion rather than about rung 2's run.
    const logged = await api(`/me/body-signals/${day}`, {
      method: 'PUT',
      body: JSON.stringify({ energy: 4, timeZone: zone }),
    })
    expect(logged.status).toBe(200)

    const served = await json<TodayBody>(await api(`/me/today?timeZone=${zone}`))
    expect(served.date).toBe(day)
    expect(served.card.templateId).toBe('signals_today')
    expect(served.card.rung).toBe('pattern')
  })
})

// ── The cycle maths, through the route ─────────────────────────────────────────────────

/**
 * `GET /me/today` over a real cycle history (#179).
 *
 * Until this issue `today.ts` handed D1 a hardcoded "knows nothing" `CycleEstimate`, so no
 * request this repo could make had ever produced a card that states a phase. These cases are
 * the first that do, and they are deliberately end to end — through the route, against
 * entries created through `POST /me/events` — because the two things #179 could quietly get
 * wrong are both invisible one layer down: a `periodEnd` mark dropped on the mapping seam,
 * and an event window too narrow to see the history the maths is asked to read. Both pass
 * every unit test of `cycle.ts`, which is tested against fixtures it is handed directly.
 *
 * They run against this file's own server, which has the pattern rung configured and
 * inherits the `CYCLE_*` group from the environment `scripts/ci-api.sh` exports.
 *
 * Age is not a variable here: every fixture's variation is either 0–1 day (inside the
 * tightest FIGO band) or over 20 (outside the widest), so which band `bandForAge` picks
 * cannot change an answer — which is what lets these cases run after the one that saves a
 * questionnaire without depending on whether it did.
 */
describe.skipIf(!onEmulators)('GET /me/today, over a logged cycle history', () => {
  const post = (body: unknown) => api('/me/events', { method: 'POST', body: JSON.stringify(body) })

  /** One flow day, optionally carrying #75's "my period ended" mark. Returns its id, which
   *  is what the delete case needs. */
  const flowOn = async (localDate: string, periodEnd = false): Promise<string> => {
    const res = await post({
      type: 'cycle',
      localDate,
      payload: periodEnd ? { flow: 'medium', periodEnd: true } : { flow: 'medium' },
      timeZone: 'UTC',
    })
    expect(res.status).toBe(201)
    return (await json<{ event: { id: string } }>(res)).event.id
  }

  const spottingOn = async (localDate: string) => {
    const res = await post({
      type: 'cycle',
      localDate,
      payload: { spotting: true },
      timeZone: 'UTC',
    })
    expect(res.status).toBe(201)
  }

  /** A period as she would log it: `days` consecutive flow days from `start`. */
  const periodFrom = async (start: string, days: number): Promise<string> => {
    const first = await flowOn(start)
    for (let offset = 1; offset < days; offset++) await flowOn(shiftDays(start, offset))
    return first
  }

  /**
   * A known account and no cached card.
   *
   * Every case here asserts *which* card the ladder chose, so it cannot start from whatever
   * ran before it — and a soft-deleted entry is still a row `lastEventChangeAt` can see,
   * which is why `clearEvents` hard-removes rather than deleting through the route.
   */
  const startFresh = async () => {
    await clearEvents()
    for (const doc of await storedDays()) await doc.ref.delete()
  }

  const cardToday = async (): Promise<TodayBody> => {
    const res = await api('/me/today?timeZone=UTC')
    expect(res.status).toBe(200)
    return json<TodayBody>(res)
  }

  /** `today - back`, in UTC, which is the zone every case here calls in. */
  const back = (days: number) => shiftDays(todayIn('UTC'), -days)

  test('the constants these fixtures are built for are the ones this run configured', () => {
    expect(config.cycle).toEqual(CYCLE_RULES)
  })

  /**
   * **The first card in this repo's history to state a phase.**
   *
   * Six logged periods, 28 days apart, the last opening six days ago: five counted cycles
   * (over A26's ≥3 gate), a variation of zero, and a fertile window that opens on cycle day
   * 10 — so today, cycle day 7, is follicular. Her last logged flow day is four days ago,
   * which is past `minPeriodGapDays`, so the period run is over and she is not menstrual.
   *
   * Follicular is the *only* phase this card is selected for since #184/#195 — every other
   * phase falls through to the educational card rather than being told it is approaching
   * ovulation — so this fixture is built for it rather than for whichever phase happened to
   * come out.
   *
   * The oldest entry it reads is 146 days back, which is also what pins the widened event
   * window: on #98's three-day read the maths sees nothing and this card is unreachable.
   */
  test('six regular logged periods reach the phase card', async () => {
    await startFresh()
    for (const days of [146, 118, 90, 62, 34]) await periodFrom(back(days), 2)
    await periodFrom(back(6), 3)

    const today = await cardToday()
    expect(today.card.templateId).toBe('phase_energy')
    expect(today.card.rung).toBe('phase')
    expect(today.card.state).toBe('home_d')
    expect(today.card.kicker).toBe('Cycle day 7 · likely approaching ovulation')
    expect(today.card.title).toBe(TEMPLATES.find((t) => t.id === 'phase_energy')!.title)
    expect(JSON.stringify(today.card)).not.toMatch(UNFILLED)
  })

  /**
   * A25 item 5 — recomputed on every edit to a flow entry, never a nightly batch.
   *
   * Deleting the day the current period opened on moves the anchor forward one day, so the
   * same fixture answers cycle day 6 instead of 7 on the very next read. Through D3's
   * existing `dataChangedAt` path: nothing here clears the stored card, and the card that
   * comes back is a different one.
   */
  test('deleting the flow day the cycle is anchored on moves the card on the next read', async () => {
    await startFresh()
    for (const days of [146, 118, 90, 62, 34]) await periodFrom(back(days), 2)
    const anchor = await periodFrom(back(6), 3)

    const before = await cardToday()
    expect(before.card.kicker).toBe('Cycle day 7 · likely approaching ovulation')

    expect((await api(`/me/events/${anchor}`, { method: 'DELETE' })).status).toBe(200)

    const after = await cardToday()
    expect(after.card.templateId).toBe('phase_energy')
    expect(after.card.kicker).toBe('Cycle day 6 · likely approaching ovulation')
    expect(after.generatedAt > before.generatedAt).toBe(true)
  })

  /**
   * #197 (merged as #203), end to end, and the reason this issue waited for it.
   *
   * The same woman as the case above, three mornings earlier: day 4 of her period, days 1
   * to 3 logged, and this morning not logged yet — the normal state of most of any morning,
   * since `LogCycleStep.swift` logs one day at a time and back-fills nothing. Every other
   * number is unchanged: five counted 28-day cycles, no irregularity, a fertile window that
   * has not opened. Read by the *logged* run alone she is follicular on cycle day 4, and
   * rung 4's follicular-only card hands her "likely approaching ovulation" over "a harder
   * training session may be an option" while she is bleeding.
   *
   * She is menstrual instead, so no phase card is selected at all and she gets the
   * educational one — the correct answer until the canvas draws a menstrual `home_d` (#191).
   *
   * **The second half is what makes the first half evidence.** `educational` is also what
   * the no-knowledge estimate this issue replaced produced, so on its own it proves
   * nothing. Deleting yesterday's flow entry changes one fact — her last logged day is now
   * two days ago, one past the grace `minPeriodGapDays` allows — and the same account, same
   * history, same morning answers `phase_energy` on cycle day 4. That is the bound
   * `cycle.ts` states on the other side of #197's trade, observed rather than trusted:
   * never menstrual more than `minPeriodGapDays - 1` days past the last day she logged.
   */
  test('a woman still bleeding who has not logged today is not told she is approaching ovulation', async () => {
    await startFresh()
    for (const days of [143, 115, 87, 59, 31]) await periodFrom(back(days), 2)
    await flowOn(back(3))
    await flowOn(back(2))
    const yesterday = await flowOn(back(1))

    const bleeding = await cardToday()
    expect(bleeding.card.templateId).not.toBe('phase_energy')
    expect(bleeding.card.templateId).toBe('educational')
    expect(bleeding.card.state).toBe('home_edu')
    expect(JSON.stringify(bleeding.card)).not.toContain('approaching ovulation')

    expect((await api(`/me/events/${yesterday}`, { method: 'DELETE' })).status).toBe(200)

    const lapsed = await cardToday()
    expect(lapsed.card.templateId).toBe('phase_energy')
    expect(lapsed.card.kicker).toBe('Cycle day 4 · likely approaching ovulation')
  })

  /**
   * D5's contextual shortcut (#100), end to end: her first period ever, logged through the
   * route. No prediction exists — one period is no cycle — so the card states no phase, and
   * the flag must come from her own logged flow rather than from the phase. Deleting today's
   * entry is new data on the next read, and leaves one dry day — still her period (#197).
   */
  test('her first period, logged today, is ongoing before any phase can be', async () => {
    await startFresh()
    const empty = await cardToday()
    expect(empty.mode).toBe('cycle')
    expect(empty.periodOngoing).toBe(false)

    await flowOn(back(1))
    const todays = await flowOn(back(0))
    const logging = await cardToday()
    expect(logging.periodOngoing).toBe(true)
    // The premise: one period is no counted cycle, so the card is still learning her cycle
    // and names no phase — the flag above cannot have come from one.
    expect(logging.card.templateId).toBe('still_learning')

    // Yesterday alone is one dry day: still her period (#197's grace).
    expect((await api(`/me/events/${todays}`, { method: 'DELETE' })).status).toBe(200)
    expect((await cardToday()).periodOngoing).toBe(true)
  })

  /**
   * The same boundary as the card's phase through the route: the bleeding fixture above,
   * which the card answers with no ovulation copy, is ongoing; with yesterday deleted — two
   * dry days, where the card turns to `phase_energy` — it is not.
   */
  test('the flag ends where the menstrual phase ends, through the route', async () => {
    await startFresh()
    for (const days of [143, 115, 87, 59, 31]) await periodFrom(back(days), 2)
    await flowOn(back(3))
    await flowOn(back(2))
    const yesterday = await flowOn(back(1))
    expect((await cardToday()).periodOngoing).toBe(true)

    expect((await api(`/me/events/${yesterday}`, { method: 'DELETE' })).status).toBe(200)
    const lapsed = await cardToday()
    expect(lapsed.card.templateId).toBe('phase_energy')
    expect(lapsed.periodOngoing).toBe(false)
  })

  /**
   * #181's fail-closed gate, held end to end rather than in the pure module alone.
   *
   * Intervals of 28, 60, 28, 60, 28, 60. Only the three 28s are counted, which is enough
   * to pass A26's ≥3 gate, and A25's literal "over the last 6 counted cycles" would read a
   * variation of zero and hand an oligomenorrhoeic user a confident phase and a fertile
   * window. The variation is taken over every interval *between* those cycles instead, so
   * it is 32 days, the FIGO band closes, and the estimate is withheld.
   *
   * Her oldest logged period here is 270 days back — the deepest read in this file, and
   * the one the derived window has to reach for the gate to see the 60-day intervals at
   * all. A window too short does not fail loudly; it answers "regular" (#179 Risks).
   */
  test('alternating 28- and 60-day cycles stay withheld through the route', async () => {
    await startFresh()
    for (const days of [270, 242, 182, 154, 94, 66, 6]) await periodFrom(back(days), 2)

    const today = await cardToday()
    expect(today.card.templateId).toBe('irregular')
    expect(today.card.state).toBe('home_c')
    expect(today.card.rung).toBe('phase')
    expect(JSON.stringify(today.card)).not.toContain('approaching ovulation')
  })

  /**
   * #75's period-end mark, carried across the seam this issue adds — the pair below is the
   * assertion, not either case alone.
   *
   * Identical days in both: four 28-day periods, then flow on days -8, -7 and -6, spotting
   * on -5 and -4, and flow again on -3. The only difference is whether she marked the -6
   * entry as the end of her period.
   *
   * Unmarked, the spotting carries the run across and the -3 flow day continues the same
   * period: one period opening on day -8, cycle day 9, follicular, `phase_energy`. Marked,
   * the -3 flow day is at `minPeriodGapDays` past the mark, so it opens a new period — a
   * five-day interval, outside the countable range, and a variation that closes the band.
   *
   * **The marked half no longer lands on `home_c`** (#190). Her four counted cycles are all
   * 28 days and exactly one interval in the window is uncountable, so C11 withholds under
   * `uncountable-cycle` and rung 4 declines the card that says her cycle lengths vary
   * significantly. She falls through to the educational card, which is what the pair now
   * measures: the mark still changes the answer, and the answer is no longer a false one.
   *
   * **Nothing fails if `toCycleDay` drops `periodEnd`**: the maths simply never sees a mark
   * anyone set, and the marked case answers exactly as the unmarked one does. That is what
   * this pair is for, and it is why the assertion is on both halves.
   */
  const markFixture = async (marked: boolean) => {
    await startFresh()
    for (const days of [120, 92, 64, 36]) await periodFrom(back(days), 2)
    await flowOn(back(8))
    await flowOn(back(7))
    await flowOn(back(6), marked)
    await spottingOn(back(5))
    await spottingOn(back(4))
    await flowOn(back(3))
  }

  test('unmarked, the spotting carries her period across to the later flow day', async () => {
    await markFixture(false)

    const today = await cardToday()
    expect(today.card.templateId).toBe('phase_energy')
    expect(today.card.kicker).toBe('Cycle day 9 · likely approaching ovulation')
  })

  test('and the mark she set opens a new period instead — which the route can see', async () => {
    await markFixture(true)

    const today = await cardToday()
    expect(today.card.templateId).toBe('educational')
    expect(today.card.state).toBe('home_edu')
    // The two halves of what moved: no phase is spoken, and she is not told something
    // about her cycle lengths that her four counted 28-day cycles do not support (#190).
    expect(today.card.templateId).not.toBe('phase_energy')
    expect(today.card.templateId).not.toBe('irregular')
    expect(JSON.stringify(today.card)).not.toContain('vary significantly')
  })

  /**
   * The profile reaching the maths, which nothing else in this file would notice.
   *
   * `bandForAge` reads one field of it and is the only thing that does, so every other
   * fixture here is deliberately age-independent — a `null` handed over in the profile's
   * place would change none of their answers. This one is built on that seam: a spread of
   * eight days across four counted cycles, inside the 18–25 band (nine days) and outside
   * the tightest (seven), which is the band `bandForAge` falls back to when it is given no
   * profile at all. With her age the gate is open and she gets a phase card; without it the
   * same history is refused as irregular.
   *
   * It runs last because it is the one case that writes to `users/{uid}`, and it leaves the
   * account on an age the cases above would not have cared about either way.
   */
  test('her age reaches the maths, and decides which FIGO band the gate applies', async () => {
    await startFresh()
    const saved = await api('/me/questionnaire', {
      method: 'PUT',
      body: JSON.stringify(profileAged(20)),
    })
    expect(saved.status).toBe(200)

    // Intervals of 28, 28, 28 and 36: a median of 28 whichever band applies, and a
    // shortest-to-longest spread of eight.
    for (const days of [126, 98, 70, 42]) await periodFrom(back(days), 2)
    await periodFrom(back(6), 3)

    const today = await cardToday()
    expect(today.card.templateId).toBe('phase_energy')
    expect(today.card.kicker).toBe('Cycle day 7 · likely approaching ovulation')
  })
})

/**
 * The route's three refusals, each on a server that can produce only one of them — which is
 * what makes a green run evidence about *that* `instanceof` arm rather than about 503s in
 * general.
 *
 * Emulator-only and deliberately so. CI runs `scripts/ci-api.sh`, which is emulators, and
 * the only route-level 503 case before these was `skipIf(onEmulators)` — so it was the
 * suite's single skip and CI exercised neither branch. Each server is started inside its
 * case and killed with it: `config.ts` reads the environment once at import, so this is the
 * only seam, and nothing here runs against the real project.
 */
describe.skipIf(!onEmulators)('GET /me/today refuses rather than failing', () => {
  const utcDay = () => todayIn('UTC')

  test("503 when rung 2's thresholds are unconfigured", async () => {
    await todayDocs().doc(utcDay()).delete()
    // Content is seeded, so `TemplateUnavailableError` cannot fire: D1 throws first,
    // at `requirePatternRule`, before `getContent` is reached. The `CYCLE_*` group is
    // inherited and set, so C11's refusal — which since #179 is raised earlier still,
    // while the ladder's inputs are being gathered — cannot fire either.
    const server = await bootApi({ env: NO_PATTERN_ENV, range: PORT_RANGE, label: 'today.test.ts' })
    try {
      const res = await apiAt(server.base, '/me/today?timeZone=UTC')
      // 503, not the 500 `app.onError` hands back anything the route drops.
      expect(res.status).toBe(503)
      expect((await json<ErrorBody>(res)).error.code).toBe('SERVICE_UNAVAILABLE')
      // A refusal is not a card, and nothing was cached under the day.
      expect((await todayDocs().doc(utcDay()).get()).exists).toBe(false)
    } finally {
      server.child.kill()
    }
  }, 60_000)

  test('503 when the content store holds no template for the subject', async () => {
    await todayDocs().doc(utcDay()).delete()
    await firestore.collection('content').doc('templates').delete()
    // Booted *after* the delete, and `content.ts` never caches an empty bundle — so
    // this server reads the store as it is now rather than a warm copy of it. The
    // pattern rung is configured here, so the only refusal left is the template one.
    const server = await bootApi({ env: PATTERN_ENV, range: PORT_RANGE, label: 'today.test.ts' })
    try {
      const res = await apiAt(server.base, '/me/today?timeZone=UTC')
      expect(res.status).toBe(503)
      expect((await json<ErrorBody>(res)).error.code).toBe('SERVICE_UNAVAILABLE')
      expect((await todayDocs().doc(utcDay()).get()).exists).toBe(false)
    } finally {
      server.child.kill()
      await applyContent('templates', TEMPLATES, REVIEW, { rewrite: true })
      invalidateContentCache()
    }
  }, 60_000)

  /**
   * C11's, reachable for the first time since #179 (the issue's fourth acceptance
   * criterion), and tested the way the rung-2 case above is: a server booted with the group
   * empty, because `config.ts` reads the environment once at import.
   *
   * **This is the configuration every deployment runs today** — `deploy-api.yml` sets no
   * `CYCLE_*` variable, deliberately (#176, #191) — so without the arm the change made by
   * #179 turns the first real request into a 500 with a `ref` and no explanation. The
   * pattern rung is configured on this server and `content/` is seeded, so neither of the
   * other two refusals can be what answers.
   */
  test("503 when the cycle maths' constants are unconfigured", async () => {
    await todayDocs().doc(utcDay()).delete()
    const server = await bootApi({
      env: { ...PATTERN_ENV, ...NO_CYCLE_ENV },
      range: PORT_RANGE,
      label: 'today.test.ts',
    })
    try {
      const res = await apiAt(server.base, '/me/today?timeZone=UTC')
      // 503, not the 500 `app.onError` hands back anything the route drops.
      expect(res.status).toBe(503)
      expect((await json<ErrorBody>(res)).error.code).toBe('SERVICE_UNAVAILABLE')
      expect((await todayDocs().doc(utcDay()).get()).exists).toBe(false)
    } finally {
      server.child.kill()
    }
  }, 60_000)
})

/**
 * **Every refusal this module exports is mapped — and the list is derived, not written.**
 *
 * The three cases above boot a server each and prove their own `instanceof` arm end to end,
 * which is the strong evidence. `CycleRulesUnsetError` could not be proved that way until
 * #179: `getToday` handed D1 a no-knowledge `CycleEstimate`, so no request reached the arm,
 * and the arm shipped one issue early (#181) precisely because the day it became reachable
 * was the day a deployment without the `CYCLE_*` group — which is every deployment today,
 * deliberately (#176, #191) — would answer 500 instead of 503. These two cases are what kept
 * it honest in the meantime, and they still hold the general rule:
 *
 *  - the class the route branches on is the *same object* the maths constructs, so the
 *    `instanceof` will match rather than silently falling through to `app.onError`;
 *  - and the route's catch has an arm for every refusal `today.ts` exports, so the next
 *    refusal added below it fails here until it is mapped too — before anything can throw it.
 *
 * Neither needs Firestore or a server, so both run in every environment.
 */
describe('every refusal today.ts exports is a 503 at the route', () => {
  test('the re-exported class is the one the maths throws, not a second copy', () => {
    expect(todayModule.CycleRulesUnsetError).toBe(CycleRulesUnsetError)
    expect(new CycleRulesUnsetError() instanceof todayModule.CycleRulesUnsetError).toBe(true)
  })

  test('the /me/today catch has an arm for each of them', async () => {
    const source = await Bun.file(`${import.meta.dir}/../src/index.ts`).text()
    const route = source.slice(source.indexOf(`app.get('/me/today'`))
    // Comments are stripped before matching: a branch named only in prose is a comment
    // about a mapping, not a mapping.
    const body = route
      .slice(0, route.indexOf('\n});'))
      .split('\n')
      .filter((line) => !line.trimStart().startsWith('//'))
      .join('\n')
    expect(body).toContain('catch (err)')

    const refusals = Object.entries(todayModule)
      .filter(([, value]) => typeof value === 'function' && value.prototype instanceof Error)
      .map(([name]) => name)
    // The list is derived, so this assertion is what stops it being derived as empty.
    expect(refusals.sort()).toEqual([
      'CycleRulesUnsetError',
      'PatternRuleUnsetError',
      'TemplateUnavailableError',
    ])
    for (const name of refusals) {
      expect(body).toContain(`err instanceof ${name}`)
    }
  })
})

/**
 * The pattern rung's thresholds as `config.ts` reads them — a boot-time refusal, so a
 * subprocess, the same shape as `config-emulators.test.ts`. No Firestore, so it runs in
 * every environment.
 */
describe("the pattern rung's configuration", () => {
  /** Enough to get `config.ts` past every other required variable. */
  const BASE_ENV = {
    PATH: process.env.PATH ?? '',
    FIREBASE_PROJECT_ID: 'demo-eva-today-test',
    FIREBASE_WEB_API_KEY: 'not-a-real-key',
    JWT_SECRET: 'not-a-real-secret',
    EMAIL_TRANSPORT: 'log',
    NODE_ENV: 'test',
    POSTMARK_FROM: 'today-test@example.test',
    PUBLIC_WEB_URL: 'http://localhost:4321',
  }

  const bootConfig = async (over: Record<string, string>) => {
    // A bare env, not `...process.env`: a developer with these set would decide the
    // result, and the point is what a given trio does at boot.
    const proc = Bun.spawn(['bun', 'run', 'src/config.ts'], {
      cwd: new URL('..', import.meta.url).pathname,
      env: { ...BASE_ENV, ...over },
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
    return { code, stderr }
  }

  /**
   * Ratings are whole numbers from 1 to 5 (`parseRating`), so `lowAtOrBelow: 5` calls
   * every answered rating low: anyone who logs anything three days running gets the
   * pattern card, and nothing surfaces it — the configuration looks valid and the card
   * looks live. "The 1–5 rating" is a completely plausible reading of the variable name.
   *
   * `requirePatternRule` refuses it too, at selection time (#175). This is the boot-time
   * half: the operator is told at startup rather than by every user's first request.
   */
  test('a rating ceiling that would call every rating low is refused at boot', async () => {
    const { code, stderr } = await bootConfig({
      ...PATTERN_ENV,
      DASHBOARD_PATTERN_LOW_AT_OR_BELOW: '5',
    })
    expect(code).not.toBe(0)
    expect(stderr).toContain('DASHBOARD_PATTERN_LOW_AT_OR_BELOW')
    expect(stderr).toContain('at most 4')
  }, 30_000)

  test('a day count past the copy it can describe is refused at boot too', async () => {
    // The mirror of `requirePatternRule`'s 14-day ceiling (#178): the card's own
    // sentences ("consecutive days", "the last few days") stop being true past 14, so
    // an operator who reads the variable and writes 15 is told at startup.
    const low = await bootConfig({
      ...PATTERN_ENV,
      DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: '15',
    })
    expect(low.code).not.toBe(0)
    expect(low.stderr).toContain('DASHBOARD_PATTERN_LOW_SIGNAL_DAYS')
    expect(low.stderr).toContain('at most 14')

    const severe = await bootConfig({
      ...PATTERN_ENV,
      DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: '15',
    })
    expect(severe.code).not.toBe(0)
    expect(severe.stderr).toContain('DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS')
    expect(severe.stderr).toContain('at most 14')
  }, 30_000)

  test("and the trio this file's servers use boots", async () => {
    expect((await bootConfig(PATTERN_ENV)).code).toBe(0)
  }, 30_000)
})

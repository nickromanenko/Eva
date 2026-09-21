import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { FieldValue } from 'firebase-admin/firestore'
import { RETIREMENTS } from '../scripts/retire-refdata'
import { TEMPLATES } from '../scripts/seed-content'
import { DEFAULT_CATALOGUES } from '../scripts/seed-refdata'
import { adminAuth, firestore } from '../src/firebase'
import {
  applyCatalogue,
  buildSymptomRules,
  CATALOGUE_IDS,
  type Catalogues,
  catalogueVersion,
  type EmergencyGuidanceEntry,
  FALLBACK_GUIDANCE_CODE,
  type OptionItem,
  readCatalogue,
  resolveEmergencyGuidance,
  retireCode,
  type SymptomItem,
  seedIfMissing,
} from '../src/refdata'
import { signUpActivated } from './support/session'

/**
 * Integration tests against the REAL Firebase project, same pattern as events.test.ts.
 *
 * Two rules keep this suite from vandalising shared reference data:
 *
 * - It bootstraps with `seedIfMissing`, never `applyCatalogue`. A catalogue is meant to
 *   be edited in Firestore without a deploy (PRD:483); a test run that reset labels to
 *   the ones in the seed file would destroy exactly that property.
 * - Everything that *mutates* a catalogue does it to a throwaway `test-<uuid>` document,
 *   which `GET /refdata` does not serve, so two verify runs cannot collide and a crashed
 *   run leaves no half-retired chip behind.
 */

/**
 * Every case here makes live round trips to the API, Auth and Firestore. 20s is the
 * ceiling `auth.test.ts`, `events.test.ts` and `email-auth-routes.test.ts` already set, and
 * it is a **ceiling, not a measurement** (#31): high enough that no honest round trip
 * reaches it, low enough that a genuine hang still fails rather than hanging the run.
 *
 * What it replaces is Bun's 5000ms default, which nothing chose. A default that happens to
 * sit just above the cost of a cold connection is the shape of the flake #31 is about: the
 * suite gates every API merge, and one failing run in three teaches people to re-run rather
 * than to read, at which point a real regression looks like the usual flake.
 */
setDefaultTimeout(20_000)

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
const password = 'correct-horse-8'
let token = ''
let uid = ''
const tempCatalogues: string[] = []

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
      ...(init?.headers ?? {}),
    },
  })

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>

interface RefDataBody {
  version: string
  catalogues: Catalogues
}
interface ErrorResponse {
  error: { code: string; message: string }
}
interface EvaEventBody {
  id: string
  type: string
  localDate: string
  payload: { symptoms?: { code: string; severity: string; value?: string }[] }
  deletedAt: string | null
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

const today = todayIn('UTC')

const eventsCollection = () => firestore.collection('users').doc(uid).collection('events')

const refDataDoc = () => firestore.collection('refdata')

/** A throwaway catalogue document, swept in afterAll. */
const tempCatalogue = (): string => {
  const id = `test-${crypto.randomUUID()}`
  tempCatalogues.push(id)
  return id
}

const item = (code: string, label: string, extra: Record<string, unknown> = {}) =>
  ({ code, label, order: 10, status: 'active', freeText: false, ...extra }) as OptionItem

const symptomItem = (code: string, label: string, values: string[] | null = null): SymptomItem => ({
  code,
  label,
  order: 10,
  status: 'active',
  group: 'primary',
  severable: false,
  values,
})

/** The four served catalogues, with one of them filled in — enough to hash. */
const catalogues = (symptoms: SymptomItem[]): Catalogues => ({
  symptoms,
  sportActivities: [],
  appointmentTypes: [],
  emergencyGuidance: [],
})

const bodySignals = (body: Record<string, unknown>) =>
  api(`/me/body-signals/${today}`, { method: 'PUT', body: JSON.stringify(body) })

let live: RefDataBody

// **A budget, because activation is not one round trip any more.** `signUpActivated` is
// sign up, spend a link, sign in — and since #120 the middle step also creates the Firebase
// Auth account, sets its password and stamps two flags. Against the real project that runs
// past Bun's 5000ms hook default often enough to fail a run at random, which reads as a
// product regression rather than as a clock. 60s is the same kind of ceiling the live suites
// set: far above the work, still loud on a genuine hang (#31).
beforeAll(async () => {
  // Sign-up no longer hands out a session (#6): the account has to be activated first.
  // `signUpActivated` does the three steps — sign up, spend an activation token, sign in.
  const session = await signUpActivated(BASE, email, password)
  token = session.token
  uid = session.uid

  // Bootstrap only — writes nothing where a catalogue already exists.
  for (const id of CATALOGUE_IDS) await seedIfMissing(id, DEFAULT_CATALOGUES[id])
  live = await json<RefDataBody>(await api('/refdata'))
}, 60_000)

afterAll(async () => {
  if (uid) {
    const docs = await eventsCollection().listDocuments()
    await Promise.all(docs.map((doc) => doc.delete().catch(() => {})))
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
  await Promise.all(
    tempCatalogues.map((id) =>
      refDataDoc()
        .doc(id)
        .delete()
        .catch(() => {}),
    ),
  )
})

describe('refdata: the endpoint', () => {
  test('requires a bearer token', async () => {
    const res = await api('/refdata', { token: null })
    expect(res.status).toBe(401)
    expect((await json<ErrorResponse>(res)).error.code).toBe('UNAUTHORIZED')
  })

  test('serves the four catalogues, every item with a code and a label', async () => {
    expect(Object.keys(live.catalogues).sort()).toEqual([...CATALOGUE_IDS].sort())
    // Seeded by beforeAll if this project had never seen them.
    expect(live.catalogues.symptoms.length).toBeGreaterThan(0)
    expect(live.catalogues.sportActivities.length).toBeGreaterThan(0)
    expect(live.catalogues.appointmentTypes.length).toBeGreaterThan(0)
    expect(live.catalogues.emergencyGuidance.length).toBeGreaterThan(0)

    for (const id of CATALOGUE_IDS) {
      const items = live.catalogues[id]
      for (const entry of items) {
        expect(typeof entry.code).toBe('string')
        expect(entry.code.length).toBeGreaterThan(0)
        expect(typeof entry.label).toBe('string')
        expect(entry.label.length).toBeGreaterThan(0)
        expect(['active', 'retired']).toContain(entry.status)
      }
      const codes = items.map((entry) => entry.code)
      expect(new Set(codes).size).toBe(codes.length)
    }
  })

  test("one vocabulary: the cycle sheet's chips and the body-signals grid read the same list", async () => {
    // There is exactly one symptoms catalogue — nothing keyed by flow or by sheet.
    const symptomKeys = Object.keys(live.catalogues).filter((key) =>
      key.toLowerCase().includes('symptom'),
    )
    expect(symptomKeys).toEqual(['symptoms'])
    // And it carries the whole vocabulary, not a subset per surface.
    const codes = live.catalogues.symptoms.map((entry) => entry.code)
    expect(codes).toContain('cramps')
    expect(codes).toContain('discharge')
    // Spotting is a cycle marker (#23), never a symptom: one day, one claim
    // about bleeding.
    expect(codes).not.toContain('spotting')
    // Energy is a 1–5 scale on the same sheet, so it is not also a chip (PRD:484).
    expect(codes).not.toContain('low-energy')
  })

  test('libido is one code carrying its direction, with a low/high picker', () => {
    const libido = live.catalogues.symptoms.find((entry) => entry.code === 'libido')
    expect(libido).toBeDefined()
    expect(libido!.status).toBe('active')
    // A direction is a category on the chip's own axis, the way discharge's type is
    // — not a severity, and not a second code (#24).
    expect(libido!.values).toEqual(['low', 'high'])
  })

  test('and it is the only libido code offered as a new choice', () => {
    const libidoish = live.catalogues.symptoms.filter((entry) => entry.code.includes('libido'))
    const active = libidoish.filter((entry) => entry.status === 'active')
    // Two codes for one concept never aggregate — the soft form of the
    // one-vocabulary problem (#24). Exactly one is offered.
    expect(active.map((entry) => entry.code)).toEqual(['libido'])
    // The two it replaced were retired, not deleted: still served, still resolving
    // to a label, so an entry that references one still reads correctly.
    // (Asserted against the live project, which carried both before #24 was applied.)
    const retired = libidoish.filter((entry) => entry.status === 'retired')
    expect(retired.map((entry) => entry.code).sort()).toEqual(['libido-changes', 'low-libido'])
  })

  test('the version is a hash of the content it just served', async () => {
    expect(live.version).toBe(catalogueVersion(live.catalogues))
    expect(live.version.length).toBeGreaterThan(8)
  })

  test('a client holding the current version gets 304 and no body', async () => {
    const res = await api(`/refdata?version=${live.version}`)
    expect(res.status).toBe(304)
    expect(await res.text()).toBe('')
  })

  test('a stale version gets the catalogues back', async () => {
    const res = await api('/refdata?version=not-the-current-one')
    expect(res.status).toBe(200)
    expect((await json<RefDataBody>(res)).version).toBe(live.version)
  })

  test('If-None-Match works the same way, weak or strong', async () => {
    const fresh = await api('/refdata')
    expect(fresh.headers.get('etag')).toBe(`"${live.version}"`)
    for (const header of [`"${live.version}"`, `W/"${live.version}"`]) {
      const res = await api('/refdata', { headers: { 'if-none-match': header } })
      expect(res.status).toBe(304)
    }
    const stale = await api('/refdata', { headers: { 'if-none-match': '"0000000000000000"' } })
    expect(stale.status).toBe(200)
  })

  test('version query wins when non-empty and otherwise falls through to If-None-Match', async () => {
    const header = `"${live.version}"`

    const queryWins = await api('/refdata?version=not-the-current-one', {
      headers: { 'if-none-match': header },
    })
    expect(queryWins.status).toBe(200)

    const absentQuery = await api('/refdata', { headers: { 'if-none-match': header } })
    expect(absentQuery.status).toBe(304)

    const emptyQuery = await api('/refdata?version=', { headers: { 'if-none-match': header } })
    expect(emptyQuery.status).toBe(304)
  })
})

describe('refdata: codes are permanent, labels are not', () => {
  test('changing a label leaves the code alone', async () => {
    const id = tempCatalogue()
    await applyCatalogue(id, [item('probe', 'First name')])
    const before = await readCatalogue(id)
    expect(before.map((entry) => entry.code)).toEqual(['probe'])
    expect(before[0]!.label).toBe('First name')

    await applyCatalogue(id, [item('probe', 'Renamed in the console')], { relabel: true })
    const after = await readCatalogue(id)
    // The identity events point at is unchanged; only the display text moved.
    expect(after.map((entry) => entry.code)).toEqual(['probe'])
    expect(after[0]!.code).toBe(before[0]!.code)
    expect(after[0]!.label).toBe('Renamed in the console')
  })

  test('the version changes when a label changes, and not when nothing does', () => {
    const first = catalogues([symptomItem('probe', 'First name')])
    const relabelled = catalogues([symptomItem('probe', 'Renamed in the console')])
    const added = catalogues([symptomItem('probe', 'First name'), symptomItem('other', 'Other')])

    expect(catalogueVersion(first)).toBe(
      catalogueVersion(catalogues([symptomItem('probe', 'First name')])),
    )
    expect(catalogueVersion(relabelled)).not.toBe(catalogueVersion(first))
    expect(catalogueVersion(added)).not.toBe(catalogueVersion(first))
  })

  test('seeding never drops a code that has left the seed list', async () => {
    const id = tempCatalogue()
    await applyCatalogue(id, [item('kept', 'Kept'), item('dropped', 'Dropped')])
    // Re-seeding without `dropped`: an option vanishing would orphan every event
    // that already references it, so it stays.
    const after = await applyCatalogue(id, [item('kept', 'Kept')])
    expect(after.map((entry) => entry.code).sort()).toEqual(['dropped', 'kept'])
  })

  test('a project that has never seen the catalogue seeds into the retired state', async () => {
    // Without the retired rows in the seed list, a new project (a second env, a
    // staging one, CI pointed somewhere fresh) would carry neither retired code:
    // `retire:refdata` would find nothing to do, and the assertions below — which
    // hold against the live project — would read as a broken test rather than a
    // migration that never ran. The seed file has to state what the vocabulary was.
    const retired = RETIREMENTS.filter((entry) => entry.catalogue === 'symptoms')
    expect(retired.length).toBeGreaterThan(0)

    // `applyCatalogue` into a document that does not exist is a first seed.
    const id = tempCatalogue()
    await applyCatalogue(id, DEFAULT_CATALOGUES.symptoms)
    const status = new Map((await readCatalogue(id)).map((entry) => [entry.code, entry.status]))

    expect(status.get('libido')).toBe('active')
    for (const { code } of retired) expect(status.get(code)).toBe('retired')
  })

  test('retiring takes a code out of the pickers but leaves it valid to write', async () => {
    const id = tempCatalogue()
    await applyCatalogue(id, [item('fading', 'Fading')])
    expect(await retireCode(id, 'fading')).toBe(true)

    const items = await readCatalogue(id)
    expect(items[0]!.status).toBe('retired')
    // Still in the validator's index: an offline queue may hold an entry logged
    // while the chip was still on screen.
    const rules = buildSymptomRules([symptomItem('fading', 'Fading'), symptomItem('live', 'Live')])
    expect(rules.has('fading')).toBe(true)
    expect(rules.has('never-existed')).toBe(false)

    // A re-seed must not quietly bring it back either.
    await applyCatalogue(id, [item('fading', 'Fading')], { relabel: true })
    expect((await readCatalogue(id))[0]!.status).toBe('retired')
  })
})

describe('events: symptoms are checked against the catalogue', () => {
  test('a code the catalogue has never carried is rejected', async () => {
    const res = await bodySignals({ symptoms: [{ code: 'zz-not-a-real-symptom' }] })
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('UNKNOWN_SYMPTOM_CODE')
  })

  test('the same check runs on POST /me/events', async () => {
    const res = await api('/me/events', {
      method: 'POST',
      body: JSON.stringify({
        type: 'bodySignals',
        localDate: today,
        payload: { symptoms: [{ code: 'zz-not-a-real-symptom' }] },
      }),
    })
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('UNKNOWN_SYMPTOM_CODE')
  })

  test('a code from the live catalogue is accepted', async () => {
    const code = live.catalogues.symptoms.find((entry) => entry.values === null)!.code
    const res = await bodySignals({ symptoms: [{ code }] })
    expect(res.status).toBe(200)
    const { event } = await json<{ event: EvaEventBody }>(res)
    expect(event.payload.symptoms).toEqual([{ code, severity: 'normal' }])
  })

  test('discharge carries a value from its own picker, and severity stays separate', async () => {
    const discharge = live.catalogues.symptoms.find((entry) => entry.code === 'discharge')!
    expect(discharge.values).toContain('egg-white')

    const res = await bodySignals({
      symptoms: [
        { code: 'discharge', value: 'egg-white' },
        { code: 'cramps', severity: 'severe' },
      ],
    })
    expect(res.status).toBe(200)
    const { event } = await json<{ event: EvaEventBody }>(res)
    expect(event.payload.symptoms).toEqual([
      { code: 'discharge', severity: 'normal', value: 'egg-white' },
      { code: 'cramps', severity: 'severe' },
    ])
  })

  test('a value the picker does not offer is rejected', async () => {
    const res = await bodySignals({ symptoms: [{ code: 'discharge', value: 'sparkly' }] })
    expect(res.status).toBe(400)
    const { error } = await json<ErrorResponse>(res)
    expect(error.code).toBe('VALIDATION')
    expect(error.message).toContain('discharge')
  })

  test('libido takes low and high, and severity stays separate there too', async () => {
    for (const value of ['low', 'high']) {
      const res = await bodySignals({ symptoms: [{ code: 'libido', value }] })
      expect(res.status).toBe(200)
      const { event } = await json<{ event: EvaEventBody }>(res)
      expect(event.payload.symptoms).toEqual([{ code: 'libido', severity: 'normal', value }])
    }
  })

  test('a libido value outside its picker is rejected', async () => {
    const res = await bodySignals({ symptoms: [{ code: 'libido', value: 'medium' }] })
    expect(res.status).toBe(400)
    const { error } = await json<ErrorResponse>(res)
    expect(error.code).toBe('VALIDATION')
    expect(error.message).toContain('libido')
  })

  test('every declared retirement is retired, and still accepted on write', async () => {
    // Drives off the repo's own record of what was retired, so a row added to
    // `RETIREMENTS` without running the script is caught here rather than by a
    // user. Today that record is the two codes `libido` replaced.
    const retired = RETIREMENTS.filter((entry) => entry.catalogue === 'symptoms')
    expect(retired.length).toBeGreaterThan(0)

    for (const { code } of retired) {
      expect(live.catalogues.symptoms.find((entry) => entry.code === code)!.status).toBe('retired')
      // The retirement contract (#24): a retired code leaves the pickers but
      // stays writable, because an offline queue may hold an entry logged while
      // the chip was still on screen. Dropping it loses a user's health entry.
      const res = await bodySignals({ symptoms: [{ code }] })
      expect(res.status).toBe(200)
      const { event } = await json<{ event: EvaEventBody }>(res)
      expect(event.payload.symptoms).toEqual([{ code, severity: 'normal' }])
    }
  })

  test('a value on a chip that has no picker is rejected', async () => {
    const res = await bodySignals({ symptoms: [{ code: 'cramps', value: 'egg-white' }] })
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('VALIDATION')
  })
})

describe('events: history survives the catalogue changing under it', () => {
  /** Written straight to Firestore because the point is an event that predates the
   *  catalogue it no longer matches — the API will not create one for us. Same
   *  liberty events.test.ts takes when it sweeps the collection. */
  const legacyDate = '2026-01-15'
  let legacyId = ''

  beforeAll(async () => {
    const ref = eventsCollection().doc()
    await ref.set({
      type: 'bodySignals',
      localDate: legacyDate,
      loggedAt: `${legacyDate}T12:00:00`,
      note: null,
      source: 'user',
      payload: { energy: 3, symptoms: [{ code: 'zz-deleted-in-2025', severity: 'severe' }] },
      idempotencyKey: null,
      deletedAt: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    })
    legacyId = ref.id
  })

  test('it reads back untouched — no migration, no silent change of meaning', async () => {
    const res = await api(`/me/events?from=${legacyDate}&to=${legacyDate}`)
    expect(res.status).toBe(200)
    const { events } = await json<{ events: EvaEventBody[] }>(res)
    const found = events.find((event) => event.id === legacyId)!
    expect(found).toBeDefined()
    // The stored code is returned verbatim: reads never validate, so a code that
    // has since left the catalogue cannot break or rewrite an old entry.
    expect(found.payload.symptoms).toEqual([{ code: 'zz-deleted-in-2025', severity: 'severe' }])
  })

  test('and it can still be deleted', async () => {
    const res = await api(`/me/events/${legacyId}`, { method: 'DELETE' })
    expect(res.status).toBe(200)
  })
})

describe('emergency guidance (#87)', () => {
  /**
   * The per-country table LAUNCH §4.3 answers "Emergency guidance is region-aware" with.
   *
   * These are mostly assertions against the **live seeded catalogue**, because the thing
   * being tested is content: what a device in a covered country is shown, and — the one
   * safety property the issue names — that a country the table does not carry resolves
   * to the fallback and **never to another country's number**. Resolution itself runs on
   * the device (the country is never sent to the server), so `resolveEmergencyGuidance`
   * is exercised here as the written-down contract the client mirrors, against entries
   * in memory where the live rows cannot reach it (retirement).
   */
  const liveGuidance = (): EmergencyGuidanceEntry[] => live.catalogues.emergencyGuidance
  // Lazy like `liveGuidance`: these read `live`, which does not exist until `beforeAll`
  // has run. An eager call here evaluates at describe-registration time and throws
  // before any test has started.
  const covered = () =>
    liveGuidance().filter((entry) => entry.code !== FALLBACK_GUIDANCE_CODE)
  const fallback = () => liveGuidance().find((entry) => entry.code === FALLBACK_GUIDANCE_CODE)

  test('the seed ships a fallback and the six storefront countries', () => {
    expect(covered().map((entry) => entry.code).sort()).toEqual(['AU', 'CA', 'GB', 'IE', 'NZ', 'US'])
    for (const entry of liveGuidance()) {
      expect(entry.label.length).toBeGreaterThan(0)
      expect(entry.urgentCareWording.length).toBeGreaterThan(0)
    }
  })

  test('the fallback carries no number and no resources — nothing invented for an uncovered country', () => {
    const entry = fallback()!
    expect(entry).toBeDefined()
    // The safety property, stated on the data: no number at all is safer than a
    // guessed one (#87). The fallback's wording tells her whom to *contact*; it never
    // dials for her.
    expect(entry.emergencyNumber).toBeNull()
    expect(entry.support).toEqual([])
  })

  test('every covered entry states its number in its own wording, and ends in the signed tail', () => {
    for (const entry of covered()) {
      expect(entry.emergencyNumber).not.toBeNull()
      expect(entry.urgentCareWording).toContain(entry.emergencyNumber!)
      // Ends, not merely contains: the tail is the card's last word, so a wording that
      // buried it mid-sentence would be signed copy with something appended after it.
      expect(entry.urgentCareWording).toMatch(/Eva cannot assess this\.$/)
      // A support row that cannot be acted on is not a resource (seed-refdata.ts).
      for (const resource of entry.support) {
        expect(resource.label.length).toBeGreaterThan(0)
        expect(resource.detail.length).toBeGreaterThan(0)
      }
    }
  })

  test('the fallback wording is byte-identical to the red-flag template the device falls back to', () => {
    // The device substitutes a flag card's guidance line with the resolved entry's
    // wording. When refdata never arrives, the card keeps the template's own line — so
    // the fallback entry and the template line must be the same sentence, or an
    // uncovered country would see her card change wording depending on whether a
    // catalogue had loaded.
    const redFlag = TEMPLATES.find((template) => template.id === 'red_flag')!
    expect(redFlag).toBeDefined()
    expect(fallback()!.urgentCareWording).toBe(redFlag.line2 ?? '')
  })

  test('an unknown country resolves to the fallback and never to another country’s number', () => {
    for (const country of [
      'ZZ',
      'DE',
      'FR',
      'JP',
      '  ',
      'USA',
      '419',
      '',
      null,
      undefined,
    ]) {
      const resolved = resolveEmergencyGuidance(liveGuidance(), country)
      expect(resolved?.code).toBe(FALLBACK_GUIDANCE_CODE)
      // The acceptance criterion, twice over: no number, whatever the table carries.
      expect(resolved?.emergencyNumber).toBeNull()
    }
  })

  test('a covered country resolves to its own entry, case and padding aside', () => {
    expect(resolveEmergencyGuidance(liveGuidance(), 'US')?.emergencyNumber).toBe('911')
    expect(resolveEmergencyGuidance(liveGuidance(), 'gb')?.emergencyNumber).toBe('999')
    expect(resolveEmergencyGuidance(liveGuidance(), ' NZ ')?.emergencyNumber).toBe('111')
    // The zero-width no-break space is what JS `trim` strips and a naive whitespace
    // strip misses — pinned here because the device's resolver claims the same
    // contract, and its test pins the same case.
    expect(resolveEmergencyGuidance(liveGuidance(), '\uFEFFUS')?.emergencyNumber).toBe('911')
  })

  test('a retired country resolves to the fallback, not to its own stale wording', () => {
    const entries: EmergencyGuidanceEntry[] = [
      { ...fallback()! },
      { ...covered()[0]!, status: 'retired' },
    ]
    const resolved = resolveEmergencyGuidance(entries, covered()[0]!.code)
    expect(resolved?.code).toBe(FALLBACK_GUIDANCE_CODE)
    expect(resolved?.emergencyNumber).toBeNull()
  })

  test('an empty or unreadable catalogue resolves to nothing rather than to any entry', () => {
    expect(resolveEmergencyGuidance([], 'US')).toBeNull()
    expect(resolveEmergencyGuidance([covered()[0]!], 'US')).not.toBeNull()
    // No fallback in the table: a covered country resolves to its own row (the row is
    // still there), but an unknown one resolves to null — the device then keeps the
    // card's own wording, which is the same neutral sentence.
    expect(resolveEmergencyGuidance([covered()[0]!], 'DE')).toBeNull()
  })

  test('the version hash covers the guidance table: an edit re-versions every client', () => {
    const withGuidance = catalogues([])
    withGuidance.emergencyGuidance = liveGuidance()
    expect(catalogueVersion(withGuidance)).not.toBe(catalogueVersion(catalogues([])))
  })

  test('the route has no country dimension: /refdata?country= serves the identical body', async () => {
    // The data-minimisation half of #87, pinned from the receiving side: a client that
    // did send its country — which the device never does — would get exactly the same
    // catalogue back, so the server cannot hold, differentiate on, or learn a country
    // through this route. The resolution runs on the device; the API stays blind.
    const withCountry = await api('/refdata?country=US&countryCode=DE')
    expect(withCountry.status).toBe(200)
    expect(await json<RefDataBody>(withCountry)).toEqual(live)
  })
})

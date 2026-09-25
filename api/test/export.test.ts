import {
  afterAll,
  beforeAll,
  describe,
  expect,
  mock,
  setDefaultTimeout,
  spyOn,
  test,
} from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'
import { ExportAbortedError, openExport } from '../src/data-export'
import { exportEvents, type EvaEvent } from '../src/events'
import type { NutritionProfile } from '../src/nutrition-profile'
import { exportTodayCards, type TodayBanner, type TodayDocument } from '../src/today'
import type { User } from '../src/users'
import { bootApi, type BootedApi } from './support/boot-api'
import { signUpActivated } from './support/session'

/**
 * `GET /me/export` (#58): everything Eva holds about an account, as one JSON download.
 *
 * Two servers of its own, because `config.ts` is read once per process:
 *
 * - `main` pages at **two** documents (`EXPORT_PAGE_SIZE=2`) with the throttle off, so six
 *   events and three cards cross several pages — including a last page that is exactly
 *   full, which is the one that has to end on an empty read — and every case can export as
 *   often as it likes.
 * - `throttled` allows two exports per account and three per IP, so both dimensions can be
 *   driven to a 429 in a handful of requests.
 *
 * Every account is `e2e+<uuid>@e2e.evaapp.dev` (GUARDRAILS 16) and is swept in `afterAll`.
 * Fixtures the routes cannot write — a stored Today card (its route is 503 while its
 * configuration is unset in every environment), a field on an event no route writes — go
 * in through the Admin SDK, the way `events-retention.test.ts` ages a deletion.
 *
 * The mid-stream half is `openExport` driven in-process with page generators of our own:
 * the real project cannot be made to fail on its second page on demand, and must not be.
 */

setDefaultTimeout(20_000)

// A copy, not the namespace: `mock.module` rewrites the live namespace, so this snapshot is
// what goes back once the one in-process case below is done with its failing seam.
const eventsModule = { ...(await import('../src/events')) }

/** This file's draw range — clear of the suite server's window, events.test.ts'
 *  3100–3299 and today.test.ts' 3400–3599. */
const PORT_RANGE: [number, number] = [3600, 3799]
const PAGE_SIZE = 2
/** Not the default 900, so a `Retry-After` that ignores the configuration is caught. */
const THROTTLE_WINDOW_SECONDS = 777

const password = 'correct-horse-8'
const newEmail = () => `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`

let main: BootedApi
let throttled: BootedApi
const created: string[] = []

interface Session {
  email: string
  token: string
  uid: string
}
let alice: Session
let bob: Session
/** Holds only the documents another ordering would drop — see the ordering case. */
let carol: Session

/** Strings that identify one account's data, and appear nowhere else. */
const aliceMarker = `alice-${crypto.randomUUID()}`
const bobMarker = `bob-${crypto.randomUUID()}`
const canary = `internal-${crypto.randomUUID()}`

const todayInUtc = (): string => new Date().toISOString().slice(0, 10)
const shiftDays = (date: string, days: number): string =>
  new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000).toISOString().slice(0, 10)
const day = (n: number): string => shiftDays(todayInUtc(), -n)

const call = (
  base: string,
  path: string,
  token: string | null,
  init: RequestInit & { headers?: Record<string, string> } = {},
) =>
  fetch(`${base}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(token === null ? {} : { authorization: `Bearer ${token}` }),
      ...init.headers,
    },
  })

const exportAs = (session: Session, base = main.base, headers: Record<string, string> = {}) =>
  call(base, '/me/export', session.token, { headers })

interface ExportBody {
  format: string
  version: number
  exportedAt: string
  account: User
  nutritionProfile: NutritionProfile | null
  events: EvaEvent[]
  today: TodayDocument[]
}

const logEvent = async (session: Session, body: Record<string, unknown>): Promise<EvaEvent> => {
  const res = await call(main.base, '/me/events', session.token, {
    method: 'POST',
    body: JSON.stringify({ timeZone: 'UTC', ...body }),
  })
  if (res.status !== 201) throw new Error(`POST /me/events answered ${res.status}`)
  return ((await res.json()) as { event: EvaEvent }).event
}

const sport = (session: Session, localDate: string, note: string) =>
  logEvent(session, {
    type: 'sport',
    localDate,
    note,
    payload: { activity: 'Yoga', durationMin: 30, intensity: 'light' },
  })

const userDoc = (uid: string) => firestore.collection('users').doc(uid)

/** A stored day as `today.ts` writes one, bookkeeping included — the card and, since #102,
 *  the day's banner rail beside it (`[]` unless a case supplies items). */
const storeCard = (uid: string, date: string, title: string, banners: TodayBanner[] = []) =>
  userDoc(uid)
    .collection('today')
    .doc(date)
    .set({
      date,
      generatedAt: `${date}T08:00:00.000Z`,
      contentVersion: 'test-content-version',
      card: { templateId: 'home_edu', rung: 5, state: 'home_edu', title, actions: [] },
      banners,
      dataChangedAt: `${date}T07:00:00.000Z`,
      storedAt: new Date(),
    })

/** The rail stored under Alice's newest day — the one exported day whose rail is not empty. */
const ALICE_RAIL: TodayBanner[] = [
  {
    id: 'cycle_iron',
    title: 'Iron, energy and the days after your period',
    meta: 'Nutrition · 6 min read',
    url: 'https://example.org/articles/cycle_iron',
  },
]

let aliceEventIds: string[] = []
let deletedEventId = ''
let deletedEventDate = ''

beforeAll(async () => {
  main = await bootApi({
    env: {
      EXPORT_PAGE_SIZE: String(PAGE_SIZE),
      RATE_LIMIT_EXPORT_PER_USER: '0',
      RATE_LIMIT_EXPORT_PER_IP: '0',
    },
    range: PORT_RANGE,
    label: 'export.test.ts',
  })
  throttled = await bootApi({
    env: {
      RATE_LIMIT_EXPORT_PER_USER: '2',
      RATE_LIMIT_EXPORT_PER_IP: '3',
      RATE_LIMIT_WINDOW_SECONDS: String(THROTTLE_WINDOW_SECONDS),
    },
    range: PORT_RANGE,
    label: 'export.test.ts',
  })

  const open = async (): Promise<Session> => {
    const email = newEmail()
    const session = await signUpActivated(main.base, email, password)
    created.push(session.uid)
    return { email, ...session }
  }
  ;[alice, bob, carol] = await Promise.all([open(), open(), open()])

  // Six events for Alice — three pages of two, the last exactly full.
  const logged = [
    await sport(alice, day(2), `${aliceMarker} one`),
    await sport(alice, day(3), `${aliceMarker} two`),
    await sport(alice, day(4), `${aliceMarker} three`),
    await sport(alice, day(5), `${aliceMarker} four`),
    await logEvent(alice, { type: 'cycle', localDate: day(6), payload: { flow: 'medium' } }),
    await logEvent(alice, {
      type: 'bodySignals',
      localDate: day(7),
      payload: { energy: 2, symptoms: [] },
    }),
  ]
  aliceEventIds = logged.map((e) => e.id)

  // One of them soft-deleted, through the route the app uses.
  deletedEventId = logged[1]!.id
  deletedEventDate = day(3)
  const del = await call(main.base, `/me/events/${deletedEventId}`, alice.token, {
    method: 'DELETE',
  })
  if (del.status !== 200) throw new Error(`DELETE answered ${del.status}`)

  // A field no route writes, on a stored event: the export must serve the event's shape,
  // not the document.
  await userDoc(alice.uid).collection('events').doc(logged[0]!.id).update({ leak: canary })

  // The session generation, made present on the document whatever activation left there —
  // equal to what the token carries, so the session stays good.
  const tv = (await userDoc(alice.uid).get()).get('tokenVersion')
  await userDoc(alice.uid).update({ tokenVersion: typeof tv === 'number' ? tv : 0 })

  // Three stored cards for Alice (two pages), one for Bob.
  await storeCard(alice.uid, day(1), `${aliceMarker} card one`)
  await storeCard(alice.uid, day(2), `${aliceMarker} card two`)
  await storeCard(alice.uid, day(3), `${aliceMarker} card three`, ALICE_RAIL)
  await storeCard(bob.uid, day(1), `${bobMarker} card`)

  await sport(bob, day(2), `${bobMarker} note`)

  // A started nutrition setup for Alice (#221), through the route the app uses; Bob has none.
  const setup = await call(main.base, '/me/nutrition/profile', alice.token, {
    method: 'PATCH',
    body: JSON.stringify({
      goal: 'lose',
      focusAreas: ['ironDeficiencyAnaemia', 'moreWater'],
      targetWeightKg: 61.5,
      step: 'mealPattern',
    }),
  })
  if (setup.status !== 200) throw new Error(`PATCH /me/nutrition/profile answered ${setup.status}`)

  // Carol: one ordinary entry, one stored entry with no `localDate`, `createdAt` or
  // `updatedAt`, and one card with neither `date` nor `generatedAt` — each the field another ordering would
  // sort on, and a query ordered on a field skips every document that lacks it.
  await sport(carol, day(2), 'carol ordinary')
  await userDoc(carol.uid)
    .collection('events')
    .doc('carol-no-fields')
    .set({ type: 'sport', note: 'carol bare', deletedAt: null, payload: {} })
  await userDoc(carol.uid)
    .collection('today')
    .doc(day(4))
    .set({ contentVersion: 'carol-bare-card', card: { title: 't' } })
}, 120_000)

afterAll(async () => {
  main?.child.kill()
  throttled?.child.kill()
  for (const uid of created) {
    for (const sub of ['events', 'today', 'nutrition']) {
      const docs = await userDoc(uid)
        .collection(sub)
        .listDocuments()
        .catch(() => [])
      await Promise.all(docs.map((doc) => doc.delete().catch(() => {})))
    }
    await userDoc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
}, 60_000)

describe('GET /me/export — who may ask', () => {
  test('no token is 401 in the error shape', async () => {
    const res = await call(main.base, '/me/export', null)
    expect(res.status).toBe(401)
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('UNAUTHORIZED')
  })

  test('a token that is not ours is 401', async () => {
    const res = await call(main.base, '/me/export', 'not-a-token')
    expect(res.status).toBe(401)
  })

  test("a deleted account's still-valid token is refused", async () => {
    const email = newEmail()
    const doomed = await signUpActivated(main.base, email, password)
    created.push(doomed.uid)
    await sport({ email, ...doomed }, day(2), 'doomed')
    const del = await call(main.base, '/me', doomed.token, { method: 'DELETE' })
    expect(del.status).toBe(200)

    const res = await call(main.base, '/me/export', doomed.token)
    expect(res.status).toBe(401)
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('UNAUTHORIZED')
  })
})

describe('GET /me/export — a superseded session', () => {
  test('a token from before a tokenVersion bump is refused (#76)', async () => {
    const email = newEmail()
    const stale = await signUpActivated(main.base, email, password)
    created.push(stale.uid)
    expect((await call(main.base, '/me/export', stale.token)).status).toBe(200)

    const tv = (await userDoc(stale.uid).get()).get('tokenVersion')
    await userDoc(stale.uid).update({ tokenVersion: (typeof tv === 'number' ? tv : 0) + 1 })

    const res = await call(main.base, '/me/export', stale.token)
    expect(res.status).toBe(401)
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('UNAUTHORIZED')
  })
})

describe('GET /me/export — the download', () => {
  test('is an attachment named for the UTC day, and never cached', async () => {
    const before = Date.now()
    const res = await exportAs(alice)
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toBe('application/json; charset=utf-8')
    expect(res.headers.get('cache-control')).toBe('no-store')

    const body = (await res.json()) as ExportBody
    const stamped = Date.parse(body.exportedAt)
    expect(stamped).toBeGreaterThanOrEqual(before - 5_000)
    expect(stamped).toBeLessThanOrEqual(Date.now() + 5_000)
    expect(res.headers.get('content-disposition')).toBe(
      `attachment; filename="eva-export-${body.exportedAt.slice(0, 10)}.json"`,
    )
    expect(body.exportedAt.slice(0, 10)).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })

  test('has exactly the contracted top level, in order', async () => {
    const body = (await (await exportAs(alice)).json()) as ExportBody
    expect(Object.keys(body)).toEqual([
      'format',
      'version',
      'exportedAt',
      'account',
      'nutritionProfile',
      'events',
      'today',
    ])
    expect(body.format).toBe('eva-export')
    expect(body.version).toBe(1)
  })

  test('account is exactly what GET /me answers', async () => {
    const [exported, me] = await Promise.all([
      exportAs(alice).then((r) => r.json() as Promise<ExportBody>),
      call(main.base, '/me', alice.token).then((r) => r.json() as Promise<{ user: User }>),
    ])
    expect(exported.account).toEqual(me.user)
    expect(exported.account.id).toBe(alice.uid)
  })

  test('account.authProviders is assembled as GET /me assembles it, not read from the document (#117)', async () => {
    // The stored array and Auth disagree in both directions: the document lists Google,
    // which Auth does not hold; Auth holds Apple, which the document does not list. The
    // export has to answer as `GET /me` does — Auth's federated identities plus the stored
    // password fact — and must not carry the gate's internal `passwordChosen`.
    const email = newEmail()
    const session = await signUpActivated(main.base, email, password)
    created.push(session.uid)
    await userDoc(session.uid).update({ authProviders: ['password', 'google.com'] })
    await adminAuth.updateUser(session.uid, {
      providerToLink: {
        providerId: 'apple.com',
        uid: `apple.com-sub-${crypto.randomUUID()}`,
        email,
      },
    })

    const [res, me] = await Promise.all([
      exportAs({ email, ...session }),
      call(main.base, '/me', session.token).then((r) => r.json() as Promise<{ user: User }>),
    ])
    expect(res.status).toBe(200)
    const exported = (await res.json()) as ExportBody

    expect(me.user.authProviders).toEqual(['password', 'apple.com'])
    expect(exported.account.authProviders).toEqual(me.user.authProviders)
    expect(Object.keys(exported.account)).not.toContain('passwordChosen')
  })

  test('nutritionProfile is exactly what GET /me/nutrition/profile answers', async () => {
    const [exported, served] = await Promise.all([
      exportAs(alice).then((r) => r.json() as Promise<ExportBody>),
      call(main.base, '/me/nutrition/profile', alice.token).then(
        (r) => r.json() as Promise<{ nutritionProfile: NutritionProfile }>,
      ),
    ])
    expect(exported.nutritionProfile).toEqual(served.nutritionProfile)
    // Her answers, partial and saying so — and not the stored audit stamps.
    expect(exported.nutritionProfile).toMatchObject({
      goal: 'lose',
      focusAreas: ['ironDeficiencyAnaemia', 'moreWater'],
      targetWeightKg: 61.5,
      step: 'mealPattern',
      complete: false,
    })
    expect(Object.keys(exported.nutritionProfile!)).not.toContain('updatedAt')
  })

  test('nutritionProfile is null for an account that has not started setup', async () => {
    const exported = (await (await exportAs(bob)).json()) as ExportBody
    expect((await call(main.base, '/me/nutrition/profile', bob.token)).status).toBe(404)
    // Present and null — not absent — so a reader can tell "none" from "an older export".
    expect('nutritionProfile' in exported).toBe(true)
    expect(exported.nutritionProfile).toBe(null)
  })

  test('every event, across pages, exactly once — and each in GET /me/events’ shape', async () => {
    const body = (await (await exportAs(alice)).json()) as ExportBody
    const stored = (await userDoc(alice.uid).collection('events').listDocuments()).map((d) => d.id)
    expect(stored.length).toBeGreaterThan(PAGE_SIZE * 2)

    const ids = body.events.map((e) => e.id)
    expect(new Set(ids).size).toBe(ids.length)
    expect([...ids].sort()).toEqual([...stored].sort())
    expect([...ids].sort()).toEqual([...aliceEventIds].sort())

    // A live entry is byte-for-byte the calendar's own answer for it.
    const res = await call(main.base, `/me/events?from=${day(7)}&to=${day(2)}`, alice.token)
    const listed = ((await res.json()) as { events: EvaEvent[] }).events
    expect(listed.length).toBe(aliceEventIds.length - 1)
    for (const event of listed) {
      expect(body.events.find((e) => e.id === event.id)).toEqual(event)
    }
  })

  test('a soft-deleted entry is in the export, marked by its deletedAt', async () => {
    const body = (await (await exportAs(alice)).json()) as ExportBody
    const deleted = body.events.find((e) => e.id === deletedEventId)
    expect(deleted).toBeDefined()
    expect(typeof deleted!.deletedAt).toBe('string')
    expect(Number.isNaN(Date.parse(deleted!.deletedAt!))).toBe(false)
    expect(deleted!.note).toBe(`${aliceMarker} two`)
    expect(
      body.events.filter((e) => e.id !== deletedEventId).every((e) => e.deletedAt === null),
    ).toBe(true)

    // …while the calendar, correctly, no longer shows it.
    const res = await call(
      main.base,
      `/me/events?from=${deletedEventDate}&to=${deletedEventDate}`,
      alice.token,
    )
    expect(((await res.json()) as { events: EvaEvent[] }).events).toEqual([])
  })

  test('every stored card, across pages, in date order and in GET /me/today’s shape', async () => {
    const body = (await (await exportAs(alice)).json()) as ExportBody
    expect(body.today.map((t) => t.date)).toEqual([day(3), day(2), day(1)])
    for (const card of body.today) {
      expect(Object.keys(card)).toEqual([
        'date',
        'generatedAt',
        'contentVersion',
        'card',
        'banners',
      ])
      expect(card.card.title.startsWith(aliceMarker)).toBe(true)
    }
  })

  test("a day's banner rail is exported with it, verbatim (#102)", async () => {
    const body = (await (await exportAs(alice)).json()) as ExportBody
    const rails = Object.fromEntries(body.today.map((t) => [t.date, t.banners]))
    expect(rails[day(3)]).toEqual(ALICE_RAIL)
    expect(rails[day(2)]).toEqual([])
    // A day stored before the rail existed exports an empty one, not a missing key.
    const carolBody = (await (await exportAs(carol)).json()) as ExportBody
    expect(carolBody.today.map((t) => t.banners)).toEqual([[]])
  })

  test("never carries another account's data", async () => {
    const [aliceRaw, bobRaw] = await Promise.all([
      exportAs(alice).then((r) => r.text()),
      exportAs(bob).then((r) => r.text()),
    ])
    const bobEvents = (await userDoc(bob.uid).collection('events').listDocuments()).map((d) => d.id)
    expect(bobEvents.length).toBeGreaterThan(0)

    for (const leaked of [bobMarker, bob.uid, bob.email, ...bobEvents]) {
      expect(aliceRaw.includes(leaked)).toBe(false)
    }
    for (const leaked of [aliceMarker, alice.uid, alice.email, ...aliceEventIds]) {
      expect(bobRaw.includes(leaked)).toBe(false)
    }
    // And each one does carry its own, so the absences above are not vacuous.
    expect(aliceRaw.includes(aliceMarker)).toBe(true)
    expect(bobRaw.includes(bobMarker)).toBe(true)
    const bobBody = JSON.parse(bobRaw) as ExportBody
    expect(bobBody.events.map((e) => e.id)).toEqual(bobEvents)
    expect(bobBody.today.map((t) => t.date)).toEqual([day(1)])
  })

  test('a document lacking the fields another ordering would use is still exported', async () => {
    const body = (await (await exportAs(carol)).json()) as ExportBody
    const ids = body.events.map((e) => e.id)
    expect(ids).toContain('carol-no-fields')
    expect(ids).toHaveLength(2)
    expect(body.today.map((t) => t.contentVersion)).toEqual(['carol-bare-card'])
  })

  test('leaks no internal field and no credential', async () => {
    const raw = await (await exportAs(alice)).text()
    const account = (await userDoc(alice.uid).get()).data()!
    // Present on the document, absent from the export.
    expect(account.tokenVersion).toBeDefined()
    expect(account.activatedAt).toBeDefined()

    for (const internal of [
      '"tokenVersion"',
      '"tv"',
      '"activatedAt"',
      '"dataChangedAt"',
      '"storedAt"',
      '"leak"',
      canary,
    ]) {
      expect(raw.includes(internal)).toBe(false)
    }

    // The link tokens: their document id is the hash, which is the credential's only trace.
    const tokens = await firestore.collection('authTokens').where('email', '==', alice.email).get()
    for (const doc of tokens.docs) expect(raw.includes(doc.id)).toBe(false)
  })
})

describe('GET /me/export — throttle', () => {
  const ip = (n: number) => ({ 'x-forwarded-for': `198.51.100.${n}` })

  test('per account, then per IP, each a 429 with Retry-After', async () => {
    // Alice: two served, the third refused by her own budget.
    expect((await exportAs(alice, throttled.base, ip(7))).status).toBe(200)
    expect((await exportAs(alice, throttled.base, ip(7))).status).toBe(200)
    const third = await exportAs(alice, throttled.base, ip(7))
    expect(third.status).toBe(429)
    expect(((await third.json()) as { error: { code: string } }).error.code).toBe('RATE_LIMITED')
    expect(third.headers.get('retry-after')).toBe(String(THROTTLE_WINDOW_SECONDS))

    // Bob has spent nothing — but that IP has spent three, so his first is refused…
    const shared = await exportAs(bob, throttled.base, ip(7))
    expect(shared.status).toBe(429)
    expect(((await shared.json()) as { error: { code: string } }).error.code).toBe('RATE_LIMITED')
    // …and from anywhere else it is served, so it was the IP and not his account.
    expect((await exportAs(bob, throttled.base, ip(8))).status).toBe(200)

    // Alice's own budget follows her account, not her address: a fresh IP does not reset it.
    const moved = await exportAs(alice, throttled.base, ip(9))
    expect(moved.status).toBe(429)
    expect(moved.headers.get('retry-after')).toBe(String(THROTTLE_WINDOW_SECONDS))
  })
})

// ── The stream itself, in-process ───────────────────────────────────────────────────────

async function* pages<T>(list: T[][], failAt = -1): AsyncGenerator<T[], void, undefined> {
  for (const [i, page] of list.entries()) {
    if (i === failAt) throw new Error('Firestore: users/SECRET-UID/events is unavailable')
    yield page
  }
}

const account = { id: 'u1', email: 'x@example.com' } as unknown as User
const profile = { goal: 'maintain', complete: false } as unknown as NutritionProfile
const ev = (id: string) => ({ id, deletedAt: null }) as unknown as EvaEvent
const card = (date: string) => ({ date }) as unknown as TodayDocument

/** Reads a stream to its end or its failure, keeping every byte that arrived. */
const drain = async (
  stream: ReadableStream<Uint8Array>,
): Promise<{ text: string; failure: unknown }> => {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let text = ''
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) return { text, failure: null }
      text += decoder.decode(value, { stream: true })
    }
  } catch (failure) {
    return { text, failure }
  }
}

const parses = (text: string): boolean => {
  try {
    JSON.parse(text)
    return true
  } catch {
    return false
  }
}

describe('openExport', () => {
  test('writes the whole document, pages joined, key order fixed', async () => {
    const stream = await openExport({
      exportedAt: '2026-09-24T10:00:00.000Z',
      account,
      nutritionProfile: profile,
      events: pages([[ev('a'), ev('b')], [ev('c')], []]),
      today: pages([[card('2026-09-01')], [card('2026-09-02')]]),
      onAbort: () => {
        throw new Error('not expected')
      },
    })
    const { text, failure } = await drain(stream)
    expect(failure).toBe(null)
    const body = JSON.parse(text)
    expect(Object.keys(body)).toEqual([
      'format',
      'version',
      'exportedAt',
      'account',
      'nutritionProfile',
      'events',
      'today',
    ])
    expect(body.nutritionProfile).toEqual(profile)
    expect(body.events.map((e: EvaEvent) => e.id)).toEqual(['a', 'b', 'c'])
    expect(body.today.map((t: TodayDocument) => t.date)).toEqual(['2026-09-01', '2026-09-02'])
  })

  test('an account with nothing logged is two empty arrays', async () => {
    const stream = await openExport({
      exportedAt: '2026-09-24T10:00:00.000Z',
      account,
      nutritionProfile: null,
      events: pages([]),
      today: pages([]),
      onAbort: () => {},
    })
    const body = JSON.parse((await drain(stream)).text)
    expect(body.nutritionProfile).toBe(null)
    expect(body.events).toEqual([])
    expect(body.today).toEqual([])
  })

  test('a failed first read throws before there is a stream', async () => {
    let aborted = false
    await expect(
      openExport({
        exportedAt: '2026-09-24T10:00:00.000Z',
        account,
        nutritionProfile: null,
        events: pages([[ev('a')]], 0),
        today: pages([]),
        onAbort: () => {
          aborted = true
        },
      }),
    ).rejects.toThrow('Firestore')
    expect(aborted).toBe(false)
  })

  test('a failure on a later page fails the stream, and what arrived is not valid JSON', async () => {
    const seen: unknown[] = []
    for (const [events, today] of [
      [pages([[ev('a')], [ev('b')], [ev('c')]], 2), pages([[card('2026-09-01')]])],
      [pages([[ev('a')]]), pages([[card('2026-09-01')], [card('2026-09-02')]], 1)],
    ] as const) {
      const stream = await openExport({
        exportedAt: '2026-09-24T10:00:00.000Z',
        account,
        nutritionProfile: null,
        events,
        today,
        onAbort: (err) => seen.push(err),
      })
      const { text, failure } = await drain(stream)
      expect(failure).toBeInstanceOf(ExportAbortedError)
      // Nothing of Firestore's message reaches what the runtime is handed to print.
      expect(String((failure as Error).message).includes('SECRET-UID')).toBe(false)
      expect(text.length).toBeGreaterThan(0)
      expect(parses(text)).toBe(false)
    }
    // The route is told, with the real error, once per failure.
    expect(seen).toHaveLength(2)
    expect((seen[0] as Error).message).toContain('SECRET-UID')
  })
})

// Page sizes only: a single unbounded read sliced into pages would still pass this.
describe('the owning modules yield bounded pages', () => {
  test('exportEvents and exportTodayCards yield pages no larger than asked for', async () => {
    const eventPages: number[] = []
    for await (const page of exportEvents(alice.uid, 1)) eventPages.push(page.length)
    expect(eventPages).toEqual(aliceEventIds.map(() => 1))

    const cardPages: number[] = []
    for await (const page of exportTodayCards(alice.uid, 2)) cardPages.push(page.length)
    expect(cardPages).toEqual([2, 1])
  })
})

describe('GET /me/export — a failure after the headers, through the real route', () => {
  test('cuts the body short and logs one line naming no one', async () => {
    const leakedMessage = `FIRESTORE-MESSAGE users/${alice.uid}/events/page-2 unavailable`
    mock.module('../src/events', () => ({
      ...eventsModule,
      exportEvents: async function* (): AsyncGenerator<EvaEvent[], void, undefined> {
        yield [{ id: 'first-page', deletedAt: null } as unknown as EvaEvent]
        throw new Error(leakedMessage)
      },
    }))
    const logged = spyOn(console, 'error').mockImplementation(() => {})
    try {
      const { default: server } = await import('../src/index')
      const res = await server.fetch(
        new Request('http://localhost/me/export', {
          headers: { authorization: `Bearer ${alice.token}` },
        }),
      )
      expect(res.status).toBe(200)
      const { text, failure } = await drain(res.body!)
      expect(failure).not.toBe(null)
      expect(text.includes('first-page')).toBe(true)
      expect(parses(text)).toBe(false)

      const lines = logged.mock.calls.map((args) => args.map(String).join(' '))
      expect(lines.filter((line) => line.includes('export_aborted'))).toHaveLength(1)
      for (const line of lines) {
        for (const secret of [alice.uid, alice.email, 'FIRESTORE-MESSAGE', aliceMarker]) {
          expect(line.includes(secret)).toBe(false)
        }
      }
    } finally {
      logged.mockRestore()
      mock.module('../src/events', () => eventsModule)
    }
  })
})

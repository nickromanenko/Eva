import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'
import { signUpActivated } from './support/session'
import { testEmail } from './support/test-email'

/**
 * The consent record and the collection gate (A21, #86).
 *
 * One unconsented account, taken through the whole life of a consent: refused writes,
 * the grant, the freeze a withdrawal is, the re-grant a policy change asks for, and the
 * validation edges. The refusal's shape of "no" that matters most is the one every
 * pre-#86 account is in — there is no record at all, which refuses exactly as a
 * withdrawn record does, and for the same sentence.
 *
 * The account is created with `consent: false`, which is what `signUpActivated`'s
 * default grants and what this suite is here to test by hand.
 */
setDefaultTimeout(20_000)

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const email = testEmail()
const password = 'correct-horse-8'
let token = ''
let uid = ''
let grantedEventId = ''

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
    },
  })

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>

interface ConsentRecordBody {
  version: string
  at: string
  withdrawnAt: string | null
}
interface UserResponse {
  user: { consent: { collect: ConsentRecordBody | null; share: ConsentRecordBody | null } }
}
interface ErrorResponse {
  error: { code: string; message: string }
}

const today = (): string => new Date().toISOString().slice(0, 10)
const backday = (days: number): string =>
  new Date(Date.parse(`${today()}T00:00:00.000Z`) - days * 86_400_000).toISOString().slice(0, 10)

const sport = (localDate: string, extra: Record<string, unknown> = {}) => ({
  type: 'sport',
  localDate,
  payload: { activity: 'Yoga', durationMin: 30, intensity: 'light' },
  timeZone: 'UTC',
  ...extra,
})

const profile = {
  dateOfBirth: '1995-06-15',
  weightKg: 64,
  heightCm: 168,
  goals: ['Energy'],
  conditions: ['noneOfThese'],
  medications: 'none',
  lifestyle: 'active',
  sports: ['Yoga'],
  timeZone: 'UTC',
}

const consent = async (kind: string, body: Record<string, unknown>) =>
  api(`/me/consent/${kind}`, { method: 'PUT', body: JSON.stringify(body) })

const me = async (): Promise<UserResponse['user']> =>
  (await json<UserResponse>(await api('/me'))).user

beforeAll(async () => {
  const session = await signUpActivated(BASE, email, password, { consent: false })
  token = session.token
  uid = session.uid
}, 60_000)

afterAll(async () => {
  if (uid) {
    const events = await firestore.collection('users').doc(uid).collection('events').listDocuments()
    await Promise.all(events.map((doc) => doc.delete().catch(() => {})))
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
})

describe('the consent record (#86)', () => {
  test('a new account has consented to nothing', async () => {
    const user = await me()
    expect(user.consent.collect).toBe(null)
    expect(user.consent.share).toBe(null)
  })

  test('health writes are refused before any consent, and reads and deletes are not', async () => {
    const date = backday(1)
    // All five gated routes, each pinned to the code as well as the status — the code is
    // the client's contract (§3), and a 403 that said something else would sail past a
    // status-only assert. The gate sits before every handler, so the two id-shaped
    // routes answer 403 even with an id nothing matches.
    for (const [attempt, init] of [
      ['/me/events', { method: 'POST', body: JSON.stringify(sport(date)) }],
      ['/me/events/none', { method: 'PATCH', body: JSON.stringify(sport(date)) }],
      ['/me/events/none/restore', { method: 'POST', body: '{}' }],
      [`/me/body-signals/${date}`, { method: 'PUT', body: '{}' }],
      ['/me/questionnaire', { method: 'PUT', body: JSON.stringify(profile) }],
    ] as const) {
      const res = await api(attempt, init)
      expect(res.status).toBe(403)
      expect((await json<ErrorResponse>(res)).error.code).toBe('CONSENT_REQUIRED')
    }

    // Reads and deletion are collection's opposite: both stay open.
    expect((await api(`/me/events?from=${date}&to=${date}`)).status).toBe(200)
    expect((await api(`/me/events/none`, { method: 'DELETE' })).status).toBe(404)
  })

  test('the route itself validates before anything is recorded', async () => {
    expect((await consent('collect', { granted: true })).status).toBe(400)
    expect((await consent('collect', { granted: 'yes', version: 'v' })).status).toBe(400)
    expect((await consent('collect', { granted: true, version: '   ' })).status).toBe(400)
    // The cap is 64 — the refusal test uses 65, because a 64-char *success* would write
    // a record and break the still-nothing-on-record assert below.
    expect((await consent('collect', { granted: true, version: 'v'.repeat(65) })).status).toBe(400)
    expect((await consent('nowhere', { granted: true, version: 'v' })).status).toBe(404)
    expect((await api('/me/consent/collect', { method: 'PUT', token: null, body: '{}' })).status).toBe(401)
    // Still nothing on record after all of that.
    expect((await me()).consent.collect).toBe(null)
  })

  test('withdrawing a consent that was never granted is a no-op', async () => {
    const res = await consent('share', { granted: false })
    expect(res.status).toBe(200)
    expect((await me()).consent.share).toBe(null)
  })

  test('the share consent is recorded but governs nothing', async () => {
    expect((await consent('share', { granted: true, version: '2026-08-30' })).status).toBe(200)
    expect((await me()).consent.share?.version).toBe('2026-08-30')
    // Health writes still refuse — share is not collect.
    expect(
      (await api('/me/events', { method: 'POST', body: JSON.stringify(sport(backday(1))) })).status,
    ).toBe(403)
    expect((await consent('share', { granted: false })).status).toBe(200)
    expect((await me()).consent.share?.withdrawnAt).not.toBe(null)
  })

  test('granting collect records version, instant, and no withdrawal — and opens the writes', async () => {
    const res = await consent('collect', { granted: true, version: '2026-08-30' })
    expect(res.status).toBe(200)
    const record = (await json<UserResponse>(res)).user.consent.collect
    expect(record?.version).toBe('2026-08-30')
    expect(record?.at).toBeTruthy()
    expect(record?.withdrawnAt).toBe(null)

    // The id is kept for the freeze test: what withdrawal may never take away.
    const created = await api('/me/events', {
      method: 'POST',
      body: JSON.stringify(sport(backday(2))),
    })
    expect(created.status).toBe(201)
    grantedEventId = ((await json<{ event: { id: string } }>(created)).event).id
    expect(
      (await api(`/me/body-signals/${backday(1)}`, { method: 'PUT', body: '{"symptoms":[]}' }))
        .status,
    ).toBe(200)
    expect((await api('/me/questionnaire', { method: 'PUT', body: JSON.stringify(profile) })).status).toBe(200)
  })

  test('a withdrawn record freezes rather than erases', async () => {
    const before = (await me()).consent.collect
    expect(before).not.toBe(null)

    const res = await consent('collect', { granted: false })
    expect(res.status).toBe(200)
    const record = (await json<UserResponse>(res)).user.consent.collect
    // The freeze keeps the record's own version and instant, and adds the withdrawal.
    expect(record?.version).toBe(before?.version)
    expect(record?.at).toBe(before?.at)
    expect(record?.withdrawnAt).not.toBe(null)

    // A fresh read agrees, the writes are closed again, and the freeze's whole point is
    // pinned: the event granted above is still there — in the body, not merely a 200
    // that an empty list would also produce.
    expect((await me()).consent.collect?.withdrawnAt).not.toBe(null)
    const surviving = (await json<{ events: { id: string }[] }>(
      await api(`/me/events?from=${backday(2)}&to=${backday(2)}`),
    )).events
    expect(surviving.map((e) => e.id)).toEqual([grantedEventId])
    expect(
      (await api('/me/events', { method: 'POST', body: JSON.stringify(sport(backday(1))) })).status,
    ).toBe(403)
  })

  test('re-granting after a withdrawal records the new version and opens the writes again', async () => {
    const res = await consent('collect', { granted: true, version: '2026-12-01' })
    expect(res.status).toBe(200)
    const record = (await json<UserResponse>(res)).user.consent.collect
    expect(record?.version).toBe('2026-12-01')
    expect(record?.withdrawnAt).toBe(null)
    expect((await api('/me/events', { method: 'POST', body: JSON.stringify(sport(backday(1))) })).status).toBe(201)
  })
})

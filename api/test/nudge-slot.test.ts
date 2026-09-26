import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'
import { applyContent, applySignalVocabulary, invalidateContentCache, type Review } from '../src/content'
import { BANNERS, NUDGES, REVIEW, TEMPLATES, VOCABULARY } from '../scripts/seed-content'
import { bootApi } from './support/boot-api'
import { signIn, signUpActivated } from './support/session'
import { testEmail } from './support/test-email'

/**
 * The nudge slot end to end (D6, #101): the `nudge` on `GET /me/today`, chosen once with the
 * card, and `POST /me/nudges/{id}/dismiss` making an id never eligible again. The pure
 * eligibility is `nudge.test.ts`; this runs the Firestore half against the emulators and a
 * booted API.
 */
setDefaultTimeout(20_000)

const PASSWORD = 'correct-horse-8'
const email = testEmail()

let token = ''
let uid = ''
let base = ''
let child: ReturnType<typeof Bun.spawn> | null = null

const SEED_REVIEW: Review = REVIEW
const RAIL = BANNERS.map((b) => ({ ...b, url: `https://example.org/articles/${b.id}` }))

/** The pattern rung's thresholds, chosen here so the ladder can be evaluated rather than
 *  answer 503 — the same three today.test.ts boots its server with. */
const PATTERN_ENV = {
  DASHBOARD_PATTERN_LOW_SIGNAL_DAYS: '3',
  DASHBOARD_PATTERN_LOW_AT_OR_BELOW: '2',
  DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS: '2',
}

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${base}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
      ...(init?.headers ?? {}),
    },
  })

const todayDoc = () => firestore.collection('users').doc(uid).collection('today')

beforeAll(async () => {
  const spawned = await bootApi({ env: PATTERN_ENV, range: [4200, 4299], label: 'nudge-slot.test.ts' })
  base = spawned.base
  child = spawned.child

  await applyContent('templates', TEMPLATES, SEED_REVIEW, { rewrite: true })
  await applySignalVocabulary(VOCABULARY, SEED_REVIEW)
  await applyContent('banners', RAIL, SEED_REVIEW, { rewrite: true })
  await applyContent('nudges', NUDGES, SEED_REVIEW, { rewrite: true })
  invalidateContentCache()

  const account = await signUpActivated(base, email, PASSWORD)
  token = account.token
  uid = account.uid
}, 60_000)

afterAll(async () => {
  const snapshot = await todayDoc()
    .get()
    .catch(() => null)
  for (const doc of snapshot?.docs ?? []) await doc.ref.delete().catch(() => {})
  if (uid)
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
  if (uid) await adminAuth.deleteUser(uid).catch(() => {})
  for (const id of ['templates', 'vocabulary', 'banners', 'nudges'])
    await firestore
      .collection('content')
      .doc(id)
      .delete()
      .catch(() => {})
  child?.kill()
})

describe('the nudge slot', () => {
  test('a fresh account gets the setup nudge, the only one eligible', async () => {
    const res = await api('/me/today?timeZone=UTC')
    expect(res.status).toBe(200)
    const body = (await res.json()) as { nudge: { id: string } | null }
    // No prediction (no cycle data), no appointment, nothing logged, setup unfinished: the
    // only eligible rule is `nutrition_setup`.
    expect(body.nudge?.id).toBe('nutrition_setup')
  })

  test('dismissing that id removes it from the next generation, and survives a second token', async () => {
    const dismissed = await api('/me/nudges/nutrition_setup/dismiss', { method: 'POST' })
    expect(dismissed.status).toBe(200)

    // The stored day was built before the dismissal; force a regeneration the way new data
    // would, and the re-chosen nudge is empty — the dismissed id never returns.
    await todayDoc().get().then((s) => s.docs.forEach((d) => d.ref.delete()))
    const regenerated = await api('/me/today?timeZone=UTC')
    const body = (await regenerated.json()) as { nudge: { id: string } | null }
    expect(body.nudge).toBeNull()

    // A second token for the same account sees the same record — the dismissal is on
    // `users/{uid}`, not the device.
    const secondToken = await signIn(base, email, PASSWORD)
    const res = await api('/me/today?timeZone=UTC', { token: secondToken })
    const again = (await res.json()) as { nudge: { id: string } | null }
    expect(again.nudge).toBeNull()
  })

  test('dismissing an unknown or already-dismissed id is still 200', async () => {
    expect((await api('/me/nudges/nutrition_setup/dismiss', { method: 'POST' })).status).toBe(200)
    expect((await api('/me/nudges/does-not-exist/dismiss', { method: 'POST' })).status).toBe(200)
  })
})

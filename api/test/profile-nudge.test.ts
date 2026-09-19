import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'
import { signUpActivated } from './support/session'

/**
 * The dismissible "complete your profile" nudge (#19). Server-side so a dismissal survives
 * reinstall and a second device, and it must never block anything.
 */
setDefaultTimeout(20_000)

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
const password = 'correct-horse-8'
let token = ''
let uid = ''

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
    },
  })

const dismissed = async (res: Response): Promise<boolean> =>
  ((await res.json()) as { user: { profileNudgeDismissed: boolean } }).user.profileNudgeDismissed

beforeAll(async () => {
  const session = await signUpActivated(BASE, email, password)
  token = session.token
  uid = session.uid
}, 60_000)

afterAll(async () => {
  if (uid) {
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
  const rows = await firestore.collection('authTokens').where('email', '==', email).get()
  for (const row of rows.docs) await row.ref.delete().catch(() => {})
})

describe('the profile nudge (#19)', () => {
  test('is not dismissed by default, and the dismiss route flips it for good', async () => {
    expect(await dismissed(await api('/me'))).toBe(false)

    const res = await api('/me/profile-nudge/dismiss', { method: 'POST' })
    expect(res.status).toBe(200)
    expect(await dismissed(res)).toBe(true)

    // Server-side: a fresh read sees it, so a second device is not asked again.
    expect(await dismissed(await api('/me'))).toBe(true)
  })

  test('dismissing is idempotent and blocks nothing', async () => {
    const again = await api('/me/profile-nudge/dismiss', { method: 'POST' })
    expect(again.status).toBe(200)
    expect(await dismissed(again)).toBe(true)
    // Profile still reads fine afterwards.
    const me = await api('/me')
    expect(me.status).toBe(200)
  })
})

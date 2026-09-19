import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'
import { signUpActivated } from './support/session'

/**
 * The self-serve "qualitative mode" setting (A31, #212).
 *
 * It is a plain boolean on `users/{uid}` that hides calories, weight targets and
 * deficit/surplus language. Two properties matter and each is pinned here:
 *
 * - **It is off by default and only the explicit route changes it** — a setting, not a
 *   declaration, so turning it on discloses nothing and turning it off restores nothing
 *   silently.
 * - **Eva never infers it.** A31 is "self-declared only": no heuristic on logging patterns,
 *   weight or profile. The one writer is `saveNutritionSetting`; the modules that process
 *   her data must not mention the field, or the source scan below fails the day one does.
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

beforeAll(async () => {
  const session = await signUpActivated(BASE, email, password)
  token = session.token
  uid = session.uid
}, 60_000)

afterAll(async () => {
  if (uid) {
    await firestore.collection('users').doc(uid).delete().catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
  const rows = await firestore.collection('authTokens').where('email', '==', email).get()
  for (const row of rows.docs) await row.ref.delete().catch(() => {})
})

describe('the qualitative-mode setting (A31, #212)', () => {
  const qualitativeOnly = async (res: Response): Promise<boolean> =>
    ((await res.json()) as { user: { nutritionQualitativeOnly: boolean } }).user
      .nutritionQualitativeOnly

  test('is off by default, and only the explicit route turns it on', async () => {
    expect(await qualitativeOnly(await api('/me'))).toBe(false)

    const on = await api('/me/nutrition-settings', {
      method: 'PUT',
      body: JSON.stringify({ qualitativeOnly: true }),
    })
    expect(on.status).toBe(200)
    expect(await qualitativeOnly(on)).toBe(true)

    // Persisted: a fresh read sees it, so the toggle is not a session-only flag.
    expect(await qualitativeOnly(await api('/me'))).toBe(true)
  })

  test('turning it off is reversible, and nothing is silently restored', async () => {
    const off = await api('/me/nutrition-settings', {
      method: 'PUT',
      body: JSON.stringify({ qualitativeOnly: false }),
    })
    expect(off.status).toBe(200)
    expect(await qualitativeOnly(await api('/me'))).toBe(false)
  })

  test('a non-boolean value is refused at the edge', async () => {
    const res = await api('/me/nutrition-settings', {
      method: 'PUT',
      body: JSON.stringify({ qualitativeOnly: 'yes' }),
    })
    expect(res.status).toBe(400)
  })

  test('never inferred: no module that processes her data mentions the field', async () => {
    // A31 is "self-declared only". The setting is a boolean the user toggles, never a
    // conclusion Eva draws from her logs, weight or profile. `saveNutritionSetting` is the
    // one writer; the modules that read her data must not mention the field at all, so an
    // inference added later fails here rather than shipping.
    for (const file of [
      'events.ts',
      'cycle.ts',
      'today.ts',
      'dashboard-rules.ts',
      'content.ts',
      'refdata.ts',
    ]) {
      const source = await Bun.file(`${import.meta.dir}/../src/${file}`).text()
      expect(source).not.toContain('nutritionQualitativeOnly')
    }
  })
})

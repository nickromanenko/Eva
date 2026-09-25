import { afterAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { Timestamp } from 'firebase-admin/firestore'
import { mintToken } from '../src/auth'
import { adminAuth, firestore } from '../src/firebase'
import { default as server } from '../src/index'

/**
 * The retired "qualitative mode" setting (#283).
 *
 * #252 put the hide-numbers preference (A31, #212) on `users/{uid}.nutritionQualitativeOnly`
 * behind `PUT /me/nutrition-settings`; #221 then gave it its one home,
 * `users/{uid}/nutrition/profile.hideNumbers`. #283 removed the route and the `User` field,
 * and left any stored value **dormant**: deleting stored user data is Always-human
 * (AUTONOMY), and nothing reads it. Three things are pinned here:
 *
 * - the route is gone — an unmatched path, not a validation error;
 * - `GET /me` no longer serves the field, whatever the document holds;
 * - nothing rewrites or deletes a stored value — not `GET /me`, not the retired path, and
 *   not a write through a route that serves `User`.
 *
 * Driven **in-process** through `server.fetch` against the real Firestore, like
 * `nutrition-profile.test.ts`, so this file binds no port. The account is written directly
 * with a real Auth user, because every route that serves `User` reads Auth beside the
 * document (#117).
 */
setDefaultTimeout(20_000)

const userDoc = (uid: string) => firestore.collection('users').doc(uid)
const createdUids: string[] = []

/** An activated account whose document still carries the retired field, as one written
 *  while #252's route existed would. */
const legacyAccount = async (): Promise<{ uid: string; token: string }> => {
  const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
  const { uid } = await adminAuth.createUser({
    email,
    password: 'correct-horse-8',
    emailVerified: true,
  })
  createdUids.push(uid)
  await userDoc(uid).set({
    email,
    authProviders: ['password'],
    questionnaireCompleted: false,
    profile: null,
    activatedAt: Timestamp.now(),
    consent: {},
    nutritionQualitativeOnly: true,
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

const stored = async (uid: string): Promise<unknown> =>
  (await userDoc(uid).get()).get('nutritionQualitativeOnly')

afterAll(async () => {
  for (const uid of createdUids) {
    await userDoc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
})

describe('the retired qualitative-mode setting (#283)', () => {
  test('PUT /me/nutrition-settings is an unmatched route, and writes nothing', async () => {
    const { uid, token } = await legacyAccount()
    // Read back after every send, not once at the end: a handler that writes and then answers
    // 404 must fail here. `false` goes first because it is the value that differs from the
    // stored `true`; the `true` send is there so a write of it would still be a 404 to assert.
    for (const qualitativeOnly of [false, true]) {
      const res = await call(token, 'PUT', '/me/nutrition-settings', { qualitativeOnly })
      expect(res.status).toBe(404)
      expect(res.body.error.code).toBe('NOT_FOUND')
      expect({ sent: qualitativeOnly, stored: await stored(uid) }).toEqual({
        sent: qualitativeOnly,
        stored: true,
      })
    }
  })

  test('GET /me no longer serves the field, and leaves the stored value as it was', async () => {
    const { uid, token } = await legacyAccount()
    const me = await call(token, 'GET', '/me')
    expect(me.status).toBe(200)
    // The premise, so the absence below is the route's doing and not a missing account.
    expect(me.body.user.id).toBe(uid)
    expect(Object.keys(me.body.user)).not.toContain('nutritionQualitativeOnly')
    expect(await stored(uid)).toBe(true)
  })

  test('a write through a route that serves User leaves the dormant value untouched', async () => {
    const { uid, token } = await legacyAccount()
    const nudge = await call(token, 'POST', '/me/profile-nudge/dismiss', {})
    expect(nudge.status).toBe(200)
    expect(Object.keys(nudge.body.user)).not.toContain('nutritionQualitativeOnly')
    expect(await stored(uid)).toBe(true)
  })

  test('no module under src/ names the field, so nothing can write it again', async () => {
    // The hide-numbers preference has one home, the nutrition profile's `hideNumbers`
    // (#221). A second writer of the old field is the duplication #283 removed.
    const SRC = `${import.meta.dir}/../src`
    for await (const file of new Bun.Glob('**/*.ts').scan(SRC)) {
      const source = await Bun.file(`${SRC}/${file}`).text()
      expect({ file, mentions: source.includes('nutritionQualitativeOnly') }).toEqual({
        file,
        mentions: false,
      })
    }
  })
})

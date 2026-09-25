import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { Timestamp } from 'firebase-admin/firestore'
import { adminAuth, firestore } from '../src/firebase'
import { signUpActivated } from './support/session'
import { RETENTION_DAYS, purgeUserEvents, retentionCutoff } from '../src/events'
import { testEmail } from './support/test-email'

/**
 * The two halves of "recoverable for 30 days" (#28): the restore route, and the purge
 * that eventually takes what was not restored.
 *
 * Its own account, deliberately. The purge sweeps every event in the account it is
 * pointed at, so sharing a user with events.test.ts would let a broken cutoff quietly
 * delete another test's fixtures and report itself as some unrelated failure.
 *
 * Restore is exercised over HTTP, the way the client will call it. The purge is called
 * as a function, because it has no HTTP surface at all — that is the design (see
 * scripts/purge-events.ts), not a gap in the test.
 *
 * Ages are forced by writing `deletedAt` directly with the Admin SDK. Nothing here
 * waits for real time to pass, and nothing depends on the machine's time zone:
 * `deletedAt` is a server instant and the whole comparison is in milliseconds.
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
const email = testEmail()
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

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>

interface EvaEventBody {
  id: string
  type: string
  localDate: string
  payload: Record<string, unknown>
  deletedAt: string | null
}
interface EventResponse {
  event: EvaEventBody
}
interface EventsResponse {
  events: EvaEventBody[]
}
interface ErrorResponse {
  error: { code: string; message: string }
}

const todayInUtc = (): string => new Date().toISOString().slice(0, 10)

const shiftDays = (date: string, days: number): string =>
  new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000).toISOString().slice(0, 10)

/** A distinct backdated day per fixture, so nothing collides and range reads are exact. */
const day = (n: number): string => shiftDays(todayInUtc(), -n)

const eventsCollection = () => firestore.collection('users').doc(uid).collection('events')

const post = (body: Record<string, unknown>) =>
  api('/me/events', { method: 'POST', body: JSON.stringify(body) })

const addSport = async (localDate: string): Promise<EvaEventBody> =>
  (
    await json<EventResponse>(
      await post({
        type: 'sport',
        localDate,
        timeZone: 'UTC',
        payload: { activity: 'Yoga', durationMin: 30, intensity: 'light' },
      }),
    )
  ).event

const softDelete = (id: string) => api(`/me/events/${id}`, { method: 'DELETE' })

const restore = (id: string) => api(`/me/events/${id}/restore`, { method: 'POST' })

const range = async (from: string, to: string): Promise<EvaEventBody[]> =>
  (await json<EventsResponse>(await api(`/me/events?from=${from}&to=${to}`))).events

const exists = async (id: string): Promise<boolean> =>
  (await eventsCollection().doc(id).get()).exists

/** Backdate the soft delete itself — the audit instant, not the user's wall clock. */
const ageDeletion = (id: string, at: Timestamp) =>
  eventsCollection().doc(id).update({ deletedAt: at })

const daysAgo = (days: number): Timestamp => Timestamp.fromMillis(Date.now() - days * 86_400_000)

/** One backdated soft delete: log it, delete it, then age the deletion. */
const deletedAt = async (localDate: string, at: Timestamp): Promise<string> => {
  const event = await addSport(localDate)
  await softDelete(event.id)
  await ageDeletion(event.id, at)
  return event.id
}

/** Hard-clears the account so a purge test can assert an exact count. */
const clearAll = async () => {
  const docs = await eventsCollection().listDocuments()
  await Promise.all(docs.map((doc) => doc.delete()))
}

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
}, 60_000)

afterAll(async () => {
  if (uid) {
    await clearAll().catch(() => {})
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
    await adminAuth.deleteUser(uid).catch(() => {})
  }
})

describe('events: restore', () => {
  test('restore requires a bearer token', async () => {
    expect((await api('/me/events/x/restore', { method: 'POST', token: null })).status).toBe(401)
  })

  test('a deleted entry comes back whole', async () => {
    const date = day(3)
    const event = await addSport(date)
    expect((await softDelete(event.id)).status).toBe(200)
    expect(await range(date, date)).toHaveLength(0)

    const res = await restore(event.id)
    expect(res.status).toBe(200)
    const restored = (await json<EventResponse>(res)).event
    expect(restored.id).toBe(event.id)
    expect(restored.deletedAt).toBe(null)
    expect(restored.payload.activity).toBe('Yoga')

    // Back in the calendar, and editable again.
    expect((await range(date, date)).map((e) => e.id)).toEqual([event.id])
    const patched = await api(`/me/events/${event.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ type: 'sport', localDate: date, timeZone: 'UTC', note: 'back' }),
    })
    expect(patched.status).toBe(200)
  }, 15_000)

  test('an unknown id and a live entry both 404', async () => {
    const unknown = await restore('does-not-exist')
    expect(unknown.status).toBe(404)
    expect((await json<ErrorResponse>(unknown)).error.code).toBe('NOT_FOUND')

    const live = await addSport(day(4))
    const res = await restore(live.id)
    expect(res.status).toBe(404)
    expect((await json<ErrorResponse>(res)).error.code).toBe('NOT_FOUND')
  }, 15_000)

  test('the recovery window is 30 days: day 29 restores, day 31 does not', async () => {
    // 29 and 31 are written out rather than derived from RETENTION_DAYS: this is
    // the promise the PRD makes to the user (PRD:472), not a restatement of the
    // constant, so it has to fail if the constant moves.
    expect(RETENTION_DAYS).toBe(30)
    const [inside, outside] = await Promise.all([
      deletedAt(day(5), daysAgo(29)),
      deletedAt(day(6), daysAgo(31)),
    ])

    expect((await restore(inside!)).status).toBe(200)
    const res = await restore(outside!)
    expect(res.status).toBe(404)
    const body = await json<ErrorResponse>(res)
    expect(body.error.code).toBe('NOT_FOUND')
    expect(body.error.message).toContain('recovery window')
    // Refusing to restore is not deleting: the purge is the only thing that removes.
    expect(await exists(outside!)).toBe(true)
  }, 20_000)

  test('a one-per-day entry whose day was taken refuses instead of overwriting', async () => {
    const date = day(7)
    const first = (
      await json<EventResponse>(
        await post({ type: 'cycle', localDate: date, timeZone: 'UTC', payload: { flow: 'heavy' } }),
      )
    ).event
    await softDelete(first.id)

    // Re-logging the day reuses the deterministic document ID, so the deleted entry
    // is already gone — there is nothing left for a restore to bring back.
    const again = await post({
      type: 'cycle',
      localDate: date,
      timeZone: 'UTC',
      payload: { spotting: true },
    })
    expect(again.status).toBe(201)
    expect((await json<EventResponse>(again)).event.id).toBe(first.id)

    const res = await restore(first.id)
    expect(res.status).toBe(409)
    expect((await json<ErrorResponse>(res)).error.code).toBe('DAY_ALREADY_LOGGED')

    // The newer entry is untouched — not replaced, not duplicated, not relabelled.
    const cycles = (await range(date, date)).filter((e) => e.type === 'cycle')
    expect(cycles).toHaveLength(1)
    expect(cycles[0]!.payload).toEqual({ spotting: true })
    expect(cycles[0]!.deletedAt).toBe(null)
  }, 20_000)
})

describe('events: purge', () => {
  test('the cutoff is exact to the millisecond, and live entries are never touched', async () => {
    await clearAll()
    const cutoff = retentionCutoff()

    const [live, justDeleted, atCutoff, oneMsOlder] = await Promise.all([
      addSport(day(8)).then((e) => e.id),
      deletedAt(day(9), Timestamp.now()),
      deletedAt(day(10), cutoff),
      deletedAt(day(11), Timestamp.fromMillis(cutoff.toMillis() - 1)),
    ])

    const result = await purgeUserEvents(uid, { cutoff })

    // Exactly one document is one millisecond past the window. Nothing else moves.
    expect(result).toEqual({ purged: 1, skipped: 0 })
    expect(await Promise.all([oneMsOlder, atCutoff, justDeleted, live].map(exists))).toEqual([
      false,
      true,
      true,
      true,
    ])
    // The live entry is still a live entry, not a survivor with a mangled state.
    expect((await range(day(8), day(8))).map((e) => e.id)).toEqual([live!])
  }, 30_000)

  test('with the real cutoff, 29 days stays and 31 days goes', async () => {
    await clearAll()
    const [stays, goes] = await Promise.all([
      deletedAt(day(12), daysAgo(29)),
      deletedAt(day(13), daysAgo(31)),
    ])

    expect(await purgeUserEvents(uid)).toEqual({ purged: 1, skipped: 0 })
    expect(await Promise.all([stays!, goes!].map(exists))).toEqual([true, false])
    // Still restorable, because it was never past its window.
    expect((await restore(stays!)).status).toBe(200)
  }, 30_000)

  test('a dry run deletes nothing, and a purged entry cannot be restored', async () => {
    await clearAll()
    const doomed = await deletedAt(day(14), daysAgo(31))

    expect(await purgeUserEvents(uid, { dryRun: true })).toEqual({ purged: 1, skipped: 0 })
    expect(await exists(doomed)).toBe(true)

    expect(await purgeUserEvents(uid)).toEqual({ purged: 1, skipped: 0 })
    expect(await exists(doomed)).toBe(false)
    expect((await restore(doomed)).status).toBe(404)
  }, 20_000)
})

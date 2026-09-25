import { afterAll, afterEach, describe, expect, setDefaultTimeout, spyOn, test } from 'bun:test'
import { DocumentReference, Timestamp, Transaction } from 'firebase-admin/firestore'
import { mintToken } from '../src/auth'
import { config } from '../src/config'
import * as content from '../src/content'
import { TEMPLATE } from '../src/dashboard-rules'
import {
  createEvent,
  deleteAllUserEvents,
  restoreEvent,
  softDeleteEvent,
  updateEvent,
  type NewEvent,
} from '../src/events'
import { firestore } from '../src/firebase'
import { default as server } from '../src/index'
import { deleteNutritionProfile, saveNutritionProfile } from '../src/nutrition-profile'
import { deleteAllUserToday, getToday, type Phraser } from '../src/today'
import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import {
  AccountGoneError,
  NO_SESSION,
  SessionSupersededError,
  bumpTokenVersion,
  deleteUserDocument,
  markUserDeleted,
} from '../src/users'

/**
 * A write racing `DELETE /me` (#286).
 *
 * The race: a request passes `requireAccount` while the account is live, and its write lands
 * after `DELETE /me` has stamped the tombstone **and swept the collection it writes to** — so
 * the document it creates is under an account nothing links to and nothing will ever delete.
 * Every per-user subcollection writer now reads the account inside its own write transaction
 * (`assertAccountLive`), and refuses.
 *
 * **The interleaving is forced, not hoped for.** `deleteBeforeNextTransaction` replaces
 * `firestore.runTransaction` for one call: that call first runs the delete's tombstone and
 * its subcollection sweeps, then hands over to the real transaction. The account gate reads
 * with a plain `get`, never a transaction, so the handler has already passed it by the time
 * the seam fires — and each case asserts the seam fired, which is what separates "refused by
 * the write" from "refused by the gate". Without the check, every case here writes a document
 * after the sweep and fails on it.
 *
 * That seam fires *before* the transaction starts, so it cannot tell a read inside the
 * transaction from a plain `get` just before it — both see the tombstone. The case under
 * "inside the transaction" closes that: it lets the account read happen, *then* starts the
 * delete while the transaction is still open, which only the read set can refuse.
 *
 * **The same read refuses a superseded session (#294).** A request that passed the gate at
 * one token version, and whose write then reads the account after a password reset bumped it,
 * is refused exactly as the gate would refuse it one request later. The last section forces
 * that interleaving inside the write's own transaction.
 *
 * In-process through `server.fetch`, against the real Firestore — the seam
 * `nutrition-profile.test.ts` uses — so this file binds no port. Accounts are written
 * directly, never signed up: what is under test is the write, not the account's creation.
 */
setDefaultTimeout(20_000)

const createdUids: string[] = []

const userDoc = (uid: string) => firestore.collection('users').doc(uid)
const eventDocs = (uid: string) => userDoc(uid).collection('events')
const todayDocs = (uid: string) => userDoc(uid).collection('today')
const nutritionDocs = (uid: string) => userDoc(uid).collection('nutrition')

/** A live, activated account with a collect consent on record (#86), and a session for it. */
const account = async (): Promise<{ uid: string; token: string }> => {
  const uid = `e2e-delete-race-${crypto.randomUUID()}`
  const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
  createdUids.push(uid)
  await userDoc(uid).set({
    email,
    authProviders: ['password'],
    questionnaireCompleted: false,
    profile: null,
    activatedAt: Timestamp.now(),
    consent: { collect: { version: '2026-08-30', at: Timestamp.now(), withdrawnAt: null } },
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
  })
  return { uid, token: await mintToken(uid, email, SESSION) }
}

/** The generation every session `account()` mints is at — its document carries no
 *  `tokenVersion`, which reads as `0` (#76) — and so what a direct writer call passes as the
 *  request's session. */
const SESSION = 0

afterAll(async () => {
  for (const uid of createdUids) {
    await deleteAllUserEvents(uid).catch(() => {})
    await deleteAllUserToday(uid).catch(() => {})
    await deleteNutritionProfile(uid).catch(() => {})
    await deleteUserDocument(uid).catch(() => {})
  }
})

let seam: ReturnType<typeof spyOn> | null = null
afterEach(() => {
  seam?.mockRestore()
  seam = null
})

/**
 * `DELETE /me`'s inerting and sweeping steps, run inside the next `runTransaction` call and
 * before the real one starts: the tombstone, then every subcollection sweep — the exact state
 * the delete is in when the stranded write used to land.
 */
const deleteBeforeNextTransaction = (uid: string) => {
  const real = firestore.runTransaction.bind(firestore)
  seam = spyOn(firestore, 'runTransaction').mockImplementationOnce((async (
    ...args: Parameters<typeof real>
  ) => {
    expect(await markUserDeleted(uid)).toBe(true)
    await deleteAllUserEvents(uid)
    await deleteAllUserToday(uid)
    await deleteNutritionProfile(uid)
    return real(...args)
  }) as typeof real)
  return seam
}

const call = async (token: string, method: string, path: string, body?: unknown) => {
  const res = await server.fetch(
    new Request(`http://api.test${path}`, {
      method,
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
  )
  return { status: res.status, body: (await res.json()) as Record<string, unknown> }
}

const todayUtc = () => new Date().toISOString().slice(0, 10)

const sport = (localDate: string, idempotencyKey: string | null = null): NewEvent => ({
  type: 'sport',
  localDate,
  loggedAt: `${localDate}T08:00:00`,
  note: null,
  source: 'user',
  idempotencyKey,
  payload: { activity: 'Yoga', durationMin: 30, intensity: 'light' },
})

const cycle = (localDate: string): NewEvent => ({
  type: 'cycle',
  localDate,
  loggedAt: `${localDate}T08:00:00`,
  note: null,
  source: 'user',
  idempotencyKey: null,
  payload: { flow: 'medium' },
})

/** A25–A27's values, as `today.test.ts` carries them. Only so a card can be built in-process
 *  (a local `.env` leaves the group unset); nothing here asserts on the maths. */
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

const PATTERN = { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 2 }

/** Every console line written while `fn` runs — the "not a fault, so no line" half. */
const capturingLogs = async (fn: () => Promise<void>): Promise<string[]> => {
  const logged: string[] = []
  const spies = (['log', 'info', 'warn', 'error', 'debug'] as const).map((method) =>
    spyOn(console, method).mockImplementation((...args: unknown[]) => {
      logged.push(args.map(String).join(' '))
    }),
  )
  try {
    await fn()
  } finally {
    for (const spy of spies) spy.mockRestore()
  }
  return logged
}

/** One eligible row for the banner rail: the Dashboard's mode, a real URL, no subject. */
const RAIL_ITEM: content.Banner = {
  id: 'race_banner',
  phase: 'cycle',
  mode: 'cycle',
  focus: 'Nutrition',
  title: 'A banner',
  meta: 'Nutrition · 4 min read',
  url: 'https://example.test/article',
  subjects: [],
  focusAreas: [],
  status: 'active',
  order: 0,
}
const RAIL_ITEM_SERVED = {
  id: RAIL_ITEM.id,
  title: RAIL_ITEM.title,
  meta: RAIL_ITEM.meta,
  url: RAIL_ITEM.url,
}

/**
 * Runs `fn` with a Today card buildable in-process, so `GET /me/today` reaches its cache
 * write: C11's constants and rung 2's rule (both unset in a local `.env`), and signed content
 * — one active template per id and confidence, one eligible banner — through a stub of
 * `getSignedContent`, the one content read the card path makes (#102). None of it is what is
 * under test; the stub is handed to `fn` so each case can assert it was actually used.
 */
const withBuildableCard = async (
  fn: (stub: ReturnType<typeof spyOn>) => Promise<void>,
): Promise<void> => {
  const saved = { cycle: config.cycle, pattern: config.dashboard.pattern }
  ;(config as { cycle: unknown }).cycle = CYCLE_RULES
  ;(config.dashboard as { pattern: unknown }).pattern = PATTERN
  const templates: content.Template[] = Object.values(TEMPLATE).flatMap((id) =>
    (['plain', 'hedged'] as const).map((confidence) => ({
      id,
      rung: 'any',
      mode: 'any',
      state: 'home_x',
      confidence,
      title: 'A card',
      actions: [],
      slots: [],
      status: 'active' as const,
      order: 0,
    })),
  )
  const stub = spyOn(content, 'getSignedContent').mockResolvedValue({
    content: { version: 'test', templates, banners: [RAIL_ITEM], nudges: [] },
    signedBanners: [RAIL_ITEM],
  })
  try {
    await fn(stub)
  } finally {
    stub.mockRestore()
    ;(config as { cycle: unknown }).cycle = saved.cycle
    ;(config.dashboard as { pattern: unknown }).pattern = saved.pattern
  }
}

/** What the account gate answers a deleted account's token — the answer the racing write
 *  has to match exactly (no new code). */
const DEAD_TOKEN = { error: { code: 'UNAUTHORIZED', message: 'Invalid or expired token' } }

// ── Through the routes: the acceptance criterion ──────────────────────────────────────

describe('a write racing DELETE /me through the route', () => {
  test('POST /me/events: refused inside the write, answered as a dead token, nothing survives', async () => {
    const { uid, token } = await account()
    const logged: string[] = []
    const errors = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
      logged.push(args.map(String).join(' '))
    })
    try {
      const race = deleteBeforeNextTransaction(uid)
      const res = await call(token, 'POST', '/me/events', {
        type: 'cycle',
        localDate: todayUtc(),
        payload: { flow: 'medium' },
        timeZone: 'UTC',
      })
      // The seam fired: the handler passed the gate and reached the write's transaction.
      expect(race).toHaveBeenCalledTimes(1)
      expect(res.status).toBe(401)
      expect(res.body).toEqual(DEAD_TOKEN)
      expect((await eventDocs(uid).get()).size).toBe(0)
      // Not a fault: no `unhandled_error` line.
      expect(logged).toEqual([])
    } finally {
      errors.mockRestore()
    }
    // The same token, one request later, meets the gate — and the gate's answer is identical.
    const after = await call(token, 'GET', `/me/events?from=${todayUtc()}&to=${todayUtc()}`)
    expect(after).toEqual({ status: 401, body: DEAD_TOKEN })
  })

  test('PATCH /me/nutrition/profile: refused inside the write, nothing survives', async () => {
    const { uid, token } = await account()
    const logged = await capturingLogs(async () => {
      const race = deleteBeforeNextTransaction(uid)
      const res = await call(token, 'PATCH', '/me/nutrition/profile', {
        goal: 'lose',
        targetWeightKg: 58,
        step: 'focusAreas',
      })
      expect(race).toHaveBeenCalledTimes(1)
      expect(res).toEqual({ status: 401, body: DEAD_TOKEN })
    })
    expect((await nutritionDocs(uid).get()).size).toBe(0)
    expect(logged).toEqual([])
  })

  test('GET /me/today: the cache write refused answers 401 like the rest — not a 503', async () => {
    const { uid, token } = await account()
    await withBuildableCard(async (stub) => {
      const race = deleteBeforeNextTransaction(uid)
      const res = await call(token, 'GET', '/me/today?timeZone=UTC')
      // Both seams ran: the card was built from the stub, and the delete landed in the gap
      // before the cache write's transaction — so the 401 is the write's, not the gate's.
      expect(stub).toHaveBeenCalled()
      expect(race).toHaveBeenCalledTimes(1)
      expect(res).toEqual({ status: 401, body: DEAD_TOKEN })
    })
    expect((await todayDocs(uid).get()).size).toBe(0)
  })

  test('GET /me/today, no race: the card and its banner rail are stored by that transaction', async () => {
    const { uid, token } = await account()
    await withBuildableCard(async (stub) => {
      const real = firestore.runTransaction.bind(firestore)
      seam = spyOn(firestore, 'runTransaction').mockImplementation(((
        ...args: Parameters<typeof real>
      ) => real(...args)) as typeof real)
      const res = await call(token, 'GET', '/me/today?timeZone=UTC')
      expect(stub).toHaveBeenCalled()
      expect(res.status).toBe(200)
      // The cache write is the only transaction on this path, and it carried the rail (#102).
      expect(seam).toHaveBeenCalledTimes(1)
      const stored = (await todayDocs(uid).get()).docs.map((doc) => doc.data())
      expect(stored).toHaveLength(1)
      expect(stored[0]!.banners).toEqual([RAIL_ITEM_SERVED])
      expect(res.body.banners).toEqual([RAIL_ITEM_SERVED])
    })
  })
})

// ── Inside the transaction: the read has to be in the read set ─────────────────────────

describe('the account read is part of the write transaction, not a check before it', () => {
  /**
   * Starts DELETE /me — tombstone, then the sweep, *not* awaited — the moment the account
   * document has been read "live", by whichever read the writer uses: a transactional `get`
   * or `getAll`, or a plain `DocumentReference.get`. The transaction is still open. With the
   * read in the read set, the tombstone has to wait for (or abort) this transaction, so the
   * write is either swept or refused. With a read outside it, nothing holds the tombstone, the
   * sweep finishes inside the pause, and the write lands after it.
   */
  const deleteAfterAccountRead = (uid: string) => {
    const accountPath = userDoc(uid).path
    const state: { deleting: Promise<void> | null } = { deleting: null }
    const readsAccount = (value: unknown): boolean =>
      (value as { path?: unknown } | null)?.path === accountPath
    const hook = <T extends object>(proto: T, method: keyof T) => {
      const real = proto[method] as (...a: unknown[]) => Promise<unknown>
      return spyOn(proto, method as never).mockImplementation(async function (
        this: unknown,
        ...args: unknown[]
      ) {
        const result = await real.apply(this, args)
        if (state.deleting === null && [this, ...args].some(readsAccount)) {
          state.deleting = (async () => {
            for (let attempt = 0; ; attempt++) {
              try {
                await markUserDeleted(uid)
                break
              } catch (err) {
                if (attempt >= 5) throw err
              }
            }
            await deleteAllUserEvents(uid)
          })()
          // Long enough for an unlocked tombstone and sweep to finish; bounded, because a
          // locked tombstone is waiting on this very transaction.
          await Promise.race([state.deleting, Bun.sleep(4_000)])
        }
        return result
      } as never)
    }
    const spies = [
      hook(Transaction.prototype, 'get'),
      hook(Transaction.prototype, 'getAll'),
      hook(DocumentReference.prototype, 'get'),
    ]
    return { state, restore: () => spies.forEach((spy) => spy.mockRestore()) }
  }

  for (const [path, entry] of [
    ['the plain path — the account is its only read', () => sport(todayUtc())],
    ['the one-per-day path — the account read folded into its own', () => cycle(todayUtc())],
  ] as const) {
    test(`${path}: a delete between the account read and the commit leaves nothing`, async () => {
      const { uid } = await account()
      const race = deleteAfterAccountRead(uid)
      try {
        // Refused on a retry, or committed before the tombstone and then swept — both are
        // fine. What is not fine is an entry left once the delete has finished.
        await createEvent(uid, SESSION, entry()).catch((err: unknown) => {
          expect(err).toBeInstanceOf(AccountGoneError)
        })
      } finally {
        race.restore()
      }
      expect(race.state.deleting).not.toBeNull()
      await race.state.deleting
      expect((await eventDocs(uid).get()).size).toBe(0)
    })
  }
})

// ── Every writer, directly ─────────────────────────────────────────────────────────────

describe('every per-user subcollection writer refuses a tombstoned account in its transaction', () => {
  test('createEvent — the one-per-day path', async () => {
    const { uid } = await account()
    deleteBeforeNextTransaction(uid)
    await expect(createEvent(uid, SESSION, cycle(todayUtc()))).rejects.toBeInstanceOf(
      AccountGoneError,
    )
    expect((await eventDocs(uid).get()).size).toBe(0)
  })

  test('createEvent — the idempotency-key path', async () => {
    const { uid } = await account()
    deleteBeforeNextTransaction(uid)
    await expect(
      createEvent(uid, SESSION, sport(todayUtc(), crypto.randomUUID())),
    ).rejects.toBeInstanceOf(AccountGoneError)
    expect((await eventDocs(uid).get()).size).toBe(0)
  })

  test('createEvent — the plain path, which was not a transaction before #286', async () => {
    const { uid } = await account()
    deleteBeforeNextTransaction(uid)
    await expect(createEvent(uid, SESSION, sport(todayUtc()))).rejects.toBeInstanceOf(
      AccountGoneError,
    )
    expect((await eventDocs(uid).get()).size).toBe(0)
  })

  test('saveNutritionProfile', async () => {
    const { uid } = await account()
    deleteBeforeNextTransaction(uid)
    await expect(saveNutritionProfile(uid, SESSION, { goal: 'maintain' })).rejects.toBeInstanceOf(
      AccountGoneError,
    )
    expect((await nutritionDocs(uid).get()).size).toBe(0)
  })

  test("getToday's cache write — a card is her data in prose, and outlives nothing", async () => {
    const { uid } = await account()
    // The card is built before the write, so the two configured inputs it needs are supplied
    // for this case alone: C11's constants (unset in a local `.env`) and a phraser that needs
    // no seeded `content/`. Neither is what is under test.
    const saved = config.cycle
    ;(config as { cycle: unknown }).cycle = CYCLE_RULES
    const phraser: Phraser = {
      id: 'fixed',
      phrase: () => ({ state: 'home_edu', title: 'A card', actions: [] }),
    }
    const warn = spyOn(console, 'warn').mockImplementation(() => {})
    try {
      const race = deleteBeforeNextTransaction(uid)
      await expect(
        getToday(
          uid,
          SESSION,
          { date: todayUtc(), timeZone: 'UTC' },
          { pattern: { lowSignalDays: 3, lowAtOrBelow: 2, severeSymptomDays: 2 } },
          phraser,
        ),
      ).rejects.toBeInstanceOf(AccountGoneError)
      expect(race).toHaveBeenCalledTimes(1)
      expect((await todayDocs(uid).get()).size).toBe(0)
    } finally {
      ;(config as { cycle: unknown }).cycle = saved
      warn.mockRestore()
    }
  })
})

describe('the edits cannot create a document, and still refuse rather than act on a tombstone', () => {
  /** An entry written while the account was live, then the tombstone — no sweep, so the
   *  entry is still there to be acted on and the assertion is that it was not. */
  const liveEntryThenTombstone = async (
    deleted = false,
  ): Promise<{ uid: string; id: string; before: FirebaseFirestore.DocumentData }> => {
    const { uid } = await account()
    const event = await createEvent(uid, SESSION, sport(todayUtc()))
    if (deleted) expect(await softDeleteEvent(uid, SESSION, event.id)).toBe(true)
    const before = (await eventDocs(uid).doc(event.id).get()).data()!
    expect(await markUserDeleted(uid)).toBe(true)
    return { uid, id: event.id, before }
  }

  const stored = async (uid: string, id: string) => (await eventDocs(uid).doc(id).get()).data()

  test('updateEvent', async () => {
    const { uid, id, before } = await liveEntryThenTombstone()
    await expect(
      updateEvent(uid, SESSION, id, { type: 'sport', localDate: todayUtc(), note: 'edited' }),
    ).rejects.toBeInstanceOf(AccountGoneError)
    expect(await stored(uid, id)).toEqual(before)
  })

  test('softDeleteEvent', async () => {
    const { uid, id, before } = await liveEntryThenTombstone()
    await expect(softDeleteEvent(uid, SESSION, id)).rejects.toBeInstanceOf(AccountGoneError)
    expect(await stored(uid, id)).toEqual(before)
  })

  test('restoreEvent', async () => {
    const { uid, id, before } = await liveEntryThenTombstone(true)
    await expect(restoreEvent(uid, SESSION, id)).rejects.toBeInstanceOf(AccountGoneError)
    expect(await stored(uid, id)).toEqual(before)
  })
})

test('a finished delete — no document at all — refuses the same way', async () => {
  const { uid } = await account()
  await deleteUserDocument(uid)
  await expect(createEvent(uid, SESSION, sport(todayUtc()))).rejects.toBeInstanceOf(
    AccountGoneError,
  )
  expect((await eventDocs(uid).get()).size).toBe(0)
})

// ── A write racing a password reset (#294) ─────────────────────────────────────────────

describe('a write whose session a password reset ends between the gate and the commit', () => {
  /**
   * The reset's first step — `bumpTokenVersion` — run **inside** the write's transaction, the
   * moment it is about to read the account: the request has passed `requireAccount` at the old
   * generation, and the write's own read then sees the new one. Hooks the transaction's reads,
   * not `runTransaction`, so the bump lands after the transaction has begun rather than before
   * it; and before the read rather than after it, because once the account is in the read set
   * the bump waits on this transaction and the write commits first — a legitimate ordering,
   * and not the one under test. `firing` keeps the bump's own `tx.get` of the account from
   * re-entering the hook.
   */
  const resetBeforeAccountRead = (uid: string) => {
    const accountPath = userDoc(uid).path
    const state = { firing: false, bumpedTo: null as number | null }
    const readsAccount = (value: unknown): boolean =>
      (value as { path?: unknown } | null)?.path === accountPath
    const hook = (method: 'get' | 'getAll') => {
      const real = Transaction.prototype[method] as (...a: unknown[]) => Promise<unknown>
      return spyOn(Transaction.prototype, method as never).mockImplementation(async function (
        this: unknown,
        ...args: unknown[]
      ) {
        if (!state.firing && args.some(readsAccount)) {
          state.firing = true
          state.bumpedTo = await bumpTokenVersion(uid)
        }
        return real.apply(this, args)
      } as never)
    }
    const spies = [hook('get'), hook('getAll')]
    return { state, restore: () => spies.forEach((spy) => spy.mockRestore()) }
  }

  /** Runs one route call with the reset forced into its write, and asserts the whole of the
   *  contract: the seam fired (so the gate had passed), the answer is the dead token's, and no
   *  error line was written — `app.onError`'s `unhandled_error` is a `console.error`, and the
   *  read path's own warnings (an unseeded `refdata/` on an emulator) are not this change's. The
   *  caller asserts what was not written. */
  const refusedMidWrite = async (
    uid: string,
    token: string,
    send: () => Promise<{ status: number; body: Record<string, unknown> }>,
  ): Promise<void> => {
    const race = resetBeforeAccountRead(uid)
    const logged: string[] = []
    const errors = spyOn(console, 'error').mockImplementation((...args: unknown[]) => {
      logged.push(args.map(String).join(' '))
    })
    try {
      const res = await send()
      expect(race.state.bumpedTo).toBe(SESSION + 1)
      expect(res).toEqual({ status: 401, body: DEAD_TOKEN })
    } finally {
      race.restore()
      errors.mockRestore()
    }
    expect(logged).toEqual([])
    // What the gate says to the same token one request later — the refusal above has to be
    // byte-for-byte this, or the client would meet a superseded session two different ways.
    expect(await call(token, 'GET', '/me')).toEqual({ status: 401, body: DEAD_TOKEN })
  }

  for (const [path, body] of [
    [
      'the plain path',
      () => ({
        type: 'sport',
        localDate: todayUtc(),
        payload: { activity: 'Yoga', durationMin: 30, intensity: 'light' },
      }),
    ],
    [
      'the one-per-day path',
      () => ({ type: 'cycle', localDate: todayUtc(), payload: { flow: 'medium' } }),
    ],
    [
      'the idempotency-key path',
      () => ({
        type: 'sport',
        localDate: todayUtc(),
        idempotencyKey: crypto.randomUUID(),
        payload: { activity: 'Yoga', durationMin: 30, intensity: 'light' },
      }),
    ],
  ] as const) {
    test(`POST /me/events, ${path}: refused, answered as a superseded token, nothing written`, async () => {
      const { uid, token } = await account()
      await refusedMidWrite(uid, token, () =>
        call(token, 'POST', '/me/events', { ...body(), timeZone: 'UTC' }),
      )
      expect((await eventDocs(uid).get()).size).toBe(0)
    })
  }

  test('PATCH /me/nutrition/profile: refused, nothing written', async () => {
    const { uid, token } = await account()
    await refusedMidWrite(uid, token, () =>
      call(token, 'PATCH', '/me/nutrition/profile', {
        goal: 'lose',
        targetWeightKg: 58,
        step: 'focusAreas',
      }),
    )
    expect((await nutritionDocs(uid).get()).size).toBe(0)
  })

  test('GET /me/today: the cache write refused answers 401 like the rest — no card stored', async () => {
    const { uid, token } = await account()
    await withBuildableCard(async (stub) => {
      await refusedMidWrite(uid, token, () => call(token, 'GET', '/me/today?timeZone=UTC'))
      // The card was built — the refusal is the write's, after the whole of the read path.
      expect(stub).toHaveBeenCalled()
    })
    expect((await todayDocs(uid).get()).size).toBe(0)
  })

  for (const [route, send] of [
    [
      'PATCH /me/events/:id',
      (token: string, id: string) =>
        call(token, 'PATCH', `/me/events/${id}`, {
          type: 'sport',
          localDate: todayUtc(),
          note: 'edited',
          timeZone: 'UTC',
        }),
    ],
    [
      'DELETE /me/events/:id',
      (token: string, id: string) => call(token, 'DELETE', `/me/events/${id}`),
    ],
  ] as const) {
    test(`${route} carries the session too: refused, the entry left as it was`, async () => {
      const { uid, token } = await account()
      const entry = await createEvent(uid, SESSION, sport(todayUtc()))
      const doc = eventDocs(uid).doc(entry.id)
      const before = (await doc.get()).data()
      await refusedMidWrite(uid, token, () => send(token, entry.id))
      expect((await doc.get()).data()).toEqual(before)
    })
  }

  test('a writer called directly throws SessionSupersededError, not AccountGoneError', async () => {
    const { uid } = await account()
    expect(await bumpTokenVersion(uid)).toBe(SESSION + 1)
    await expect(createEvent(uid, SESSION, sport(todayUtc()))).rejects.toBeInstanceOf(
      SessionSupersededError,
    )
    // Equality, not `<`: a generation the account has never reached is not a session either.
    await expect(createEvent(uid, SESSION + 2, sport(todayUtc()))).rejects.toBeInstanceOf(
      SessionSupersededError,
    )
    expect((await eventDocs(uid).get()).size).toBe(0)
    // The current generation still writes — the check refuses a stale session, not a bumped
    // account.
    await createEvent(uid, SESSION + 1, sport(todayUtc()))
    expect((await eventDocs(uid).get()).size).toBe(1)
  })
})

describe('NO_SESSION: a write with no request token behind it', () => {
  test('skips the generation check and nothing else — a tombstone still refuses it', async () => {
    const { uid } = await account()
    expect(await bumpTokenVersion(uid)).toBe(SESSION + 1)
    await createEvent(uid, NO_SESSION, sport(todayUtc()))
    expect((await eventDocs(uid).get()).size).toBe(1)

    expect(await markUserDeleted(uid)).toBe(true)
    await expect(createEvent(uid, NO_SESSION, sport(todayUtc()))).rejects.toBeInstanceOf(
      AccountGoneError,
    )
    expect((await eventDocs(uid).get()).size).toBe(1)
  })

  /**
   * No route may write on nobody's session: every one holds a token, and passing `NO_SESSION`
   * from one would quietly restore #294's window for it. Nothing in `src/` needs the mode today,
   * so the scan is strict — a first production caller (a job, a backfill) fails it and has to be
   * added here on purpose, with the reason in review. Comments are stripped, so documenting the
   * mode does not trip it.
   */
  test('no module under src/ but users.ts names it', async () => {
    const dir = join(import.meta.dir, '..', 'src')
    const named: string[] = []
    for (const file of await readdir(dir)) {
      if (!file.endsWith('.ts') || file === 'users.ts') continue
      const source = (await Bun.file(join(dir, file)).text())
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/.*$/gm, '')
      if (/\bNO_SESSION\b/.test(source)) named.push(file)
    }
    expect(named).toEqual([])
  })
})

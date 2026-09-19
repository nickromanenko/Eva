import { afterAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { createHash } from 'node:crypto'
import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import {
  ACTIVATION_TTL_SECONDS,
  RESET_TTL_SECONDS,
  TOKEN_LENGTH,
  consumeToken,
  deleteTokensForAccount,
  issueToken,
} from '../src/email-tokens'
import { firestore } from '../src/firebase'

/**
 * The `afterAll` below sweeps `authTokens/` with live round trips, and a **per-case timeout
 * does not reach a hook** — so the per-case `SLOW` on every test in this file left the one
 * piece of it that talks to Firestore on Bun's 5000ms default (#31). A hook that times out
 * is reported against an unrelated test *and* leaves the sweep unfinished, which is rows
 * stranded in the real project on top of an unreadable red run.
 */
setDefaultTimeout(20_000)

/**
 * The token store behind activation and reset links (#6), tested directly against the
 * REAL Firestore project — the transaction in `consumeToken` is the property under test,
 * and a fake store would only prove the fake.
 *
 * The uids are fabricated and nothing under `users/` is ever written; the only documents
 * this file creates live in `authTokens/` and are swept in `afterAll` by uid.
 *
 * The clock is injected rather than slept through, as `rate-limit.test.ts` does it: a
 * 24-hour expiry is not something a test waits for.
 */

const UID = `email-tokens-test-${crypto.randomUUID()}`
const OTHER_UID = `email-tokens-test-${crypto.randomUUID()}`
const EMAIL = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`

/** Real round trips to Firestore, several per test (#31). */
const SLOW = 20_000

const tokenDocs = () => firestore.collection('authTokens')

const sha256 = (raw: string) => createHash('sha256').update(raw).digest('hex')

/** The address the `uid: null` cases below use, and the only handle they have — sweeping
 *  them needs the email key, which is the point of that half of the sweep. */
const PENDING_EMAIL = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`

afterAll(async () => {
  await deleteTokensForAccount(UID, null).catch(() => {})
  await deleteTokensForAccount(OTHER_UID, null).catch(() => {})
  await deleteTokensForAccount('no-such-uid', PENDING_EMAIL).catch(() => {})
})

/**
 * The shape #120 introduced to this module: a token issued **before** its account exists.
 *
 * `POST /auth/signup` creates nothing now, so the activation link it mails is issued with no
 * uid at all and the address is the only thing identifying it. Every other case in this file
 * passes a uid, so the null one was reaching Firestore only incidentally through the routes
 * — and the module that owns `authTokens/` is where its round trip belongs.
 */
describe('a token issued before the account exists', () => {
  test(
    'null is stored as null and comes back as null, and nothing else changes',
    async () => {
      const raw = await issueToken(null, PENDING_EMAIL, 'activation')

      const stored = await tokenDocs().doc(sha256(raw)).get()
      expect(stored.exists).toBe(true)
      // `null`, not absent: a missing field and a null one are different documents,
      // and `where('uid','==',null)` would not match an absent one.
      expect(stored.data()!.uid).toBeNull()
      expect(stored.data()!.email).toBe(PENDING_EMAIL)
      expect(stored.data()!.kind).toBe('activation')

      const spent = await consumeToken(raw, 'activation')
      expect(spent.ok).toBe(true)
      if (!spent.ok) return
      // The address is what the route activates on; the uid it resolves itself.
      expect(spent.uid).toBeNull()
      expect(spent.email).toBe(PENDING_EMAIL)
    },
    SLOW,
  )

  test(
    'single use and expiry are the same for it as for any other token',
    async () => {
      const raw = await issueToken(null, PENDING_EMAIL, 'activation')
      expect((await consumeToken(raw, 'activation')).ok).toBe(true)
      // Spent once is spent: the missing uid does not exempt it from the transaction.
      expect((await consumeToken(raw, 'activation')).ok).toBe(false)

      const stale = await issueToken(
        null,
        PENDING_EMAIL,
        'activation',
        () => Date.now() - ACTIVATION_TTL_SECONDS * 1000 - 1000,
      )
      const dead = await consumeToken(stale, 'activation')
      expect(dead.ok).toBe(false)
      if (dead.ok) return
      expect(dead.reason).toBe('expired')
    },
    SLOW,
  )

  test(
    'the address sweep is the only one that can find it',
    async () => {
      const raw = await issueToken(null, PENDING_EMAIL, 'activation')
      const id = sha256(raw)
      expect((await tokenDocs().doc(id).get()).exists).toBe(true)

      // The uid half of `deleteTokensForAccount` cannot see it — there is no uid to
      // match. That is exactly why `DELETE /me` sweeps by address as well: without it
      // a signed-up-but-never-activated address survived its own account's deletion.
      await deleteTokensForAccount('no-such-uid', null)
      expect((await tokenDocs().doc(id).get()).exists).toBe(true)

      await deleteTokensForAccount('no-such-uid', PENDING_EMAIL)
      expect((await tokenDocs().doc(id).get()).exists).toBe(false)
    },
    SLOW,
  )
})

describe('what is issued, and what is stored', () => {
  test(
    'a token is TOKEN_LENGTH characters of base64url, and no two are alike',
    async () => {
      const tokens = await Promise.all([
        issueToken(UID, EMAIL, 'activation'),
        issueToken(UID, EMAIL, 'activation'),
        issueToken(UID, EMAIL, 'activation'),
      ])
      for (const token of tokens) {
        expect(token).toMatch(new RegExp(`^[A-Za-z0-9_-]{${TOKEN_LENGTH}}$`))
      }
      expect(new Set(tokens).size).toBe(3)
      // 32 bytes, so 256 bits: enough that guessing is not a strategy.
      expect(TOKEN_LENGTH).toBe(43)
    },
    SLOW,
  )

  test(
    'only the hash reaches Firestore: the document is keyed by sha256 and no field holds the token',
    async () => {
      const raw = await issueToken(UID, EMAIL, 'activation')
      const doc = await tokenDocs().doc(sha256(raw)).get()

      expect(doc.exists).toBe(true)
      const data = doc.data()!
      expect(Object.keys(data).sort()).toEqual([
        'createdAt',
        'email',
        'expiresAt',
        'kind',
        'uid',
        'usedAt',
      ])
      expect(data.uid).toBe(UID)
      expect(data.email).toBe(EMAIL)
      expect(data.kind).toBe('activation')
      expect(data.usedAt).toBeNull()
      expect(data.expiresAt).toBeInstanceOf(Timestamp)
      expect(JSON.stringify(data)).not.toContain(raw)

      // And nothing else under this uid carries it either.
      const all = await tokenDocs().where('uid', '==', UID).get()
      for (const d of all.docs) {
        expect(d.id).not.toBe(raw)
        expect(JSON.stringify(d.data())).not.toContain(raw)
      }
    },
    SLOW,
  )

  test(
    'an activation token expires 24 hours out, a reset token 60 minutes out',
    async () => {
      const at = 1_800_000_000_000
      const activation = await issueToken(UID, EMAIL, 'activation', () => at)
      const reset = await issueToken(UID, EMAIL, 'reset', () => at)

      const expiresAt = async (raw: string) =>
        ((await tokenDocs().doc(sha256(raw)).get()).get('expiresAt') as Timestamp).toMillis()

      expect(await expiresAt(activation)).toBe(at + ACTIVATION_TTL_SECONDS * 1000)
      expect(await expiresAt(reset)).toBe(at + RESET_TTL_SECONDS * 1000)
      expect(ACTIVATION_TTL_SECONDS).toBe(24 * 60 * 60)
      expect(RESET_TTL_SECONDS).toBe(60 * 60)
    },
    SLOW,
  )
})

describe('single use', () => {
  test(
    'the first consume wins, the second is invalid, and the document says so',
    async () => {
      const raw = await issueToken(UID, EMAIL, 'activation')

      expect(await consumeToken(raw, 'activation')).toEqual({
        ok: true,
        uid: UID,
        email: EMAIL,
      })
      expect(await consumeToken(raw, 'activation')).toEqual({
        ok: false,
        reason: 'invalid',
      })

      const doc = await tokenDocs().doc(sha256(raw)).get()
      expect(doc.get('usedAt')).toBeInstanceOf(Timestamp)
    },
    SLOW,
  )

  test(
    'two consumes racing on one token cannot both win',
    async () => {
      const raw = await issueToken(UID, EMAIL, 'reset')
      const results = await Promise.all([
        consumeToken(raw, 'reset'),
        consumeToken(raw, 'reset'),
        consumeToken(raw, 'reset'),
      ])
      expect(results.filter((r) => r.ok)).toHaveLength(1)
    },
    SLOW,
  )

  test(
    'a token unknown to the store is invalid, not an error',
    async () => {
      const invented = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url')
      expect(await consumeToken(invented, 'activation')).toEqual({
        ok: false,
        reason: 'invalid',
      })
    },
    SLOW,
  )
})

describe('kind', () => {
  test(
    'an activation token spent as a reset is invalid, and is not spent by the attempt',
    async () => {
      // The two links do different things; a reset link must not activate and an
      // activation link must never set a password. The wrong-kind attempt is refused
      // *without* burning the token, so the right kind still works afterwards.
      const raw = await issueToken(UID, EMAIL, 'activation')
      expect(await consumeToken(raw, 'reset')).toEqual({ ok: false, reason: 'invalid' })
      expect((await consumeToken(raw, 'activation')).ok).toBe(true)
    },
    SLOW,
  )
})

describe('expiry', () => {
  test(
    'the last millisecond inside the window is served and the boundary is not',
    async () => {
      const at = 1_800_000_000_000
      const ttl = ACTIVATION_TTL_SECONDS * 1000
      const inside = await issueToken(UID, EMAIL, 'activation', () => at)
      const boundary = await issueToken(UID, EMAIL, 'activation', () => at)

      expect((await consumeToken(inside, 'activation', () => at + ttl - 1)).ok).toBe(true)
      expect(await consumeToken(boundary, 'activation', () => at + ttl)).toEqual({
        ok: false,
        reason: 'expired',
      })
    },
    SLOW,
  )

  test(
    'an expired token stays refusable, and a spent one reads as invalid rather than expired',
    async () => {
      const at = 1_800_000_000_000
      const raw = await issueToken(UID, EMAIL, 'reset', () => at)
      const later = () => at + RESET_TTL_SECONDS * 1000 + 1

      expect(await consumeToken(raw, 'reset', later)).toEqual({
        ok: false,
        reason: 'expired',
      })
      expect(await consumeToken(raw, 'reset', later)).toEqual({
        ok: false,
        reason: 'expired',
      })

      // Spent first, then past expiry: "used" wins, so a holder of an old link learns
      // nothing about when it stopped working from *why* it stopped working.
      const spent = await issueToken(UID, EMAIL, 'reset', () => at)
      expect((await consumeToken(spent, 'reset', () => at)).ok).toBe(true)
      expect(await consumeToken(spent, 'reset', later)).toEqual({
        ok: false,
        reason: 'invalid',
      })
    },
    SLOW,
  )
})

describe('a new reset link kills the old ones', () => {
  test(
    'issuing a reset token marks every unused reset token of that uid used',
    async () => {
      const first = await issueToken(UID, EMAIL, 'reset')
      const second = await issueToken(UID, EMAIL, 'reset')
      const third = await issueToken(UID, EMAIL, 'reset')

      expect(await consumeToken(first, 'reset')).toEqual({ ok: false, reason: 'invalid' })
      expect(await consumeToken(second, 'reset')).toEqual({ ok: false, reason: 'invalid' })
      expect((await consumeToken(third, 'reset')).ok).toBe(true)
    },
    SLOW,
  )

  test(
    "it leaves activation tokens, and other accounts' reset tokens, alone",
    async () => {
      const activation = await issueToken(UID, EMAIL, 'activation')
      const someoneElse = await issueToken(OTHER_UID, EMAIL, 'reset')
      await issueToken(UID, EMAIL, 'reset')

      expect((await consumeToken(activation, 'activation')).ok).toBe(true)
      expect((await consumeToken(someoneElse, 'reset')).ok).toBe(true)
    },
    SLOW,
  )
})

describe('a second activation link does NOT kill the first', () => {
  test(
    'only reset tokens are revoked on reissue, and the asymmetry is deliberate',
    async () => {
      // Resend issues another activation token and leaves the earlier one alive, so
      // someone who clicks the first email after asking for a second still gets in.
      // Reset is the opposite (`invalidateResetTokens`), because a reset link left
      // live in an old inbox is a standing credential. A change that made the two
      // symmetric would break Resend silently — hence a test that names it.
      const uid = `email-tokens-test-${crypto.randomUUID()}`
      const first = await issueToken(uid, EMAIL, 'activation')
      const second = await issueToken(uid, EMAIL, 'activation')

      expect((await consumeToken(first, 'activation')).ok).toBe(true)
      expect((await consumeToken(second, 'activation')).ok).toBe(true)
      await deleteTokensForAccount(uid, null)
    },
    SLOW,
  )
})

describe('deleteTokensForAccount', () => {
  test(
    'removes every token of the uid, used or not, and is a no-op the second time',
    async () => {
      const uid = `email-tokens-test-${crypto.randomUUID()}`
      const spent = await issueToken(uid, EMAIL, 'activation')
      await consumeToken(spent, 'activation')
      await issueToken(uid, EMAIL, 'reset')
      expect((await tokenDocs().where('uid', '==', uid).get()).size).toBe(2)

      await deleteTokensForAccount(uid, null)
      expect((await tokenDocs().where('uid', '==', uid).get()).size).toBe(0)
      await deleteTokensForAccount(uid, null)
    },
    SLOW,
  )

  test('removes more tokens than a single Firestore batch can hold', async () => {
    // A `WriteBatch` caps at 500 operations, and nothing bounds how many tokens an
    // account accumulates — every Resend issues one and activation tokens are
    // never revoked. A single-batch delete would throw here, and because
    // `DELETE /me` deletes tokens before the tombstone, that account could never
    // finish being deleted: every retry would fail in the same place.
    //
    // Written directly rather than through `issueToken`, which is one round trip
    // each; the delete path does not care how they got there.
    const uid = `email-tokens-test-${crypto.randomUUID()}`
    for (let written = 0; written < 520; written += 400) {
      const batch = firestore.batch()
      for (let i = written; i < Math.min(written + 400, 520); i++) {
        batch.set(tokenDocs().doc(sha256(`${uid}-${i}`)), {
          uid,
          email: EMAIL,
          kind: 'activation',
          expiresAt: Timestamp.fromMillis(Date.now() + 86_400_000),
          usedAt: null,
          createdAt: FieldValue.serverTimestamp(),
        })
      }
      await batch.commit()
    }
    expect((await tokenDocs().where('uid', '==', uid).get()).size).toBe(520)

    await deleteTokensForAccount(uid, null)
    expect((await tokenDocs().where('uid', '==', uid).get()).size).toBe(0)
  }, 60_000)
})

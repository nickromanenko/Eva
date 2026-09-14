import { createHash } from 'node:crypto'
import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import { firestore } from './firebase'

/**
 * The tokens behind activation and password-reset links (issue #6). The only module that
 * touches `authTokens/` (GUARDRAILS 10).
 *
 * A token is 32 random bytes, handed to the caller once as base64url and never stored:
 * the document is keyed by its SHA-256, so a read of the collection — a leaked export, a
 * console session — yields nothing that opens an account. Each is single-use, consumed in
 * a transaction so two clicks racing on the same link cannot both win, and each expires
 * on its own clock. They are deliberately not JWTs: a reset link must be revocable (a
 * second request kills the first) and must not be minted with the session secret, which
 * would make every reset link a session in disguise.
 *
 * Nothing in this file writes to the console, and nothing should start: a raw token or
 * its hash in a log line is the link itself (GUARDRAILS 12).
 */

export type TokenKind = 'activation' | 'reset'

/** How long an activation link works — what the email and the canvas both say. */
export const ACTIVATION_TTL_SECONDS = 24 * 60 * 60
/** How long a reset link works. Short, because it sets a password without one. */
export const RESET_TTL_SECONDS = 60 * 60

const TTL_SECONDS: Record<TokenKind, number> = {
  activation: ACTIVATION_TTL_SECONDS,
  reset: RESET_TTL_SECONDS,
}

const TOKEN_BYTES = 32
/** `TOKEN_BYTES` as unpadded base64url, for the route edge to refuse anything else. */
export const TOKEN_LENGTH = Math.ceil((TOKEN_BYTES * 4) / 3)

/**
 * `uid` is `null` for an activation token issued before the account exists (#120). Sign-up
 * no longer creates a Firebase Auth user — the address is not proven yet, and a credential
 * on an unproven address is the thing #120 removes — so the only identity an activation
 * token can carry at that point is the address itself.
 *
 * A reset token always has one: resetting is something you do to an account that exists.
 */
export type ConsumeResult =
  | { ok: true; uid: string | null; email: string }
  | { ok: false; reason: 'invalid' | 'expired' }

const tokens = () => firestore.collection('authTokens')

const hashToken = (raw: string): string => createHash('sha256').update(raw).digest('hex')

/**
 * Marks every unused reset token of `uid` used. Requesting a new link is what kills the
 * old one (PRD: "send link → invalidate the old one"), so a reset email that sat in an
 * inbox for a while cannot be picked up after a fresher one was asked for.
 */
const invalidateResetTokens = async (uid: string): Promise<void> => {
  // Bounded by construction — every issue invalidates first, so at most a handful can be
  // unused at once — but limited anyway, because the batch below caps at 500 and "bounded
  // by construction" is the kind of thing a later change quietly stops being true.
  const unused = await tokens()
    .where('uid', '==', uid)
    .where('kind', '==', 'reset')
    .where('usedAt', '==', null)
    .limit(DELETE_BATCH)
    .get()
  if (unused.empty) return
  const batch = firestore.batch()
  for (const doc of unused.docs) batch.update(doc.ref, { usedAt: FieldValue.serverTimestamp() })
  await batch.commit()
}

/**
 * Issues a token and returns the only copy of it that will ever exist in the clear. The
 * caller's job is to put it in a link and forget it.
 *
 * `now` is injectable so a test can issue a token that is already past its expiry
 * without sleeping through a day.
 */
export const issueToken = async (
  uid: string | null,
  email: string,
  kind: TokenKind,
  now: () => number = Date.now,
): Promise<string> => {
  // `uid` is non-null for every reset token by construction: the route looks the account up
  // before issuing one.
  if (kind === 'reset' && uid !== null) await invalidateResetTokens(uid)
  const raw = Buffer.from(crypto.getRandomValues(new Uint8Array(TOKEN_BYTES))).toString('base64url')
  await tokens()
    .doc(hashToken(raw))
    .set({
      uid,
      email,
      kind,
      expiresAt: Timestamp.fromMillis(now() + TTL_SECONDS[kind] * 1000),
      usedAt: null,
      createdAt: FieldValue.serverTimestamp(),
    })
  return raw
}

/**
 * Spends a token. `invalid` covers unknown, already used, and the wrong kind — three
 * facts the caller has no use for telling apart, and one of which (unknown vs. used)
 * would let a link's holder learn whether somebody else already clicked it. `expired`
 * is separate because the user can act on it: ask for a new link.
 *
 * A transaction, so the read of `usedAt` and the write of it are one step: two requests
 * carrying the same token cannot both see it unused.
 */
export const consumeToken = async (
  raw: string,
  kind: TokenKind,
  now: () => number = Date.now,
): Promise<ConsumeResult> => {
  const ref = tokens().doc(hashToken(raw))
  return firestore.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref)
    if (!snapshot.exists) return { ok: false, reason: 'invalid' }
    const data = snapshot.data()!
    if (data.kind !== kind || data.usedAt !== null) return { ok: false, reason: 'invalid' }
    const at = now()
    if ((data.expiresAt as Timestamp).toMillis() <= at) return { ok: false, reason: 'expired' }
    tx.update(ref, { usedAt: Timestamp.fromMillis(at) })
    return { ok: true, uid: data.uid, email: data.email }
  })
}

/** A Firestore `WriteBatch` caps at 500 operations. The same number `events.ts` pages by,
 *  and for the same reason. */
const DELETE_BATCH = 400

const deleteMatching = async (
  query: FirebaseFirestore.Query,
): Promise<void> => {
  for (;;) {
    const owned = await query.limit(DELETE_BATCH).get()
    if (owned.empty) return
    const batch = firestore.batch()
    for (const doc of owned.docs) batch.delete(doc.ref)
    await batch.commit()
  }
}

/**
 * Removes every token belonging to an account, used or not — part of account deletion
 * (#8), because a token document carries the account's address and a deleted account keeps
 * nothing. Deleting nothing succeeds, so a resumed delete passes through here quietly.
 *
 * **Both keys, and that is not belt-and-braces.** A uid query alone was complete while every
 * token carried one. Since #120 an activation token is issued *before* its account exists
 * and stores `uid: null`, so a uid query cannot see it — a sign-up and every Resend after it
 * survived `DELETE /me` and kept the user's address in `authTokens/` until the TTL policy
 * reaped them. The address is the other half of what identifies them, and it is the half the
 * new shape has.
 *
 * `address` is nullable because the delete route can only learn it from the document it is
 * about to remove, and a resumed delete that already passed that step has nothing left to
 * sweep by.
 *
 * A batch at a time, re-querying rather than paging a cursor, exactly as
 * `deleteAllUserEvents` does. Nothing bounds how many tokens an account can accumulate —
 * every Resend issues one and only reset tokens are ever revoked — so a single batch
 * would throw past 500 and leave `DELETE /me` unable to finish, permanently: the
 * tombstone would stay, every retry would fail the same way, and the documents holding
 * the address would survive. An unbounded collection needs an unbounded delete.
 */
export const deleteTokensForAccount = async (
  uid: string,
  address: string | null,
): Promise<void> => {
  await deleteMatching(tokens().where('uid', '==', uid))
  if (address !== null) await deleteMatching(tokens().where('email', '==', address))
}

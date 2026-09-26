import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import { firestore } from './firebase'
import { assertAccountLive, type WriteSession } from './users'

/**
 * The notification queue (A9, #79): the only module that touches
 * `users/{uid}/notifications/` (GUARDRAILS 10). An intent — what *will be* delivered, then
 * what *was* — not the notification centre's read surface, which is its own slice
 * (out of scope here). The catalogue of kinds is out of scope too; `kind` is an opaque
 * string the sender carries into the fixed payload, never into the preview.
 *
 * **At-most-once, by construction.** A send is recorded (`sentAt`) in the same write that
 * claims the row, before the APNs call, so a job that dies mid-run re-sends nothing: a
 * missed reminder is a smaller harm than a duplicate (ARCHITECTURE §9.2).
 */

/** A wall-clock reminder intent, as its future producer hands it over. */
export interface NotificationIntent {
  /** Opaque until the catalogue lands; carried in the payload, never the preview. */
  kind: string
  /** The instant it should go out — already resolved to the device's zone by the caller. */
  dueAt: Date
}

/** A due, unclaimed row — what the sender job works from. */
export interface DueNotification {
  id: string
  kind: string
}

const documents = (uid: string) =>
  firestore.collection('users').doc(uid).collection('notifications')

/** Enqueues an intent. No route yet — the catalogue is a later slice; the producers that
 *  exist (the sender job's test, and the pregnancy-loss stop's test) call this directly. */
export const enqueueNotification = async (
  uid: string,
  session: WriteSession,
  intent: NotificationIntent,
): Promise<void> => {
  const ref = documents(uid).doc()
  await firestore.runTransaction(async (tx) => {
    await assertAccountLive(tx, uid, session, ref)
    tx.set(ref, {
      kind: intent.kind,
      dueAt: Timestamp.fromDate(intent.dueAt),
      sentAt: null,
      cancelledAt: null,
    })
  })
}

/** Every due, unclaimed, uncancelled row — the sender job's select. */
export const dueNotifications = async (uid: string, now: Date): Promise<DueNotification[]> => {
  const snapshot = await documents(uid)
    .where('dueAt', '<=', Timestamp.fromDate(now))
    .where('sentAt', '==', null)
    .where('cancelledAt', '==', null)
    .get()
  return snapshot.docs
    .map((doc) => ({ id: doc.id, kind: doc.data().kind as string }))
    .filter((row) => typeof row.kind === 'string')
}

/** Claims one row as sent, in a transaction so the same row can never be claimed twice. */
export const markSent = async (uid: string, id: string): Promise<void> => {
  await firestore.runTransaction(async (tx) => {
    const ref = documents(uid).doc(id)
    const snapshot = await tx.get(ref)
    if (!snapshot.exists) return
    if (snapshot.get('sentAt') !== null || snapshot.get('cancelledAt') !== null) return
    tx.update(ref, { sentAt: FieldValue.serverTimestamp() })
  })
}

/** Cancels every queued send — the server half of the pregnancy-loss stop rule (§9.1:
 *  "local cancel + server marks notifications/"). Queued means not yet sent; a sent row
 *  already reached a device and is not un-sent. In a transaction that reads the account, as
 *  every user-initiated write here does. */
export const cancelQueuedNotifications = async (
  uid: string,
  session: WriteSession,
): Promise<number> => {
  return firestore.runTransaction(async (tx) => {
    await assertAccountLive(tx, uid, session)
    const snapshot = await documents(uid)
      .where('sentAt', '==', null)
      .where('cancelledAt', '==', null)
      .get()
    const now = FieldValue.serverTimestamp()
    for (const doc of snapshot.docs) tx.update(doc.ref, { cancelledAt: now })
    return snapshot.size
  })
}

/** Firestore's ceiling on a batched write. */
const DELETE_BATCH = 500

/** Hard-deletes the queue — its half of account deletion (#8). A queued notification is
 *  intent about a user, and goes with the account rather than outliving it. */
export const deleteAllUserNotifications = async (uid: string): Promise<number> => {
  let removed = 0
  for (;;) {
    const snapshot = await documents(uid).limit(DELETE_BATCH).get()
    if (snapshot.empty) return removed
    const batch = firestore.batch()
    for (const doc of snapshot.docs) batch.delete(doc.ref)
    await batch.commit()
    removed += snapshot.size
  }
}

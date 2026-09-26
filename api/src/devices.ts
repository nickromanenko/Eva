import { FieldValue } from 'firebase-admin/firestore'
import { firestore } from './firebase'
import { assertAccountLive, type WriteSession } from './users'

/**
 * The device registry (A9, #79): the only module that touches `users/{uid}/devices/`
 * (GUARDRAILS 10). A row per installed app, keyed by a device id the app mints once per
 * install, so a token rotation is a replace rather than a second row (ARCHITECTURE §9.2).
 *
 * The token is the APNs device token — an identifier that reaches a third party (Apple), so
 * it is a credential this module handles like one: never logged, never in a response body it
 * was not asked for. `timeZone` is stored here because the sender job turns a wall-clock
 * reminder intent into an instant in the device's own zone (§9.2); it is updated on every
 * register.
 */

export type DeviceEnvironment = 'sandbox' | 'production'

/** What the register route accepts, already validated at the edge. */
export interface DeviceRegistration {
  token: string
  environment: DeviceEnvironment
  /** IANA zone name, e.g. `America/New_York`. */
  timeZone: string
}

/** A device as the sender job reads it. */
export interface Device extends DeviceRegistration {
  id: string
}

const documents = (uid: string) => firestore.collection('users').doc(uid).collection('devices')

const isEnvironment = (value: unknown): value is DeviceEnvironment =>
  value === 'sandbox' || value === 'production'

/** A stored row read as *this* schema; a row that is not (a hand edit, a future schema) is
 *  skipped rather than sent to. */
const toDevice = (id: string, data: FirebaseFirestore.DocumentData): Device | null => {
  if (typeof data.token !== 'string' || data.token === '') return null
  if (!isEnvironment(data.environment)) return null
  if (typeof data.timeZone !== 'string' || data.timeZone === '') return null
  return { id, token: data.token, environment: data.environment, timeZone: data.timeZone }
}

/** Registers or replaces one device. The device id is the app's, minted once per install; a
 *  second register with the same id is a token rotation. In a transaction that also reads the
 *  account (#286), so a register racing `DELETE /me` cannot recreate a row after the sweep. */
export const registerDevice = async (
  uid: string,
  session: WriteSession,
  deviceId: string,
  registration: DeviceRegistration,
): Promise<void> => {
  const ref = documents(uid).doc(deviceId)
  await firestore.runTransaction(async (tx) => {
    await assertAccountLive(tx, uid, session, ref)
    tx.set(ref, { ...registration, updatedAt: FieldValue.serverTimestamp() }, { merge: true })
  })
}

/** Removes one device — the app's half of "sign out". A row that is already gone is a no-op,
 *  so a retried sign-out never answers 404. Same transaction-and-account rule as register. */
export const removeDevice = async (
  uid: string,
  session: WriteSession,
  deviceId: string,
): Promise<void> => {
  const ref = documents(uid).doc(deviceId)
  await firestore.runTransaction(async (tx) => {
    await assertAccountLive(tx, uid, session, ref)
    tx.delete(ref)
  })
}

/** Every device registered to an account — what the sender job fans out to. */
export const listDevices = async (uid: string): Promise<Device[]> => {
  const snapshot = await documents(uid).get()
  return snapshot.docs
    .map((doc) => toDevice(doc.id, doc.data()))
    .filter((device): device is Device => device !== null)
}

/** Firestore's ceiling on a batched write. */
const DELETE_BATCH = 500

/** Hard-deletes every device row — its half of account deletion (#8). A device token is an
 *  identifier for a user; it goes with the account rather than leaving APNs a live handle. */
export const deleteAllUserDevices = async (uid: string): Promise<number> => {
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

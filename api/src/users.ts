import { FieldValue } from 'firebase-admin/firestore'
import { firestore } from './firebase'

export interface Profile {
  age: number
  weightKg: number
  heightCm: number
  goals: string[]
  conditions: string[]
  medications: string
  lifestyle: string
  sports: string[]
}

export interface User {
  id: string
  email: string
  questionnaireCompleted: boolean
  profile: Profile | null
  /** Which credentials open this account: `password`, `apple.com`, `google.com` (#7). The
   *  client shows it in Profile and decides from it whether "Link Apple" is still offered.
   *  Absent on no document — the field has existed since the first one. */
  authProviders: string[]
  /** Whether the address has been confirmed (#6). Derived from `activatedAt`, which the
   *  client never sees. */
  activated: boolean
}

const users = () => firestore.collection('users')

/** `activatedAt` is `null` from creation until the activation link is used, and a
 *  timestamp after. **Absent means activated**: every document written before #6 has no
 *  such field, and those accounts signed in for months on a password alone — a gate that
 *  locked them out until they found a confirmation email they were never sent would be a
 *  regression, not security. Hence `!== null` rather than a truthiness test. */
const isActivatedData = (data: FirebaseFirestore.DocumentData): boolean =>
  data.activatedAt !== null

const toUser = (id: string, data: FirebaseFirestore.DocumentData): User => ({
  id,
  email: data.email,
  questionnaireCompleted: data.questionnaireCompleted ?? false,
  profile: data.profile ?? null,
  authProviders: data.authProviders ?? [],
  activated: isActivatedData(data),
})

/** gRPC NOT_FOUND — the document the write was aimed at is not there. */
const NOT_FOUND = 5

/** A document carrying `deletedAt` is a tombstone, not a user: the account behind it is
 *  being deleted and nothing brings it back (#8). Absent on every document written
 *  before deletion existed, hence `!= null` rather than `!== null`. */
const isTombstone = (snapshot: FirebaseFirestore.DocumentSnapshot): boolean =>
  snapshot.get('deletedAt') != null

/** Creates the user doc if missing; returns the (existing or new) user.
 *  Doc ID = Firebase Auth uid, so a provider resolving to the same Auth account always
 *  lands on the same document. **Never by email** (#7): what puts an Apple or Google
 *  sign-in on an existing account is Firebase returning the uid it already keyed to that
 *  provider's `sub`, and nothing here looks an address up. An unseen `sub` is a new
 *  account even when the address matches one that exists — see `signInWithIdp`.
 *
 *  `null` means the uid names a tombstone — a delete is in flight — and this refuses to
 *  revive it. That refusal is half of what makes deletion real: `ensureUser` runs on every
 *  sign-in, so without it a deleted account would come back the moment its owner (or
 *  anyone holding the password) signed in again while the sweep was still running.
 *
 *  The other half is an ordering invariant `deleteAccount`'s caller owes this function:
 *  the tombstone is removed only *after* the Firebase Auth user is gone. So a *missing*
 *  document can no longer be reached by a sign-in at all, which is why the create branch
 *  below is still safe to take. */
export const ensureUser = async (
  uid: string,
  email: string,
  provider: string,
): Promise<User | null> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (snapshot.exists) {
    if (isTombstone(snapshot)) return null
    // `update`, never `set`: it fails rather than creates if the document went away
    // between the read and here, so a delete landing mid-sign-in cannot be undone.
    await ref.update({
      authProviders: FieldValue.arrayUnion(provider),
      updatedAt: FieldValue.serverTimestamp(),
    })
    // The union is applied to the value that is returned as well as to the document, so a
    // caller is never handed a list that is already stale by one provider — which is
    // exactly what `POST /me/auth/providers` answers with (#7). Reading the document back
    // would cost a second round trip to learn something we just decided.
    const data = snapshot.data()!
    const existing: string[] = data.authProviders ?? []
    return toUser(uid, {
      ...data,
      authProviders: existing.includes(provider) ? existing : [...existing, provider],
    })
  }
  // A new document starts *not* activated, explicitly: `null`, never absent, because
  // absent is what a pre-#6 document looks like and means the opposite (see
  // `isActivatedData`). That holds for a sign-in that creates the document too — an Auth
  // user with no document was made outside the API, and its address was never proven.
  await ref.set({
    email,
    authProviders: [provider],
    questionnaireCompleted: false,
    profile: null,
    activatedAt: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  })
  return {
    id: uid,
    email,
    questionnaireCompleted: false,
    profile: null,
    authProviders: [provider],
    activated: false,
  }
}

/**
 * What `/auth/idp` needs to know *before* it writes anything (#7).
 *
 * `getUser` answers `null` for both "no document" and "tombstone", which are the same
 * answer to a route that only wants to read. They are not the same answer to one that has
 * to decide whether to refuse: a provider sign-in must not revive a deleted account, and
 * must run the claim on an account that has none yet.
 *
 * It exists because `ensureUser` *writes* — it unions the provider into `authProviders` —
 * and calling it before the claim gate left a refused credential's provider permanently
 * mirrored on a stranger's document. That is not cosmetic: the app reads `authProviders`
 * to decide whether to offer "Connect Apple", so a false entry removes the real owner's
 * only way to link the identity they actually own.
 */
export const readUser = async (
  uid: string,
): Promise<{ deleted: boolean; user: User | null }> => {
  const snapshot = await users().doc(uid).get()
  if (!snapshot.exists) return { deleted: false, user: null }
  if (isTombstone(snapshot)) return { deleted: true, user: null }
  return { deleted: false, user: toUser(uid, snapshot.data()!) }
}

export const getUser = async (uid: string): Promise<User | null> => {
  const snapshot = await users().doc(uid).get()
  return snapshot.exists && !isTombstone(snapshot) ? toUser(uid, snapshot.data()!) : null
}

/** The activation gate's question (#6). A named seam rather than a field read, so the
 *  routes that ask it — sign-in, resend — say what they are asking. */
export const isActivated = (user: User): boolean => user.activated

/**
 * Stamps `activatedAt`, once: a document already activated — by a timestamp, or by
 * predating the field — is left exactly as it is, so the first confirmation stays the
 * record of when the address was proven. `false` means there was nothing to activate: no
 * document, or a tombstone. The caller treats that as a dead link, not an error.
 *
 * It briefly reported *which* of those three it did, so a caller could act on the
 * transition. That is no longer how the retraction is decided (#7): the routes read the
 * account before writing anything and retract while it is still unactivated, because
 * anything keyed on this call's result necessarily happens **after** the stamp — and the
 * stamp is what disarms `/auth/idp`'s claim gate. See `proveAddress`.
 */
export const markActivated = async (uid: string): Promise<boolean> => {
  const ref = users().doc(uid)
  return firestore.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref)
    if (!snapshot.exists || isTombstone(snapshot)) return false
    if (isActivatedData(snapshot.data()!)) return true
    tx.update(ref, {
      activatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    })
    return true
  })
}

export const saveQuestionnaire = async (uid: string, profile: Profile): Promise<User | null> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (!snapshot.exists) return null
  await ref.update({
    profile,
    questionnaireCompleted: true,
    updatedAt: FieldValue.serverTimestamp(),
  })
  return toUser(uid, { ...snapshot.data()!, profile, questionnaireCompleted: true })
}

/** Stamps `deletedAt` on the document, which is the moment the account stops existing as
 *  far as every route is concerned (#8): `getUser` answers `null` from here on, so the
 *  account gate in `index.ts` rejects every token that names this uid, and `ensureUser`
 *  refuses to revive it, so signing in cannot bring it back either. Nothing clears it —
 *  an account has no Undo, unlike a single event.
 *
 *  It is deliberately the *first* step of a delete and the tombstone the rest of the
 *  sweep runs under: whatever fails after it, the account is already inert and the
 *  retry is a plain re-run.
 *
 *  `false` means there was no document to mark — an already-finished delete, or an Auth
 *  user that never got one. That is not an error; the caller carries on, which is what
 *  makes a second `DELETE /me` a no-op rather than a failure. */
export const markUserDeleted = async (uid: string): Promise<boolean> => {
  try {
    await users().doc(uid).update({
      deletedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    })
    return true
  } catch (err) {
    if ((err as { code?: number }).code === NOT_FOUND) return false
    throw err
  }
}

/**
 * The address on a document that is on its way out, tombstone or not — the one thing a
 * delete still needs to read after `markUserDeleted` has made every ordinary accessor
 * answer `null`.
 *
 * It exists for the `authTokens/` sweep (#8). That sweep was keyed on uid alone, which was
 * complete while every token carried one; since #120 an activation token is issued *before*
 * its account exists and carries `uid: null`, so a uid query cannot see it and `DELETE /me`
 * left the documents holding the user's address behind. The TTL policy on `expiresAt` reaps
 * them within a day, but "immediate and complete" is what ARCHITECTURE promises, and a day
 * is not immediate.
 *
 * Read from the raw snapshot rather than through `getUser`, deliberately: by the time the
 * sweep runs the tombstone is already set, and every accessor that respects it — which is
 * all of them, correctly — answers `null`. `null` here means no document at all, which is a
 * resumed delete that already got past `deleteUserDocument`, and there is nothing left to
 * sweep by then.
 */
export const addressOfDeletedUser = async (uid: string): Promise<string | null> => {
  const snapshot = await users().doc(uid).get()
  if (!snapshot.exists) return null
  const email = snapshot.data()!.email
  return typeof email === 'string' ? email : null
}

/** Removes the tombstone — the last step of a delete, and only ever after the Firebase
 *  Auth user and the events are gone. Deleting a document that is not there succeeds, so
 *  a resumed delete ends here quietly rather than erroring. */
export const deleteUserDocument = async (uid: string): Promise<void> => {
  await users().doc(uid).delete()
}

/** Every user document ID. For the jobs that must sweep all of them — the retention
 *  purge. (Account deletion, #8, turned out not to need it: a delete knows its own uid.)
 *  `listDocuments` rather than a query, so the caller gets IDs and never loads a
 *  `profile` it has no use for. */
export const listAllUids = async (): Promise<string[]> =>
  (await users().listDocuments()).map((doc) => doc.id)

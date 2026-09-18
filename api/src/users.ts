import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import { firestore } from './firebase'

/**
 * Hormonal medication, as one opaque code (PRD §Sign Up, Profile fields 4; review §8 A8).
 *
 * **Codes, not labels, and permanent** — the rule `refdata.ts` states for its own
 * catalogues, and for the same reason: the client renders a label, the document stores a
 * code, and editing the wording must never be a data migration. A code is never reused for
 * a different meaning.
 *
 * **One value, not a list.** The PRD's own list ends in "None", which a multi-select cannot
 * hold without contradicting itself, and the field was already a single `string`. Widening
 * it later is a migration; narrowing it now is not.
 */
export const MEDICATION_CODES = [
  'combinedPill',
  'progestogenOnlyPill',
  'hormonalIud',
  'implant',
  'hrt',
  'none',
] as const

export type MedicationCode = (typeof MEDICATION_CODES)[number]

/** Conditions (PRD §Sign Up, Profile fields 5; A8), extended past the four the app shipped
 *  with by Diabetes, Coeliac disease and Food allergies. Same rule as the medications above:
 *  opaque, permanent, never reused. `noneOfThese` is a real answer and not an empty list —
 *  "I have none of these" and "I did not say" are different facts. */
export const CONDITION_CODES = [
  'pcos',
  'endometriosis',
  'thyroidCondition',
  'anaemia',
  'diabetes',
  'coeliacDisease',
  'foodAllergies',
  'noneOfThese',
] as const

export type ConditionCode = (typeof CONDITION_CODES)[number]

export interface Profile {
  /**
   * The user's date of birth, `YYYY-MM-DD` — a calendar label, never an instant, exactly as
   * an event's `localDate` is.
   *
   * **Stored; age is derived from it and never stored** (#81, A8): a stored age is wrong
   * within a year of being written and wrong silently, and the one thing it is read for —
   * `bandForAge` in `cycle.ts` — is a gate on whether a fertile window is drawn at all.
   *
   * It is also what Eva's 18+ floor (A12) is enforced against, at the route edge in
   * `parseProfile` where the date is captured. Nothing here re-checks it: a document that
   * carries a date of birth under 18 did not come through that route, and `bandForAge`
   * refuses rather than guessing which of the two it is (#187).
   */
  dateOfBirth: string
  weightKg: number
  heightCm: number
  goals: string[]
  conditions: ConditionCode[]
  medications: MedicationCode
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

/**
 * The stored `profile` map read as *this* schema, or `null`.
 *
 * **This is #81's migration, and it is a read rather than a write.** Documents written
 * before it carry `profile.age` and no `dateOfBirth`, and there is no date of birth
 * derivable from an age — 28 is any of 366 days — so nothing is backfilled and nothing is
 * deleted. A profile with no `dateOfBirth` is simply not a profile under this schema: it is
 * served as none, `questionnaireCompleted` follows it (see `toUser`), and the app asks the
 * four questionnaire steps again. Nobody is locked out and no date is invented.
 *
 * The stored document keeps its old `profile` map untouched until she answers, at which
 * point `saveQuestionnaire` replaces the whole map and the legacy key goes with it. What
 * this guarantees in the meantime is that `age` never leaves the API: it is dropped here,
 * which is the one place every read passes through.
 *
 * `dateOfBirth` alone is the discriminator, deliberately. It is present on every document
 * this schema writes and absent from every document it does not, so the test is exact —
 * where "does every field still validate?" would quietly discard a profile the day an
 * enumeration is extended.
 */
const storedProfile = (raw: unknown): Profile | null => {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const fields: Record<string, unknown> = { ...(raw as Record<string, unknown>) }
  delete fields.age
  return typeof fields.dateOfBirth === 'string' ? (fields as unknown as Profile) : null
}

const toUser = (id: string, data: FirebaseFirestore.DocumentData): User => {
  const profile = storedProfile(data.profile)
  return {
    id,
    email: data.email,
    // **Derived, not just read** (#81). A pre-migration document says `true` over a profile
    // this schema cannot serve, and the app routes on this flag alone — so reporting it
    // verbatim would leave that account permanently without a date of birth, which is
    // permanently un-age-verified and permanently on the tightest irregularity band. The
    // stored flag is untouched; what changes is what it is worth without a profile to go
    // with it.
    questionnaireCompleted: (data.questionnaireCompleted ?? false) && profile !== null,
    profile,
    authProviders: data.authProviders ?? [],
    activated: isActivatedData(data),
  }
}

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

/**
 * When this document last changed — the profile half of the Today card's "has her data
 * moved" signal (#98, D3).
 *
 * Every write in this file stamps `updatedAt`, so saving the questionnaire moves it and a
 * card built before that is regenerated. Deliberately *not* added to `User`: this is an
 * audit instant, and `GET /me` serves that shape to the app.
 *
 * `null` for a missing document or a tombstone — the same answer `getUser` gives, for the
 * same reason. A card cannot be stale on behalf of an account that is being deleted.
 */
export const lastUserChangeAt = async (uid: string): Promise<string | null> => {
  const snapshot = await users().doc(uid).get()
  if (!snapshot.exists || isTombstone(snapshot)) return null
  const updatedAt = snapshot.get('updatedAt')
  return updatedAt instanceof Timestamp ? updatedAt.toDate().toISOString() : null
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

/**
 * Writes the questionnaire answers onto an account, or `null` if there is no account to
 * write them onto — no document, or a tombstone.
 *
 * The tombstone half is defence in depth (#56), and it is worth saying why it is not
 * redundant. `requireAccount` runs before the route and already refuses a deleted account,
 * so this is unreachable today — but "unreachable" here means "the middleware happens to be
 * ordered that way", which is the kind of true that stops being true when someone adds a
 * second caller or reorders the gate. Every other read in this module refuses a tombstone
 * on its own; this was the one that only did so by arrangement.
 */
export const saveQuestionnaire = async (uid: string, profile: Profile): Promise<User | null> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (!snapshot.exists || isTombstone(snapshot)) return null
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

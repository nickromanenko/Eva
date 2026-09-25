import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import { firestore } from './firebase'
import { ACTIVITY_BANDS, type ActivityBand } from './nutrition'

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

/**
 * The activity band (PRD §Sign Up; A8, #25 Q4, #221): four codes, the rule above.
 *
 * **One union, declared once, in `nutrition.ts`** — this is that array, not a copy of it.
 * The band is the one profile answer arithmetic reads (S2's activity factor), and the engine
 * keeps its factor table a `Record<ActivityBand, number>` so that a band without a factor is
 * a compile error. A second declaration here would be a second list that could gain a member
 * the table never heard of, which is exactly the `FACTORS[lifestyle] ?? 1.2` defect #221
 * exists to remove. It lives in the engine rather than here because the engine imports
 * nothing at all, and this is a downward import of a value from a leaf with no imports —
 * free at runtime, the shape `config.ts` already uses for `nutritionRulesProblem`.
 */
export const ACTIVITY_BAND_CODES: readonly ActivityBand[] = ACTIVITY_BANDS

export type { ActivityBand }

/**
 * The four labels the questionnaire stored before #221, and the one code each means.
 *
 * **A read, not a backfill** — #81's `storedProfile` shape, decided on #221: every document
 * written before the band became a code carries the English label the chip drew, and these
 * four strings are the only ones the app ever offered. They are matched **exactly**; a
 * reworded, localised or otherwise unrecognised string is not guessed at, because the guess
 * is precisely the defect — the nearest plausible band is a plausible daily calorie target.
 * Nothing is written back: the stored label stays until she next saves her profile, which
 * replaces the map with a code.
 */
const LIFESTYLE_LABELS: ReadonlyMap<string, ActivityBand> = new Map([
  ['Mostly sitting', 'mostlySitting'],
  ['Lightly active', 'lightlyActive'],
  ['Active', 'active'],
  ['Very active', 'veryActive'],
])

/**
 * A stored `lifestyle` read as a code, or `null`.
 *
 * A code passes through; one of the four known labels maps by the table above; **anything
 * else is absent**, and absent means nutrition setup asks rather than a band being assumed.
 * `null` rather than a default band on purpose: `null` does not fit the engine's
 * `activityBand`, so nothing downstream can compute from it without asking first.
 */
export const storedLifestyle = (raw: unknown): ActivityBand | null => {
  if (typeof raw !== 'string') return null
  if ((ACTIVITY_BAND_CODES as readonly string[]).includes(raw)) return raw as ActivityBand
  return LIFESTYLE_LABELS.get(raw) ?? null
}

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
  /**
   * The activity band, as a code (#221), or `null` when unanswered: she has not chosen one
   * yet (`parseProfile` accepts `null` or absent and stores `null`), or the document predates
   * codes and holds a label that is not one of the four the app offered — see
   * `storedLifestyle`. Either way nutrition setup asks; nothing assumes a band.
   */
  lifestyle: ActivityBand | null
  sports: string[]
}

/** The two things consent can be asked for (A21, #86). Both exist whether or not either
 *  changes what Eva does today: `share` governs nothing while Eva's only processors act
 *  under contract with Eva itself (LAUNCH §4.5), and it is still recorded, because the
 *  vendor list the policy names is exactly what a future `share` decision will hang from. */
export const CONSENT_KINDS = ['collect', 'share'] as const

export type ConsentKind = (typeof CONSENT_KINDS)[number]

/**
 * One recorded consent (#86): which text she saw, when she granted it, and whether she has
 * withdrawn it since.
 *
 * `version` is the consent text's own version string — the "Consent v1 · 2026-08-30" line
 * the screen displays — sent by the client that showed her that text and stored verbatim.
 * The server does not keep a table of known versions to check it against: the record exists
 * so a *future* text can be recognised as not the one she agreed to, and the app makes that
 * comparison against the version it ships with. A policy change re-prompts by being a
 * different string, not by the server learning the new one first.
 *
 * `at` and `withdrawnAt` are instants, served as ISO strings the way `lastUserChangeAt`
 * serves its own.
 */
export interface ConsentRecord {
  version: string
  at: string
  withdrawnAt: string | null
}

/**
 * A consent record in the shape the stored document may hold, before `storedConsent` has
 * judged it. `at` is a Firestore `Timestamp` on every document this module writes.
 */
export interface Consent {
  collect: ConsentRecord | null
  share: ConsentRecord | null
}

export interface User {
  id: string
  email: string
  questionnaireCompleted: boolean
  profile: Profile | null
  /**
   * The account's consent record (A21, #86), read-side. Both kinds are present as `null`
   * until granted — a new account has consented to nothing, and an account created before
   * #86 has no `consent` map at all, which reads the same way: there is no record of her
   * having consented, which is the fact the refusal gate and the app's screen both act on.
   *
   * **Absence is not withdrawal.** A withdrawal is a record with `withdrawnAt` set — she
   * was asked, she said yes once, she has said no since. The distinction is the whole
   * point of the freeze decision on #86: withdrawal stops collection and keeps the stored
   * data, so it has to be representable without erasing the grant it withdrew.
   */
  consent: Consent
  /**
   * Which ways in this account offers: `password`, `apple.com`, `google.com` (#7) —
   * Firebase's provider ids, never the request-body words. The client shows it in Profile,
   * decides from it whether "Connect Apple" is still offered, and asks Apple for a
   * revocation code on delete when it contains `apple.com`.
   *
   * **Assembled per response from two owners, and stored whole by neither (#117).**
   *
   * - `apple.com` / `google.com` come from Firebase Auth's `providerData`, read at the
   *   moment of answering (`federatedProvidersOf` in `identity-toolkit.ts`). They used to be
   *   a copy in `users/{uid}.authProviders`, and a copy drifted: `claimUnprovenAccount`
   *   unlinks identities from Auth and nothing pruned the document, so Profile could show a
   *   provider Firebase no longer held — and refuse to offer linking it. Auth is the record
   *   of which identities open the account, so it is the one read.
   * - `password` comes from `users/{uid}.authProviders` containing `"password"` — see
   *   `UserRecord.passwordChosen`. That is an Eva fact, not a copy of one: Firebase lists
   *   `password` for every account `claimUnprovenAccount` has run on, because the claim
   *   overwrites the password with random bytes nobody knows. Deriving it from Auth would
   *   tell every Apple- and Google-first user she has an "Email and password" sign-in.
   *
   * Federated entries still in the stored array are **never read** — see `ensureUser` for
   * why they are still written. Display and decisions in the *client* only: no server-side
   * authorization may read this list; ask `adminAuth.getUser().providerData` (#113).
   */
  authProviders: string[]
  /** Whether the address has been confirmed (#6). Derived from `activatedAt`, which the
   *  client never sees. */
  activated: boolean
  /**
   * Whether she dismissed the "complete your profile" nudge (#19). Server-side, so a
   * dismissal survives reinstall and a second device. `false` when absent — the nudge shows
   * while it is false and `questionnaireCompleted` is false, and stops once either changes.
   */
  profileNudgeDismissed: boolean
}

/**
 * Everything `users/{uid}` can say about her — every `User` field except `authProviders`,
 * which is half Firebase Auth's and cannot be answered from this collection (#117).
 *
 * What this module reads and writes returns this, never `User`, so that a route cannot
 * serve a user without first asking Auth which identities she holds: `servedUser` is the
 * only way from one to the other, and it needs that answer as an argument. Composed at the
 * route edge because neither owner may read the other's store (GUARDRAILS 10).
 */
export interface UserRecord extends Omit<User, 'authProviders'> {
  /**
   * Whether she chose a password: `"password"` in the stored `authProviders`, which
   * `ensureUser` writes on the password sign-in and on activation. Not on the wire — it is
   * served as `authProviders` containing `"password"`. Firebase's `providerData` cannot
   * answer this: it also lists the random password `claimUnprovenAccount` sets.
   */
  passwordChosen: boolean
}

/** Reads the stored half of `authProviders` (#117). Only `"password"` is looked for;
 *  federated entries in the stored array are dormant and deliberately ignored. */
const storedPasswordChosen = (data: FirebaseFirestore.DocumentData): boolean =>
  Array.isArray(data.authProviders) && data.authProviders.includes('password')

/**
 * The `User` the client receives: the record, plus the federated identities Firebase Auth
 * holds *now* (#117). `federated` is `federatedProvidersOf`'s answer — this module never
 * asks Auth itself. `password` first, then Auth's order; the order carries no meaning, and the
 * client only ever tests membership.
 */
export const servedUser = (record: UserRecord, federated: readonly string[]): User => {
  const { passwordChosen, ...user } = record
  return { ...user, authProviders: [...(passwordChosen ? ['password'] : []), ...federated] }
}

/**
 * A user **and the session generation her tokens must match** (#76).
 *
 * `tokenVersion` is deliberately *not* a field on `User`, for the reason `lastUserChangeAt`
 * gives further down this file: `GET /me` serves `User` verbatim to the app, and a counter
 * the client has no use for does not belong in a response body. It is a server-side fact
 * about sessions, so it travels beside the user rather than inside her.
 *
 * Every read that needs it gets it from the *same snapshot* the user came out of — which
 * is what makes #76's check one comparison and not a second Firestore round trip.
 */
export interface Account {
  user: UserRecord
  tokenVersion: number
}

const users = () => firestore.collection('users')

/** `activatedAt` is `null` from creation until the activation link is used, and a
 *  timestamp after. **Absent means activated**: every document written before #6 has no
 *  such field, and those accounts signed in for months on a password alone — a gate that
 *  locked them out until they found a confirmation email they were never sent would be a
 *  regression, not security. Hence `!== null` rather than a truthiness test. */
const isActivatedData = (data: FirebaseFirestore.DocumentData): boolean => data.activatedAt !== null

/**
 * The account's session generation (#76). **Absent is `0`**, for the reason
 * `isActivatedData` reads an absent `activatedAt` as activated: every document written
 * before this field existed has none, and those accounts hold tokens that carry no `tv`
 * claim — which `auth.ts` also reads as `0`. The two absences therefore compare equal and
 * the deploy signs nobody out. A non-number is read the same way rather than trusted:
 * this is a gate, and `0` is its closed position.
 */
const storedTokenVersion = (data: FirebaseFirestore.DocumentData): number =>
  typeof data.tokenVersion === 'number' ? data.tokenVersion : 0

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
  if (typeof fields.dateOfBirth !== 'string') return null
  // #221's migration, on the same terms as #81's: the stored label is read as a code, and
  // an unrecognised one as absent — never rewritten, never guessed.
  fields.lifestyle = storedLifestyle(fields.lifestyle)
  return fields as unknown as Profile
}

/**
 * One stored consent record read as *this* schema, or `null`.
 *
 * The same read-side answer `storedProfile` gives a profile it cannot serve: a record
 * missing its version or its `at` is not a consent record under this schema — there is no
 * text it could name and no instant it could date — and inventing either would be worse
 * than serving none, because the whole value of the record is being able to say what was
 * agreed to and when. It is served as no record, and she is asked again.
 *
 * `at`/`withdrawnAt` accept Firestore `Timestamp`s (what this module writes) and fall back
 * to ISO strings, so a record read back from a document this module wrote always survives
 * the round trip.
 */
const storedConsentRecord = (raw: unknown): ConsentRecord | null => {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const record = raw as Record<string, unknown>
  if (typeof record.version !== 'string' || record.version.length === 0) return null
  const asISO = (v: unknown): string | null => {
    if (v instanceof Timestamp) return v.toDate().toISOString()
    return typeof v === 'string' && v.length > 0 ? v : null
  }
  const at = asISO(record.at)
  if (at === null) return null
  return { version: record.version, at, withdrawnAt: asISO(record.withdrawnAt) }
}

/** The stored `consent` map read as *this* schema. Absent map, absent kind — all the same
 *  answer: no record. A malformed *kind* is dropped to `null` on its own, so a future kind
 *  or a bad `share` cannot take the `collect` record down with it. */
const storedConsent = (raw: unknown): Consent => {
  const record = (v: unknown): ConsentRecord | null =>
    raw === null || typeof raw !== 'object' || Array.isArray(raw) ? null : storedConsentRecord(v)
  const map = (raw ?? {}) as Record<string, unknown>
  return {
    collect: record(map.collect),
    share: record(map.share),
  }
}

/**
 * The refusal gate's question (#86), the way `isActivated` is the activation gate's.
 *
 * A granted record with `withdrawnAt` set is a withdrawal, and a withdrawal is the freeze:
 * nothing new is collected, everything already stored stays. Absent is the never-asked
 * state every pre-#86 account and every new account starts in, and it refuses for the
 * same reason — collection may only follow the record.
 */
export const hasCollectConsent = (user: UserRecord): boolean =>
  user.consent.collect !== null && user.consent.collect.withdrawnAt === null

const toUser = (id: string, data: FirebaseFirestore.DocumentData): UserRecord => {
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
    consent: storedConsent(data.consent),
    passwordChosen: storedPasswordChosen(data),
    activated: isActivatedData(data),
    profileNudgeDismissed: data.profileNudgeDismissed ?? false,
  }
}

/** gRPC NOT_FOUND — the document the write was aimed at is not there. */
const NOT_FOUND = 5

/** A document carrying `deletedAt` is a tombstone, not a user: the account behind it is
 *  being deleted and nothing brings it back (#8). Absent on every document written
 *  before deletion existed, hence `!= null` rather than `!== null`. */
const isTombstone = (snapshot: FirebaseFirestore.DocumentSnapshot): boolean =>
  snapshot.get('deletedAt') != null

/**
 * A write to one of her subcollections found the account tombstoned or gone (#286).
 *
 * Thrown by `assertAccountLive`, from inside the writing module's transaction, and answered
 * by `app.onError` with exactly what the account gate gives a deleted account's token — a
 * `401 UNAUTHORIZED` — because that is what the caller is: a request that passed the gate a
 * moment before `DELETE /me` stamped the tombstone. No new code, and no log line: it is an
 * ordinary outcome of a race, not a fault. Its message names nothing about the account.
 */
export class AccountGoneError extends Error {
  constructor() {
    super('the account this write belongs to is being deleted or is gone')
    this.name = 'AccountGoneError'
  }
}

/**
 * Refuses, inside the caller's transaction, a write under `users/{uid}/…` when the account is
 * tombstoned or its document is gone (#286). Every module that writes a per-user subcollection
 * calls this as a read of the transaction it writes in — never `users/` itself (GUARDRAILS 10).
 *
 * **Why inside the transaction, and why that is sufficient.** `requireAccount` reads the
 * document before the handler runs, so a request can pass it, lose the CPU, and write after
 * `DELETE /me` has stamped the tombstone *and swept that subcollection* — leaving health data
 * under an account that nothing links to and nothing will ever delete. Reading the document
 * as part of the write's own transaction puts it in the read set: if `markUserDeleted` commits
 * between this read and the commit, the transaction is retried and this read then sees the
 * tombstone. So every committed write is serialized either **before** the tombstone — and the
 * sweep, which runs after it, removes what it wrote — or it is refused. There is no third
 * ordering, which is what a check before the transaction (or the gate alone) cannot say.
 *
 * `!exists` refuses too: a missing document is a finished delete, and a write there would be
 * the same orphan with the tombstone already gone. The cost is one document read per write,
 * billed as a read, and the contention of a read lock on `users/{uid}` for the life of a
 * short transaction — ARCHITECTURE §4 has the measurement.
 */
export const assertAccountLive = async (
  tx: FirebaseFirestore.Transaction,
  uid: string,
): Promise<void> => {
  const snapshot = await tx.get(users().doc(uid))
  if (!snapshot.exists || isTombstone(snapshot)) throw new AccountGoneError()
}

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
): Promise<Account | null> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (snapshot.exists) {
    if (isTombstone(snapshot)) return null
    // `update`, never `set`: it fails rather than creates if the document went away
    // between the read and here, so a delete landing mid-sign-in cannot be undone.
    //
    // **Federated ids are still unioned in, and nothing reads them (#117).** Only
    // `"password"` is read back (`storedPasswordChosen`); `apple.com` and `google.com` are
    // served from Auth. The write stays because removing it is not free: the build before
    // #117 reads this array whole, so a rollback to it would find every account created in
    // between without its Apple entry — and the app skips Apple token revocation on delete
    // for an account whose list lacks `apple.com`. Stop writing them once no deployable
    // build reads them; never delete what is already stored (data deletion is a human call).
    await ref.update({
      authProviders: FieldValue.arrayUnion(provider),
      updatedAt: FieldValue.serverTimestamp(),
    })
    // The union is applied to the value that is returned as well as to the document, so a
    // password sign-in that first records the password is answered with it. Reading the
    // document back would cost a second round trip to learn something we just decided.
    const data = snapshot.data()!
    const existing: string[] = data.authProviders ?? []
    // The version comes off the snapshot this function already read (#76): a sign-in mints
    // at the account's current generation, and it costs nothing to know what that is.
    return {
      user: toUser(uid, {
        ...data,
        authProviders: existing.includes(provider) ? existing : [...existing, provider],
      }),
      tokenVersion: storedTokenVersion(data),
    }
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
  // A fresh document carries no `tokenVersion` and needs none: `0` is what every reader
  // makes of its absence, and there are no earlier sessions for it to strand.
  return {
    user: {
      id: uid,
      email,
      questionnaireCompleted: false,
      profile: null,
      consent: { collect: null, share: null },
      passwordChosen: provider === 'password',
      activated: false,
      profileNudgeDismissed: false,
    },
    tokenVersion: 0,
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
 * It exists because `ensureUser` *writes*, and nothing may be written for a credential the
 * claim gate is about to refuse. It was first found as a refused credential's provider left
 * permanently in the stored `authProviders` on a stranger's document, which the app then
 * read to decide whether to offer "Connect Apple". Since #117 the served list takes its
 * federated entries from Auth rather than from that array, so that particular harm cannot
 * recur through here — but a write before the gate is still a write on the say-so of a
 * credential that has not earned the account, and the order stays.
 */
export const readUser = async (
  uid: string,
): Promise<{ deleted: boolean; user: UserRecord | null }> => {
  const snapshot = await users().doc(uid).get()
  if (!snapshot.exists) return { deleted: false, user: null }
  if (isTombstone(snapshot)) return { deleted: true, user: null }
  return { deleted: false, user: toUser(uid, snapshot.data()!) }
}

/**
 * What the account gate reads (#76): the user, and the generation her token has to carry.
 *
 * **One read, and it is the read the gate already made.** `requireAccount` has always
 * loaded this document to prove the account still exists (#8); this returns one more
 * value out of the same snapshot, so checking the token version costs a comparison and
 * not a round trip. Anything that needed a second read would be the wrong design — say so
 * rather than paying it.
 *
 * `null` for a missing document and for a tombstone alike, exactly as `getUser` answers,
 * and for the same reason: a delete in flight is not an account.
 */
export const getAccount = async (uid: string): Promise<Account | null> => {
  const snapshot = await users().doc(uid).get()
  if (!snapshot.exists || isTombstone(snapshot)) return null
  const data = snapshot.data()!
  return { user: toUser(uid, data), tokenVersion: storedTokenVersion(data) }
}

/** The user alone, for the callers that have no session to check — expressed through
 *  `getAccount` so the tombstone rule has one implementation rather than two. */
export const getUser = async (uid: string): Promise<UserRecord | null> =>
  (await getAccount(uid))?.user ?? null

/**
 * Ends every session on this account, and returns the generation the caller may mint at
 * (#76).
 *
 * **What bumps it, and why each answer is what it is.** The rule is: *a credential that
 * could already open this account has been taken away or replaced.* Concretely —
 *
 * - **`POST /auth/password/reset` — yes, always.** The decision on #76, and the reason the
 *   field exists: someone resetting a password usually does it because somebody else has
 *   it, and a reset that leaves the other session live defeats its own purpose. Not behind
 *   an opt-in, because a second control is found by the people who least need it.
 * - **`POST /auth/activate` on the claim path — yes.** That path sets a password on an
 *   account this request did not create, and `retractUnprovenIdentities` beside it already
 *   revokes Firebase's refresh tokens; leaving Eva's own sessions alone there would be the
 *   two halves of one act disagreeing. It is belt and braces *today* — an account with a
 *   live Eva session is necessarily activated (sign-in requires it, `/auth/idp` and reset
 *   stamp it), and the route refuses an activated account as a dead link — so there is
 *   provably nothing to strand. That argument is true by arrangement of three other
 *   routes, which is the kind of true that stops being true quietly.
 * - **The create path of `/auth/activate` — no.** There is no account yet, so there is no
 *   session to end and nothing to bump from.
 * - **`POST /me/auth/providers` (link) — no.** Adding a credential takes nothing from
 *   anyone. Signing a woman out of her other devices for connecting Apple would be a bug
 *   wearing security's clothes.
 * - **A provider *unlink* — yes, when a route for it exists.** There is none today, which
 *   is why this is a sentence and not a call site. The reasoning is the reset's own: an
 *   unlink exists to stop a credential opening this account, and a session that credential
 *   minted is that credential still opening it. Whoever builds that route calls this, and
 *   mints the caller a fresh token the way the reset route does, so the device doing the
 *   unlinking is not the one it punishes.
 * - **`DELETE /me` — no.** The tombstone already refuses every token for the account, and
 *   an account that is gone has no sessions left to number.
 *
 * `null` means there was no account to bump — no document, or a tombstone — which the
 * caller answers as a dead link rather than as an error.
 *
 * A transaction, and not `FieldValue.increment`, because the caller needs the resulting
 * number to mint with: two concurrent resets must not both mint at the same generation,
 * or the loser's token opens the winner's account.
 */
export const bumpTokenVersion = async (uid: string): Promise<number | null> => {
  const ref = users().doc(uid)
  return firestore.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref)
    if (!snapshot.exists || isTombstone(snapshot)) return null
    const next = storedTokenVersion(snapshot.data()!) + 1
    tx.update(ref, { tokenVersion: next, updatedAt: FieldValue.serverTimestamp() })
    return next
  })
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
export const isActivated = (user: UserRecord): boolean => user.activated

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
export const saveQuestionnaire = async (
  uid: string,
  profile: Profile,
): Promise<UserRecord | null> => {
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

/**
 * Marks the "complete your profile" nudge dismissed (#19).
 *
 * Server-side rather than device-side, so a dismissal made on one device is not asked again
 * on a second — the decision recorded on #19. Dismissing never blocks anything: it only
 * flips this flag, and the Profile route and every other write keep working regardless.
 * `null` for a missing document or a tombstone, the same answer `saveQuestionnaire` gives.
 */
export const dismissProfileNudge = async (uid: string): Promise<UserRecord | null> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (!snapshot.exists || isTombstone(snapshot)) return null
  await ref.update({
    profileNudgeDismissed: true,
    updatedAt: FieldValue.serverTimestamp(),
  })
  return toUser(uid, { ...snapshot.data()!, profileNudgeDismissed: true })
}

/**
 * Records or withdraws one consent kind (A21, #86) — and is the **only writer of
 * `consent` in the system**: a consent record that anything else could change is a consent
 * record that cannot testify. The route validates the request; this function is the record.
 *
 * **Granting** writes the record whole — `version` is the text the client says it showed
 * her, `at` is this instant, and `withdrawnAt` is explicitly `null` so a re-grant after a
 * withdrawal leaves the record reading as granted rather than carrying a stale withdrawal
 * inside it.
 *
 * **Withdrawing is the freeze**, per the decision on #86: it stamps `withdrawnAt` on the
 * record that is there and touches nothing else — `version` and `at` are the stored
 * record's own, because the withdrawal's meaning is "the consent recorded here no longer
 * holds", and erasing the grant it withdrew would stop the record saying what was
 * withdrawn. Nothing is deleted here; withdrawal is not `DELETE /me` by another name, and
 * the stored data keeps until export or account deletion removes it through their own
 * paths. Withdrawing a consent that was never granted writes nothing and returns the user
 * as she is — there is no record to freeze, and an idempotent answer is what a Settings
 * toggle wants.
 *
 * `null` for a missing document or a tombstone, the same answer every writer in this
 * file gives.
 */
export const saveConsent = async (
  uid: string,
  kind: ConsentKind,
  granted: boolean,
  version: string,
): Promise<UserRecord | null> => {
  const ref = users().doc(uid)
  // A transaction, not a read-then-write, for the same reason `bumpTokenVersion` is: the
  // decision depends on what the document holds *now* — whether there is a grant to
  // withdraw, and which version/`at` the withdrawal stamps — and a re-grant landing
  // between the read and the write would otherwise be clobbered by a withdrawal built
  // from the stale record, leaving the field saying she withdrew a text she never saw.
  // The security review of #86 found exactly that window.
  return firestore.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref)
    if (!snapshot.exists || isTombstone(snapshot)) return null

    const field = `consent.${kind}`
    const before = storedConsent(snapshot.data()!.consent)

    if (granted) {
      // The record as it will read after the write, in the *stored* shape (Timestamps,
      // not ISO strings) so it can be both written and spliced into the returned user —
      // which `toUser` then serves through `storedConsent` exactly as a later read
      // would see it. Echoing what the route just decided, rather than re-reading the
      // document, is the same shape `saveQuestionnaire` answers with.
      const record = { version, at: Timestamp.now(), withdrawnAt: null }
      tx.update(ref, { [field]: record, updatedAt: FieldValue.serverTimestamp() })
      return toUser(uid, { ...snapshot.data()!, consent: { ...before, [kind]: record } })
    }

    const existing = before[kind]
    if (!existing) return toUser(uid, snapshot.data()!)
    const withdrawn = {
      version: existing.version,
      at: Timestamp.fromDate(new Date(existing.at)),
      withdrawnAt: Timestamp.now(),
    }
    tx.update(ref, { [field]: withdrawn, updatedAt: FieldValue.serverTimestamp() })
    return toUser(uid, { ...snapshot.data()!, consent: { ...before, [kind]: withdrawn } })
  })
}

/** Stamps `deletedAt` on the document, which is the moment the account stops existing as
 *  far as every route is concerned (#8): `getUser` answers `null` from here on, so the
 *  account gate in `index.ts` rejects every token that names this uid, and `ensureUser`
 *  refuses to revive it, so signing in cannot bring it back either. Nothing clears it —
 *  an account has no Undo, unlike a single event.
 *
 *  It is deliberately the first **inerting** step and step 2 of deletion overall: the
 *  bounded link-token cleanup runs while the account still proves ownership of its address,
 *  then this tombstone protects the health-data sweep. Whatever fails after it, the account
 *  is already inert and the retry is a plain re-run.
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

import { FieldPath, FieldValue, Timestamp } from 'firebase-admin/firestore'
import { firestore } from './firebase'

/** Owner of `users/{uid}/events/` (GUARDRAILS rule 10). Nothing else touches it.
 *
 *  Two kinds of time live on an event, deliberately:
 *  - `localDate` / `loggedAt` / `startAt` are the *user's* wall clock. They are stored
 *    as strings exactly as the client sent them and are never derived from an instant,
 *    so a timezone change cannot move an entry to another day (PRD edge case 5).
 *  - `createdAt` / `updatedAt` / `deletedAt` are system audit instants, server-set.
 *
 *  Never log an event or its payload: this is health data (GUARDRAILS rule 12). */

/** `sex` is reserved so the enum is stable when C10 ships it with its privacy switch.
 *  It has no payload and no validator yet — the route rejects it. */
export type EventType = 'cycle' | 'bodySignals' | 'sport' | 'appointment' | 'sex' | 'positiveTest'
export type LoggableEventType = Exclude<EventType, 'sex'>
export type EventSource = 'user' | 'eva'
export type FlowLevel = 'light' | 'medium' | 'heavy'
export type SportIntensity = 'light' | 'medium' | 'hard'
export type SymptomSeverity = 'normal' | 'severe'

/** Spotting is a separate marker, not a fourth flow level: a spotting day does not
 *  start a period. The `never` arms make "both at once" unrepresentable.
 *
 *  `periodEnd` is the explicit "my period ended" mark from the day sheet (#75). It rides
 *  on the cycle entry of the last day **with** flow, not on its own entry on the first dry
 *  day, which is what keeps it inside the one-per-day document ID: an entry at
 *  `cycle_<first dry day>` would have to share that ID with a spotting entry on the same
 *  date, and this is a union rather than a record. Two rules follow, and the arms below
 *  state both — `parseCyclePayload` refuses them at the edge, where input is checked:
 *   - it never appears with `spotting: true`, because spotting is by definition not flow;
 *   - it never appears without a flow level on the same entry. A period cannot end on a
 *     day that records no bleeding, so the mark cannot store a fact that contradicts
 *     itself.
 *  Absent means "not marked", and the key is absent rather than `false` or `undefined`
 *  (Firestore rejects undefined). Setting and clearing are both edits to the day's
 *  existing entry, so `localDate` never moves.
 *
 *  **Nothing here reads it, and exactly one thing anywhere does.** The inferred end — the
 *  first day with no flow logged (PRD §Calendar) — is unchanged and still inferred. #75
 *  stored the fact and deliberately left the disagreement open; #186 answered it in
 *  `cycle.ts`, narrowly: a mark decides whether a *later flow day* continues the period it
 *  ended, and nothing else — no end date, no period length, no cycle length. That read is
 *  on the maths' own input type, so what carries this stored field to it is `toCycleDay` in
 *  `today.ts` (#179) — the one mapping between this field and its one reader. */
export type CyclePayload =
  | { spotting: true; flow?: never; periodEnd?: never }
  | { flow: FlowLevel; spotting?: never; periodEnd?: true }

/** A positive pregnancy test on this day, and nothing else (#80; PRD §Positive test —
 *  "Positive test — marks the day"). The entry *is* the fact, so there is no field to
 *  carry and the payload is empty. `parsePositiveTestPayload` refuses every key rather
 *  than dropping it, which is the only door a beta-hCG reading or a "negative" could come
 *  through (GUARDRAILS 35).
 *
 *  **Its own event type rather than a third arm of `CyclePayload`**, and three things
 *  decided that independently:
 *   - A test is not bleeding. Both arms above require flow or spotting, which is exactly
 *     what let `periodEnd` ride on the day it qualifies. A positive test has no such host
 *     — the day it usually lands on has nothing logged on it at all — so an arm would
 *     have meant either a `cycle` entry recording no cycle fact, or asking a woman to log
 *     flow she does not have.
 *   - `cycle` holds one entry per day at `cycle_<localDate>`. An arm would put a positive
 *     test and a spotting day on the same date into one document, which is the collision
 *     the `periodEnd` comment above explains `CyclePayload` was shaped to avoid.
 *   - `cycle.ts` must not read it, and `today.ts`'s `toCycleDay` maps *cycle* entries
 *     (`event.type !== 'cycle'` → `null`). A separate type never enters that mapping, so
 *     "the maths cannot see this" is a property of the type rather than a rule someone
 *     has to remember. A third arm would have put it inside the one module that must not
 *     have it.
 *
 *  **Nothing reads it**, and that is the decision rather than an omission: no mode moves,
 *  no card changes, no prediction shifts. The same place #75 left `periodEnd` in, for the
 *  same reason — the cycle-to-pregnancy transition this fact will trigger is D10's, and
 *  its semantics are not decided. Recording the fact first is what makes it available the
 *  day they are. */
export type PositiveTestPayload = Record<string, never>

/** `code` is validated at the route edge against the catalogue in `refdata.ts` (#24).
 *
 *  `severity` and `value` are two different axes and neither can express the other:
 *  severity is an intensity (the second tap on Cramps), `value` is a category the
 *  chip's own picker offers — discharge is `dry|sticky|creamy|watery|egg-white`.
 *  Only chips whose catalogue entry declares `values` carry one; the key is absent
 *  otherwise, never `undefined` (Firestore rejects undefined). */
export interface Symptom {
  code: string
  severity: SymptomSeverity
  value?: string
}

/** Every rating is optional — nothing is preselected in the sheet, and an absent
 *  rating means "not answered", which is not the same as a 3. */
export interface BodySignalsPayload {
  energy?: number
  mood?: number
  sleep?: number
  symptoms: Symptom[]
}

export interface SportPayload {
  activity: string
  durationMin: number
  intensity: SportIntensity
}

export interface AppointmentPayload {
  /** Local wall clock `YYYY-MM-DDTHH:mm:ss`, same day as `localDate`. */
  startAt: string
  type: string | null
  questions: string[]
  /** Reminder *intent* only — nothing is scheduled here. `null` means no reminder. */
  reminderMinutesBefore: number | null
}

type Typed =
  | { type: 'cycle'; payload: CyclePayload }
  | { type: 'bodySignals'; payload: BodySignalsPayload }
  | { type: 'sport'; payload: SportPayload }
  | { type: 'appointment'; payload: AppointmentPayload }
  | { type: 'positiveTest'; payload: PositiveTestPayload }

export type EventPayload = Typed['payload']

interface EventFields {
  localDate: string
  loggedAt: string
  note: string | null
  source: EventSource
  idempotencyKey: string | null
}

export type NewEvent = EventFields & Typed

export type EvaEvent = EventFields &
  Typed & {
    id: string
    deletedAt: string | null
    createdAt: string | null
    updatedAt: string | null
  }

/** Patch fields are already validated at the route edge. `type` is asserted by the
 *  caller (the client knows what it is editing) so the edge can validate the payload
 *  without reading Firestore. */
export interface EventPatch {
  type: LoggableEventType
  localDate?: string
  loggedAt?: string
  note?: string | null
  payload?: EventPayload
}

export type UpdateResult =
  | { ok: true; event: EvaEvent }
  | { ok: false; reason: 'not-found' | 'type-mismatch' | 'immutable-date' }

/** One entry per user per day, enforced by a deterministic document ID rather than a
 *  read-then-write. `bodySignals` is upserted (PRD "Other requirements" 3); a second
 *  `cycle` entry replaces the first (PRD "Menstrual cycle").
 *
 *  `positiveTest` joins them (#80) because the day *is* its whole content: the payload is
 *  empty, so a second entry on one date is a duplicate rather than a second fact, and two
 *  identical rows in the day list is what a user would see. Storage, not semantics —
 *  nothing here branches on the type beyond where its document lives. */
const ONE_PER_DAY: ReadonlySet<LoggableEventType> = new Set([
  'cycle',
  'bodySignals',
  'positiveTest',
])

export const isOnePerDay = (type: LoggableEventType): boolean => ONE_PER_DAY.has(type)

const events = (uid: string) => firestore.collection('users').doc(uid).collection('events')

const dayDocId = (type: LoggableEventType, localDate: string) => `${type}_${localDate}`

const toIso = (value: unknown): string | null =>
  value instanceof Timestamp ? value.toDate().toISOString() : null

const toEvent = (snapshot: FirebaseFirestore.DocumentSnapshot): EvaEvent => {
  const data = snapshot.data()!
  return {
    id: snapshot.id,
    type: data.type,
    localDate: data.localDate,
    loggedAt: data.loggedAt,
    note: data.note ?? null,
    source: data.source ?? 'user',
    payload: data.payload,
    idempotencyKey: data.idempotencyKey ?? null,
    deletedAt: toIso(data.deletedAt),
    createdAt: toIso(data.createdAt),
    updatedAt: toIso(data.updatedAt),
  } as EvaEvent
}

const writableFields = (input: NewEvent) => ({
  type: input.type,
  localDate: input.localDate,
  loggedAt: input.loggedAt,
  note: input.note,
  source: input.source,
  payload: input.payload,
  idempotencyKey: input.idempotencyKey,
  deletedAt: null,
  updatedAt: FieldValue.serverTimestamp(),
})

const read = async (ref: FirebaseFirestore.DocumentReference): Promise<EvaEvent> =>
  toEvent(await ref.get())

/** Creates an event, or replaces the day's entry for the one-per-day types.
 *  A repeated `idempotencyKey` returns the event that key already created rather
 *  than writing a second one — the offline queue will retry. */
export const createEvent = async (uid: string, input: NewEvent): Promise<EvaEvent> => {
  const collection = events(uid)

  if (ONE_PER_DAY.has(input.type)) {
    const ref = collection.doc(dayDocId(input.type, input.localDate))
    await firestore.runTransaction(async (tx) => {
      const existing = await tx.get(ref)
      // Replacing clears a previous soft delete: the day has an entry again.
      tx.set(ref, {
        ...writableFields(input),
        createdAt: existing.get('createdAt') ?? FieldValue.serverTimestamp(),
      })
    })
    return read(ref)
  }

  if (input.idempotencyKey) {
    const key = input.idempotencyKey
    const ref = await firestore.runTransaction(async (tx) => {
      const seen = await tx.get(collection.where('idempotencyKey', '==', key).limit(1))
      if (!seen.empty) return seen.docs[0]!.ref
      const fresh = collection.doc()
      tx.set(fresh, { ...writableFields(input), createdAt: FieldValue.serverTimestamp() })
      return fresh
    })
    return read(ref)
  }

  const ref = collection.doc()
  await ref.set({ ...writableFields(input), createdAt: FieldValue.serverTimestamp() })
  return read(ref)
}

/** Inclusive range read on the stored `localDate`, soft-deleted entries excluded in the
 *  query itself. That needs the composite index on `deletedAt` + `localDate`, which sits in
 *  firestore.indexes.json and is deployed (#27). */
export const listEvents = async (uid: string, from: string, to: string): Promise<EvaEvent[]> => {
  const snapshot = await events(uid)
    .where('deletedAt', '==', null)
    .where('localDate', '>=', from)
    .where('localDate', '<=', to)
    .orderBy('localDate', 'asc')
    .get()

  return snapshot.docs
    .map(toEvent)
    .sort((a, b) => a.localDate.localeCompare(b.localDate) || a.loggedAt.localeCompare(b.loggedAt))
}

export const getEvent = async (uid: string, id: string): Promise<EvaEvent | null> => {
  const snapshot = await events(uid).doc(id).get()
  if (!snapshot.exists || snapshot.get('deletedAt') !== null) return null
  return toEvent(snapshot)
}

/**
 * The newest `updatedAt` across *every* entry, soft-deleted ones included — the Today
 * card's "has her data moved" signal (#98, D3).
 *
 * Soft-deleted entries are the reason this exists rather than a scan of `listEvents`:
 * deleting an entry is exactly a change the card must be regenerated for, and a deleted
 * entry is invisible to every other read in this file. Every write here stamps
 * `updatedAt` — create, edit, soft delete, restore — so one ordered read answers all four.
 *
 * `null` for an account that has never logged anything. A *purge* can move this backwards,
 * which cannot move a card: a purge only removes entries soft-deleted 30 days ago, and
 * nothing that old is in today's card.
 */
export const lastEventChangeAt = async (uid: string): Promise<string | null> => {
  const snapshot = await events(uid).orderBy('updatedAt', 'desc').limit(1).get()
  return toIso(snapshot.docs[0]?.get('updatedAt'))
}

/** How many of the most recent entries `lastLoggedDate` reads before giving up. A bound
 *  rather than a filter, because `deletedAt` cannot be combined with an ordered range on
 *  `localDate` without a composite index — and an index is a deploy a human gates. */
const LAST_LOG_SCAN = 50

/**
 * The most recent day on or before `onOrBefore` that carries a live entry of any kind —
 * what D1's `daysSinceLastLog` is measured from, and what tells its cold-start card that
 * this is a first open (#98).
 *
 * Capped at `LAST_LOG_SCAN` entries: a user whose last fifty entries on or before that day
 * are *all* soft-deleted reads as "nothing logged". That direction is the safe one — it
 * shows the card that explains what to log — and it is unreachable for anyone who has not
 * deleted fifty entries without logging since.
 */
export const lastLoggedDate = async (uid: string, onOrBefore: string): Promise<string | null> => {
  const snapshot = await events(uid)
    .where('localDate', '<=', onOrBefore)
    .orderBy('localDate', 'desc')
    .limit(LAST_LOG_SCAN)
    .get()
  for (const doc of snapshot.docs) {
    if (doc.get('deletedAt') === null) return doc.get('localDate') as string
  }
  return null
}

export const updateEvent = async (
  uid: string,
  id: string,
  patch: EventPatch,
): Promise<UpdateResult> => {
  const ref = events(uid).doc(id)
  const snapshot = await ref.get()
  // A soft-deleted event is gone as far as the API is concerned; `restoreEvent` is
  // the one way back, so editing one must not silently resurrect it as a side effect.
  if (!snapshot.exists || snapshot.get('deletedAt') !== null)
    return { ok: false, reason: 'not-found' }
  if (snapshot.get('type') !== patch.type) return { ok: false, reason: 'type-mismatch' }
  // The day is part of the document ID for these, so moving one would mean a new event.
  if (patch.localDate && patch.localDate !== snapshot.get('localDate') && isOnePerDay(patch.type)) {
    return { ok: false, reason: 'immutable-date' }
  }

  await ref.update({
    ...(patch.localDate !== undefined ? { localDate: patch.localDate } : {}),
    ...(patch.loggedAt !== undefined ? { loggedAt: patch.loggedAt } : {}),
    ...(patch.note !== undefined ? { note: patch.note } : {}),
    ...(patch.payload !== undefined ? { payload: patch.payload } : {}),
    updatedAt: FieldValue.serverTimestamp(),
  })
  return { ok: true, event: await read(ref) }
}

/** Soft delete: the document stays, so the entry is recoverable — by `restoreEvent`
 *  for `RETENTION_DAYS`, after which `purgeUserEvents` removes it for good. */
export const softDeleteEvent = async (uid: string, id: string): Promise<boolean> => {
  const ref = events(uid).doc(id)
  const snapshot = await ref.get()
  if (!snapshot.exists) return false
  if (snapshot.get('deletedAt') !== null) return true // already deleted: idempotent
  await ref.update({
    deletedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  })
  return true
}

/** Firestore's own ceiling on a batched write. The sweep below is one batch per pass,
 *  so this is also the most documents one pass reads. */
const DELETE_BATCH = 500

/** Hard-deletes *every* event of one user, soft-deleted entries included — the data half
 *  of account deletion (#8). Nothing here consults `deletedAt`: an account that no longer
 *  exists cannot have a 30-day recovery window inside it, which is the one place this
 *  deliberately parts company with `purgeUserEvents`.
 *
 *  It parts company on preconditions too, and that is the point rather than an oversight.
 *  The purge deletes on a timer and must never touch a live entry, so every document is
 *  re-checked and every delete carries a `lastUpdateTime`. This runs under the caller's
 *  own explicit request, after the account has already been marked deleted, and its
 *  correct behaviour is "leave nothing" — a precondition here would *preserve* health
 *  data the user asked us to destroy.
 *
 *  A batch at a time, re-querying rather than paging a cursor, so a failure part-way
 *  through is a partial delete and not a lost position: the next call simply finds what
 *  is left. Returns how many documents it removed — a count, never an id, a date or a
 *  payload (GUARDRAILS 12). */
export const deleteAllUserEvents = async (uid: string): Promise<number> => {
  const collection = events(uid)
  let deleted = 0
  for (;;) {
    const snapshot = await collection.limit(DELETE_BATCH).get()
    if (snapshot.empty) return deleted
    const batch = firestore.batch()
    for (const doc of snapshot.docs) batch.delete(doc.ref)
    await batch.commit()
    deleted += snapshot.size
  }
}

/**
 * Every event of one user, a page at a time — the calendar half of `GET /me/export` (#58).
 *
 * **Every stored entry, soft-deleted ones included**, each in exactly the shape
 * `listEvents` serves, so a deleted entry is told apart by its `deletedAt` and by nothing
 * else. That includes an entry past its recovery window that the purge has not reached yet:
 * the export answers "what does Eva hold about me", and an entry still stored is held,
 * whatever the retention promise says should already have happened to it. The same
 * reasoning `deleteAllUserEvents` gives for taking soft-deleted entries, from the other
 * side — the account's own request is about all of it.
 *
 * **Ordered by document id, not by `localDate`.** An ordered query silently drops a
 * document that lacks the field it is ordered on, and an export that can lose an entry
 * without saying so is the one failure it may not have; the document id is on every
 * document. It also needs no index, and it makes the cursor strictly increasing, so an
 * entry can appear at most once even while she keeps logging during the download.
 *
 * Not a point-in-time snapshot: an entry written or edited while the pages are being read
 * may or may not be in them. A page at a time is what keeps 20,000 entries out of memory at
 * once; the caller streams each page out before asking for the next. Yields nothing at all
 * for an account with no events, rather than one empty page.
 */
export async function* exportEvents(
  uid: string,
  pageSize: number,
): AsyncGenerator<EvaEvent[], void, undefined> {
  const ordered = events(uid).orderBy(FieldPath.documentId()).limit(pageSize)
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null
  for (;;) {
    const page = await (cursor === null ? ordered : ordered.startAfter(cursor)).get()
    if (page.empty) return
    yield page.docs.map(toEvent)
    if (page.size < pageSize) return
    cursor = page.docs.at(-1) ?? null
  }
}

/** How long a soft-deleted entry stays recoverable (PRD:472). One constant, so the
 *  restore window and the purge cannot drift apart. */
export const RETENTION_DAYS = 30

const RETENTION_MS = RETENTION_DAYS * 24 * 60 * 60 * 1000

/** Before this instant, a deleted entry is past its window. `deletedAt` is a server
 *  instant, so this is instant arithmetic end to end — no calendar, no time zone, no
 *  DST, nothing that moves when the caller's clock does. Deliberately *not* derived
 *  from `localDate`: the wall-clock fields say what day the user logged, not when the
 *  retention clock started. */
export const retentionCutoff = (now: number = Date.now()): Timestamp =>
  Timestamp.fromMillis(now - RETENTION_MS)

/** Explicit floor on the purge query. Firestore already excludes `null` and missing
 *  fields from a range filter — checked against the real backend, not assumed, so
 *  `deletedAt < cutoff` alone does not match live events. The floor is here anyway
 *  because it states the intent in the query itself rather than resting a delete on
 *  one subtlety of an operator's semantics, and it costs nothing: still one field,
 *  still the automatic single-field index. */
const EPOCH = Timestamp.fromMillis(0)

/** gRPC FAILED_PRECONDITION: the document changed between the read and the delete. */
const FAILED_PRECONDITION = 9

export type RestoreResult =
  | { ok: true; event: EvaEvent }
  | { ok: false; reason: 'not-found' | 'expired' | 'day-taken' }

type RestoreOutcome = 'restored' | 'not-found' | 'expired' | 'day-taken'

/** Undo for a soft delete — the toast affordance in C5. Clears `deletedAt` if the
 *  entry is still inside its window, in a transaction so a concurrent re-log cannot
 *  land between the read and the write.
 *
 *  `day-taken` is the one-per-day case, and it is not `not-found`. `cycle` and
 *  `bodySignals` live at a deterministic document ID, so the day *is* the document:
 *  if anything has logged that day since the delete, `createEvent` has already
 *  overwritten this very document and the deleted entry no longer exists anywhere.
 *  Clearing `deletedAt` there would not resurrect the old entry, it would relabel the
 *  newer one as restored — so this refuses instead.
 *
 *  The cost of that design, stated rather than discovered: a *live* document at a
 *  one-per-day ID cannot distinguish "the day was retaken" from "this was never
 *  deleted", because replacing keeps the ID and `createdAt` and leaves no trace of the
 *  delete. Both answer `day-taken`. Restoring something that was never deleted is a
 *  client bug either way, and "that day already has an entry" is true in both cases.
 *
 *  `deletedAt >= cutoff` here is the exact complement of `purgeUserEvents`'
 *  `deletedAt < cutoff`: no entry is ever both restorable and purgeable. */
export const restoreEvent = async (uid: string, id: string): Promise<RestoreResult> => {
  const ref = events(uid).doc(id)
  const cutoffMs = retentionCutoff().toMillis()

  const outcome = await firestore.runTransaction<RestoreOutcome>(async (tx) => {
    const snapshot = await tx.get(ref)
    if (!snapshot.exists) return 'not-found'

    const deletedAt = snapshot.get('deletedAt')
    if (!(deletedAt instanceof Timestamp)) {
      const type = snapshot.get('type') as LoggableEventType
      const takesTheDay =
        isOnePerDay(type) && snapshot.id === dayDocId(type, snapshot.get('localDate'))
      return takesTheDay ? 'day-taken' : 'not-found'
    }
    if (deletedAt.toMillis() < cutoffMs) return 'expired'

    tx.update(ref, { deletedAt: null, updatedAt: FieldValue.serverTimestamp() })
    return 'restored'
  })

  if (outcome === 'restored') return { ok: true, event: await read(ref) }
  return { ok: false, reason: outcome }
}

export interface PurgeResult {
  /** Hard-deleted, or — under `dryRun` — what would have been. */
  purged: number
  /** Matched the query but was not deleted: re-check failed, or it changed under us. */
  skipped: number
}

export interface PurgeOptions {
  cutoff?: Timestamp
  dryRun?: boolean
}

/** Hard-deletes one user's events whose recovery window has passed — the job behind
 *  "recoverable for 30 days". Driven by `scripts/purge-events.ts`; see that file for
 *  why this is a script and not a route.
 *
 *  Scoped to a single uid on purpose. Nothing here can start a project-wide delete,
 *  so a test, or a script run with the wrong argument, cannot reach data it was not
 *  pointed at; the fan-out over users lives in the script, where it is visible.
 *
 *  Three independent things keep a live entry safe, because one is not enough for a
 *  timer that deletes health data:
 *   1. the query is bounded at both ends (see `EPOCH`);
 *   2. every document is re-checked in code before it is deleted, so a wrong query
 *      cannot by itself become a wrong delete — and `skipped` is where that shows up,
 *      so a purge that matched something it should not have is visible, not silent;
 *   3. the delete carries a `lastUpdateTime` precondition, so an entry restored or
 *      re-logged between the read and the delete is skipped rather than removed.
 *
 *  Returns counts and nothing else — no IDs, no dates, no payloads. A purge is exactly
 *  where someone would be tempted to log what it deleted (GUARDRAILS 12). */
export const purgeUserEvents = async (
  uid: string,
  options: PurgeOptions = {},
): Promise<PurgeResult> => {
  const cutoff = options.cutoff ?? retentionCutoff()
  const cutoffMs = cutoff.toMillis()

  const snapshot = await events(uid)
    .where('deletedAt', '>=', EPOCH)
    .where('deletedAt', '<', cutoff)
    .get()

  let purged = 0
  let skipped = 0
  for (const doc of snapshot.docs) {
    const deletedAt = doc.get('deletedAt')
    if (!(deletedAt instanceof Timestamp) || deletedAt.toMillis() >= cutoffMs) {
      skipped += 1
      continue
    }
    if (options.dryRun) {
      purged += 1
      continue
    }
    try {
      await doc.ref.delete({ lastUpdateTime: doc.updateTime })
      purged += 1
    } catch (err) {
      // Only "it changed under us" is expected. Anything else is a real fault and
      // must not be swallowed into a count that reads like success.
      if ((err as { code?: number }).code !== FAILED_PRECONDITION) throw err
      skipped += 1
    }
  }

  return { purged, skipped }
}

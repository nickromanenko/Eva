import { FieldValue, Timestamp } from 'firebase-admin/firestore'
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
export type EventType = 'cycle' | 'bodySignals' | 'sport' | 'appointment' | 'sex'
export type LoggableEventType = Exclude<EventType, 'sex'>
export type EventSource = 'user' | 'eva'
export type FlowLevel = 'light' | 'medium' | 'heavy'
export type SportIntensity = 'light' | 'medium' | 'hard'
export type SymptomSeverity = 'normal' | 'severe'

/** Spotting is a separate marker, not a fourth flow level: a spotting day does not
 *  start a period. The `never` arms make "both at once" unrepresentable. */
export type CyclePayload =
  | { spotting: true; flow?: never }
  | { flow: FlowLevel; spotting?: never }

/** `code` is opaque until #24 ships the catalogue it validates against. */
export interface Symptom {
  code: string
  severity: SymptomSeverity
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
 *  `cycle` entry replaces the first (PRD "Menstrual cycle"). */
const ONE_PER_DAY: ReadonlySet<LoggableEventType> = new Set(['cycle', 'bodySignals'])

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

/** Inclusive range read on the stored `localDate`, soft-deleted entries excluded.
 *
 *  `deletedAt` is filtered here rather than in the query on purpose: adding
 *  `.where('deletedAt', '==', null)` turns this into a composite query, and the
 *  composite index in firestore.indexes.json is not deployed (GUARDRAILS rule 7 —
 *  a human deploys indexes). A range is one user's calendar window, so the rows
 *  discarded here are a handful. Move the filter into the query once the index is live. */
export const listEvents = async (uid: string, from: string, to: string): Promise<EvaEvent[]> => {
  const snapshot = await events(uid)
    .where('localDate', '>=', from)
    .where('localDate', '<=', to)
    .orderBy('localDate', 'asc')
    .get()

  return snapshot.docs
    .map(toEvent)
    .filter((event) => event.deletedAt === null)
    .sort((a, b) => a.localDate.localeCompare(b.localDate) || a.loggedAt.localeCompare(b.loggedAt))
}

export const getEvent = async (uid: string, id: string): Promise<EvaEvent | null> => {
  const snapshot = await events(uid).doc(id).get()
  if (!snapshot.exists || snapshot.get('deletedAt') !== null) return null
  return toEvent(snapshot)
}

export const updateEvent = async (
  uid: string,
  id: string,
  patch: EventPatch,
): Promise<UpdateResult> => {
  const ref = events(uid).doc(id)
  const snapshot = await ref.get()
  // A soft-deleted event is gone as far as the API is concerned; there is no
  // restore route yet, so editing one must not silently resurrect it.
  if (!snapshot.exists || snapshot.get('deletedAt') !== null) return { ok: false, reason: 'not-found' }
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

/** Soft delete: the document stays, so the entry is recoverable. Nothing purges
 *  it yet — the 30-day window is a retention policy, not a job that exists. */
export const softDeleteEvent = async (uid: string, id: string): Promise<boolean> => {
  const ref = events(uid).doc(id)
  const snapshot = await ref.get()
  if (!snapshot.exists) return false
  if (snapshot.get('deletedAt') !== null) return true // already deleted: idempotent
  await ref.update({ deletedAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() })
  return true
}

import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import { config } from './config'
import { getContent, type Template } from './content'
import {
  PatternRuleUnsetError,
  selectSubject,
  type DashboardInput,
  type DashboardRules,
  type Rung,
  type SignalEntry,
  type Subject,
  type TemplateId,
  type UpcomingAppointment,
} from './dashboard-rules'
import { firestore } from './firebase'
import { lastEventChangeAt, lastLoggedDate, listEvents, type EvaEvent } from './events'
import { lastUserChangeAt, getUser } from './users'

/**
 * Owner of `users/{uid}/today/{date}` (GUARDRAILS rule 10) — the Today card, slice D3 of
 * #10 (#98). Nothing else touches the subcollection.
 *
 * This module is the *join*: D1 (`dashboard-rules.ts`) chooses the subject, D2
 * (`content.ts`) holds the words, and this gathers the inputs D1 needs, asks it, fills the
 * template D1 named, and stores the result for the day.
 *
 * **It decides nothing D1 decides.** The rung and the template id on a stored card are
 * copied from the `Subject`, never from the template and never from a phraser — PRD
 * §Dashboard, "the message subject is never free-generated". `Phraser` below is handed a
 * subject and returns *text*; `buildCard` writes the subject's two routing fields **after**
 * spreading that text, so a phraser that returns them anyway is overwritten rather than
 * obeyed. The type alone does not carry this: a dynamically-built return object — which is
 * what a model phraser (#106) will produce — slips past the excess-property check.
 *
 * **Two kinds of time, as everywhere else (ARCHITECTURE §4).** The card's `date` is the
 * user's wall clock, resolved from the request's `timeZone` at the route edge exactly as
 * `events.ts` entries are. `generatedAt` and the stored audit instants are system time.
 * D1 reads no clock at all, so both arrive there as arguments.
 *
 * Never log a card, a slot value or a signal: this is health data (GUARDRAILS rule 12).
 */

/**
 * The card the app renders — the canvas' `CARDS` fields, plus what the device routes on.
 *
 * `templateId` and `rung` are the routing targets and come from the subject. There is no
 * raw signal value here beyond what the filled text already carries, and no event of any
 * kind: the only logged input D1 receives is body signals, so a Sex entry cannot reach a
 * card by any path (PRD Edge case 6, and `SignalEntry`'s note in D1).
 */
export interface TodayCard {
  templateId: TemplateId
  rung: Rung
  /** The canvas state this renders, e.g. `home_a`. From the template the phraser used. */
  state: string
  tone?: string
  kicker?: string
  title: string
  line2?: string
  line3?: string
  meta?: string
  actions: string[]
}

/** What `GET /me/today` answers with, and what is stored under the day. */
export interface TodayDocument {
  /** The user's local date, `YYYY-MM-DD`. */
  date: string
  /** When this card was generated, ISO-8601. System time. */
  generatedAt: string
  /** The `content.ts` version the text was filled from (#97). */
  contentVersion: string
  card: TodayCard
}

/**
 * Text for a card, and nothing that could name a different one.
 *
 * Deliberately missing `templateId` and `rung`: those come from D1's `Subject` and are
 * attached by `buildCard` below, so a phraser — this one, or D9's model (#106) — cannot
 * change the subject even by returning something else. Missing from the *type* is the
 * weaker half: it only catches an object literal. What actually holds is `buildCard`'s
 * order, and the case that proves it returns both keys and watches them lose.
 */
export interface PhrasedText {
  state: string
  tone?: string
  kicker?: string
  title: string
  line2?: string
  line3?: string
  meta?: string
  actions: string[]
}

/**
 * Turns a subject and the day's templates into the card's words.
 *
 * One implementation today (`TemplatePhraser`, a deterministic fill). D9 adds the model
 * phraser behind this same interface — which is why it is exported and why the route
 * never names an implementation.
 */
export interface Phraser {
  /** Recorded on nothing; it exists so a caller can say which phraser it is holding. */
  readonly id: string
  phrase(subject: Subject, templates: readonly Template[]): PhrasedText
}

/** Thrown when the subject names a template the content store cannot supply at the
 *  subject's confidence — an unseeded store, a retired template, or a hedged subject whose
 *  only template states it plainly. Its own class so the route can answer "unavailable"
 *  rather than "bug", and so the refusal is greppable. */
export class TemplateUnavailableError extends Error {
  constructor(templateId: string) {
    super(`the Today card's template ${templateId} is not available at the required confidence`)
    this.name = 'TemplateUnavailableError'
  }
}

/** `{slot}` — the placeholder form the seeded copy uses (`Cycle day {cycleDay} · …`). */
const PLACEHOLDER = /\{(\w+)\}/g

/**
 * The deterministic fill: slot values substituted, and the wording class honoured.
 *
 * **Confidence is a filter, not a preference.** A subject D1 marked `hedged` is rendered
 * only by a template the store also labels `hedged`, so the plain variant of a phase card
 * is unreachable at that class by construction rather than by review — PRD §Dashboard,
 * "the wording must reflect that rather than asserting the phase as fact". If the store
 * holds no such template the card is refused; it is never quietly stated plainly.
 *
 * **An unfilled slot removes its line, it does not invent one.** `home_edu`'s `meta` is
 * `'{category} · {readMinutes} min read'` and no slice owns choosing the article yet (D1
 * leaves both slots empty on purpose), so the educational card renders without its meta
 * line rather than with `{category}` showing or a placeholder nobody chose. `title` is the
 * one field that cannot be dropped — a card with no title is not a card — so a title
 * referencing an unfilled slot is a refusal.
 */
export class TemplatePhraser implements Phraser {
  readonly id = 'template'

  phrase(subject: Subject, templates: readonly Template[]): PhrasedText {
    const template = templates
      .filter(
        (candidate) =>
          candidate.id === subject.templateId &&
          candidate.status === 'active' &&
          candidate.confidence === subject.confidence,
      )
      .sort((a, b) => a.order - b.order)[0]
    if (template === undefined) throw new TemplateUnavailableError(subject.templateId)

    const fill = (value: string | undefined): string | undefined => {
      if (value === undefined) return undefined
      let complete = true
      const filled = value.replace(PLACEHOLDER, (match, slot: string) => {
        const supplied = subject.slots[slot as keyof typeof subject.slots]
        if (supplied === undefined) {
          complete = false
          return match
        }
        return String(supplied)
      })
      return complete ? filled : undefined
    }

    const title = fill(template.title)
    if (title === undefined) throw new TemplateUnavailableError(subject.templateId)

    return {
      state: template.state,
      ...defined('tone', template.tone),
      ...defined('kicker', fill(template.kicker)),
      title,
      ...defined('line2', fill(template.line2)),
      ...defined('line3', fill(template.line3)),
      ...defined('meta', fill(template.meta)),
      // Labels, not destinations. What the device does with them is D4's (#99); this
      // stores what the reviewed copy says, unchanged.
      actions: [...template.actions],
    }
  }
}

/** An absent optional field is left out rather than written as `undefined`: Firestore
 *  rejects `undefined`, and an absent key is also what makes two generations of the same
 *  card byte-identical. */
const defined = <K extends string, V>(key: K, value: V | undefined): Record<K, V> | object =>
  value === undefined ? {} : ({ [key]: value } as Record<K, V>)

const buildCard = (subject: Subject, text: PhrasedText): TodayCard => ({
  ...text,
  // **Last, so the subject wins.** From the subject, never from the phraser or the template
  // — see `PhrasedText`. Spread first and a phraser carrying these keys would name its own
  // card, `flag` included, which is the one rung that must never be reachable without the
  // ladder (PRD §Dashboard: "the message subject is never free-generated").
  templateId: subject.templateId,
  rung: subject.rung,
})

// ── Time ───────────────────────────────────────────────────────────────────────────────
// `events.ts` stores the user's wall clock and never an instant. D1 needs an instant for
// its 24-hour window, and refuses a value carrying no offset. The conversion is here,
// because this is the layer that knows the caller's zone.

const WALL_CLOCK = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/

/** What a zone's offset was at a given instant, in minutes east of UTC. */
const offsetMinutesAt = (timeZone: string, instantMs: number): number => {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date(instantMs))
  const part = (name: string) => Number(parts.find((entry) => entry.type === name)!.value)
  const asIfUtc = Date.UTC(
    part('year'),
    part('month') - 1,
    part('day'),
    part('hour'),
    part('minute'),
    part('second'),
  )
  return (asIfUtc - instantMs) / 60_000
}

/**
 * A stored wall clock (`YYYY-MM-DDTHH:mm:ss`, in the caller's zone) as a UTC instant.
 *
 * Two passes, because the offset depends on the instant we are still solving for: the
 * first guess uses the offset in force at the wall clock read as UTC, the second uses the
 * offset in force at that guess. That resolves every ordinary case and the DST shifts
 * either side of it; an hour that does not exist (the spring-forward gap) lands on the
 * hour after it, which is the same direction `Date` itself picks.
 *
 * Expressed in UTC rather than in the caller's offset on purpose: D1 needs an instant, and
 * `…Z` is one. Nothing downstream reads the offset itself.
 */
const wallClockToInstant = (wallClock: string, timeZone: string): string | null => {
  if (!WALL_CLOCK.test(wallClock)) return null
  const naive = Date.parse(`${wallClock.length === 16 ? `${wallClock}:00` : wallClock}Z`)
  if (Number.isNaN(naive)) return null
  const first = naive - offsetMinutesAt(timeZone, naive) * 60_000
  const second = naive - offsetMinutesAt(timeZone, first) * 60_000
  return new Date(second).toISOString()
}

/** `YYYY-MM-DD` shifted by whole days, in UTC — a calendar label, never an instant. */
const shiftDays = (date: string, days: number): string =>
  new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000).toISOString().slice(0, 10)

const wholeDaysBetween = (from: string, to: string): number =>
  Math.round(
    (Date.parse(`${to}T00:00:00.000Z`) - Date.parse(`${from}T00:00:00.000Z`)) / 86_400_000,
  )

// ── Gathering D1's inputs ──────────────────────────────────────────────────────────────

/**
 * How far back body signals are read.
 *
 * Derived from the configured rule rather than fixed, because rung 2 counts *consecutive
 * days ending today*: a window shorter than the rule's span would make the rule match
 * nothing while looking live, which is the exact failure #26's process note exists to
 * prevent. The floor covers the 24-hour observed-signal window across a date boundary.
 */
const signalWindowDays = (rules: DashboardRules): number =>
  Math.max(rules.pattern?.lowSignalDays ?? 0, rules.pattern?.severeSymptomDays ?? 0, 2)

/** How far ahead appointments are read for rung 3. A week: the milestone rung's cards are
 *  all "your scan is tomorrow" shaped, and nothing today reads further out. */
const APPOINTMENT_LOOKAHEAD_DAYS = 7

const toSignalEntry = (event: EvaEvent, timeZone: string): SignalEntry | null => {
  if (event.type !== 'bodySignals') return null
  const loggedAt = wallClockToInstant(event.loggedAt, timeZone)
  // A stored entry whose wall clock does not parse is dropped rather than passed on: D1
  // refuses an unparseable `loggedAt` for the whole request, and one malformed row must
  // not take the card down. It cannot happen through the API — the route validates the
  // shape on the way in — so this is a floor under a hand-edited document.
  if (loggedAt === null) return null
  const payload = event.payload as { energy?: number; mood?: number; sleep?: number; symptoms?: unknown }
  const symptoms = Array.isArray(payload.symptoms) ? payload.symptoms : []
  return {
    localDate: event.localDate,
    loggedAt,
    energy: payload.energy ?? null,
    mood: payload.mood ?? null,
    sleep: payload.sleep ?? null,
    symptoms: symptoms.map((symptom) => {
      const entry = symptom as { code?: unknown; severity?: unknown }
      return {
        code: String(entry.code ?? ''),
        severity: entry.severity === 'severe' ? ('severe' as const) : ('normal' as const),
      }
    }),
  }
}

const toAppointment = (event: EvaEvent, today: string): UpcomingAppointment | null => {
  if (event.type !== 'appointment') return null
  const payload = event.payload as { startAt?: unknown; type?: unknown }
  const startAt = typeof payload.startAt === 'string' ? payload.startAt : null
  if (startAt === null) return null
  return {
    startAt,
    type: typeof payload.type === 'string' ? payload.type : null,
    inDays: wholeDaysBetween(today, event.localDate),
  }
}

/**
 * The cycle maths' answers, as this module can supply them today.
 *
 * **C11 (#11) does not exist yet**, so every field here is the "I know nothing about her
 * cycle" value rather than a number computed on the way past. That is deliberate and it is
 * the safe direction: with `cycleDay` null and no phase, D1's phase rung can only reach
 * the cold-start card or fall through to the educational one, and no card can state a
 * phase Eva has not earned the right to state (PRD Confidence and cold start 2–4).
 *
 * Re-deriving any of this here would be the drift D1 refuses by taking these as inputs —
 * the ≥3-cycle gate and the irregularity band are C11's constants, and a second copy of
 * them is a second answer. When C11 lands, this function is the one place that changes.
 */
const cycleEstimate = (): DashboardInput['cycle'] => ({
  countedCycles: 0,
  enoughCyclesForEstimates: false,
  irregular: false,
  cycleDay: null,
  phase: null,
  daysPastPredictedPeriod: null,
})

const gatherInput = async (
  uid: string,
  today: string,
  now: string,
  timeZone: string,
  rules: DashboardRules,
): Promise<DashboardInput> => {
  const from = shiftDays(today, -signalWindowDays(rules))
  const to = shiftDays(today, APPOINTMENT_LOOKAHEAD_DAYS)
  const [events, user, lastLogged] = await Promise.all([
    listEvents(uid, from, to),
    getUser(uid),
    lastLoggedDate(uid, today),
  ])

  const signals: SignalEntry[] = []
  const upcomingAppointments: UpcomingAppointment[] = []
  for (const event of events) {
    const signal = toSignalEntry(event, timeZone)
    if (signal !== null) {
      signals.push(signal)
      continue
    }
    const appointment = toAppointment(event, today)
    if (appointment !== null && appointment.inDays >= 0) upcomingAppointments.push(appointment)
  }

  return {
    // Cycle mode is the only one the app can be in today: `users/{uid}` carries no mode and
    // the other four are D10's (#107), together with the rungs that read them.
    mode: 'cycle',
    today,
    now,
    cycle: cycleEstimate(),
    signals,
    // D10 owns the mapping from a logged code to a flag. Until it exists there is nothing
    // to resolve, which is why D1 documents `null` as the value in every mode.
    redFlag: null,
    upcomingAppointments,
    profileComplete: user?.questionnaireCompleted === true && user?.profile !== null,
    // The Nutrition adviser (#25) has no profile and no totals yet. Both are stated rather
    // than guessed: PRD Today at a glance 2 refuses a partial state.
    nutritionSetUp: false,
    todayTotals: null,
    daysSinceLastLog: lastLogged === null ? null : wholeDaysBetween(lastLogged, today),
  }
}

// ── The day's document ─────────────────────────────────────────────────────────────────

const days = (uid: string) => firestore.collection('users').doc(uid).collection('today')

/**
 * What the ladder is configured with, from `config.ts`.
 *
 * `pattern` is `null` until #26 settles A32's thresholds, and D1 throws rather than
 * answering without them. That refusal reaches the caller as an unavailable capability —
 * see `getToday`.
 */
export const dashboardRules = (): DashboardRules => ({ pattern: config.dashboard.pattern })

interface StoredToday extends TodayDocument {
  /** The newest change to the user's own data that this card was built from. The
   *  regeneration test compares against *this*, not against `generatedAt`: it is exact,
   *  it cannot be moved by server clock skew, and it closes the window between reading the
   *  inputs and stamping the card. */
  dataChangedAt: string | null
}

/** Read back in a fixed key order, so two generations of the same day are byte-identical
 *  whatever order Firestore hands the fields back in. */
const toDocument = (data: FirebaseFirestore.DocumentData): TodayDocument => ({
  date: data.date,
  generatedAt:
    data.generatedAt instanceof Timestamp
      ? data.generatedAt.toDate().toISOString()
      : data.generatedAt,
  contentVersion: data.contentVersion,
  card: data.card,
})

/** The newest instant at which anything this card is built from changed — an event
 *  created, edited, deleted or restored, body signals upserted, or the profile saved.
 *  `null` for an account that has neither. */
const dataChangedAt = async (uid: string): Promise<string | null> => {
  const [events, user] = await Promise.all([lastEventChangeAt(uid), lastUserChangeAt(uid)])
  if (events === null) return user
  if (user === null) return events
  return events > user ? events : user
}

export interface TodayRequest {
  /** The caller's local date, resolved from `timeZone` at the route edge. */
  date: string
  /** The caller's IANA zone, or `UTC` when they did not name one — the same fallback
   *  `events.ts` entries get. Used only to turn stored wall clocks into instants. */
  timeZone: string
}

/**
 * The card for a user's local date: the stored one when it is still current, a fresh one
 * when her data has moved under it.
 *
 * **A refresh is not a change.** PRD §Dashboard, Other requirements 3 and Edge case 5: the
 * card is generated once per day and does not change between opens. So the stored document
 * is returned untouched — not re-filled, not re-stamped — unless something the card is
 * built from changed after it was built. New copy in `content/` is deliberately *not* such
 * a thing: an existing day keeps its filled text and its `contentVersion`, because new data
 * changes the card and new words do not.
 *
 * Throws `PatternRuleUnsetError` (D1's) and `TemplateUnavailableError` — refusals the route
 * answers `503` to, never `500`. `CycleRulesUnsetError` (C11's) is mapped there too and is
 * not yet reachable from here: this function still hands D1 a no-knowledge `CycleEstimate`
 * and #179 is what replaces it with `analyzeCycles`. The mapping ships with the error
 * rather than after it, because the failure it prevents is a 500 on the first deployment
 * that runs #179's code without the `CYCLE_*` group — and that is a deployment nobody
 * would test first.
 *
 * D1 also documents `InvalidTimeError`, and this function cannot raise it: `request.date`
 * is `resolveClock`'s output, `now` is `new Date().toISOString()`, and `toSignalEntry`
 * drops a stored wall clock it cannot parse rather than handing it down. The route used to
 * map it anyway; that branch was unreachable and therefore untestable, so it is gone.
 * Changing any of those three puts it back in play, here and at the route.
 */
export const getToday = async (
  uid: string,
  request: TodayRequest,
  rules: DashboardRules = dashboardRules(),
  phraser: Phraser = new TemplatePhraser(),
): Promise<TodayDocument> => {
  const ref = days(uid).doc(request.date)
  const [snapshot, changedAt] = await Promise.all([ref.get(), dataChangedAt(uid)])

  if (snapshot.exists) {
    const stored = snapshot.data() as StoredToday
    const builtFrom = stored.dataChangedAt ?? null
    // Strictly newer, and `null` never regenerates: an account with no data at all has
    // nothing that can have changed.
    const stale = changedAt !== null && (builtFrom === null || changedAt > builtFrom)
    if (!stale) return toDocument(stored)
  }

  const now = new Date().toISOString()
  const input = await gatherInput(uid, request.date, now, request.timeZone, rules)
  const subject = selectSubject(input, rules)
  const content = await getContent()
  const card = buildCard(subject, phraser.phrase(subject, content.templates))

  const document: TodayDocument = {
    date: request.date,
    generatedAt: now,
    contentVersion: content.version,
    card,
  }
  await ref.set({ ...document, dataChangedAt: changedAt, storedAt: FieldValue.serverTimestamp() })
  return document
}

/** Firestore's ceiling on a batched write, as `events.ts` uses it. */
const DELETE_BATCH = 500

/**
 * Hard-deletes every stored card for one user — the Dashboard half of account deletion
 * (#8). A filled card carries her own logged data in prose, so it goes with the events
 * rather than being left behind as the one readable summary of a deleted account.
 */
export const deleteAllUserToday = async (uid: string): Promise<number> => {
  let removed = 0
  for (;;) {
    const snapshot = await days(uid).limit(DELETE_BATCH).get()
    if (snapshot.empty) return removed
    const batch = firestore.batch()
    for (const doc of snapshot.docs) batch.delete(doc.ref)
    await batch.commit()
    removed += snapshot.size
  }
}

/**
 * The refusals `GET /me/today` answers `503` to, re-exported from the one place each is
 * defined so the route's `instanceof` is the same class object the thrower constructs.
 *
 * `index.ts` imports them from here rather than from `dashboard-rules.ts` and `cycle.ts`
 * directly, which is what keeps the module diagram in `api/CLAUDE.md` true: the route knows
 * this module and this module knows the two below it.
 */
export { PatternRuleUnsetError }
export { CycleRulesUnsetError } from './cycle'

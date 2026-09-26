import { FieldPath, FieldValue, Timestamp } from 'firebase-admin/firestore'
import { config } from './config'
import { llm } from './llm'
import { ModelPhraser } from './model-phraser'
import {
  getSignalVocabulary,
  getSignedContent,
  type Banner,
  type Nudge,
  type SignalVocabulary,
  type Template,
} from './content'
import {
  analyzeCycles,
  periodOngoing,
  toCycleEstimate,
  type CycleAnalysis,
  type CycleDay,
  type CycleRules,
} from './cycle'
import {
  PatternRuleUnsetError,
  observedSignal,
  selectBanners,
  selectNudge,
  selectSubject,
  TEMPLATE,
  type DashboardInput,
  type DashboardRules,
  type Mode,
  type NudgeInput,
  type Rung,
  type SignalEntry,
  type Subject,
  type TemplateId,
  type UpcomingAppointment,
} from './dashboard-rules'
import { firestore } from './firebase'
import { lastEventChangeAt, lastLoggedDate, listEvents, type EvaEvent } from './events'
import { getNutritionProfile, lastNutritionProfileChangeAt } from './nutrition-profile'
import { getSymptomLabels } from './refdata'
import {
  assertAccountLive,
  lastUserChangeAt,
  getUser,
  type Profile,
  type WriteSession,
} from './users'

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
 * **The banner rail is chosen here too, once, with the card (D7, #102).** `selectBanners`
 * in D1's module decides which rows; this gathers its inputs — the mode, the subject D1 just
 * chose, and the focus areas of a *finished* Nutrition setup — and stores the answer in the
 * same document, so the rail follows the card's regeneration rule exactly.
 *
 * Never log a card, a slot value, a signal or a banner id: this is health data (GUARDRAILS
 * rule 12), and which article a user was offered is derived from her subject and her focus
 * areas.
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
  /** Which phraser produced the text — `template` (D3's deterministic fill, or a model
   *  answer that failed the rules and fell back) or `model` (D9's rewrite). Recorded so a
   *  model's words are never mistaken for the reviewed copy, and so the export says which. */
  phraser: 'template' | 'model'
}

/**
 * One item on the "Worth reading" rail (D7, #102) — exactly what the rail draws and opens.
 *
 * A **copy** of the reviewed row, not a reference to it: the day's rail must not change
 * when `content/` does (the card's rule), and must render offline from the stored document.
 * The routing tags (`mode`, `subjects`, `focusAreas`) are selection inputs and stay behind;
 * the client has no use for them, and `focusAreas` would echo her setup answers back.
 */
export interface TodayBanner {
  /** The `content/` banner id — permanent and opaque. */
  id: string
  title: string
  /** Category and reading time, as the reviewed copy writes it: `"Nutrition · 4 min read"`. */
  meta: string
  /** An absolute `https://` URL; never empty — a row without one is not selected. */
  url: string
}

/**
 * One nudge for the slot (D6, #101) — what the client draws and dismisses. A **copy** of the
 * reviewed row, like the rail: the trigger and the `withinDays` parameter are selection
 * inputs and stay behind, so the stored day is stable and renders offline.
 */
export interface TodayNudge {
  id: string
  text: string
  sub?: string
  action: string
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
  /** The day's rail, in display order: zero to three items, never padded (#102). Empty —
   *  never absent — when nothing is eligible, and for a day stored before D7. */
  banners: TodayBanner[]
  /** The day's nudge for the slot below the glance row (D6, #101), or `null` when none is
   *  eligible. Chosen once with the card and stable across the day; `null` on a day stored
   *  before D6. */
  nudge: TodayNudge | null
  /**
   * The mode the card was built in — the one D1 was handed, so the shortcuts row (#100, D5)
   * and the card cannot be in two different modes. `cycle` for every account today: nothing
   * stores a mode until D10 (#107). A day stored before D5 reads `cycle`, which is what it
   * was built in.
   */
  mode: Mode
  /**
   * Whether her logged period is still running today — C11's `periodOngoing`, the menstrual
   * boundary without the prediction gate (see there). What labels the first shortcut
   * `Log period` (#100). Not a phase and not a prediction: it never reaches the card.
   * `null` only on a day stored before D5, which is not rebuilt to fill it in.
   */
  periodOngoing: boolean | null
  /**
   * Whether the Nutrition coach setup is finished — `completedSetup`'s answer, the one
   * definition (#221). `Scan meal` when true, `Set up meals` and the setup card when not
   * (#100). `null` only on a day stored before D5.
   */
  nutritionSetUp: boolean | null
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

const toTodayBanner = (row: Banner): TodayBanner => ({
  id: row.id,
  title: row.title,
  meta: row.meta,
  url: row.url,
})

/** The slot's copy of a nudge: the display fields, the trigger and parameter left behind. */
const toTodayNudge = (row: Nudge): TodayNudge => ({
  id: row.id,
  text: row.text,
  ...(row.sub !== undefined ? { sub: row.sub } : {}),
  action: row.action,
})

const buildCard = (subject: Subject, text: PhrasedText): Omit<TodayCard, 'phraser'> => ({
  ...text,
  // **Last, so the subject wins.** From the subject, never from the phraser or the template
  // — see `PhrasedText`. Spread first and a phraser carrying these keys would name its own
  // card, `flag` included, which is the one rung that must never be reachable without the
  // ladder (PRD §Dashboard: "the message subject is never free-generated").
  templateId: subject.templateId,
  rung: subject.rung,
})

// ── The signal vocabulary's readback (#200) ─────────────────────────────────────────
// `dashboard-rules.ts` holds ratings as numbers and symptoms as `refdata/` codes, and is
// text-free. These two functions turn a stored entry into the phrase `{signal}` fills: the
// reviewed words live in `content/` (`SignalVocabulary`) and the symptom names in `refdata/`,
// so neither is a literal scattered in a module.

/** The rating at or below which a signal is "low" — `1–2` on the validated 1–5 scale. A
 *  readback band, not rung 2's configured pattern threshold: "low energy" describes a
 *  number, it does not detect a pattern. */
export const SIGNAL_LOW_AT_OR_BELOW = 2

/** Lowercase the first letter of a `refdata/` label, so "Cramps" reads as "cramps" inside a
 *  sentence. A label is the reviewed name for the chip; casing is presentation. */
const lowerFirst = (label: string): string =>
  label.length === 0 ? label : label[0]!.toLowerCase() + label.slice(1)

/**
 * The phrase that names what an entry reports, for the `{signal}` slot.
 *
 * The order is the whole decision, and every branch is true of the entry: a low rating is
 * named before a symptom because "low energy" is the readback this slice exists for, and a
 * symptom is named before the fallback because a concrete event outranks "body signals". A
 * symptom whose code has no label is *skipped*, never rendered as a code — the next symptom
 * or the fallback names the entry instead (#200: a code with no label cannot reach the
 * screen).
 */
export const phraseForEntry = (
  entry: SignalEntry,
  vocabulary: SignalVocabulary,
  labelFor: (code: string) => string | null,
): string => {
  if (entry.energy !== null && entry.energy <= SIGNAL_LOW_AT_OR_BELOW) return vocabulary.energy
  if (entry.mood !== null && entry.mood <= SIGNAL_LOW_AT_OR_BELOW) return vocabulary.mood
  if (entry.sleep !== null && entry.sleep <= SIGNAL_LOW_AT_OR_BELOW) return vocabulary.sleep
  for (const symptom of entry.symptoms) {
    const label = labelFor(symptom.code)
    if (label !== null) return lowerFirst(label)
  }
  return vocabulary.fallback
}

/**
 * Fills the `{signal}` slot for the two cards that name what she logged, and leaves every
 * other subject untouched.
 *
 * A missing vocabulary leaves the slot unfilled on purpose: a title that references
 * `{signal}` is then a `TemplateUnavailableError` in `TemplatePhraser`, never a rendered
 * `{signal}` or an invented phrase. Pure — the two inputs it needs are passed in, which is
 * what lets the copy audit run it against the seeded vocabulary and catalogue.
 */
export const resolveSignals = (
  subject: Subject,
  input: DashboardInput,
  vocabulary: SignalVocabulary | null,
  labelFor: (code: string) => string | null,
): Subject => {
  if (
    subject.templateId !== TEMPLATE.signalsToday &&
    subject.templateId !== TEMPLATE.signalOverridesPhase
  ) {
    return subject
  }
  if (vocabulary === null) return subject
  const entry = observedSignal(input)
  // Unreachable through the ladder — both cards are selected only when an entry is observed
  // — but failing open here would render `{signal}` for a subject D1 never produced.
  if (entry === null) return subject
  return {
    ...subject,
    slots: { ...subject.slots, signal: phraseForEntry(entry, vocabulary, labelFor) },
  }
}

/**
 * An instant (`…Z` or `…+02:00`) as `HH:mm` wall-clock in the caller's zone — the form the
 * canvas draws (`Logged 14:20`), never the raw ISO the event carries (#201).
 */
const wallClockTime = (instant: string, timeZone: string): string | null => {
  const ms = Date.parse(instant)
  if (Number.isNaN(ms)) return null
  return new Intl.DateTimeFormat('en-US', {
    timeZone,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(new Date(ms))
}

/**
 * Rewrites the red-flag card's `{loggedAt}` slot from an instant to a wall-clock time in the
 * caller's zone.
 *
 * The ladder fills the slot with `RedFlagSignal.loggedAt`, a raw instant; rendered as is, the
 * kicker reads `Logged 2026-09-13T08:00:00Z` where the canvas draws `Logged 14:20`. The ladder
 * cannot do this itself — it is pure and holds no zone — so it happens here, where `getToday`
 * knows the request's `timeZone`, the same zone the day boundary is resolved in. An instant
 * that does not parse is left as it was: the ladder only ever passes a validated instant, so
 * that is a floor under a hand-edited document rather than a rendering path. The truth audit
 * cannot see this — a raw instant is *true* — so presentation is tested in `today.test.ts`
 * rather than in `dashboard-copy.test.ts`.
 */
export const formatLoggedAt = (subject: Subject, timeZone: string): Subject => {
  if (subject.templateId !== TEMPLATE.redFlag) return subject
  const raw = subject.slots.loggedAt
  if (typeof raw !== 'string') return subject
  const clock = wallClockTime(raw, timeZone)
  if (clock === null) return subject
  return { ...subject, slots: { ...subject.slots, loggedAt: clock } }
}

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
  Math.round((Date.parse(`${to}T00:00:00.000Z`) - Date.parse(`${from}T00:00:00.000Z`)) / 86_400_000)

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
  const payload = event.payload as {
    energy?: number
    mood?: number
    sleep?: number
    symptoms?: unknown
  }
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
 * A stored `cycle` entry in the vocabulary the maths reads (#179).
 *
 * Three facts and no more: the day, which marker it carries, and #75's explicit "my period
 * ended" mark. **`periodEnd` is carried here or nowhere** — `cycle.ts` is its one reader
 * (#186, #196) and this mapping is the only thing between the stored field and that read,
 * so dropping it would leave a mark the user set deciding nothing while every test of the
 * maths still passed.
 *
 * `flow` and `spotting` are mutually exclusive in `CyclePayload` and the route refuses a
 * body carrying both, so the arms below are a floor under a hand-edited document rather than
 * a rule — and flow wins, the same direction `loggedPeriods` takes for the same reason: the
 * one that keeps a real period visible.
 */
const toCycleDay = (event: EvaEvent): CycleDay | null => {
  if (event.type !== 'cycle') return null
  const payload = event.payload as { flow?: unknown; spotting?: unknown; periodEnd?: unknown }
  if (typeof payload.flow === 'string' && payload.flow.length > 0) {
    return payload.periodEnd === true
      ? { localDate: event.localDate, kind: 'flow', periodEnd: true }
      : { localDate: event.localDate, kind: 'flow' }
  }
  if (payload.spotting === true) return { localDate: event.localDate, kind: 'spotting' }
  return null
}

/**
 * How far back `cycle` entries are read.
 *
 * **Derived from the constants, never written as a number** — the same rule
 * `signalWindowDays` follows, for the same reason: a window shorter than the maths' own
 * reach would silently drop the oldest cycles from the median and the variation, and a
 * prediction drawn from a truncated history looks exactly like one drawn from all of it.
 *
 * `historyCycles` intervals need `historyCycles + 1` first flow days, which span at most
 * `historyCycles × maxCycleLengthDays`. One more cycle covers the one in progress today,
 * and one more is the margin that keeps the oldest of them inside the window when a cycle
 * runs to the edge of the countable range. At A25's values that is 360 days — about a year,
 * bounded, and one user's calendar on the single-field `localDate` index.
 *
 * An unset group reads nothing extra: `analyzeCycles` refuses below rather than answering,
 * so a year of health data would be read for an answer that is never produced.
 */
const cycleWindowDays = (rules: CycleRules | null): number =>
  rules === null ? 0 : (rules.historyCycles + 2) * rules.maxCycleLengthDays

/**
 * C11's answers, for this user, today (#179) — D1's estimate, and since #100 whether her
 * logged period is still running, for the shortcuts row.
 *
 * The whole of the cycle maths is `cycle.ts`'s and none of it is re-derived here — this
 * gathers the days, hands them over with the constants, and projects the result into the
 * shape D1 already consumes. `toCycleEstimate` reads the local date off the analysis rather
 * than being handed it again, which is what stops a phase and a cycle day being measured
 * against two different days.
 *
 * Throws `CycleRulesUnsetError` when the `CYCLE_*` group is unset — a refusal the route
 * answers `503` to, exactly as it does rung 2's. That is the direction #176 chose: no
 * default, because a default here is a clinical constant nobody recorded choosing.
 */
const cycleToday = (
  days: readonly CycleDay[],
  today: string,
  profile: Profile | null,
  rules: CycleRules | null,
): {
  estimate: DashboardInput['cycle']
  periodOngoing: boolean
  daysUntilPredictedPeriod: number | null
} => {
  // One analysis, three projections: the card's estimate, the shortcut's period flag (#100),
  // and the nudge slot's "period within N days" (D6, #101) are all read off the same answer,
  // so they cannot be measured against two different histories.
  const analysis = analyzeCycles({ days, today, profile }, rules)
  return {
    estimate: toCycleEstimate(analysis),
    periodOngoing: periodOngoing(analysis),
    daysUntilPredictedPeriod:
      analysis.prediction === null
        ? null
        : wholeDaysBetween(today, analysis.prediction.nextPeriodStart),
  }
}

/**
 * How far *ahead* `cycle` entries are read.
 *
 * One day rather than none: a caller who names no zone gets a day of slack in both
 * directions (`resolveClock` in `index.ts`), so an entry stored on tomorrow's UTC date is a
 * real day a real device wrote about its own today, and dropping it would move the anchor
 * every prediction hangs off. `gatherInput` below spans further still, so no `cycle` entry
 * is visible to one of these two readers and invisible to the other.
 */
const CYCLE_LOOKAHEAD_DAYS = 1

/**
 * C11's whole answer for one user on one local date (#205).
 *
 * **`CycleAnalysis`, not `CycleEstimate`.** `cycleToday` above projects the same analysis
 * into the narrower shape D1 consumes, which carries no `cycles` list — so "unusual length"
 * cannot surface through it, and neither can the fertile window's own dates. The Dashboard
 * needs the projection; the calendar needs the analysis. Both come from one call to
 * `analyzeCycles`, which is what keeps the date the calendar draws and the phase the card
 * speaks from the same arithmetic.
 *
 * It re-decides nothing: the window it reads, the mapping it reads through and the constants
 * it hands over are the same three `gatherInput` uses, and every gate is `cycle.ts`'s. A
 * second implementation of any of them is the drift #176's Risks name — in particular
 * `toCycleDay`, which carries #75's `periodEnd` mark and is the only thing between the stored
 * field and the one function that reads it.
 *
 * Throws `CycleRulesUnsetError` when the `CYCLE_*` group is unset, from `analyzeCycles`
 * rather than from a check here — the refusal has one implementation too. The route answers
 * `503` to it, exactly as `GET /me/today` does.
 */
export const cycleAnalysisFor = async (uid: string, today: string): Promise<CycleAnalysis> => {
  const rules = config.cycle
  const [events, user] = await Promise.all([
    listEvents(
      uid,
      shiftDays(today, -cycleWindowDays(rules)),
      shiftDays(today, CYCLE_LOOKAHEAD_DAYS),
    ),
    getUser(uid),
  ])
  const days: CycleDay[] = []
  for (const event of events) {
    const day = toCycleDay(event)
    if (day !== null) days.push(day)
  }
  // The profile goes through untouched, for the reason `gatherInput` gives: `bandForAge` is
  // the only thing that reads it, and it reads one field.
  return analyzeCycles({ days, today, profile: user?.profile ?? null }, rules)
}

/** D1's inputs, and the C11 answer plus the nudge slot's inputs the day's document carries
 *  beside the card (#100, #101). */
interface Gathered {
  input: DashboardInput
  periodOngoing: boolean
  nudgeInput: NudgeInput
  dismissedNudges: string[]
}

const gatherInput = async (
  uid: string,
  today: string,
  now: string,
  timeZone: string,
  rules: DashboardRules,
): Promise<Gathered> => {
  // One read: the window the query spans and the constants the maths is handed are the same
  // set by construction rather than by two lookups happening to agree.
  const cycleRules = config.cycle
  const signalsFrom = shiftDays(today, -signalWindowDays(rules))
  const from = shiftDays(today, -Math.max(cycleWindowDays(cycleRules), signalWindowDays(rules)))
  const to = shiftDays(today, APPOINTMENT_LOOKAHEAD_DAYS)
  const [events, user, lastLogged] = await Promise.all([
    listEvents(uid, from, to),
    getUser(uid),
    lastLoggedDate(uid, today),
  ])

  const signals: SignalEntry[] = []
  const cycleDays: CycleDay[] = []
  const upcomingAppointments: UpcomingAppointment[] = []
  for (const event of events) {
    const cycleDay = toCycleDay(event)
    if (cycleDay !== null) {
      cycleDays.push(cycleDay)
      continue
    }
    // Body signals stay on rung 2's own span. The read above is a year long for the maths'
    // sake, and rung 2 counts consecutive days *ending today*, so an older entry cannot
    // change an answer — it would only be a year of health data held in memory for nothing.
    const signal = event.localDate < signalsFrom ? null : toSignalEntry(event, timeZone)
    if (signal !== null) {
      signals.push(signal)
      continue
    }
    const appointment = toAppointment(event, today)
    if (appointment !== null && appointment.inDays >= 0) upcomingAppointments.push(appointment)
  }

  const cycle = cycleToday(cycleDays, today, user?.profile ?? null, cycleRules)
  const input: DashboardInput = {
    // Cycle mode is the only one the app can be in today: `users/{uid}` carries no mode and
    // the other four are D10's (#107), together with the rungs that read them.
    mode: 'cycle',
    today,
    now,
    // The profile goes through untouched: `bandForAge` is the only thing that reads it, and
    // it reads one field (#176, and #81 when age becomes a date of birth).
    cycle: cycle.estimate,
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
  return {
    input,
    periodOngoing: cycle.periodOngoing,
    nudgeInput: {
      daysUntilPredictedPeriod: cycle.daysUntilPredictedPeriod,
      upcomingAppointments,
      daysSinceLastLog: input.daysSinceLastLog,
      nutritionSetUp: input.nutritionSetUp,
    },
    dismissedNudges: user?.dismissedNudges ?? [],
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
  card: {
    ...data.card,
    // A day stored before D9 (#104) was phrased deterministically, and is read, never
    // rebuilt — `template` is what it was.
    phraser: data.card?.phraser === 'model' ? 'model' : 'template',
  },
  // A day stored before D7 has no rail, and gets none: filling one in on a later open would
  // change the document on a refresh, which is the thing D3's rule forbids.
  banners: Array.isArray(data.banners) ? data.banners : [],
  // A day stored before D6 (#101) has no nudge, and gets none — `null`, never a back-filled
  // one, for the same reason.
  nudge:
    data.nudge !== null && typeof data.nudge === 'object' && typeof data.nudge.id === 'string'
      ? (data.nudge as TodayNudge)
      : null,
  // A day stored before D5 (#100) is read, never rebuilt, for the same reason. Its mode is
  // known — every card before D10 was built in `cycle` — and the other two are not: `null`
  // says so, where `false` would put an invented fact about her period in her export.
  // The stored value is only ever `input.mode`, written below.
  mode: typeof data.mode === 'string' ? (data.mode as Mode) : 'cycle',
  periodOngoing: typeof data.periodOngoing === 'boolean' ? data.periodOngoing : null,
  nutritionSetUp: typeof data.nutritionSetUp === 'boolean' ? data.nutritionSetUp : null,
})

/** The newest instant at which anything this document is built from changed — an event
 *  created, edited, deleted or restored, body signals upserted, the profile saved, or the
 *  nutrition profile saved (its focus areas rank the rail, #102). `null` for an account that
 *  has none of them. ISO strings in one format, so the greatest sorts last. */
const dataChangedAt = async (uid: string): Promise<string | null> => {
  const instants = await Promise.all([
    lastEventChangeAt(uid),
    lastUserChangeAt(uid),
    lastNutritionProfileChangeAt(uid),
  ])
  return instants.reduce<string | null>(
    (newest, at) => (at !== null && (newest === null || at > newest) ? at : newest),
    null,
  )
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
 * Throws `PatternRuleUnsetError` (D1's), `TemplateUnavailableError` and — since #179 wired
 * `analyzeCycles` in — `CycleRulesUnsetError` (C11's): refusals the route answers `503` to,
 * never `500`. The third was mapped before it could be thrown, deliberately (#181), because
 * the day it became reachable was the day a deployment without the `CYCLE_*` group would
 * start answering 500 for an unset configuration — and that group is unset in every
 * environment today (#191). It is reachable now, and `today.test.ts` boots a server with the
 * group emptied to prove the arm rather than the mapping.
 *
 * It can also throw `users.ts`'s `AccountGoneError` from the cache write (#286), and its
 * `SessionSupersededError` when a password reset ended `session` after the gate (#294). Those
 * are not 503s and are deliberately not re-exported here: they are not the Dashboard's
 * refusals but every subcollection writer's, and `app.onError` answers them once, as a dead
 * token. `session` is only for that write — a card is read and built the same for any
 * session, and a stale one is refused before anything is stored, never served a different
 * card.
 *
 * D1 also documents `InvalidTimeError`, and this function cannot raise it: `request.date`
 * is `resolveClock`'s output, `now` is `new Date().toISOString()`, and `toSignalEntry`
 * drops a stored wall clock it cannot parse rather than handing it down. The route used to
 * map it anyway; that branch was unreachable and therefore untestable, so it is gone.
 * Changing any of those three puts it back in play, here and at the route.
 */
export const getToday = async (
  uid: string,
  session: WriteSession,
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
  const { input, periodOngoing, nudgeInput, dismissedNudges } = await gatherInput(
    uid,
    request.date,
    now,
    request.timeZone,
    rules,
  )
  const subject = selectSubject(input, rules)
  const [{ content, signedBanners }, vocabulary, labels, nutrition] = await Promise.all([
    getSignedContent(),
    getSignalVocabulary(),
    getSymptomLabels(),
    getNutritionProfile(uid),
  ])
  const labelFor = (code: string): string | null => labels?.get(code) ?? null
  const resolved = resolveSignals(subject, input, vocabulary, labelFor)
  const clocked = formatLoggedAt(resolved, request.timeZone)
  const filled = phraser.phrase(clocked, content.templates)
  // D9 (#104): the model phraser, when the vendor is provisioned, rewrites the deterministic
  // fill within the rules; on any failure it falls back to `filled`. The card records which
  // one won. Unprovisioned (`apiKey` null) is the whole model path skipped, not a failure.
  let text = filled
  let source: TodayCard['phraser'] = 'template'
  if (config.llm.apiKey !== null) {
    const result = await new ModelPhraser(llm).rewrite(clocked, filled)
    text = result.text
    source = result.source
  }
  const card: TodayCard = { ...buildCard(clocked, text), phraser: source }
  // After the card, and from D1's subject rather than from the card the phraser returned —
  // the rail excludes what the ladder chose, whatever the words say. Only a finished setup's
  // focus areas rank it: `complete` is `completedSetup`'s answer, the one definition.
  const banners = selectBanners(signedBanners, {
    mode: input.mode,
    subject: subject.templateId,
    focusAreas: nutrition?.complete === true ? nutrition.focusAreas : [],
  }).map(toTodayBanner)
  // D6 (#101): one nudge, chosen once with the card from D2's active rules and D1's inputs.
  // A dismissed id is never eligible again; with none eligible the slot is empty, not padded.
  const chosen = selectNudge(nudgeInput, content.nudges, new Set(dismissedNudges))
  const nudge: TodayNudge | null = chosen === null ? null : toTodayNudge(chosen)

  const document: TodayDocument = {
    date: request.date,
    generatedAt: now,
    contentVersion: content.version,
    card,
    banners,
    nudge,
    // The shortcuts row's three facts (#100, D5), stored with the card so they follow its
    // regeneration rule exactly: every input is already one `dataChangedAt` watches — the
    // events the cycle maths read, and the nutrition profile (#102).
    mode: input.mode,
    periodOngoing,
    // `complete` is `completedSetup`'s answer, the same one the rail's focus areas are gated
    // on above. Deliberately not D1's `input.nutritionSetUp`, which is still the hardcoded
    // `false` of a ladder with no nutrition totals to read (rung 5).
    nutritionSetUp: nutrition?.complete === true,
  }
  // **In a transaction that also reads the account (#286).** A cache, but not a harmless
  // one: the card is her logged data written out as prose, built from inputs read while the
  // account was live. Written after `DELETE /me` swept `today/`, it would be the one readable
  // summary of a deleted account, stranded where nothing deletes it. Refused, it throws
  // `AccountGoneError` and the request is answered as a deleted account's token is. A
  // session a reset has ended since the gate is refused by the same read (#294).
  await firestore.runTransaction(async (tx) => {
    await assertAccountLive(tx, uid, session)
    tx.set(ref, { ...document, dataChangedAt: changedAt, storedAt: FieldValue.serverTimestamp() })
  })
  return document
}

/**
 * Every stored card for one user, a page at a time — the Dashboard half of `GET /me/export`
 * (#58).
 *
 * Each in exactly the shape `GET /me/today` answers with (`toDocument`): the date, when it
 * was generated, the copy version and the filled card. A filled card is her own logged data
 * written out as prose, which is the reason `deleteAllUserToday` exists and the same reason
 * it is exported. `dataChangedAt` and `storedAt` are **left behind**: they are this module's
 * cache bookkeeping — when to regenerate, when the write landed — and not something she told
 * Eva or Eva told her.
 *
 * Ordered by document id, which here *is* the date, so the pages come out in calendar order
 * and a document cannot be dropped for lacking the ordered field. Yields nothing for an
 * account that never opened the Dashboard.
 */
export async function* exportTodayCards(
  uid: string,
  pageSize: number,
): AsyncGenerator<TodayDocument[], void, undefined> {
  const ordered = days(uid).orderBy(FieldPath.documentId()).limit(pageSize)
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null
  for (;;) {
    const page = await (cursor === null ? ordered : ordered.startAfter(cursor)).get()
    if (page.empty) return
    yield page.docs.map((doc) => toDocument(doc.data()))
    if (page.size < pageSize) return
    cursor = page.docs.at(-1) ?? null
  }
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

/**
 * Whole years from a date of birth to a date (#81), re-exported for the same reason the
 * refusal above is: `parseProfile` enforces Eva's 18+ floor at the route edge and must
 * measure the age exactly as `bandForAge` does, and `index.ts` reaches `cycle.ts` through
 * this module or not at all.
 *
 * One implementation rather than two, because the two disagree. The spelling a route would
 * reach for — subtract 18 from the year and compare — rolls 29 February forward into 1
 * March, so on a leap day it admits somebody a day under the floor while the maths reads her
 * as 17 and refuses to band her. Neither half decides the floor: each side declares its own,
 * because one is a legal line and the other is a clinical band's edge.
 */
export { ageYearsOn } from './cycle'

/**
 * The vocabulary `GET /me/cycle/predictions` answers in (#205), re-exported for the same
 * reason the refusal above is: the route reads C11's answers through this module, so the
 * confidence class and the withheld reason it puts on the wire are `cycle.ts`'s own names
 * and not a second set that could drift from them.
 *
 * Types only — `verbatimModuleSyntax` erases them, so this adds no runtime edge.
 */
export type {
  CycleAnalysis,
  CyclePrediction,
  EstimateWithheld,
  FertileWindow,
} from './cycle'

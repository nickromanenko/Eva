import { FieldValue } from 'firebase-admin/firestore'
import { createHash } from 'node:crypto'
import { firestore } from './firebase'

/**
 * Owner of `content/` (GUARDRAILS rule 10). Nothing else touches it.
 *
 * The Dashboard's words — card templates, banner items, nudge rules — are data, not
 * code (PRD §Dashboard, Other requirements 2: "All card templates, banner content and
 * nudge rules are server-configurable and do not require an app release"). Same shape as
 * `refdata/` (#24), for the same reasons: one document per kind, a content-derived
 * `version` the device caches against, served with a `304` handshake so the words are
 * available offline (A3).
 *
 * **One difference from refdata, and it is the point of this module.** Catalogue entries
 * are option labels; these are *clinical copy*. PRD Other requirements 4: "Clinical
 * content in cards and banners follows the same review requirement as the rest of the
 * product." So every document carries `reviewedBy`, `reviewedAt` and `source`, and this
 * module **refuses to write without them**. A template nobody signed cannot reach a
 * device by accident, and the seed script cannot be talked into it with a flag.
 *
 * Two rules inherited from refdata, for the same reasons:
 *
 * - **An id is permanent and opaque.** A device caches a rendered card pointing at a
 *   template id; relabelling copy must never change the id, and an id is never reused
 *   for different words.
 * - **Nothing is deleted, only retired.** A template a cached card points at still has
 *   to resolve, so removal is `retireContent`, never a side effect of re-seeding. Retired
 *   rows stay in `GET /content`, but consumers must not select them for new cards,
 *   banners or nudges; `TemplatePhraser` enforces that rule for today's card.
 *
 * What this module deliberately does **not** do: choose a template for a day (D1), fill
 * one (D3), or render one (D4–D8). It holds the words and says who signed them.
 */

/** The three kinds `GET /content` serves, in the order it serves them. */
export const CONTENT_IDS = ['templates', 'banners', 'nudges'] as const
export type ContentId = (typeof CONTENT_IDS)[number]

export type ContentStatus = 'active' | 'retired'

/**
 * Who signed this document's copy off, and against what.
 *
 * Not optional, and not defaulted. `reviewedBy` is a person, `reviewedAt` an ISO date,
 * `source` what they reviewed it against — the canvas state, a guideline, a clinician's
 * note. An empty string in any of them is a refusal, not a warning: the whole reason
 * this exists is that clinical copy without a name on it must not be servable.
 */
export interface Review {
  reviewedBy: string
  reviewedAt: string
  source: string
}

/**
 * How confidently a card may speak (#11 C11, PRD §Dashboard tone rule 5).
 *
 * `hedged` is the wording used when a phase is estimated rather than confirmed —
 * "likely", "many women notice". `plain` states something observed: a log the user made,
 * an appointment they booked. D1 picks between them from the cycle maths' confidence.
 *
 * The store records the label; it does not police it. Nothing here reads the words to
 * check that a `hedged` template hedges, and nothing refuses a `plain` phase template —
 * the seed's own phase templates are all hedged and a test pins that, but a document
 * written in the console is taken at its word. `hedged` is the default the parser falls
 * back to, so an unlabelled template is treated as the more cautious of the two.
 */
export type Confidence = 'hedged' | 'plain'

/**
 * The slot vocabulary a template may reference, enumerated on purpose.
 *
 * PRD §Dashboard: "No comparison to other users, no scores for the person, no streaks."
 * A template cannot ask for a slot that does not exist here, so a score, a streak or a
 * comparison cannot be introduced by editing a Firestore document — it would need a code
 * change, a review, and this list to grow. That is the mechanism, not the intention.
 */
export const SLOTS = [
  'cycleDay',
  'phase',
  'cycleCount',
  'appointmentAt',
  'appointmentWith',
  'appointmentPlace',
  'loggedAt',
  'pregnancyWeek',
  'pregnancyDay',
  'postpartumDay',
  'readMinutes',
  'category',
  'signal',
  'symptom',
] as const
export type Slot = (typeof SLOTS)[number]

/** A card template. Field names follow the canvas card (`kicker`, `title`, `line2`,
 *  `line3`, `meta`, `actions`, `tone`). */
export interface Template {
  /** Permanent and opaque. The canvas' `CARDS` key, lowercased. */
  id: string
  /** Which rung of the priority ladder this belongs to (D1 decides, this records). */
  rung: string
  /** `cycle` | `planning` | `pregnancy` | `postpartum` | `loss` | `any`. */
  mode: string
  /** The canvas state this renders, e.g. `home_d`. */
  state: string
  confidence: Confidence
  tone?: string
  kicker?: string
  title: string
  line2?: string
  line3?: string
  meta?: string
  actions: string[]
  /** Slots the strings above reference. Checked against `SLOTS`. */
  slots: Slot[]
  status: ContentStatus
  order: number
}

/** A banner item — the educational rail beside the card. */
export interface Banner {
  id: string
  /** `cycle` | `pregnancy` | `postpartum`. */
  phase: string
  mode: string
  /** Nutrition, Movement, Recovery, Pregnancy — the canvas' category word. */
  focus: string
  title: string
  meta: string
  /** Where the article lives. Empty until the article exists; a banner with no URL is
   *  still servable, because the rail is drawn from this and the link is the last part
   *  to arrive. */
  url: string
  status: ContentStatus
  order: number
}

/** A nudge rule: when to offer it, and what it says. */
export interface Nudge {
  id: string
  /**
   * The PRD's parameter for this nudge, and nothing invented beside it: period within
   * `2` days, appointment `tomorrow`, a logging gap of `3` days, a setup step never
   * completed. `null` for the rules that have no number.
   */
  withinDays: number | null
  trigger: string
  text: string
  sub?: string
  action: string
  status: ContentStatus
  order: number
}

/**
 * The reviewed vocabulary that turns a stored body-signal rating into words (#200).
 *
 * `dashboard-rules.ts` holds ratings as numbers and symptoms as `refdata/` codes, and is
 * text-free by design. These phrases are the other half: a rating of 1 or 2 is "low", and
 * "low energy" is a *judgement about a number* rather than a readback of it — which is why
 * it is reviewed copy in this collection and not a literal in the ladder. The low band is
 * `1–2` on the validated 1–5 scale, the same boundary `.env.example` states for the pattern
 * rung, but it is a readback here and not that rung's configured threshold.
 *
 * `fallback` names the card when nothing more specific is true: a card that is *about* what
 * she logged and cannot name it precisely still has to say something true of it.
 */
export interface SignalVocabulary {
  /** `1–2` on energy, e.g. `"low energy"`. */
  energy: string
  /** `1–2` on mood, e.g. `"low mood"`. */
  mood: string
  /** `1–2` on sleep, e.g. `"poor sleep"`. */
  sleep: string
  /** A nameable entry with no low rating and no symptom, e.g. `"body signals"`. */
  fallback: string
}

export interface ContentBundle {
  templates: Template[]
  banners: Banner[]
  nudges: Nudge[]
}

export interface Content {
  version: string
  templates: Template[]
  banners: Banner[]
  nudges: Nudge[]
}

const collection = () => firestore.collection('content')

const asString = (value: unknown, fallback = ''): string =>
  typeof value === 'string' ? value : fallback

const asStatus = (value: unknown): ContentStatus => (value === 'retired' ? 'retired' : 'active')

const asStringArray = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []

const byOrderThenId = (a: { order: number; id: string }, b: { order: number; id: string }) =>
  a.order - b.order || a.id.localeCompare(b.id)

const toTemplate = (raw: Record<string, unknown>, index: number): Template => ({
  id: asString(raw.id),
  rung: asString(raw.rung),
  mode: asString(raw.mode, 'any'),
  state: asString(raw.state),
  confidence: raw.confidence === 'plain' ? 'plain' : 'hedged',
  ...(typeof raw.tone === 'string' ? { tone: raw.tone } : {}),
  ...(typeof raw.kicker === 'string' ? { kicker: raw.kicker } : {}),
  title: asString(raw.title),
  ...(typeof raw.line2 === 'string' ? { line2: raw.line2 } : {}),
  ...(typeof raw.line3 === 'string' ? { line3: raw.line3 } : {}),
  ...(typeof raw.meta === 'string' ? { meta: raw.meta } : {}),
  actions: asStringArray(raw.actions),
  slots: asStringArray(raw.slots).filter((slot): slot is Slot =>
    (SLOTS as readonly string[]).includes(slot),
  ),
  status: asStatus(raw.status),
  order: typeof raw.order === 'number' ? raw.order : index,
})

const toBanner = (raw: Record<string, unknown>, index: number): Banner => ({
  id: asString(raw.id),
  phase: asString(raw.phase),
  mode: asString(raw.mode, 'any'),
  focus: asString(raw.focus),
  title: asString(raw.title),
  meta: asString(raw.meta),
  url: asString(raw.url),
  status: asStatus(raw.status),
  order: typeof raw.order === 'number' ? raw.order : index,
})

const toNudge = (raw: Record<string, unknown>, index: number): Nudge => ({
  id: asString(raw.id),
  withinDays: typeof raw.withinDays === 'number' ? raw.withinDays : null,
  trigger: asString(raw.trigger),
  text: asString(raw.text),
  ...(typeof raw.sub === 'string' ? { sub: raw.sub } : {}),
  action: asString(raw.action),
  status: asStatus(raw.status),
  order: typeof raw.order === 'number' ? raw.order : index,
})

/**
 * The read path, in one pure function: a Firestore document's `items` become the typed
 * rows `GET /content` serves, dropping anything the code does not recognise.
 *
 * Exported because the dropping is the point. A document can reach this collection
 * without passing `applyContent` — someone editing in the Firebase console, a future
 * script — so "a template cannot reference a slot that does not exist" is enforced here
 * or nowhere, and a test has to be able to hand it a document that no writer in this
 * repo would produce. Pure, like `contentVersion` and `reviewProblems` beside it.
 */
export const parseItems = (id: ContentId, data: unknown): unknown[] => {
  const raw = (data as { items?: unknown } | undefined)?.items
  if (!Array.isArray(raw)) return []
  const rows = raw.filter(
    (row): row is Record<string, unknown> => typeof row === 'object' && row !== null,
  )
  const parsed =
    id === 'templates'
      ? rows.map(toTemplate)
      : id === 'banners'
        ? rows.map(toBanner)
        : rows.map(toNudge)
  // First write wins on a repeated id: `applyContent` dedupes on the way in, but a
  // document edited in the console can hold the same id twice, and serving a card twice
  // contradicts "ids are permanent and opaque" in a way the client cannot unpick.
  const seen = new Set<string>()
  return (parsed as { id: string; order: number }[])
    .filter((item) => {
      if (item.id.length === 0 || seen.has(item.id)) return false
      seen.add(item.id)
      return true
    })
    .sort(byOrderThenId)
}

/** Key-sorted JSON, so the version depends on the words rather than on the order the
 *  fields happened to be written in. Same helper refdata uses, same reason. */
const stable = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(stable)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, inner]) => [key, stable(inner)]),
    )
  }
  return value
}

/**
 * Derived from the content, never bumped by hand: editing one template's `line2` changes
 * the version by construction, and re-seeding identical words does not — so an idempotent
 * re-seed cannot invalidate every device's cache for nothing.
 *
 * The review metadata is deliberately **not** in the hash. Re-signing the same words is
 * not a content change, and making it one would push a new bundle to every device every
 * time someone re-reviewed.
 */
export const contentVersion = (bundle: ContentBundle): string =>
  createHash('sha256')
    .update(JSON.stringify(stable(bundle)))
    .digest('hex')
    .slice(0, 16)

/** Thrown by `applyContent` when a document has no signature. Its own class so the seed
 *  script can tell a refusal from a Firestore failure and say so. */
export class UnreviewedContentError extends Error {
  constructor(id: string, missing: string[]) {
    super(`content/${id} is missing review metadata: ${missing.join(', ')}`)
    this.name = 'UnreviewedContentError'
  }
}

/** Thrown before a writer could normalise away stored rows that have no usable id. */
export class UnusableContentRowsError extends Error {
  constructor(id: string, indexes: number[]) {
    super(`content/${id} has rows with no usable id at indexes: ${indexes.join(', ')}`)
    this.name = 'UnusableContentRowsError'
  }
}

/** The check `applyContent` refuses on. Exported so the seed script can report every
 *  problem at once instead of one write at a time. */
export const reviewProblems = (review: Partial<Review> | undefined): string[] => {
  const missing: string[] = []
  for (const field of ['reviewedBy', 'reviewedAt', 'source'] as const) {
    if (!asString(review?.[field]).trim()) missing.push(field)
  }
  return missing
}

const CACHE_TTL_MS = 60_000
let cache: { at: number; data: Content } | null = null
let lastWarnedAt = 0

const invalidate = (): void => {
  cache = null
  lastWarnedAt = 0
}

type StoredContentRow = { id: string; status?: ContentStatus }

const rawContentItems = (data: Record<string, unknown> | undefined): unknown[] =>
  Array.isArray(data?.items) ? data.items : []

/**
 * Writers refuse rows the read path cannot identify instead of turning a write for one
 * item into a destructive normalisation pass over the whole document.
 */
const storedContentRows = (id: ContentId, rows: unknown[]): StoredContentRow[] => {
  const unusable: number[] = []
  const usable: StoredContentRow[] = []
  rows.forEach((row, index) => {
    if (
      typeof row !== 'object' ||
      row === null ||
      typeof (row as { id?: unknown }).id !== 'string' ||
      (row as { id: string }).id.length === 0
    ) {
      unusable.push(index)
    } else {
      usable.push(row as StoredContentRow)
    }
  })
  if (unusable.length > 0) throw new UnusableContentRowsError(id, unusable)
  return usable
}

const loadBundle = async (): Promise<ContentBundle> => {
  const refs = CONTENT_IDS.map((id) => collection().doc(id))
  const snapshots = await firestore.getAll(...refs)
  const parsed = CONTENT_IDS.map((id, index) => parseItems(id, snapshots[index]?.data()))
  return {
    templates: (parsed[0] ?? []) as Template[],
    banners: (parsed[1] ?? []) as Banner[],
    nudges: (parsed[2] ?? []) as Nudge[],
  }
}

const isEmpty = (bundle: ContentBundle): boolean =>
  bundle.templates.length === 0 && bundle.banners.length === 0 && bundle.nudges.length === 0

export const getContent = async (): Promise<Content> => {
  const now = Date.now()
  if (cache && now - cache.at < CACHE_TTL_MS) return cache.data

  const bundle = await loadBundle()
  const data: Content = { version: contentVersion(bundle), ...bundle }
  // An unseeded collection is an operational state, not a snapshot worth holding onto:
  // caching it would keep an instance blind for a minute after seeding. Unlike `refdata/`,
  // where empty is a brief boot window, empty is the *steady* state here until a clinician
  // signs the copy — so the warning is rate-limited to the cache window it stands in for,
  // rather than one line per request forever.
  if (isEmpty(bundle)) {
    if (now - lastWarnedAt >= CACHE_TTL_MS) {
      lastWarnedAt = now
      console.warn('content: no documents found — run `bun run seed:content`')
    }
  } else {
    cache = { at: now, data }
  }
  return data
}

// ── Editing ────────────────────────────────────────────────────────────────────
// Copy edits are document writes, not deploys. These exist so the seed script and the
// tests do not reach into the collection themselves; a human editing a line in the
// console is equally supported and needs none of them — except that the console can
// write a document with no signature, which is why `GET /content` serves what is there
// rather than re-checking. The refusal is on the path this repo controls.

export const readContent = async (id: ContentId): Promise<unknown[]> =>
  parseItems(id, (await collection().doc(id).get()).data())

/**
 * Writes one kind's items, **refusing without a signature**.
 *
 * Additive, like `applyCatalogue`: unknown ids are appended, known ones left alone unless
 * `rewrite` is asked for, and absent ids are never removed — a template vanishing would
 * orphan every cached card pointing at it, so retirement is a deliberate act. Items it
 * leaves alone are written back byte for byte, fields this module does not model included.
 *
 * The refusal is transitive, which matters because the merge is additive and the signature
 * is on the document rather than on each item. Items already in the document are kept and
 * written back under *this* call's signature, so a document that is itself unsigned — one
 * somebody added to in the Firebase console — would otherwise come out carrying a
 * reviewer's name over copy that reviewer never saw. That is the failure this collection
 * exists to prevent, arriving through the sanctioned path, so an unsigned document with
 * items in it is refused rather than re-signed. Emptying or fixing its signature in the
 * console is the way through, and both are visible acts.
 */
export const applyContent = async (
  id: ContentId,
  items: { id: string; order: number; status: ContentStatus }[],
  review: Review,
  options: { rewrite?: boolean } = {},
): Promise<unknown[]> => {
  const missing = reviewProblems(review)
  if (missing.length > 0) throw new UnreviewedContentError(id, missing)

  const snapshot = await collection().doc(id).get()
  const stored = snapshot.data()
  // The stored rows **as written**, not as `parseItems` would serve them: a merge must not
  // be the thing that quietly deletes a field this parser does not model yet. The read path
  // is where unknown shapes are dropped; the write path leaves what it did not come to
  // change.
  const rawItems = rawContentItems(stored)
  // Every stored row counts as existing copy for the review gate, including one the
  // read path cannot identify. Otherwise malformed unsigned copy could be erased and
  // the replacement stamped with this call's signature.
  if (rawItems.length > 0) {
    const unsigned = reviewProblems(stored as Partial<Review>)
    if (unsigned.length > 0) throw new UnreviewedContentError(id, unsigned)
  }
  const existing = storedContentRows(id, rawItems)
  // First wins on a repeated id, the same survivor `parseItems` picks. Last-wins here
  // would mean a duplicate typed into the console is hidden by the read path — the good
  // row keeps being served — right up until a legitimate re-seed promotes the second one
  // and signs it. The two paths have to agree on which row is real.
  const byId = new Map<string, { id: string; status?: ContentStatus }>()
  for (const item of existing) if (!byId.has(item.id)) byId.set(item.id, item)
  for (const item of items) {
    const current = byId.get(item.id)
    if (!current) byId.set(item.id, item)
    // A rewrite keeps `status`: re-seeding must not un-retire what someone retired.
    else if (options.rewrite) byId.set(item.id, { ...item, status: current.status ?? item.status })
  }
  const merged = [...byId.values()].sort(byOrderThenId as never)
  await collection().doc(id).set({
    items: merged,
    reviewedBy: review.reviewedBy,
    reviewedAt: review.reviewedAt,
    source: review.source,
    updatedAt: FieldValue.serverTimestamp(),
  })
  invalidate()
  return merged
}

/** Takes an id out of what is offered while leaving it resolvable, so a card cached
 *  yesterday still renders. The supported removal.
 *
 *  Works on the stored rows rather than the parsed ones, for the reason `applyContent`
 *  does: retiring one banner must not be the operation that deletes a field somebody added
 *  to the other eight. It writes no signature — flipping a status changes what is offered,
 *  not what the words say — so the document's existing `reviewedBy` keeps covering copy it
 *  still describes. */
export const retireContent = async (id: ContentId, itemId: string): Promise<boolean> => {
  const stored = (await collection().doc(id).get()).data()
  const items = storedContentRows(id, rawContentItems(stored))
  const item = items.find((entry) => entry.id === itemId)
  if (!item || item.status === 'retired') return false
  item.status = 'retired'
  await collection().doc(id).update({ items, updatedAt: FieldValue.serverTimestamp() })
  invalidate()
  return true
}

/** Test support — nothing in `src/` calls it. */
export const invalidateContentCache = invalidate

// ── Signal vocabulary (server-internal, never served to the client) ──────────────────
// The phrases that fill `{signal}` are not part of `GET /content`: the client receives the
// *filled* card, never the vocabulary. They live here rather than in `today.ts` because
// they are reviewed copy, and the only door that lets them in is the one `applyContent`
// guards — the `REVIEW` signature.

const vocabularyRef = () => collection().doc('vocabulary')

const toSignalVocabulary = (raw: Record<string, unknown> | undefined): SignalVocabulary | null => {
  if (!raw) return null
  const energy = asString(raw.energy).trim()
  const mood = asString(raw.mood).trim()
  const sleep = asString(raw.sleep).trim()
  const fallback = asString(raw.fallback).trim()
  // A half-written document must not serve a card that names a rating but not the other two.
  if (energy.length === 0 || mood.length === 0 || sleep.length === 0 || fallback.length === 0) {
    return null
  }
  return { energy, mood, sleep, fallback }
}

let vocabularyCache: { at: number; data: SignalVocabulary } | null = null

/**
 * The signal vocabulary, or `null` when `content/vocabulary` is unseeded. A missing
 * vocabulary leaves `{signal}` unfilled, which `TemplatePhraser` refuses for a title rather
 * than rendering — the same fail-closed shape as an unseeded `content/`.
 */
export const getSignalVocabulary = async (): Promise<SignalVocabulary | null> => {
  const now = Date.now()
  if (vocabularyCache && now - vocabularyCache.at < CACHE_TTL_MS) return vocabularyCache.data
  const data = toSignalVocabulary((await vocabularyRef().get()).data())
  if (data !== null) vocabularyCache = { at: now, data }
  return data
}

/**
 * Writes the signal vocabulary, **refusing without a signature**, exactly as `applyContent`
 * does. A phrase describing a person's own body is the copy the `REVIEW` gate exists for, so
 * there is no unsigned path in.
 */
export const applySignalVocabulary = async (
  vocabulary: SignalVocabulary,
  review: Review,
): Promise<void> => {
  const missing = reviewProblems(review)
  if (missing.length > 0) throw new UnreviewedContentError('vocabulary', missing)
  await vocabularyRef().set({
    ...vocabulary,
    reviewedBy: review.reviewedBy,
    reviewedAt: review.reviewedAt,
    source: review.source,
    updatedAt: FieldValue.serverTimestamp(),
  })
  vocabularyCache = null
}

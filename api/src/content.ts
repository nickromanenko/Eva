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
 *   to resolve, so removal is `retireTemplate`, never a side effect of re-seeding.
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
 * an appointment they booked. D1 picks between them from the cycle maths' confidence; the
 * store only holds both and refuses a phase template that has no hedged variant.
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
  const rows = raw.filter((row): row is Record<string, unknown> => typeof row === 'object' && row !== null)
  const parsed =
    id === 'templates'
      ? rows.map(toTemplate)
      : id === 'banners'
        ? rows.map(toBanner)
        : rows.map(toNudge)
  return (parsed as { id: string; order: number }[])
    .filter((item) => item.id.length > 0)
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
  createHash('sha256').update(JSON.stringify(stable(bundle))).digest('hex').slice(0, 16)

/** Thrown by `applyContent` when a document has no signature. Its own class so the seed
 *  script can tell a refusal from a Firestore failure and say so. */
export class UnreviewedContentError extends Error {
  constructor(id: string, missing: string[]) {
    super(`content/${id} is missing review metadata: ${missing.join(', ')}`)
    this.name = 'UnreviewedContentError'
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

const invalidate = (): void => {
  cache = null
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
  // caching it would keep an instance blind for a minute after seeding.
  if (isEmpty(bundle)) {
    console.warn('content: no documents found — run `bun run seed:content`')
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
 * orphan every cached card pointing at it, so retirement is a deliberate act.
 */
export const applyContent = async (
  id: ContentId,
  items: { id: string; order: number; status: ContentStatus }[],
  review: Review,
  options: { rewrite?: boolean } = {},
): Promise<unknown[]> => {
  const missing = reviewProblems(review)
  if (missing.length > 0) throw new UnreviewedContentError(id, missing)

  const existing = (await readContent(id)) as { id: string; status: ContentStatus }[]
  const byId = new Map(existing.map((item) => [item.id, item]))
  for (const item of items) {
    const current = byId.get(item.id)
    if (!current) byId.set(item.id, item)
    // A rewrite keeps `status`: re-seeding must not un-retire what someone retired.
    else if (options.rewrite) byId.set(item.id, { ...item, status: current.status })
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
 *  yesterday still renders. The supported removal. */
export const retireContent = async (id: ContentId, itemId: string): Promise<boolean> => {
  const items = (await readContent(id)) as { id: string; status: ContentStatus }[]
  const item = items.find((entry) => entry.id === itemId)
  if (!item || item.status === 'retired') return false
  item.status = 'retired'
  await collection().doc(id).update({ items, updatedAt: FieldValue.serverTimestamp() })
  invalidate()
  return true
}

/** Test support — nothing in `src/` calls it. */
export const invalidateContentCache = invalidate

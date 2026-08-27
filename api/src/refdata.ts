import { FieldValue } from 'firebase-admin/firestore'
import { createHash } from 'node:crypto'
import { firestore } from './firebase'

/** Owner of `refdata/` (GUARDRAILS rule 10). Nothing else touches it.
 *
 *  The option lists the client draws — symptom chips, sport activities, appointment
 *  types — are data, not code (PRD:483: new options ship without an app release).
 *  One document per catalogue, each holding `items`, served by `GET /refdata` with a
 *  content-derived `version` the client caches against.
 *
 *  Two rules hold this together:
 *
 *  - **A code is permanent.** Labels are editable; codes are opaque identifiers that
 *    events already point at. Changing a label must never change a code, and a code is
 *    never reused for a different meaning.
 *  - **Nothing is deleted, only retired.** A retired item keeps resolving to a label,
 *    so an entry logged last year still reads correctly, and it is still accepted on
 *    write, so a queued offline entry is never dropped for being out of fashion. It is
 *    simply not offered as a new choice. `retireCode` is the supported removal. */

export type CatalogueId = 'symptoms' | 'sportActivities' | 'appointmentTypes'

/** The catalogues `GET /refdata` serves, in the order it serves them. Any other
 *  document in the collection is ignored by the API — reference data is only
 *  reference data once something reads it. */
export const CATALOGUE_IDS = ['symptoms', 'sportActivities', 'appointmentTypes'] as const

export type ItemStatus = 'active' | 'retired'

interface BaseItem {
  /** Stable, opaque, never reused. The client renders `label`, never the code. */
  code: string
  label: string
  /** Display order hint. C7's adaptive ordering re-sorts on top of this. */
  order: number
  status: ItemStatus
}

export interface SymptomItem extends BaseItem {
  /** Where the chip sits before adaptive ordering: the grid, or behind "More…". */
  group: 'primary' | 'more'
  /** PRD chip requirement 4: a second tap marks *these* chips severe. Advisory —
   *  the API accepts `severity` on any symptom, because narrowing that now would
   *  reject entries #23 already allows. */
  severable: boolean
  /** The chip's own value axis — discharge is `dry|sticky|creamy|watery|egg-white`.
   *  `null` means the chip has no picker. Deliberately *not* `severity`: severity is
   *  an intensity, a value is a category, and one cannot express the other. */
  values: string[] | null
}

export interface OptionItem extends BaseItem {
  /** "Other" reveals a free-text field, so this code is not the whole answer. */
  freeText: boolean
}

export type CatalogueItem = SymptomItem | OptionItem

export interface Catalogues {
  symptoms: SymptomItem[]
  sportActivities: OptionItem[]
  appointmentTypes: OptionItem[]
}

export interface RefData {
  version: string
  catalogues: Catalogues
}

/** What the route edge needs to validate a symptom, and nothing more — the
 *  validator has no business knowing about labels or display order. */
export interface SymptomRules {
  /** Retired codes answer `true`: they are historical, not invalid. */
  has: (code: string) => boolean
  /** The allowed values for a chip's value axis, or `null` if it has none. */
  valuesFor: (code: string) => readonly string[] | null
}

const collection = () => firestore.collection('refdata')

const asString = (value: unknown, fallback = ''): string =>
  typeof value === 'string' ? value : fallback

const asStatus = (value: unknown): ItemStatus => (value === 'retired' ? 'retired' : 'active')

/** Documents are hand-editable, so read defensively: a missing `order` or `status`
 *  on a row someone typed into the console must not break the catalogue. */
const toSymptomItem = (raw: Record<string, unknown>, index: number): SymptomItem => ({
  code: asString(raw.code),
  label: asString(raw.label, asString(raw.code)),
  order: typeof raw.order === 'number' ? raw.order : index,
  status: asStatus(raw.status),
  group: raw.group === 'more' ? 'more' : 'primary',
  severable: raw.severable === true,
  values:
    Array.isArray(raw.values) && raw.values.length > 0
      ? raw.values.filter((v): v is string => typeof v === 'string')
      : null,
})

const toOptionItem = (raw: Record<string, unknown>, index: number): OptionItem => ({
  code: asString(raw.code),
  label: asString(raw.label, asString(raw.code)),
  order: typeof raw.order === 'number' ? raw.order : index,
  status: asStatus(raw.status),
  freeText: raw.freeText === true,
})

const byOrderThenCode = (a: BaseItem, b: BaseItem) =>
  a.order - b.order || a.code.localeCompare(b.code)

const parseItems = (id: string, data: unknown): CatalogueItem[] => {
  const raw = (data as { items?: unknown } | undefined)?.items
  if (!Array.isArray(raw)) return []
  const rows = raw.filter((row): row is Record<string, unknown> => typeof row === 'object' && row !== null)
  const items =
    id === 'symptoms' ? rows.map(toSymptomItem) : rows.map(toOptionItem)
  return items.filter((item) => item.code.length > 0).sort(byOrderThenCode)
}

/** Key-sorted JSON so the version depends on catalogue *content*, not on the order
 *  the fields happened to be written in. */
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

/** Derived from the content, never bumped by hand: a catalogue edit changes the
 *  version by construction, and rewriting the same content does not — so an
 *  idempotent re-seed cannot invalidate every client's cache for nothing.
 *  No timestamp goes into this for the same reason. */
export const catalogueVersion = (catalogues: Catalogues): string =>
  createHash('sha256').update(JSON.stringify(stable(catalogues))).digest('hex').slice(0, 16)

export const buildSymptomRules = (items: SymptomItem[]): SymptomRules => {
  // Retired codes stay in the index on purpose: rejecting one would refuse an entry
  // that a stale client or an offline queue is entitled to write, and would make an
  // old entry uneditable. Only a code the catalogue has never heard of is invalid.
  const values = new Map(items.map((item) => [item.code, item.values]))
  return {
    has: (code) => values.has(code),
    valuesFor: (code) => values.get(code) ?? null,
  }
}

/** Reference data is read on nearly every write (symptom validation) and changes a
 *  few times a year, so it is held in memory. The window is the staleness a catalogue
 *  edit takes to reach an instance, and the reason routes cost no Firestore read. */
const CACHE_TTL_MS = 60_000

let cache: { at: number; data: RefData } | null = null

const invalidate = () => {
  cache = null
}

const isEmpty = (catalogues: Catalogues): boolean =>
  CATALOGUE_IDS.every((id) => catalogues[id].length === 0)

const loadCatalogues = async (): Promise<Catalogues> => {
  const refs = CATALOGUE_IDS.map((id) => collection().doc(id))
  const snapshots = await firestore.getAll(...refs)
  const parsed = CATALOGUE_IDS.map((id, index) => parseItems(id, snapshots[index]?.data()))
  return {
    symptoms: (parsed[0] ?? []) as SymptomItem[],
    sportActivities: (parsed[1] ?? []) as OptionItem[],
    appointmentTypes: (parsed[2] ?? []) as OptionItem[],
  }
}

export const getRefData = async (): Promise<RefData> => {
  const now = Date.now()
  if (cache && now - cache.at < CACHE_TTL_MS) return cache.data

  const catalogues = await loadCatalogues()
  const data: RefData = { version: catalogueVersion(catalogues), catalogues }
  // An unseeded collection is an operational state, not a snapshot worth holding:
  // caching it would keep an instance blind for a minute after seeding.
  if (isEmpty(catalogues)) {
    console.warn('refdata: no catalogues found — run `bun run seed:refdata`')
  } else {
    cache = { at: now, data }
  }
  return data
}

/** `null` means "no catalogue to check against" — an unseeded collection or a
 *  Firestore that just failed. Validation then falls back to the opaque-code rules
 *  from #23. Losing a user's health entry because reference data is unavailable is
 *  the worse failure of the two. */
export const getSymptomRules = async (): Promise<SymptomRules | null> => {
  const data = await getRefData().catch((): null => {
    // No codes, no uid: never log what a user selected (GUARDRAILS rule 12).
    console.warn('refdata: catalogue read failed, symptom validation skipped')
    return null
  })
  if (!data || data.catalogues.symptoms.length === 0) return null
  return buildSymptomRules(data.catalogues.symptoms)
}

// ── Editing ────────────────────────────────────────────────────────────────────
// Catalogue edits are document writes, not deploys (PRD:483). These exist so the
// seed script and tests do not reach into the collection themselves; a human
// editing a label in the console is equally supported and needs none of them.

export const readCatalogue = async (id: string): Promise<CatalogueItem[]> =>
  parseItems(id, (await collection().doc(id).get()).data())

const write = async (id: string, items: CatalogueItem[]): Promise<void> => {
  await collection().doc(id).set({ items, updatedAt: FieldValue.serverTimestamp() })
  invalidate()
}

/** Additive: unknown codes are appended, known ones are left as they are unless
 *  `relabel` is asked for. Absent codes are **not** removed — an item vanishing from
 *  the catalogue orphans every event pointing at it, so retirement is a deliberate
 *  act (`retireCode`), never a side effect of re-running the seeder. */
export const applyCatalogue = async (
  id: string,
  items: CatalogueItem[],
  options: { relabel?: boolean } = {},
): Promise<CatalogueItem[]> => {
  const existing = await readCatalogue(id)
  const byCode = new Map(existing.map((item) => [item.code, item]))
  for (const item of items) {
    const current = byCode.get(item.code)
    if (!current) byCode.set(item.code, item)
    // A relabel keeps `status`: re-seeding must not un-retire what someone retired.
    else if (options.relabel) byCode.set(item.code, { ...item, status: current.status })
  }
  const merged = [...byCode.values()].sort(byOrderThenCode)
  await write(id, merged)
  return merged
}

/** Bootstrap only — writes nothing if the document exists, so it can never revert a
 *  label someone edited in the console. Returns whether it wrote. */
export const seedIfMissing = async (id: string, items: CatalogueItem[]): Promise<boolean> => {
  const ref = collection().doc(id)
  const created = await firestore.runTransaction(async (tx) => {
    if ((await tx.get(ref)).exists) return false
    tx.set(ref, { items, updatedAt: FieldValue.serverTimestamp() })
    return true
  })
  if (created) invalidate()
  return created
}

/** Takes a code out of the pickers while leaving it resolvable for every entry that
 *  already references it. This is what "removing an option" means here. */
export const retireCode = async (id: string, code: string): Promise<boolean> => {
  const items = await readCatalogue(id)
  const target = items.find((item) => item.code === code)
  if (!target || target.status === 'retired') return false
  await write(
    id,
    items.map((item) => (item.code === code ? { ...item, status: 'retired' as const } : item)),
  )
  return true
}

/** Wholesale overwrite. It *can* drop codes, which is why it is not how catalogues
 *  are seeded — it exists to restore a document to a known state (a test cleaning up
 *  after itself, a dev project being reset). */
export const replaceCatalogue = async (id: string, items: CatalogueItem[]): Promise<void> => {
  await write(id, items)
}

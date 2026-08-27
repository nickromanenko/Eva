/**
 * Seeds `refdata/` — the option lists the client draws.
 *
 *   cd api && bun run seed:refdata            # add anything missing, touch nothing else
 *   cd api && bun run seed:refdata --relabel  # also reset labels to the ones below
 *
 * A script rather than an admin route: seeding is an operator action, it needs no
 * authorization surface the API does not already have (there is no admin role, and
 * inventing one is a bigger decision than this), and the Admin SDK bypasses
 * `firestore.rules`, so nothing is loosened — the rules stay deny-all.
 *
 * The lists below are a **seed**, not the source of truth. Once a catalogue exists,
 * it lives in Firestore and is edited there; that is the point (PRD:483). Running
 * without `--relabel` will never overwrite an edit made in the console. Anything you
 * change in Firestore and want to keep should be mirrored back here, or the next
 * `--relabel` run reverts it.
 *
 * Nothing here removes an option. See `retireCode` in src/refdata.ts.
 */

import {
  CATALOGUE_IDS,
  applyCatalogue,
  readCatalogue,
  type CatalogueItem,
  type ItemStatus,
  type OptionItem,
  type SymptomItem,
} from '../src/refdata'

/** `order` and `status` come from `numbered` — a seed row states meaning, not position. */
type Seed<T extends CatalogueItem> = Omit<T, 'order' | 'status'>

const symptom = (
  code: string,
  label: string,
  extra: Partial<Omit<SymptomItem, 'code' | 'label' | 'order' | 'status'>> = {},
): Seed<SymptomItem> => ({
  code,
  label,
  group: 'primary',
  severable: false,
  values: null,
  ...extra,
})

const option = (code: string, label: string, freeText = false): Seed<OptionItem> => ({
  code,
  label,
  freeText,
})

/** Tens, so a new option can be slotted between two without renumbering the file. */
const numbered = <T extends Seed<CatalogueItem>>(
  items: T[],
): (T & { order: number; status: ItemStatus })[] =>
  items.map((item, index) => ({ status: 'active' as const, order: (index + 1) * 10, ...item }))

/** PRD "Body signals" zone 2: 14 chips, then 7 behind "More…".
 *
 *  Two deliberate departures, both settled on issue #24:
 *  - The canvas' "Spotting" chip is absent. #23 made spotting a *cycle marker*; as a
 *    symptom too, one day could carry two contradictory claims about bleeding.
 *  - The canvas' "Low energy" chip is absent. Energy is a 1–5 scale on the same sheet,
 *    and one concept may not have two representations (PRD:484).
 *
 *  `low-libido` comes from the canvas and sits behind "More…" — the PRD's own list is
 *  already 14 long against a 12-chip grid. */
const SYMPTOMS: SymptomItem[] = numbered([
  symptom('bloating', 'Bloating'),
  symptom('cramps', 'Cramps', { severable: true }),
  symptom('headache', 'Headache', { severable: true }),
  symptom('nausea', 'Nausea', { severable: true }),
  symptom('breast-tenderness', 'Breast tenderness'),
  symptom('back-pain', 'Back pain'),
  symptom('acne', 'Acne / breakout'),
  symptom('cravings', 'Cravings'),
  symptom('anxious', 'Anxious'),
  symptom('stressed', 'Stressed'),
  symptom('brain-fog', 'Brain fog'),
  symptom('poor-appetite', 'Poor appetite'),
  symptom('heavy-appetite', 'Heavy appetite'),
  symptom('libido-changes', 'Libido changes'),
  symptom('dizziness', 'Dizziness', { group: 'more' }),
  symptom('hot-flashes', 'Hot flashes', { group: 'more' }),
  symptom('constipation', 'Constipation', { group: 'more' }),
  symptom('loose-stool', 'Loose stool', { group: 'more' }),
  symptom('insomnia', 'Insomnia', { group: 'more' }),
  symptom('discharge', 'Discharge', {
    group: 'more',
    // The one chip with a value picker (PRD chip requirement 6). A category, not
    // an intensity — which is why it is `values` and not a wider `severity`.
    values: ['dry', 'sticky', 'creamy', 'watery', 'egg-white'],
  }),
  symptom('itching', 'Itching', { group: 'more' }),
  symptom('low-libido', 'Low libido', { group: 'more' }),
])

/** PRD "Sport" options. "Other" carries the free-text field. */
const SPORT_ACTIVITIES: OptionItem[] = numbered([
  option('walking', 'Walking'),
  option('running', 'Running'),
  option('cycling', 'Cycling'),
  option('swimming', 'Swimming'),
  option('strength-training', 'Strength training'),
  option('hiit', 'HIIT'),
  option('yoga', 'Yoga'),
  option('pilates', 'Pilates'),
  option('dance', 'Dance'),
  option('hiking', 'Hiking'),
  option('rowing', 'Rowing'),
  option('climbing', 'Climbing'),
  option('tennis', 'Tennis'),
  option('padel', 'Padel'),
  option('team-sport', 'Team sport'),
  option('martial-arts', 'Martial arts / boxing'),
  option('stretching-mobility', 'Stretching & mobility'),
  option('other', 'Other', true),
])

/** PRD "Doctor appointment" → Type. */
const APPOINTMENT_TYPES: OptionItem[] = numbered([
  option('scan', 'Scan'),
  option('midwife', 'Midwife'),
  option('gp', 'GP'),
  option('gynaecologist', 'Gynaecologist'),
  option('obstetrician', 'Obstetrician'),
  option('blood-test', 'Blood test'),
  option('glucose-test', 'Glucose test'),
  option('other', 'Other', true),
])

export const DEFAULT_CATALOGUES: Record<(typeof CATALOGUE_IDS)[number], CatalogueItem[]> = {
  symptoms: SYMPTOMS,
  sportActivities: SPORT_ACTIVITIES,
  appointmentTypes: APPOINTMENT_TYPES,
}

const main = async () => {
  const relabel = process.argv.includes('--relabel')
  for (const id of CATALOGUE_IDS) {
    const before = await readCatalogue(id)
    const after = await applyCatalogue(id, DEFAULT_CATALOGUES[id], { relabel })
    const added = after.length - before.length
    console.log(`${id}: ${after.length} items (${added} added${relabel ? ', labels reset' : ''})`)
  }
}

// Importable for its lists without seeding anything — api/test reads them.
if (import.meta.main) await main()

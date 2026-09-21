/**
 * Seeds `refdata/` — the option lists the client draws, and the per-country emergency
 * guidance table (#87).
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
 * Nothing here removes an option. Retirement is a separate, deliberate act:
 * `bun run retire:refdata` (scripts/retire-refdata.ts), over `retireCode` in
 * src/refdata.ts. Retired codes then stay listed below, carrying `status: 'retired'`,
 * so this file says both what the vocabulary is and what it was — and a fresh project
 * seeds straight into the retired state instead of depending on the retire script
 * having been run against it afterwards.
 */

import {
  applyCatalogue,
  CATALOGUE_IDS,
  type CatalogueItem,
  type EmergencyGuidanceEntry,
  type EmergencySupportResource,
  FALLBACK_GUIDANCE_CODE,
  type ItemStatus,
  type OptionItem,
  readCatalogue,
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
 *  Three deliberate departures, all settled on issue #24:
 *  - The canvas' "Spotting" chip is absent. #23 made spotting a *cycle marker*; as a
 *    symptom too, one day could carry two contradictory claims about bleeding.
 *  - The canvas' "Low energy" chip is absent. Energy is a 1–5 scale on the same sheet,
 *    and one concept may not have two representations (PRD:484).
 *  - The canvas' "Low libido" chip is absent, and so is the PRD's "Libido changes".
 *    A direction and a change are the same concept twice, so the two would never
 *    aggregate — the soft form of the one-vocabulary problem #24 exists to prevent.
 *    One `libido` chip carries the direction as a `values` axis instead, the way
 *    `discharge` carries its type. Both old codes are retired, never deleted — see
 *    RETIRED_SYMPTOMS below. */
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
  symptom('libido', 'Libido', {
    // A direction, not an intensity — the second chip with a value picker, following
    // `discharge` below. "Libido changes" said that something moved without saying
    // which way, which is the least useful half of the signal.
    values: ['low', 'high'],
  }),
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
])

/** Codes the vocabulary no longer offers, listed with the `order` and `status` they
 *  already carry in Firestore. They are here so seeding a project that has never seen
 *  them reproduces the live catalogue exactly — retirements included — rather than
 *  landing in a different state depending on whether `retire:refdata` was run against
 *  it. `applyCatalogue` never modifies an item that already exists, so re-seeding a
 *  project that has them writes the same rows back unchanged.
 *
 *  `order` is verbatim from the live document, not renumbered. It collides with
 *  `libido`'s 140, which is untidy but inert: `order` is a display hint, retired items
 *  are never offered as a choice, and history resolves by code. Renumbering here would
 *  only move a fresh project *away* from the live one, since `applyCatalogue` cannot
 *  rewrite the 140 already stored. See scripts/retire-refdata.ts for why each went. */
const RETIRED_SYMPTOMS: SymptomItem[] = [
  { ...symptom('libido-changes', 'Libido changes'), order: 140, status: 'retired' },
  { ...symptom('low-libido', 'Low libido', { group: 'more' }), order: 220, status: 'retired' },
]

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

/**
 * Emergency guidance per country (#87) — LAUNCH §4.3's table of the emergency number and
 * the wording for urgent maternity care, for the top English-speaking storefronts, plus
 * the neutral fallback everywhere else, and each country's support resources.
 *
 * The client resolves its country **on the device** and never sends it to the server
 * (LAUNCH §2.4), so this table travels whole to every client and the resolution rule it
 * must match lives in `resolveEmergencyGuidance` (src/refdata.ts): unknown or malformed
 * code, retired entry → `fallback`, always.
 *
 * ## Who signs this, per entry
 *
 * **Every non-fallback entry is signed under the A33 owner override** (LAUNCH §5: the
 * clinical-reviewer requirement bypassed by owner decision): **Nick Romanenko,
 * 2026-09-20**, the same signature `seed-content.ts`'s `REVIEW` carries. What that
 * signature stands behind, stated per entry so it can be audited:
 *
 * - The **emergency numbers** are the countries' official national emergency numbers —
 *   public telecom facts, not clinical judgement: 911 (US, CA), 999 (UK), 112/999 (IE —
 *   both answered, 112 everywhere in the EU, 999 the Irish number), 000 (AU), 111 (NZ).
 * - The **wording** adds exactly one sentence to the red-flag copy a reviewer already
 *   signed (`content/templates/red_flag`, seed-content.ts): "If you need urgent help,
 *   call {number} now." Nothing jurisdiction-specific beyond the number itself, per
 *   A33's "describe the body, not the health system".
 * - The **support resources** are each service's published public line — national
 *   crisis lines (988 US/CA, Samaritans 116 123 UK/IE, Lifeline 13 11 14 AU, 1737 NZ)
 *   and the perinatal services a pregnancy-loss reader is the audience for (PSI, Sands,
 *   PANDA). A service Eva cannot name with confidence stays out: **a guessed helpline is
 *   the same defect as a guessed emergency number.**
 *
 * The fallback is the one deliberately unsigned entry — it is the neutral wording the
 * signed template already carries, byte for byte, with no number and no resources. An
 * uncovered country gets "contact your provider or a local urgent care service" and
 * nothing invented, because no number at all is safer than a guessed one (#87).
 */
const guided = (
  code: string,
  label: string,
  emergencyNumber: string | null,
  urgentCareWording: string,
  support: EmergencySupportResource[] = [],
): Seed<EmergencyGuidanceEntry> => ({ code, label, emergencyNumber, urgentCareWording, support })

/** The red-flag template's guidance line, verbatim. `refdata.test.ts` holds the two
 *  together: change one without the other and the suite says so. */
const FALLBACK_WORDING =
  'Contact your provider or a local urgent care service for guidance. Eva cannot assess this.'

const EMERGENCY_GUIDANCE: EmergencyGuidanceEntry[] = numbered([
  guided(FALLBACK_GUIDANCE_CODE, 'Everywhere else', null, FALLBACK_WORDING),
  guided(
    'US',
    'United States',
    '911',
    'If you need urgent help, call 911 now. ' + FALLBACK_WORDING,
    [
      { label: '988 Suicide & Crisis Lifeline', detail: 'Call or text 988' },
      { label: 'Postpartum Support International', detail: 'Call or text 1-800-944-4773' },
    ],
  ),
  guided('CA', 'Canada', '911', 'If you need urgent help, call 911 now. ' + FALLBACK_WORDING, [
    { label: '988 Suicide Crisis Helpline', detail: 'Call or text 988' },
  ]),
  guided(
    'GB',
    'United Kingdom',
    '999',
    'If you need urgent help, call 999 now. ' + FALLBACK_WORDING,
    [
      { label: 'Samaritans', detail: 'Call 116 123, free, any time' },
      { label: 'Sands', detail: 'Call 0808 164 3332' },
    ],
  ),
  guided(
    'IE',
    'Ireland',
    '112 or 999',
    'If you need urgent help, call 112 or 999 now. ' + FALLBACK_WORDING,
    [{ label: 'Samaritans', detail: 'Call 116 123, free, any time' }],
  ),
  guided('AU', 'Australia', '000', 'If you need urgent help, call 000 now. ' + FALLBACK_WORDING, [
    { label: 'Lifeline Australia', detail: 'Call 13 11 14' },
    { label: 'PANDA', detail: 'Call 1300 726 306' },
  ]),
  guided('NZ', 'New Zealand', '111', 'If you need urgent help, call 111 now. ' + FALLBACK_WORDING, [
    { label: '1737, Need to talk?', detail: 'Call or text 1737' },
  ]),
])

export const DEFAULT_CATALOGUES: Record<(typeof CATALOGUE_IDS)[number], CatalogueItem[]> = {
  symptoms: [...SYMPTOMS, ...RETIRED_SYMPTOMS],
  sportActivities: SPORT_ACTIVITIES,
  appointmentTypes: APPOINTMENT_TYPES,
  emergencyGuidance: EMERGENCY_GUIDANCE,
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

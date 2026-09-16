/**
 * Seeds `content/` with the Dashboard copy the canvas draws (#97).
 *
 *   cd api && bun run seed:content
 *
 * Every string below is **verbatim from `docs/design/Eva App.dc.html`** — `CARDS`,
 * `NUDGES`, and the `banners` map in the home view. Changing a word here is changing what
 * a user reads, so it is a copy edit with a reviewer's name on it, not a refactor.
 *
 * ## It refused to run until someone signed, and that was the feature
 *
 * `applyContent` throws `UnreviewedContentError` without a `reviewedBy`, `reviewedAt` and
 * `source`, so this script could not seed anything until a person signed the copy off —
 * PRD §Dashboard, Other requirements 4: clinical content follows the same review
 * requirement as the rest of the product.
 *
 * `REVIEW` below is now filled, and the signature is the merge commit that filled it.
 * **There is still deliberately no `--skip-review` flag**, and adding one would undo this:
 * the refusal must stay the only door, so that the next copy change is signed the same way
 * rather than waved through. Changing a string below without moving `reviewedAt` is the
 * thing this guards against.
 *
 * ## The second half of the signature is now mechanical (#177)
 *
 * "Verbatim from the canvas" was always checkable, and `content.test.ts` checks it fragment
 * by fragment. The other half — *no card says something the rules layer has not observed* —
 * was a sentence a reviewer had to hold in their head against a ladder in another file, and
 * it did not hold: two review rounds on #96 each found a card asserting something specific
 * about a user it was not true of. `api/test/dashboard-copy.test.ts` walks every subject
 * `selectSubject` can return, checks each rendered string against what the input actually
 * contained, and pins the strings byte for byte — so a copy edit here fails there until its
 * claims have been re-read. Read that file's `UNTRUE` before signing: it is the list of what
 * the words below still get wrong, and what the canvas has to draw to close each one.
 */
import {
  applyContent,
  reviewProblems,
  UnreviewedContentError,
  type Banner,
  type Nudge,
  type Review,
  type Template,
} from '../src/content'

/**
 * Who signed this copy off.
 *
 * `source` names the exact canvas state, by the commit that last changed it, so a reviewer
 * can diff what was signed against what is drawn today rather than trusting a file name. It
 * also names the audit, because since #177 that is part of what is being signed.
 *
 * **Not a clinical review**, and the distinction is the whole reason this field is a
 * sentence and not a checkbox. No clinician has read these strings. What was reviewed is
 * that every string matches the canvas verbatim, and — this is the part that moved on
 * 2026-09-17 — **which cards are not yet true of everyone the ladder routes to them**.
 *
 * The 2026-09-16 signature said "no card states something the rules layer has not actually
 * observed about the user". That was false when it was written, and #177 is the issue that
 * establishes it: `signals_today` reads "You logged low energy and a headache today" and is
 * selected for every logged day in the four non-cycle modes and for severe-symptom,
 * low-energy-only and low-mood runs in cycle mode. It is not the only one. The canvas drew
 * these fourteen cards as illustrations — one woman, one day — and D1 routes a wide range of
 * situations into each.
 *
 * **So this signature says something narrower and checkable instead.** Thirteen strings
 * across six cards assert something their subject does not guarantee; every one of them is
 * enumerated in `api/test/dashboard-copy.test.ts`'s `UNTRUE`, with the case that
 * demonstrates it and what the canvas would have to draw. No string below changed — none
 * could, because the fix for every one of them is a card the canvas has not drawn, and a
 * seed file is not where product copy is authored. Signing this is signing that list: these
 * words, this ladder, these known gaps, and no others.
 *
 * Cards that would need a clinician to stand behind them are still not in this set: the one
 * card that speaks about a pattern reports the user's own logs and declines to interpret
 * them, and the red-flag rung that would carry real clinical weight is inert (`redFlag` is
 * `null` everywhere, D10) — which is exactly why the three mismatches the audit finds in
 * `red_flag` cost nothing today and must be closed before D10 makes it live.
 * docs/LAUNCH.md L7 remains open on its own terms and this does not close it.
 *
 * Exported so `api/test/content.test.ts` can tell whether the gate is still closed. The
 * case that proves this script has no way past the refusal has to *run* the script, and
 * now that these are filled that would seed whatever project the suite points at — so it
 * skips itself, exactly as it was built to.
 */
export const REVIEW: Review = {
  reviewedBy: 'Nick Romanenko',
  reviewedAt: '2026-09-17',
  source:
    'docs/design/Eva App.dc.html @ 0f7cda4 — Dashboard rail (CARDS, NUDGES, banners); ' +
    'plus the reachable-subject audit in api/test/dashboard-copy.test.ts (#177)',
}

/** The 14 card variants the canvas' `CARDS` holds, in its order.
 *
 *  `confidence` is the half D1 selects on: `hedged` wherever the card speaks about an
 *  *estimated* phase, `plain` wherever it reports something observed — a log the user
 *  made, an appointment she booked. Every phase template here is hedged, because there is
 *  no confirmed-ovulation path in v1 (#11 C11). */
export const TEMPLATES: Template[] = [
  {
    id: 'phase_energy', rung: 'phase', mode: 'cycle', state: 'home_d', confidence: 'hedged',
    kicker: 'Cycle day {cycleDay} · likely approaching ovulation',
    title: 'Many women notice higher energy around now',
    line2: 'This is a tendency across cycles, not a prediction about your day.',
    line3: 'If that matches how you feel, a harder training session may be an option.',
    actions: ['View cycle details'], slots: ['cycleDay', 'phase'], status: 'active', order: 0,
  },
  {
    id: 'signal_overrides_phase', rung: 'pattern', mode: 'cycle', state: 'home_e', confidence: 'plain',
    kicker: 'Cycle day {cycleDay}',
    title: 'You logged low energy this morning after a poor night’s sleep',
    line2: 'Although energy can be higher around this phase, your own log comes first.',
    line3: 'Sleep, stress and iron affect daily energy more than cycle phase. A lighter session may feel more manageable today.',
    actions: ['Review this morning’s log'], slots: ['cycleDay'], status: 'active', order: 1,
  },
  {
    id: 'cold_start', rung: 'setup', mode: 'any', state: 'home_a', confidence: 'plain',
    title: 'Start with your first log',
    line2: 'Log your period or today’s body signals so Eva can begin recognizing patterns that are specific to you.',
    actions: ['Log now', 'Open Calendar'], slots: [], status: 'active', order: 2,
  },
  {
    id: 'still_learning', rung: 'phase', mode: 'cycle', state: 'home_b', confidence: 'hedged',
    kicker: 'Cycle tracking · {cycleCount} of 3 cycles',
    title: 'Eva is still learning your cycle',
    line2: 'Log two more periods to help estimate your cycle phases more reliably. Until then, no phase is shown.',
    actions: ['Open Calendar'], slots: ['cycleCount'], status: 'active', order: 3,
  },
  {
    id: 'irregular', rung: 'phase', mode: 'cycle', state: 'home_c', confidence: 'hedged',
    kicker: 'Cycle tracking',
    title: 'Your current phase cannot be estimated reliably',
    line2: 'Your recent cycle lengths vary significantly, so Eva will not show a confident prediction.',
    actions: ['View cycle history'], slots: [], status: 'active', order: 4,
  },
  {
    id: 'late_period', rung: 'pattern', mode: 'cycle', state: 'home_f', confidence: 'plain',
    kicker: 'Cycle day {cycleDay}',
    title: 'Your period is later than predicted',
    line2: 'Eva cannot determine the reason from cycle data alone.',
    actions: ['Log period', 'Log test'], slots: ['cycleDay'], status: 'active', order: 5,
  },
  {
    id: 'signals_today', rung: 'pattern', mode: 'any', state: 'home_g', confidence: 'plain',
    kicker: 'Logged today',
    title: 'You logged low energy and a headache today',
    line2: 'A slower pace or additional rest may feel more appropriate.',
    actions: ['Review what I logged'], slots: [], status: 'active', order: 6,
  },
  {
    id: 'mood_pattern', rung: 'pattern', mode: 'any', state: 'home_h', confidence: 'plain',
    kicker: 'Pattern · last 3 days',
    title: 'You’ve logged low mood for three consecutive days',
    line2: 'Sleep has also been below your usual level during the same period. Eva can see the pattern but not its cause.',
    line3: 'Consider checking in with yourself, or talking it through with someone you trust.',
    actions: ['View pattern'], slots: [], status: 'active', order: 7,
  },
  {
    id: 'educational', rung: 'education', mode: 'any', state: 'home_edu', confidence: 'plain',
    tone: 'edu', kicker: 'Today’s read',
    title: 'Why sleep can affect appetite more than willpower',
    line2: 'Educational content, not personalized insight — nothing new in your logs today.',
    meta: '{category} · {readMinutes} min read',
    actions: ['Read article'], slots: ['category', 'readMinutes'], status: 'active', order: 8,
  },
  {
    id: 'planning_window', rung: 'phase', mode: 'planning', state: 'home_plan', confidence: 'hedged',
    kicker: 'Planning · cycle day {cycleDay}',
    title: 'Your fertile window most likely closed two days ago',
    line2: 'Based on your last three cycles. Confidence is moderate — cycle lengths varied by four days.',
    line3: 'Two more logged cycles would narrow this estimate.',
    actions: ['View window details'], slots: ['cycleDay'], status: 'active', order: 9,
  },
  {
    id: 'pregnancy_appointment', rung: 'milestone', mode: 'pregnancy', state: 'home_preg', confidence: 'plain',
    kicker: 'Pregnancy · week {pregnancyWeek}, day {pregnancyDay}',
    title: 'Your anatomy scan is scheduled for tomorrow, {appointmentAt}',
    line2: '{appointmentWith} · {appointmentPlace}.',
    line3: 'Your saved questions are ready to review.',
    actions: ['View appointment'],
    slots: ['pregnancyWeek', 'pregnancyDay', 'appointmentAt', 'appointmentWith', 'appointmentPlace'],
    status: 'active', order: 10,
  },
  {
    id: 'red_flag', rung: 'flag', mode: 'pregnancy', state: 'home_flag', confidence: 'plain',
    tone: 'flag', kicker: 'Logged {loggedAt} today',
    title: 'You logged reduced fetal movement today',
    line2: 'Contact your maternity provider or local urgent care service for guidance. Eva cannot assess this.',
    actions: ['View contact options', 'Review what I logged'], slots: ['loggedAt'],
    status: 'active', order: 11,
  },
  {
    id: 'postpartum_check', rung: 'milestone', mode: 'postpartum', state: 'home_post', confidence: 'plain',
    kicker: 'Postpartum · day {postpartumDay}',
    title: 'Your 6-week check is on Friday, {appointmentAt}',
    line2: 'Recovery, feeding and mood can all be discussed at this appointment.',
    line3: 'You can review your symptoms and prepare questions beforehand.',
    actions: ['Prepare questions'], slots: ['postpartumDay', 'appointmentAt'],
    status: 'active', order: 12,
  },
  {
    id: 'loss_ended', rung: 'milestone', mode: 'loss', state: 'home_loss', confidence: 'plain',
    tone: 'quiet', kicker: '',
    title: 'Pregnancy tracking has ended',
    line2: 'Your previous data remains private and can be reviewed or deleted from Settings.',
    actions: ['View support resources'], slots: [], status: 'active', order: 13,
  },
]

/** The nine banner items — the canvas' three sets of three. */
export const BANNERS: Banner[] = [
  { id: 'cycle_appetite', phase: 'cycle', mode: 'cycle', focus: 'Nutrition',
    title: 'Why appetite can change before your period', meta: 'Nutrition · 4 min read',
    url: '', status: 'active', order: 0 },
  { id: 'cycle_training_sleep', phase: 'cycle', mode: 'cycle', focus: 'Movement',
    title: 'How to adjust training when sleep is low', meta: 'Movement · 5 min read',
    url: '', status: 'active', order: 1 },
  { id: 'cycle_iron', phase: 'cycle', mode: 'cycle', focus: 'Nutrition',
    title: 'Iron, energy and the days after your period', meta: 'Nutrition · 6 min read',
    url: '', status: 'active', order: 2 },
  { id: 'preg_20_week_scan', phase: 'pregnancy', mode: 'pregnancy', focus: 'Pregnancy',
    title: 'What usually happens at the 20-week scan', meta: 'Pregnancy · 6 min read',
    url: '', status: 'active', order: 3 },
  { id: 'preg_movement', phase: 'pregnancy', mode: 'pregnancy', focus: 'Movement',
    title: 'Movement in the second trimester', meta: 'Movement · 5 min read',
    url: '', status: 'active', order: 4 },
  { id: 'preg_questions', phase: 'pregnancy', mode: 'pregnancy', focus: 'Pregnancy',
    title: 'Questions worth asking at your next appointment', meta: 'Pregnancy · 3 min read',
    url: '', status: 'active', order: 5 },
  { id: 'post_6_week_check', phase: 'postpartum', mode: 'postpartum', focus: 'Recovery',
    title: 'What to prepare for your 6-week check', meta: 'Recovery · 4 min read',
    url: '', status: 'active', order: 6 },
  { id: 'post_sleep', phase: 'postpartum', mode: 'postpartum', focus: 'Recovery',
    title: 'Sleep in fragments: what actually helps', meta: 'Recovery · 5 min read',
    url: '', status: 'active', order: 7 },
  { id: 'post_cycle_return', phase: 'postpartum', mode: 'postpartum', focus: 'Recovery',
    title: 'When your cycle may return', meta: 'Recovery · 4 min read',
    url: '', status: 'active', order: 8 },
]

/** The four nudge rules, each with the PRD's parameter and nothing else.
 *
 *  PRD §Dashboard: period within **two** days, appointment **tomorrow**, a logging gap of
 *  **three** days, a setup step never completed. `withinDays` carries the number where
 *  there is one; the rule that has none carries `null` rather than a made-up default. */
export const NUDGES: Nudge[] = [
  { id: 'period_due', withinDays: 2, trigger: 'periodPredictedWithinDays',
    text: 'Your period is likely to start within two days.',
    action: 'View prediction', status: 'active', order: 0 },
  { id: 'appointment_tomorrow', withinDays: 1, trigger: 'appointmentTomorrow',
    text: 'You have a gynecologist appointment tomorrow at 10:30.',
    action: 'Review questions', status: 'active', order: 1 },
  { id: 'logging_gap', withinDays: 3, trigger: 'noBodySignalsForDays',
    text: 'You haven’t added any body signals recently.',
    sub: 'Logging today may help Eva recognize patterns over time.',
    action: 'Log signals', status: 'active', order: 2 },
  { id: 'nutrition_setup', withinDays: null, trigger: 'nutritionSetupIncomplete',
    text: 'Complete your Nutrition setup to see today’s targets here.',
    action: 'Continue setup', status: 'active', order: 3 },
]

const main = async () => {
  const missing = reviewProblems(REVIEW)
  if (missing.length > 0) {
    console.error(
      `Refusing to seed: the copy has no reviewer (${missing.join(', ')} empty).\n` +
        'Clinical content follows the same review requirement as the rest of the product\n' +
        '(PRD §Dashboard, Other requirements 4). Fill in REVIEW at the top of this file, in a\n' +
        'commit, and run again. There is no flag for this.',
    )
    process.exit(1)
  }

  try {
    await applyContent('templates', TEMPLATES, REVIEW, { rewrite: true })
    await applyContent('banners', BANNERS, REVIEW, { rewrite: true })
    await applyContent('nudges', NUDGES, REVIEW, { rewrite: true })
    console.log(
      `seeded content/: ${TEMPLATES.length} templates, ${BANNERS.length} banners, ${NUDGES.length} nudges`,
    )
  } catch (err) {
    if (err instanceof UnreviewedContentError) {
      console.error(err.message)
      process.exit(1)
    }
    throw err
  }
}

// Importable for its copy without seeding anything — `api/test/content.test.ts` reads the
// three arrays, and a test that re-typed them would pass while the seed said something
// else. Same guard `seed-refdata.ts` uses, and the reason is the same.
if (import.meta.main) await main()

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
 * the words below still get wrong. It used to be true that every row there was a drawing
 * waiting to happen; after #202 it is not, and the two rows left say so themselves.
 */
import {
  applyContent,
  applySignalVocabulary,
  reviewProblems,
  UnreviewedContentError,
  type Banner,
  type Nudge,
  type Review,
  type SignalVocabulary,
  type Template,
} from '../src/content'

/**
 * Who signed this copy off.
 *
 * `source` names the exact canvas state so a reviewer can diff what was signed against what
 * is drawn today rather than trusting a file name. It also names the audit, because since
 * #177 that is part of what is being signed.
 *
 * **It names a pull request rather than a commit, and that is deliberate** (#202). It used
 * to read `@ 0f7cda4`, the commit that last changed the canvas — which worked while the
 * signature only ever followed the drawing. #202 changes the canvas and the seed in one
 * commit, and that commit's SHA cannot be written into the commit it names. A PR number
 * resolves to exactly one merge, and the diff is one click from it.
 *
 * **Not a clinical review**, and the distinction is the whole reason this field is a
 * sentence and not a checkbox. No clinician has read these strings. What was reviewed is
 * that every string matches the canvas verbatim, and — this is the part that moved on
 * 2026-09-17 — **which cards are not yet true of everyone the ladder routes to them**.
 *
 * The 2026-09-16 signature said "no card states something the rules layer has not actually
 * observed about the user". That was false when it was written, and #177 is the issue that
 * established it: `signals_today` read "You logged low energy and a headache today" and was
 * selected for every logged day in the four non-cycle modes and for severe-symptom,
 * low-energy-only and low-mood runs in cycle mode. It was not the only one. The canvas drew
 * these fourteen cards as illustrations — one woman, one day — and D1 routes a wide range of
 * situations into each.
 *
 * ## What is signed here, and what is still owed
 *
 * **Fourteen strings across seven cards carried that fault when #177 was filed. Two remain,
 * on one card.** The audit's `UNTRUE` is the list, with the cases that demonstrate each and
 * what would close it:
 *
 * - #195 took two of them off by narrowing rung 4 to the follicular phase — the one phase
 *   every line of `phase_energy` is true of. A rule change, not a drawing.
 * - **#202 takes ten off by changing the words**: twelve strings across `home_b`, `home_e`,
 *   `home_g`, `home_edu` and `home_flag`, drawn on the canvas first and transcribed here.
 *   That is the half of this signature that had never moved — the file used to say "no
 *   string below changed — none could", and it could, once somebody drew them.
 * - **The two left are `mood_pattern`'s kicker and title**, which say "3 days" while
 *   `lowSignalDays` is #26's to set. They are in a field called `canvasMustDraw` and **they
 *   are not a drawing**: no sentence closes them, because `requirePatternRule` accepts a
 *   dose of 1, where "consecutive days" is false, and imposes no ceiling, where "the last
 *   few days" is. They need a `patternDays` slot — an entry in `SLOTS` and a line in
 *   `patternRung` — or #26 fixing the dose. Both are rule changes, kept out of a signature
 *   on words.
 *
 * **Two of the ten closed by saying less rather than by saying it accurately, and #200 gave
 * them their content back.** `home_e`'s and `home_g`'s titles stopped naming what she logged,
 * because nothing could turn a rating of 1 into "low energy" — `dashboard-rules.ts` holds
 * symptom codes and never labels, by design, and `SLOTS` had no key for one. #200 added the
 * `{signal}` slot, the `VOCABULARY` below (`energy`/`mood`/`sleep`/`fallback`, seeded as
 * `content/vocabulary` behind this same gate), and `resolveSignals` in `today.ts`, which
 * fills the slot from the observed entry — a low rating, a symptom's `refdata/` label, or
 * "body signals". The two titles now read "You logged {signal}", which is true of whatever
 * the rung routes to them. **Not drawn on the canvas**: this is copy authored in this PR and
 * signed here, which the `REVIEW.source` above states rather than pretending it was verbatim.
 *
 * **Three sit in `NOTED`, beside `UNTRUE`**, because no generated input can falsify them: a
 * sentence implying a personal baseline the rule does not hold, a fixed article headline
 * nobody chose, and a card that hard-codes the ≥3-cycle gate C11 reads from configuration
 * (`CYCLE_MIN_CYCLES_FOR_ESTIMATE`, since #181). A fourth — rest offered to everyone who
 * logged anything — went with `home_g`'s line2 in #202. They are not mismatches the audit can
 * demonstrate, and they are not nothing. Read both lists.
 *
 * And read what that file says it does **not** catch, written above `UNTRUE`: it is a ledger,
 * not a gate. It goes red when the list changes, and stays green when a mismatch already on
 * the list becomes reachable by real users — the transition #184 existed to gate, and did,
 * as #195.
 *
 * Signing this is signing both lists: these words, this ladder, these known gaps, and no
 * others.
 *
 * Cards that would need a clinician to stand behind them are still not in this set: the one
 * card that speaks about a pattern reports the user's own logs and declines to interpret
 * them, and the red-flag rung that would carry real clinical weight is inert (`redFlag` is
 * `null` everywhere, D10). #202 closed all three of that card's mismatches — it no longer
 * names one symptom for every code D10 will map, no longer says "today" about a rung that
 * applies no window, and no longer sends every mode to a maternity provider. **What it still
 * does is render `{loggedAt}` as a raw ISO-8601 instant** (`Logged 2026-09-13T08:00:00Z`,
 * where the canvas draws `Logged 14:20`), which the audit is structurally blind to because
 * that string is *true*. Filed as **#201**, and it is on the one card with real clinical
 * weight. docs/LAUNCH.md L7 remains open on its own terms and this does not close it.
 *
 * **Which card reaches anyone is worth knowing before signing.** Today none of them do:
 * `DASHBOARD_PATTERN_*` is not among `deploy-api.yml`'s `--set-env-vars`, so
 * `config.dashboard.pattern` is null in production, rung 2 throws on every call and
 * `GET /me/today` answers 503. The whole surface is still one env var away from existing.
 *
 * When it is thrown, the live set is **three cards, not two — if #204 has landed by then**,
 * and it is open as this is written. As of this commit `today.ts`'s `cycleEstimate()` is
 * hard-coded to "knows nothing", so no cycle rung can fire and `educational` and
 * `signals_today` are between them nearly everything. #204 wires the real `CycleEstimate`
 * from `cycle.ts` into that function, which makes rung 4 reachable and puts `phase_energy`
 * on the surface beside them. The other half of the old sentence does not move: `redFlag` is
 * still `null` in every mode until D10, so rung 1 stays inert either way.
 *
 * That is stated as a condition rather than as a fact because both readings are wrong if it
 * is asserted — before #204 it over-counts the live set, after it, it under-counts.
 *
 * **The practical point of #202 survives it**: `educational` and `signals_today` were both
 * mismatches when #177 was filed and neither is now, and they are the two cards almost
 * everyone would have seen. **The third is worth reading differently.** `phase_energy` is
 * untouched here and its copy is true — but it is true *because #195 narrowed rung 4 to the
 * follicular phase*, the one phase every line of it describes, not because the sentences are
 * true generally. A rule is holding it up. Widen that rung without drawing the per-phase
 * variants and both of its rows come straight back into `UNTRUE`, which is the transition the
 * audit is a ledger for and not a gate against. Narrower still after #203: a woman whose last
 * logged flow day is inside the gap threshold reads as `menstrual` on a morning she has not
 * logged yet, so she falls through to `educational` rather than being told she is likely
 * approaching ovulation.
 *
 * **#190 narrows rung 4's other branch, and no string below moves for it.** `home_c`'s
 * "Your recent cycle lengths vary significantly" was selected for two different answers from
 * C11, and it is true of one: a woman whose counted cycles are all the same length and who
 * missed one period start read it for the six cycles it takes that interval to leave the
 * window. The rung now selects `home_c` for `cycles-vary` alone and the other answer falls
 * through to `educational`, so what is signed here is unchanged words over a narrower ladder
 * — the same shape as #195. The card that would explain the second case ("Eva cannot read one
 * of your recent cycles") is **not written below and must not be**: the canvas has not drawn
 * it, and #177's rule is that where it has not, the honest output is a request. It is not in
 * `UNTRUE` either, because nothing false now renders — there is no mismatch for that file to
 * demonstrate, which is the one way its ledger cannot record a debt. The debt is real and it
 * is filed as an issue instead.
 *
 * Exported so `api/test/content.test.ts` can tell whether the gate is still closed. The
 * case that proves this script has no way past the refusal has to *run* the script, and
 * now that these are filled that would seed whatever project the suite points at — so it
 * skips itself, exactly as it was built to.
 */
export const REVIEW: Review = {
  reviewedBy: 'Nick Romanenko',
  reviewedAt: '2026-09-19',
  source:
    'docs/design/Eva App.dc.html @ #202 — Dashboard rail (CARDS, NUDGES, banners); ' +
    'plus the reachable-subject audit in api/test/dashboard-copy.test.ts (#177); ' +
    '#200 gives home_e/home_g their titles back ("You logged {signal}") and adds the ' +
    'signal vocabulary — copy authored here, not yet drawn on the canvas, signed as #200',
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
    title: 'You logged {signal}',
    line2: 'Your phase is context for what you reported, not a substitute for it.',
    line3: 'Sleep, stress and iron affect daily energy more than cycle phase.',
    actions: ['Review what I logged'], slots: ['cycleDay', 'signal'], status: 'active', order: 1,
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
    line2: 'Log more periods to help estimate your cycle phases more reliably. Until then, no phase is shown.',
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
    kicker: 'Logged · last 24 hours',
    title: 'You logged {signal}',
    line2: 'Eva can see what you logged but not what caused it.',
    actions: ['Review what I logged'], slots: ['signal'], status: 'active', order: 6,
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
    line2: 'Educational content, not personalized insight — no new body signals in the last 24 hours.',
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
    tone: 'flag', kicker: 'Logged {loggedAt}',
    title: 'You logged a symptom that needs medical attention',
    line2: 'Contact your provider or a local urgent care service for guidance. Eva cannot assess this.',
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

/**
 * The signal vocabulary (#200): a stored rating of `1–2` turned into reviewed words.
 *
 * `dashboard-rules.ts` holds ratings as numbers and is text-free by design, so a rating of 2
 * never became "low energy" — which is why `home_e`'s and `home_g`'s titles were closed in
 * #202 by saying *less* ("Your own log comes first") rather than by naming what she logged.
 * These four phrases are that content, back. "Low energy" is a judgement about a number, not
 * a readback of it, so it is copy here and not a literal in the ladder.
 */
export const VOCABULARY: SignalVocabulary = {
  energy: 'low energy',
  mood: 'low mood',
  sleep: 'poor sleep',
  fallback: 'body signals',
}

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
    await applySignalVocabulary(VOCABULARY, REVIEW)
    console.log(
      `seeded content/: ${TEMPLATES.length} templates, ${BANNERS.length} banners, ${NUDGES.length} nudges, signal vocabulary`,
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

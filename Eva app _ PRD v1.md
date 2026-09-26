# **Eva \- the first AI made for women**

*Line-number citations in issues and reviews older than 2026-08-30 may be off by the edits of #69; cite headings.*

## Key concepts

**Eva is an AI Assistant for Every Woman's Prime Era**

For decades, the world has been designed as if men were the default human. Women were excluded from medical research due to potential hormonal fluctuations, office temperatures were calculated using male metabolism, and vehicle safety was tested primarily on male crash-test dummies.

As Caroline Criado Perez shows in *Invisible Women*:

* Standard office temperatures can be around 5°C colder than what is comfortable for women.  
* Female crash-test dummies were introduced in US testing only in 2011, while women are 47% more likely to be seriously injured in comparable crashes.  
* Speech-recognition systems were up to 70% more accurate at understanding male voices.  
* Conditions affecting women have historically received disproportionately little research funding and attention.

**Eva** was created to help close this gap on a personal level. It is an AI assistant that considers each woman's physiology, hormonal cycle, emotional state, habits, and goals.

Eva helps women care for their physical and mental health, plan activity and recovery, build sustainable habits, and achieve their goals more effectively. Instead of fighting their bodies, women learn to understand their unique needs and use them to their advantage.

**Eva's mission is to help every woman achieve her Glow Up, build a more comfortable life, and enter her Prime Era on her own terms.**

## Feature list

| Feature | Description |
| ----- | ----- |
| Onboarding | Superseded (2026-08-23, #3): there are no info screens. Authentication is one screen — Apple, Google, or email and password inline — see §Onboarding and §Sign Up. |
| Sign Up | Three ways to create an account: Apple ID, Google account, email \+ password (#3). The questionnaire is not part of sign-up; its fields live in Profile (#19) — what it collects is listed under §Sign Up. |
| Dashboard | The dashboard has to contain: Shortcuts to main features (action buttons) Banner area with tips and interesting facts (by clicking the user is redirected to blog article / youtube video related to it) Chat shortcut (Eva Chat has its own tab — see §Eva Chat) |
| Calendar | The calendar provides next options: Cycle tracking Sex life tracking Body signals tracking Training tracking Doctor appointments Pregnancy mode (planning, pregnancy, postpartum) |
| Nutrition adviser | A woman can specify her nutritional goals, food preferences, and deficiencies. The coach will advise on the calorie requirements for the expected activity level and cycle phase. |
| Personal trainer | Based on your desired training frequency and goals, the app creates a training program and explains the basic principles and differences of training for women. |
| Mental well-being coach | This personal coaching program helps you understand how to deal with stress, improve concentration, and get quality rest. |
| Blog | The blog is a library of articles that serve as the basis for recommendations. This means the scientific base is transparent and accessible. |
| Notifications | Push notifications, notification centre |
| Settings | Profile (change password, update personal info from questionary, delete account) Language Notifications turn on/off Log out Delete profile |
| Support |  |

## Product frame

Decisions recorded on 2026-08-30 in `docs/reviews/2026-08-30-prd-and-design-review.md` §8 (A1–A15) and written back here by #69. Each subsection names its decision. What is still undecided is listed under Open, not guessed; nothing there may be assumed by an issue or a PR.

### Scope and order

1. Everything in this document is v1 (A1). Nothing is parked, and the website's feature claims stand.  
2. Build order is data first (A13): Auth → Profile → Calendar → Dashboard → Nutrition → Eva Chat → Pregnancy mode → Learn / Personal trainer / Mental well-being coach. Pregnancy mode extends Calendar once the Dashboard exists; Eva Chat lands once it has data to see.

### Markets and language

> **Superseded (2026-08-30, decision A16 — same day, later in the day).** A2 chose the EU
> and the UK. A16 replaces it: launch in the **US and worldwide**, English only, no
> localisation in v1. The consequences are worked through in `docs/LAUNCH.md`. Items 1
> and 4 below are A2's and no longer hold; items 2 and 3 stand.

1. Launch markets are the EU and the UK (A2).  
2. English only at launch. Localisation is planned, not v1. The Language row in Settings lists English until that changes; copy is reviewed for cultural and language variants, never machine-translated (§Dashboard, Tone and framing rules).  
3. Units: metric by default, imperial as a setting.  
4. What follows from the markets: #26 assesses regulation under GDPR, EU MDR and UK MHRA; the food database must cover the EU and the UK (#25); the appointment timeline template (§Phase 2 \- Pregnancy, Appointment schedule) and emergency guidance (§Calendar, Other requirements) are per country.

Under A16:

5. Launch markets are the United States and every App Store storefront Eva is not excluded from; the exclusion list is a decision recorded in `docs/LAUNCH.md`.  
6. Units default from the device locale (imperial for a US locale), with the setting in item 3.  
7. What follows from the markets: #26 assesses regulation under the FDA general wellness policy, the FTC's Health Breach Notification Rule and US state consumer-health-data laws **as well as** GDPR, EU MDR and UK MHRA; the food database must cover the US and have worldwide barcode coverage (#25); the appointment timeline template exists only for countries whose content has been reviewed, with no template elsewhere; emergency guidance is per country with a neutral fallback. Which English variant the copy uses is open (`docs/LAUNCH.md`).

### Age

1. 18 and over (A12). Enforced at date-of-birth entry in the app and server-side in `parseProfile`.  
2. The App Store age rating, the website and the legal copy state 18+. This removes the minors question from #26.

### Monetisation

1. Paid subscription with a trial (A14): everything is behind the one subscription once the trial ends. Sold through StoreKit. The canvas gains a subscription / paywall screen and Settings gains a "Manage subscription" row (§Settings). Privacy policy and terms must cover billing.  
2. Open: trial length, price, and whether entitlement is checked client-side (StoreKit 2 receipts) or server-side (App Store Server API) — see Open below.

### Platform

1. iPhone, portrait only, iOS 18+ (`docs/ARCHITECTURE.md` §1, `mobile/CLAUDE.md`). No other platform is specified.  
2. No HealthKit in v1 (A15): no entitlement, no import of sleep or workouts. Revisit after Calendar logging ships.  
3. Widgets are mentioned under §Sex and §Pregnancy loss and remain unspecified.

### Offline

1. Offline is v1, local store first (A3). The calendar reads from the local store; entries queue and sync over the existing `idempotencyKey` (§Calendar, Edge cases; §Nutrition coach, Edge cases).  
2. The store and the sync queue are an architecture decision, recorded in `docs/ARCHITECTURE.md` before Calendar slice C3 (#11) starts — not in this document.

### Navigation

1. Five tabs (A4): Home · Calendar · Eva Chat · Learn · Profile.  
2. The Nutrition coach, Personal trainer and Mental well-being coach are reached from Dashboard shortcuts, never from a tab (A4; for the Nutrition coach also #25 Q3).

### Push notifications

1. Transport is APNs, sent directly from the API (A9). The app does not link the Firebase iOS SDK.  
2. A notification preview says "Eva has an update" and nothing else. Requirements are in §Notifications.

### Review without counsel or a clinician (A24)

There is no external counsel and no retained clinician (decision A24, 2026-08-30). Every clinical constant, threshold and legal position in this document is decided by the product owner with a **cited source per value**, recorded where the value is used. Wherever this document says "clinician sign-off" or "registered dietitian", read: *sourced, and reviewed by the product owner*. This is the highest-risk decision in the project and is recorded as such, not softened.

### Decided later on 2026-08-30 (third round)

1. English: **US English**, with neutral clinical role names — "your provider", "your doctor" — never GP / OB-GYN / midwife (A17).  
2. Storefronts: **all except China mainland and Russia** (A18).  
3. Third-party requests for health data: **legal process only, the user is notified unless a court forbids it, and a transparency report is published** (A19). The policy is `docs/REQUESTS.md`, published at `/transparency` with the report (twice a year), and stated in one sentence in the app's Privacy & security footer (#91). Permanent deletion of the pregnancy timeline stays a separate, later action (§Pregnancy loss 4).  
4. The Edinburgh Postnatal Depression Scale is **deferred**; the postpartum mood check is a non-scored check-in with a pointer to support resources (A20; supersedes §Phase 3 \- Postpartum, Mood screening 2).  
5. Consent: **one screen, two separate opt-ins** — store my health entries; let trusted providers process them — neither pre-selected, no accept-all, the same everywhere (A21; #86).  
6. Food database: **Open Food Facts + USDA FoodData Central** as the base, one metered commercial fallback; "not found" queues enrichment to Open Food Facts (A22).  
7. **Daily Firestore backups, 30-day retention**, disclosed in the privacy policy (A23).  
8. Subscription: **7-day trial, monthly and yearly tiers, entitlement verified server-side** and stored on `users/{uid}` (A14, follow-up). Prices are set in App Store Connect.

### Decided later on 2026-08-30 (fourth round — the clinical constants, under A24)

Recorded where they apply, each with its source: cycle definition and irregularity (A25, §Predictions in Cycle mode), the prediction method (A26), the fertile window in Cycle mode (A27), qualitative-only nutrition in pregnancy and postpartum (A28, §Cycle phase adjustment), the weight-target floor (A29, §Step 5), the nutrition constants (A30, §Daily targets calculation), disordered eating as self-declared only (A31, §Nutrition Other requirements), and the Dashboard's pattern rule (A32, §Priority ladder). Sources are listed with each; a value that is a product choice rather than a finding says so.

### Decided later on 2026-08-30 (fifth round)

1. The meal score is called **"Meal fit"** (A33; §Nutrition score).  
2. Analytics: **first-party aggregate counts only, no third-party SDK** — event type, never payload, never a stable user id; no analytics or crash SDK that uploads breadcrumbs; crash reports through Apple's opt-in only (A34). A guardrail, not a preference.  
3. Availability target **99.5% a month, RPO 24 hours, RTO 4 hours**, a public status page, a quarterly restore drill; stated in the terms as a target (A35).  
4. Prices: **$9.99 a month, $59.99 a year**, 7-day trial on both, set in App Store Connect (A36).

### Open

Undecided as of 2026-08-30 (after five rounds):

1. The legal texts — privacy policy, consumer-health-data policy, terms, subscription terms — written by the product owner (A24). The request policy (A19) is written: `docs/REQUESTS.md` (#91); its *counsel* markers are unconfirmed under A24, and the entity's name and address for service wait on the entity (`docs/LAUNCH.md` L1)  
2. The per-country tables (emergency numbers, support lines) and the pregnancy-phase content (appointment templates, folic-acid screen)

## Requirements

### Onboarding

> **Superseded by the design canvas (2026-08-23, issue #3).** The canvas
> (`docs/design/Eva App.dc.html`) draws onboarding as a **single screen** — hero, Apple,
> Google, "or continue with email", with email and password inline — and contains no
> science/solution screens. Nick chose the canvas flow over this section. The two
> info screens described in the feature list above are not being built.

### Sign Up

> **Partly superseded (2026-08-23, issue #3).** The three account-creation options stand.
> The questionnaire below is **not** part of sign-up: the canvas places these fields in
> Profile instead. Until a Profile screen exists it still runs as a post-auth step, so the
> requirements below remain accurate about *what* is collected, not *when*.
>
> **Superseded further (2026-08-30, issue #19).** The questionnaire moves to Profile as
> individually editable rows and the post-auth gate is removed; an incomplete profile is
> asked for once, through a dismissible nudge in the Dashboard's nudge slot, whose
> dismissal is stored server-side on `users/{uid}` so it survives reinstall and a second
> device.

The system has to provide 3 options to create account:

* AppleID  
* Google account  
* Email & password

#### User flow

1. The user can see 3 options, AppleID and Google account as primary choice, email+password as secondary.  
2. The system displays a hint "Already have an account? Log in". The user is redirected to log in screen by clicking on that hint.  
3. Once the user selects AppleID the system proposes to create an account, obligatory with the option to hide email.  
4. Once the user selects Google account as auth method, the system displays Google log in screen in web view (no redirects to browser\!)  
5. If the user prefers to create an account using email & password the system has to display 2 inputs.  
6. After account creation by email & password the user receives email with activation link.

#### Edge case

> **Superseded by issue #7 (2026-08-30).** Identity is the provider's `sub` and only
> `sub`; the email address is never used to match accounts. A provider sign-in with an
> unseen `sub` creates a new account even when the address matches an existing one.
> Attaching a second provider to an existing account is a deliberate action the user
> takes from Profile while signed in to the account she wants to keep (see §Settings,
> Manage connected accounts). The cost, stated in #7 so nobody is surprised by it: a user
> with an email/password account who taps Sign in with Apple or Google gets a second
> account until she links them. Auto-linking on a self-asserted address is an
> account-takeover shape, and would not work for Hide My Email relay addresses anyway.

1. If the user who has created an account with email\&password try to sign up with a Google account \- do not create a new one, proceed as log in to the existing profile.

#### Other requirements

1. All validations have to be displayed under the input fields.  
2. The activation link is valid for 24 hours.

#### Profile fields

Decided 2026-08-30 (review §8 A8 and A12). These are the questionnaire's fields wherever they are collected — in Profile, per #19 — and the one canonical list each; the canvas' `settings` and `editProfile` rows and the code are to be unified to it.

1. Date of birth is stored; age is derived from it and never stored. The user must be 18 or over (§Product frame, Age).  
2. Weight and height, as in the feature list.  
3. Goals & lifestyle (multiple choices): Steady energy, Better sleep, Understand my cycle, Build strength, Manage stress, Conceive within a year.  
4. Hormonal medications: Combined pill, Progestogen-only pill, Hormonal IUD, Implant, HRT, None.  
5. Conditions: PCOS, Endometriosis, Thyroid condition, Anaemia, Diabetes, Coeliac disease, Food allergies, None of these.  
6. Activity band, one of four: Mostly sitting, Lightly active, Active, Very active — the bands in `mobile/Eva/Onboarding/OnboardingModel.swift`. §Nutrition coach maps them onto its activity factors.  
7. Preferred sports: Strength, Running, Yoga, Pilates, Cycling, Swimming, Dancing, Walking — the list in the same file.  
8. Optional, asked once, never inferred (A31): "Have you been treated for disordered eating?" Yes turns the nutrition coach's qualitative mode on (§Nutrition coach, Other requirements 7–8).

This is a schema change on `users/{uid}` — `profile.age` becomes `profile.dateOfBirth`, medications become an enumeration, conditions gain entries — and falls under the always-human gate in `docs/AUTONOMY.md`. #19 builds to this list; `parseProfile` re-derives its ranges from date of birth.

### Log in

#### User flow

1. The user is landed to log in screen. The system displays all 3 log in options \+ option to restore password.  
2. Restore password flow:  
   1. Send email with link  
   2. Disactivate old one  
   3. Let the user create new password

### Calendar

The calendar operates in one of four modes. Cycle is the default; the other three are phases of Pregnancy mode and are described in the Pregnancy mode section.

1. Cycle (default)  
2. Planning  
3. Pregnancy  
4. Postpartum

The mode determines which events are offered and which predictions are shown. The calendar view, day cells, day detail and logging rules are identical in every mode.

#### View

> **Superseded in part (2026-08-30; settled in Calendar C1, issue #23, and recorded in
> `docs/ARCHITECTURE.md` §4).** Item 4 below: future dates accept **appointments only**.
> Any other event type on a future date is refused by the API with
> `FUTURE_DATE_NOT_ALLOWED`. Predictions on future dates are unchanged.

1. Month grid, current month, today highlighted  
2. Swipe left/right between months; tap header to jump to month/year picker  
3. Date number \+ up to 4 event indicators  
4. Future dates are selectable but logging is disabled beyond today. Predicted events (period, fertile window) are shown on future dates as outlines.  
5. In Pregnancy mode the week number (e.g. "w14") is displayed on each week row.

#### Day cell indicators

Each event type has a fixed colour and shape so a month can be read at a glance:

1. Menstrual cycle — filled background tint on the cell (period days form a continuous band); intensity of tint maps to flow level  
2. Sex — small dot, bottom-left  
3. Body signal — small dot, bottom-centre  
4. Sport — small dot, bottom-right  
5. Doctor appointment — small icon, top-right  
6. Predicted period / fertile window — dashed outline or light shading, visually distinct from logged data

Multiple entries of the same type on one day collapse into a single indicator.

All indicators carry a non-colour cue (shape or position) so the month is readable without relying on colour.

#### Log button

1. Floating action button, bottom right, persistent above the calendar  
2. Tap opens the event type picker  
3. The button logs into the currently selected day. If no day is selected, it defaults to today.  
4. The picker header always displays the target date with a tap-to-change control, so an entry can never be filed to the wrong day silently.

#### Day detail

Tapping a day opens a bottom sheet listing that day's entries (time, type, summary). Each row supports edit and delete (swipe or long-press). The sheet has its own "Add entry" affordance so a user who is already inspecting a past day can log into it directly.

#### Logging flow

##### Rules that apply to every flow

1. Each step is a full-width bottom sheet with large tap targets; back arrow returns to the previous step, swipe-down cancels.  
2. A step with a single mandatory choice auto-advances on selection (no "Next" button). Steps with multi-select or numeric input show an explicit Save.  
3. Every entry stores a timestamp (defaults to now for today, to 12:00 for backdated entries) and is editable.  
4. Optional note field (free text, 280 chars) available on the final step of every flow via an "Add note" link — collapsed by default.  
5. Multiple entries of the same type per day are allowed (e.g. two workouts, morning and evening energy). Exceptions: only one flow level per day and only one body signals entry per day — see the relevant sections.  
6. Save shows a brief confirmation toast with Undo.  
7. No event may cost more than 2 screens to log.

##### Event type picker

The picker displays only the events available in the current mode:

| Event | Cycle | Planning | Pregnancy | Postpartum |
| ----- | ----- | ----- | ----- | ----- |
| Menstrual cycle | yes | yes | — | yes |
| Sex | yes | yes | yes | yes |
| Body signals | yes | yes | yes | yes |
| Sport | yes | yes | yes | yes |
| Doctor appointment | yes | yes | yes | yes |
| Ovulation | — | yes | — | — |
| Positive test | yes | yes | — | — |
| Delivery date | — | — | yes | — |
| Feeding | — | — | — | yes |

##### Menstrual cycle

> **Superseded in part (2026-08-30, issue #23).** Option 1 below: spotting is a separate
> marker, not a flow level. A spotting day does not start a period. What "cycle day N"
> means across spotting days is not yet defined; it belongs with the prediction
> constants routed to #26 (§Predictions in Cycle mode).

Options:

1. Spotting  
2. Has flow:  
   1. Light  
   2. Medium  
   3. Heavy

After the flow level, the Body signals chip grid (Zone 2\) is shown so symptoms can be logged in the same flow. Chips selected here are written to that day's Body signals entry, not to a separate record — the app has one symptom vocabulary.

Only one flow level per day. Logging a second replaces the first, with a confirmation.

Period end is marked by the first day with no flow logged. The user can also mark it explicitly from the day detail sheet.

Requirement (2026-08-30, review H5): the explicit period-end mark needs its own stored field in the cycle data model. Inference from the first day with no flow logged is the default; the explicit mark from day detail is a separate, stored fact and must not be represented by the absence of a flow entry. **Modelled 2026-09-17 (#75).** `CyclePayload`'s flow arm carries `periodEnd?: true`, on the cycle entry of the last day *with* flow; it may not sit on a spotting day or on an entry with no flow level. **Resolved 2026-09-17 (#186):** flow logged within the period-gap constant of a mark means the period had not ended and the mark is stale; flow at or beyond it starts a new period and the mark stands. The cycle maths reads the field for that decision alone — never as an end date, a period length or a cycle length (`docs/ARCHITECTURE.md` §4).

##### Sex

> **Confirmed against the canvas (2026-08-30, decision A7; Calendar C10 in #11).** The
> sheet with collapsed "Add details" described below stands; the canvas' one-tap toast is
> to be redrawn to it. The stored payload is `protection` (protected / unprotected / other)
> and `type` (solo / partnered), both optional.

Single confirm step: sheet shows the date and a large Log button. No mandatory options — as specified.

Optional, collapsed behind "Add details" (do not show by default):

* Protection: protected / unprotected / other  
* Type: solo / partnered

Privacy: this event type is the most sensitive in the app. Requirements:

1. Entries are visible only inside the app (never in notification previews, widgets, or exports unless explicitly opted in)  
2. Indicator on the calendar is a neutral dot with no label until the day is opened  
3. Consider an app-level setting to hide the Sex event type entirely for users who don't want it.

##### Body signals

One screen, one Save. No drill-down: the chip is the value.

Zone 1 — three scales, always visible, 5-point rating with emoji. All three are skippable and nothing is pre-selected.

1. Energy  
2. Mood  
3. Sleep

> **Superseded (2026-08-30, issue #24).** The Zone 2 lists below were rewritten to the
> shipped vocabulary in `api/scripts/seed-refdata.ts`; the catalogue itself lives in
> Firestore (Other requirements, item 1), so labels may be edited there while codes are
> permanent. "Libido changes" is retired: one `libido` chip carries the direction as a
> low / high value, the way `discharge` carries its type. Discharge keeps its value
> picker. This also resolves the old "14 chips, maximum 12 visible" contradiction.

Zone 2 — optional, multi-select chip grid. Fourteen primary chips, visible at once:

1. Bloating (`bloating`)  
2. Cramps (`cramps`)  
3. Headache (`headache`)  
4. Nausea (`nausea`)  
5. Breast tenderness (`breast-tenderness`)  
6. Back pain (`back-pain`)  
7. Acne / breakout (`acne`)  
8. Cravings (`cravings`)  
9. Anxious (`anxious`)  
10. Stressed (`stressed`)  
11. Brain fog (`brain-fog`)  
12. Poor appetite (`poor-appetite`)  
13. Heavy appetite (`heavy-appetite`)  
14. Libido (`libido`) — carries a value, low / high

Requirements:

1. The 14 primary chips are visible at once. Seven more sit behind "More…": Dizziness (`dizziness`), Hot flashes (`hot-flashes`), Constipation (`constipation`), Loose stool (`loose-stool`), Insomnia (`insomnia`), Discharge (`discharge`), Itching (`itching`).  
2. Chip order adapts: chips logged in the last 7 days float up, then the rest are weighted by cycle phase (luteal surfaces bloating and cravings, menstrual surfaces cramps and back pain).  
3. A chip logged 3 times is automatically pinned into the visible grid.  
4. Second tap on Cramps, Headache or Nausea marks it as severe (chip fills darker). No extra screen.  
5. One Body signals entry per day. Re-opening the sheet loads the existing entry for editing and never creates a second one.  
6. Two chips carry a value, and a value is a category separate from severity: Discharge keeps its value picker — dry / sticky / creamy / watery / egg-white; Libido carries low / high.

The chip vocabulary is swapped by mode. Pregnancy and Postpartum sets are listed in the Pregnancy mode section.

##### Sport

Options:

1. Walking  
2. Running  
3. Cycling  
4. Swimming  
5. Strength training  
6. HIIT  
7. Yoga  
8. Pilates  
9. Dance  
10. Hiking  
11. Rowing  
12. Climbing  
13. Tennis  
14. Padel  
15. Team sport  
16. Martial arts / boxing  
17. Stretching & mobility  
18. Other

Duration:

1. Quick chips: 15 · 30 · 45 · 60 · 90 min  
2. Plus a custom stepper (5-minute increments, 5–300 min)  
3. Required

Intensity (single select, required):

1. Light \- Easy pace, could hold a conversation  
2. Medium \- Working, breathing harder, can still talk in short sentences  
3. Hard \- Near maximum, can't talk

The intensity descriptions must be displayed under the labels, not only in the design. Without them the value is not comparable between weeks.

Recently used activities are pinned to the top of the list. "Other" reveals a free-text field.

##### Doctor appointment

Available in every mode.

Fields:

1. Date & time — required  
2. Type — optional: Scan / Midwife / GP / Gynaecologist / Obstetrician / Blood test / Glucose test / Other  
3. Notes — free text, no 280-char limit. This is where results and instructions are written down.  
4. Reminder — optional, default 1 day before. Requires Notifications (see §Notifications).

Questions list:

1. The user can add questions to the next upcoming appointment at any time from the day detail or the appointment itself.  
2. On the appointment day the questions are surfaced as a list she can open in the consulting room.  
3. Eva can help phrase or expand a question from the chat. Requires Eva Chat (see §Eva Chat).

#### Predictions in Cycle mode

Decided 2026-08-30 (A11 routed the constants; A25–A27 set them, under A24, with sources). These are the initial values of the config-driven constants that Calendar slice C11 (#11) reads; the code fails loudly if any is unset, and none is hard-coded.

1. **A counted cycle** runs from a first flow day to the next first flow day, both logged as flow. A spotting day never starts a cycle (#23). A cycle is counted only if it is **21–45 days** long; outside that range it is excluded from estimates and shown as "unusual length" in Cycle history, never silently dropped. **Decided 2026-09-17 (#186), because a first flow day depends on it:** two or more consecutive days with nothing logged separate two periods, and one does not — so a period logged 1, 2, 4, 5 is one period starting on day 1 rather than two (#180). Config-driven like the rest (`CYCLE_MIN_PERIOD_GAP_DAYS`, initially 2), and a data-interpretation threshold rather than a clinical claim: it decides how logged days are grouped, not what the grouping means for her health.  
2. **Irregular** means the shortest-to-longest variation over the last 6 counted cycles exceeds the FIGO band for the user's age: more than 9 days at 18–25, more than 7 days at 26–41, more than 9 days at 42 and over. *Source: FIGO AUB System 1 — Munro MG et al., Int J Gynecol Obstet 2018;143:393–408. This is the "7–9 days" §Phase 1 already cites.*  
3. **Next period** = the **median** of the last 6 counted cycles, applied from the last first flow day; shown only with **3 or more** counted cycles (§Dashboard, Confidence and cold start 2). Ovulation = next period − 14 days; fertile window = ovulation − 5 through ovulation + 1; peak = the two days before ovulation and ovulation day (§Phase 1 \- Planning). *Source: the fixed-luteal calendar convention — Wilcox AJ, Dunson D, Baird DD, BMJ 2000;321:1259.*  
4. **The fertile window is shown in Cycle mode** (A27), under the same gates as Planning: withheld below 3 counted cycles or when irregular; a wide band at 3–5 cycles, a tighter band at 6 or more. "Not a contraceptive method" appears on the calendar legend and in Cycle history, not only in Planning.  
5. Predictions are recomputed on every edit to a flow entry (§Edge cases 6) and shown as outlines on future dates (§View); the Today card takes the same confidence class (§Dashboard).  
6. What "cycle day N" means across spotting days: the count starts at the first flow day of the current counted cycle; spotting days before it belong to the previous cycle.

#### Pregnancy mode

The two sections that follow this one — Edge cases and Other requirements — are calendar-wide, not part of Pregnancy mode; they sit at the same heading level as this section and apply in every mode.

Pregnancy mode is one switch with three phases. The phases advance automatically on the triggering event — the user never selects a phase from a menu.

##### Turning it on

> **Confirmed against the canvas (2026-08-30, decision A6; closes #11 Q1).** Mode entry is
> Settings only, as item 1 says. The calendar shows a read-only label of the current mode
> and has no mode-switcher control; the canvas' four-way segmented control is removed, and
> cycle-only Calendar slices ship no control. The one-time dismissible prompt in item 1
> stands and still needs drawing.

1. Entry point: Settings → Pregnancy mode. Also offered once on the calendar as a dismissible prompt, never repeated after dismissal.  
2. On activation the system asks one question: "Where are you now?"  
   1. I'm trying to conceive → Planning phase  
   2. I'm already pregnant → straight to the confirmation flow, skipping Planning  
3. The user can switch the mode off from Settings at any time, from any phase, returning to Cycle mode.  
4. Cycle history is never deleted when the mode changes. It is hidden while irrelevant and restored on return to Cycle mode.  
5. All phase transitions are reversible.  
6. The mode is stored as a dated state on a timeline, not as a flag on the profile. Multiple pregnancies over the life of the account must all be preserved.

##### Phase 1 \- Planning

On entering Planning the system offers one skippable screen with pre-conception basics, including folic acid, with an optional daily reminder. It is shown once and never repeated.

Ovulation window

The system calculates and displays a fertile window on the calendar:

1. Ovulation day ≈ next predicted period − 14 days  
2. Fertile window \= ovulation − 5 days through ovulation \+ 1 day  
3. Peak days \= the 2 days before ovulation and ovulation day

Confidence rules:

1. Fewer than 3 logged cycles — no window is shown. The system displays what is needed instead: "Log 2 more cycles and Eva can estimate your fertile days."  
2. 3–5 cycles — the window is displayed as a wide band with visible uncertainty.  
3. 6 or more regular cycles — the window is displayed as a tighter band.  
4. If cycle length varies by more than 7–9 days, no window is shown and the system says so plainly, then points to the inputs that would improve it.  
5. A confident window must never be drawn over irregular data.

The system must display, at the point of use and not only in the T\&Cs, that the fertile window is not a contraceptive method.

Ovulation event

Available in Planning only. One step:

1. Ovulation test — Positive / Negative  
2. Ovulation signs — Ovulation pain / Egg-white discharge

Requirements:

1. A positive test must be reachable in one tap from the event picker. It is the highest-value input in this phase.  
2. A positive test moves that cycle's predicted ovulation to match, updates the displayed window immediately, and adjusts future predictions.

Sex logging in Planning

The system may display, passively, whether logged sex fell inside the fertile window ("You logged sex on 2 of your peak days"). It must never instruct, score, or state what was missed.

Cycles trying counter

1. The system counts cycles since Planning was switched on.  
2. At 12 cycles (user under 35\) or 6 cycles (35 and over) the system shows one gentle, dismissible note that this is a reasonable point to speak to a doctor about fertility.  
3. Shown once per threshold. Never repeated, never escalated.

Notification tone in Planning

No countdowns to a test date, no "Did you get pregnant?" prompts, nothing celebratory or expectant. A quiet fertile-window heads-up is the only proactive notification in this phase.

##### Positive test and confirmation

Two separate events.

1. Positive test — marks the day. Does not advance the phase.  
2. Pregnancy confirmed — advances to Pregnancy phase.

Both are reversible. Undoing a positive test must be as quiet as the loss flow: one tap, no questions.

Dating on confirmation. Gestational age is counted from the first day of the last menstrual period, not from the positive test and not from conception. A woman testing positive on the day of a missed period is already about 4 weeks pregnant. The system must:

1. Use the logged LMP from cycle history where available  
2. Ask for the LMP where it is not  
3. Offer "my doctor gave me a due date" as a direct alternative that bypasses the calculation  
4. Offer an IVF path: transfer date \+ (280 − embryo age). A day-5 blastocyst transfer gives EDD \= transfer \+ 261 days.

##### Phase 2 \- Pregnancy

Weeks counter

1. Displayed as "Week 12 · Day 3". Weeks and days, not weeks alone.  
2. Trimester and days remaining to the estimated due date are displayed alongside.  
3. The progress display is understated. No large celebratory progress bar.  
4. The dating method in use (LMP / ultrasound / IVF / doctor-provided) is visible and editable at all times. A date provided by a clinician always overrides the app's calculation.  
5. Cycle predictions are hidden for the duration of this phase.

Due date

1. Estimated due date \= LMP \+ 280 days, or the ultrasound / IVF / doctor-provided date.  
2. Always labelled "estimated".  
3. Displayed as a range alongside the single date, since most babies arrive within roughly two weeks either side.

Body signals in Pregnancy

Zone 1 is unchanged. Zone 2 chips are swapped:

1. Nausea  
2. Vomiting  
3. Fatigue  
4. Heartburn  
5. Constipation  
6. Back pain  
7. Swelling  
8. Cramping  
9. Round ligament pain  
10. Braxton Hicks  
11. Insomnia  
12. Food aversions

Behind "More…": dizziness, headache, pelvic pain, reflux, shortness of breath, leg cramps, itching, discharge changes, bleeding, reduced movement.

Bleeding, severe itching, severe headache and reduced movement are red-flag triggers. Selecting them must surface the escalation card described in Other requirements, not merely record a data point.

Appointment schedule

On entering the Pregnancy phase the system offers to pre-populate the standard appointment timeline for the user's region (dating scan, 12-week, 20-week anomaly scan, glucose test) as unconfirmed placeholders she can edit or delete. The template is server-configurable per region.

##### Pregnancy loss

Requirements:

1. Entry point is in Settings under Pregnancy mode, worded neutrally ("End pregnancy tracking"). It is never placed adjacent to celebratory content and is never prominent.  
2. One tap. No confirmation form, no "how did it end?" question, no reason required.  
3. All pregnancy notifications, widgets, badges, week counters and content pushes stop immediately, including anything already queued. Not within 24 hours — immediately.  
4. Pregnancy data is hidden, not deleted. Deletion is offered separately, later, without pressure.  
5. One quiet, permanently dismissible line offering support resources. Offered, never pushed.  
6. The system never asks whether she is trying again. Not then, not after 30 days, not at any point unprompted.  
7. Cycle tracking resumes only when the user chooses. When it does, cycle predictions reset rather than resume.  
8. Available from the positive test event onwards, including before clinical confirmation.  
9. The same flow serves miscarriage, stillbirth, termination and termination for medical reasons. The system must never need to know which.

##### Delivery

1. Delivery date event advances the mode to Postpartum and becomes day 0 for postpartum tracking.  
2. Optional and collapsed: time, birth type (vaginal / assisted / caesarean), child's name.  
3. Postpartum phase must be fully functional with none of the optional fields completed.

##### Phase 3 \- Postpartum

Feeding

Feeding is a dedicated event, not a Sport activity. A newborn feeds 8–12 times a day, so the flow is optimised for one-handed repetition rather than completeness.

1. Entry point is a quick-action button on the calendar screen during Postpartum phase, not the event picker.  
2. Breast: start / stop timer, one tap each, with a left / right toggle.  
3. Pump: duration and volume.  
4. Formula: volume.  
5. Manual entry for feeds logged after the fact, which will be the majority.  
6. No streaks, no goals, no targets, no comparison to averages. Mixed and formula feeding are presented as equal options, not fallbacks.

Body signals in Postpartum

Zone 1 unchanged. Zone 2 chips are swapped:

1. Bleeding  
2. Pain  
3. Stitches / incision  
4. Breast pain  
5. Back pain  
6. Headache  
7. Fatigue  
8. Anxious  
9. Low mood  
10. Overwhelmed  
11. Night sweats  
12. Hair loss

Return of cycle

1. Cycle tracking resumes automatically when a period is logged.  
2. Predictions must degrade honestly while breastfeeding: the system states that cycles are often unpredictable while breastfeeding rather than displaying a confident date.  
3. The postpartum phase ends when the user switches the mode off. It does not end automatically.

Mood screening

> **Superseded in part (2026-08-30, decision A20).** Item 2: the EPDS is **not** implemented in
> v1. The mood check is a non-scored check-in — a plain question and a pointer to support
> resources — with no threshold and no escalation logic. A validated screening instrument
> with an escalation path is the feature closest to clinical decision support under FDA's
> 2026 general-wellness guidance (`docs/LAUNCH.md` §1.1), and there is no clinician to sign
> it off (A24).

1. The system offers a mood check at approximately 6 weeks and periodically after.  
2. If the Edinburgh Postnatal Depression Scale is implemented, item 10 covers self-harm and requires a defined escalation path, not only a score.

#### Edge cases

> **Superseded in part (2026-08-30; settled in Calendar C1, issue #23, and recorded in
> `docs/ARCHITECTURE.md` §4).** Item 2 below: a future date accepts **appointments only**;
> the API refuses every other type with `FUTURE_DATE_NOT_ALLOWED`. A tapped future day
> still shows predictions.

1. Backdating is allowed for any past date, capped at 12 months by default.  
2. Logging on future dates is disabled. Tapping a future date shows predictions only.  
3. Deleting an entry is a soft delete, recoverable for 30 days &mdash; for as long as the
   entry has not been superseded. Re-logging a day replaces the deleted entry for the types
   that hold one per day (`cycle`, `bodySignals`), and Undo is not offered once it has.  
4. Full logging works offline. Entries queue and sync; the calendar reads from the local store.  
5. On timezone change an entry keeps the local date it was logged on. Nothing is shifted retroactively.  
6. Editing a past period day recalculates predictions immediately.  
7. A second Body signals entry on the same day loads the existing entry for editing.  
8. Chips selected inside the menstrual cycle flow are written to that day's Body signals entry, creating it if absent.  
9. First-run empty state: calendar with a pointer to the Log button and the prompt "Log your first period to start predictions."  
10. A user who is already pregnant on sign-up must be able to reach the Pregnancy phase without passing through Planning.

#### Other requirements

1. All option lists (symptom chips, sport activities, appointment types) are server-configurable reference data, not hardcoded in the client. New options must ship without an app release.  
2. Symptom chips are stored against a single shared vocabulary regardless of which flow they were logged from.  
3. Body signals entries are unique per user per day and are upserted. Cycle, Sex, Sport, Appointment and Feeding entries may repeat within a day.  
4. Entries created by Eva from chat are marked as such so they can be identified and reverted. Requires Eva Chat (see §Eva Chat).  
5. Red-flag escalation is deterministic and bypasses the model entirely. Triggers: vaginal bleeding in pregnancy, severe or persistent headache with visual changes, reduced fetal movement, severe itching especially of palms and soles, fluid leaking, regular contractions before 37 weeks, fever, persistent vomiting with inability to keep fluids down, calf pain or swelling. The escalation card directs the user to contact her provider.  
6. Eva never diagnoses and never reassures. Acceptable: "that's common in the second trimester, and here's when to call someone." Not acceptable: "you're fine."  
7. Emergency guidance is region-aware.  
8. All medical content requires clinician sign-off and a documented review cycle.  
9. Regulatory scope must be assessed before implementation of conversational symptom interpretation. Symptom logging is out of scope for medical device regulation; symptom interpretation may not be.  
10. Accessibility: every option chip has an accessible label, and rating scales are announced as "2 of 5".

### Nutrition coach

The adviser gives no advice until the setup flow is complete. Nothing is calculated, displayed or suggested from partial data.

The feature has four parts:

1. Setup flow — collects goal, focus areas, meal pattern and body metrics  
2. Daily targets — calories and macronutrient split, recalculated by cycle phase  
3. Scanner — photo, barcode or manual entry, returning nutrition values and a score  
4. Chat — open questions about food, planning and how to feel better

#### Setup flow

Five steps, one screen each, with a progress indicator. Back navigation is allowed at every step. The flow can be resumed if abandoned.

##### Step 1 \- Goal

Single select, required:

1. Lose weight  
2. Gain weight  
3. Build muscle  
4. Maintain my weight  
5. Eat better without changing my weight

Options 4 and 5 must be present and must be as visually prominent as the others. A large share of women want to change how they eat without pursuing weight change at all, and an adviser that treats weight change as the only valid goal excludes them.

##### Step 2 \- Focus areas

Multi-select, maximum 3, optional:

1. Eat more vegetables and fibre  
2. Eat less fast food and ultra-processed food  
3. Fight iron deficiency anaemia  
4. Eat more protein  
5. Cut down on sugar  
6. Eat more regularly, stop skipping meals  
7. Drink more water  
8. Reduce caffeine  
9. Reduce alcohol  
10. Support bone health (calcium and vitamin D)  
11. Reduce bloating, improve digestion  
12. Manage PMS cravings  
13. Eat enough around my period  
14. Reduce salt  
15. Balance a vegetarian or vegan diet  
16. Improve energy, reduce afternoon crashes  
17. Support skin

In Pregnancy mode, item 18 "Support pregnancy nutrition" is added and items relating to weight reduction are removed.

The 3-item cap is deliberate. Focus areas drive the wording of every note the adviser produces; with no cap the advice becomes generic.

##### Step 3 \- Meal pattern

1. Meals per day: 2 / 3 / 4 / 5  
2. Snacks: yes / no  
3. Optional: usual times for each meal, used for reminders and for spacing advice. Reminders require Notifications (see §Notifications).

##### Step 4 \- Body metrics

1. Height and current weight are pre-filled from the Sign Up questionary. The user confirms or corrects them.  
2. Age and activity level are also taken from Sign Up and are not asked again.  
3. Activity level is refined automatically from Sport events logged in the Calendar over the previous 4 weeks. Where logged activity disagrees with the declared lifestyle, logged activity wins.  
4. Units follow the profile setting (kg/cm or lb/ft).

The system must not re-ask anything Sign Up already collected. It shows the stored value for confirmation instead.

##### Step 5 \- Target weight

Shown only for goals 1, 2 and 3\. Skipped entirely for goals 4 and 5\.

1. The user enters a target weight.  
2. The system displays the implied timeline at a safe rate of change.  
3. The system displays the resulting daily calorie target before the user confirms.

Guardrails, applied before the target is accepted:

1. A target below BMI 18.5 is not accepted. The system explains why and offers the lowest target it will support. *Decided 2026-08-30 (A29): 18.5 stands — the WHO underweight threshold — and a single plan may not target below the current weight minus 15%; when she reaches it she can set a new plan. The 15% cap is a product choice, not a finding.*  
2. Rate of weight loss is capped at approximately 0.5 kg per week, or 1% of body weight per week, whichever is lower.  
3. The calculated calorie target is never set below the user's basal metabolic rate.  
4. An absolute floor of 1200 kcal applies. If the maths produces less, the timeline is extended instead of lowering the target further.  
5. Weight-change goals are unavailable in Pregnancy phase, and unavailable in Postpartum phase for the first 6 weeks after delivery.

#### Daily targets calculation

##### **Calories**

> **Superseded in part (2026-08-30, issue #25 Q4).** Item 2 below: the profile stores four
> activity bands (Mostly sitting, Lightly active, Active, Very active — see §Sign Up), and
> they map one-to-one onto four factors; "Extremely active" is dropped. Nothing is
> invented and the questionnaire does not change. The cost, stated in #25 so it is not
> rediscovered: a genuinely very active user is under-fed by the model — the safer
> direction to be wrong in a product with this eating-disorder-risk profile, but still
> wrong, and the reason to revisit if the band ever gains a source.

1. Basal metabolic rate uses Mifflin-St Jeor for women: BMR \= (10 × weight in kg) \+ (6.25 × height in cm) − (5 × age) − 161  
2. Total daily energy expenditure \= BMR × activity factor:  
   1. Sedentary — 1.2  
   2. Lightly active — 1.375  
   3. Moderately active — 1.55  
   4. Very active — 1.725  
   5. Extremely active — 1.9 *(dropped, #25 Q4; the four bands map to 1.2 / 1.375 / 1.55 / 1.725 — Mifflin MD et al., Am J Clin Nutr 1990;51:241–7)*  
3. Goal adjustment applied to TDEE:  
   1. Lose weight — minus 15 to 20% *(A30: −15%, the safer end of the range; a product choice)*  
   2. Maintain / eat better — no adjustment  
   3. Gain weight — plus 10 to 15%  
   4. Build muscle — plus 5 to 10%  
4. The result is clamped by the guardrails in Step 5\.

##### Macronutrients

1. Protein is set first, by body weight:  
   1. Lose weight — 1.6 to 2.0 g per kg *(A30: 1.6)*  
   2. Build muscle — 1.6 to 2.2 g per kg *(A30: 1.8)*  
   3. All other goals — 1.2 to 1.6 g per kg *(A30: 1.2)* — *within Phillips SM & Van Loon LJC, J Sports Sci 2011;29(S1):S29–38 and the ISSN position stand, Jäger R et al., JISSN 2017;14:20*  
2. Fat is set second, and must not fall below 20% of total calories. This is a hard floor, not a default. Sustained low fat intake is associated with menstrual disruption, and an adviser built for women must not produce a plan that causes it.  
3. Carbohydrate is the remainder.  
4. Fibre target is set at 25–30 g per day, and is raised when focus area 1 or 11 is selected. *(A30: 25 g, from the DGA 2020–2025 rule of 14 g per 1,000 kcal at ~1,800 kcal; raised to 30 g when focus area 1 or 11 is selected.)*

##### Cycle phase adjustment

This is the part that distinguishes Eva from a generic calorie tracker and it must not be dropped for scope.

1. In the luteal phase the calorie target is raised by approximately 5% (typically 100–250 kcal), reflecting the increase in resting metabolic rate.  
2. During menstruation, if focus area 3 is selected or anaemia was declared at Sign Up, iron-rich foods are prioritised in suggestions.  
3. The daily target displayed in the UI is the phase-adjusted one. The adjustment is explained in one line, not hidden.  
4. In Planning, Pregnancy and Postpartum modes the phase adjustment is replaced by the mode adjustment: pregnancy adds roughly 340 kcal in the second trimester and 450 in the third, and breastfeeding adds roughly 330–500 kcal.

> **Superseded (2026-08-30, decision A28).** While Pregnancy Mode is on, and for the first six
> weeks postpartum, the coach shows **no calorie or macronutrient numbers at all** — only
> qualitative guidance: meal composition, regularity, hydration, and the "not eating for two"
> framing. Weight-change goals stay paused (Step 5 guardrail 5). A numeric energy
> prescription in pregnancy is the feature closest to guiding clinical management under
> FDA's 2026 general-wellness guidance (`docs/LAUNCH.md` §1.1), and there is no clinician to
> sign it off (A24). The luteal adjustment (item 1) is unaffected. Planning mode keeps
> numbers.

The intent is that a woman eating more in her luteal phase sees her target move to meet her, rather than seeing herself fail against a flat number. This single behaviour is the strongest argument for the feature existing.

##### Recalculation triggers

Targets are recalculated when:

1. Weight is updated  
2. Goal or target weight changes  
3. Cycle phase changes  
4. Calendar mode changes  
5. Logged activity over 4 weeks shifts the activity factor by one band

The user is notified when the target changes and told why, in one sentence.

#### Scanner

##### Input methods

1. Take a photo  
2. Upload an existing photo  
3. Scan a barcode  
4. Search a food database by name  
5. Quick-add from favourites and previously logged meals

Barcode and search are not optional extras. Photo recognition is the least accurate of the methods, and packaged food is most reliably identified by its barcode.

##### Recognition

1. Photo input returns the most likely dish, plus alternatives the user can switch to in one tap.  
2. Barcode input returns the product from the food database.  
3. The system always returns an editable portion size. Portion estimation from a photo is the largest source of error in the whole feature and must never be presented as settled.  
4. Where confidence is low the system says so and asks the user to confirm rather than presenting a number as fact.  
5. If nothing is recognised, the system falls back to search rather than failing.

##### Output

For every scan the system displays:

1. Calories  
2. Carbohydrates, fat, protein in grams  
3. Fibre  
4. Nutrition score  
5. The note described below

Presentation rules:

1. Calories are rounded to the nearest 10 and labelled as an estimate. Displaying "487 kcal" implies a precision the method does not have.  
2. Every value is editable by the user, and edits are remembered for that dish.  
3. The scan can be saved to a meal slot (breakfast, lunch, dinner, snack) or discarded.

#### Nutrition score

> **Superseded in part (2026-08-30, issue #25 Q1).** The score is shown, but under a
> non-judgmental name that is not yet chosen — "Nutrition score" here and "Fit" on the
> canvas are both placeholders, and a name that reads as a grade is the thing being
> avoided. It ships only after the clinical sign-off in #26 has landed, not alongside it.
> The composition and requirements below are not addressed by that decision.
> **Name decided 2026-08-30 (A33): "Meal fit".**

A 0–100 score shown per scanned meal, composed of four parts:

1. Food quality (40%) — fibre, protein density, micronutrient content, added sugar, sodium, saturated fat, degree of processing  
2. Goal fit (30%) — how the meal fits the remaining calorie and macronutrient budget for the day, given the user's goal  
3. Focus area fit (20%) — how the meal serves the focus areas selected in Step 2\. A meal high in iron scores strongly here for a user who selected focus area 3\.  
4. Cycle phase fit (10%) — how the meal suits the current phase

Requirements:

1. The score is contextual, not absolute. The same food scores differently for different users, and differently for the same user at different times of day and cycle phase. The UI must make this obvious, otherwise users will compare scores as if they were food ratings.  
2. The breakdown is always available in one tap. A score with no explanation is not usable advice.  
3. No food is labelled bad, unhealthy, junk, or a cheat. A low score is displayed neutrally and paired with what would raise it, never with disapproval.  
4. No red colouring, no warning icons, no penalties, no streaks that break.  
5. Scores are never aggregated into a daily grade for the user herself. Meals are scored; people are not.

Point 3 through 5 are not tone preferences. Calorie tracking combined with food scoring is the highest eating-disorder-risk pattern in consumer health apps, and this product is aimed squarely at the population most affected.

#### Post-scan note

After each scan the system generates one short note, 2–3 sentences, combining:

1. The meal's composition  
2. Current cycle phase, or pregnancy or postpartum phase  
3. Body signals logged in the last 24 hours, from the Calendar  
4. The user's focus areas

Examples of the intended shape:

1. Luteal phase, low energy logged, high refined carbohydrate meal — a note about steadier energy and what to add, not a warning.  
2. Menstruation, focus area 3 selected, iron-rich meal — a note confirming the choice, and that vitamin C alongside it helps absorption.  
3. Post-workout, muscle-building goal, low protein meal — a note on protein timing.

Requirements:

1. Notes are produced by a rules layer that selects the relevant angle, with the model used for phrasing only. A note must never be free-generated from the meal alone.  
2. If no body signals or cycle data are available, the note falls back to composition only. It never invents context.  
3. Notes are informational. They do not instruct the user to eat or avoid anything.  
4. One note per scan. No follow-up nudges.

#### Chat

1. Open text chat scoped to nutrition, reachable from the adviser and from the Dashboard chat area.  
2. The chat has access to the user's goal, focus areas, targets, recent meals, cycle phase and recent body signals.  
3. Typical use: which foods help with a specific symptom, how to plan meals for the week, what to eat before or after training, how to hit a fibre or iron target.  
4. Answers reference Blog articles where one exists, so the scientific basis is visible.  
5. The chat may not produce a meal plan that conflicts with the safety guardrails, and may not set or change targets. Target changes go through the setup flow.

#### Meal log

1. Scanned and manually added meals are stored against the day and meal slot.  
2. A day view shows meals, running totals against the calorie and macronutrient targets, and remaining budget.  
3. A week view shows adherence trends and focus-area progress.  
4. Remaining budget is displayed neutrally. No warnings when a target is exceeded, no celebration when it is not.  
5. Water intake is tracked if focus area 7 is selected.  
6. Meal entries appear in the Calendar day detail alongside other events. The calendar indicator scheme (§Calendar, Day cell indicators) has no position for meals — a Calendar decision, open.

#### Edge cases

1. Setup abandoned mid-flow — progress is saved and the user resumes where she left off. No advice is shown until it is complete.  
2. Barcode not found in the database — the user is offered manual entry, and the product is queued for database enrichment.  
3. Photo contains several dishes — the system splits them into separate items the user can confirm or remove individually.  
4. Photo is not food — the system says so and offers search.  
5. Offline — photos and barcodes are queued and processed when connectivity returns. Manual entry works fully offline.  
6. Conditions declared at Sign Up (diabetes, coeliac disease, PCOS, thyroid conditions, food allergies) suppress conflicting suggestions and add a one-time note that the adviser does not replace medical nutrition advice.  
7. Entering Pregnancy phase with an active weight-loss goal — the goal is suspended automatically, the user is told once, and it is restored only if she chooses after Postpartum ends.  
8. Target weight already reached — the system offers to switch the goal to maintenance rather than continuing a deficit.

#### Other requirements

1. Food and product data comes from a licensed nutrition database. Coverage varies sharply by region; the chosen provider must cover the launch markets or the barcode feature will fail for most users.  
2. All calculation constants (activity factors, goal adjustments, macronutrient ranges, phase adjustments, score weights) are server-configurable, not hardcoded.  
3. Photos are processed for recognition and are not used for training without explicit separate consent.  
4. All nutrition logic and content requires sign-off by a registered dietitian, with a documented review cycle.  
5. The adviser does not diagnose. Iron deficiency anaemia in particular can only be confirmed by a blood test; the adviser may support a diagnosis the user already has, and must signpost testing rather than infer the condition from symptoms.  
6. The adviser does not recommend specific supplements or doses. It may state which foods are sources of a nutrient.  
7. If disordered eating is declared at Sign Up or detected in chat, weight-change goals and calorie display are disabled and the adviser switches to qualitative guidance only. This state is user-reversible only through Settings, never through a prompt in the flow.  
   > **Superseded in part (2026-08-30, decision A31).** Self-declared only: one optional question in Profile ("Have you been treated for disordered eating?"); yes switches qualitative mode on and weight goals off, reversible only in Settings. **The assistant never infers it** — "detected in chat" is removed, because a model screening for a psychiatric condition and silently changing the product contradicts item 5. The assistant still refuses to help set extreme targets and points to support resources when asked directly.  
8. A global setting allows any user to hide calorie numbers and use qualitative guidance alone, with no loss of other functionality.  
9. Accessibility: scores and macronutrient splits are announced with values, not conveyed by colour or chart shape alone.

### Dashboard

#### Purpose

The Calendar is where the user gives data. The Nutrition adviser is opened when there is a task to do. The Dashboard is the only screen that gives something back without being asked, and it is therefore the screen that determines whether the app is opened on a day when nothing needs logging.

Its job is to answer one question: what is worth knowing about my body today.

#### Layout

Top to bottom:

1. Today card  
2. Shortcuts (action buttons)  
3. Today at a glance  
4. Nudge slot  
5. Banner area

#### Today card

The hero element. One card, one message, once per day.

##### **Composition**

Three lines maximum:

1. Where she is — cycle day, or pregnancy week and day, or postpartum day  
2. What is known — what she logged, or what is typical for the phase if she logged nothing  
3. One suggestion — at most one, and only when there is something worth suggesting

##### Observed data outranks predicted data

This is the central rule of the card. If the user has logged body signals in the last 24 hours, the card must lead with what she reported, not with what her cycle phase predicts.

An app that tells a woman she is probably feeling energetic on a day she has just logged energy 1 of 5 is wrong, and is wrong in a way she will notice immediately. The phase is context for what she reported; it is not a substitute for it.

Worked example, no signals logged:

> Day 13\. You're likely approaching ovulation. Many women notice their energy is higher around now — if that matches how you feel, it can be a good window for harder training.

Worked example, same day, energy logged at 1 of 5 and sleep at 2 of 5:

> Day 13\. You logged low energy this morning, after a poor night's sleep. Sleep, stress and iron affect day-to-day energy more than cycle phase does — a lighter session today is a reasonable call.

##### Priority ladder

The card selects its message by priority. The first applicable rule wins and no other message is shown that day:

1. Red-flag escalation (Pregnancy mode) — always wins, and is displayed as an escalation card rather than a Today card  
2. A pattern in her own logged data that is worth naming — for example a third consecutive day of low mood. *Decided 2026-08-30 (A32): three consecutive logged days with mood, energy or sleep at 2 of 5 or below, or the same symptom marked severe on three consecutive days. The card names the pattern and points outward — a person, a provider — never a cause. A product heuristic, stated as one; not a clinical instrument. Implemented narrowly as mood **and** sleep — energy is not read — on A32's own authority: its record makes the canvas' `home_h` copy the shape, and that copy names mood and sleep together and never mentions energy.*  
3. A mode milestone — an upcoming scan, the 6-week check, a due appointment  
4. Cycle phase context  
5. A nutrition or training suggestion derived from her goal and today's totals  
6. Fallback — one fact or article from the Blog

##### Confidence and cold start

1. The card states confidence honestly. Phase estimates without ovulation confirmation are approximate, and the wording ("likely", "probably") must reflect that rather than asserting the phase as fact.  
2. With fewer than 3 logged cycles the card does not estimate a phase. It states what is needed instead: "Log your first period and Eva can start telling you what to expect."  
3. With irregular cycles the card says the phase cannot be estimated reliably, matching the rule used for the fertile window.  
4. The card must never generate a personalised-sounding message from data the app does not have. Generic content presented as insight is detected by users immediately and is the fastest way to lose trust in the feature.

##### Mode variants

| Mode | Line 1 | Typical content |
| ----- | ----- | ----- |
| Cycle | Cycle day and phase | Phase context, symptom patterns, nutrition and training fit |
| Planning | Cycle day and fertile window position | Window status, what would sharpen the estimate |
| Pregnancy | Week and day | What is happening this week, upcoming appointments |
| Postpartum | Days since birth | Recovery, feeding, the 6-week check, return of cycle |

After a pregnancy loss the Dashboard returns to Cycle mode content immediately. All pregnancy-related cards, milestones and banners are cleared in the same action that ends pregnancy tracking, with nothing left queued.

#### Shortcuts

1. Four action buttons: Log, Scan meal, Calendar, Chat.  
2. The first button is contextual. During menstruation it is Log period; in Postpartum phase it is Log feed; otherwise it is Log.  
3. Shortcuts for features the user has not set up are replaced by a set-up prompt rather than hidden.

#### Today at a glance

1. Compact row showing calories remaining, protein, water and logged activity against today's targets.  
2. Displayed only when the Nutrition adviser setup is complete. It is not shown in a partial state.  
3. Values are neutral. No warning colours when a target is exceeded, no celebration when it is met, per the Nutrition adviser rules.  
4. Tapping the row opens the meal log.

#### Nudge slot

1. At most one nudge per day, dismissible, below the glance row.  
2. Eligible nudges: a period predicted to start within 2 days, an appointment tomorrow, a gap of 3 or more days in logging, a set-up step never completed.  
3. A nudge that is dismissed does not return the next day.  
4. Logging gaps are stated neutrally and never as failure. No streaks, and nothing that can be broken.

#### Banner area

1. Tips and interesting facts, as specified in the feature list. Tapping opens the related Blog article or video.  
2. Banner content is selected by cycle phase, mode and declared focus areas, so it is relevant rather than random.  
3. The banner never duplicates the subject of the Today card on the same day.

#### Tone and framing rules

These apply to the Today card, banners, nudges and notifications alike.

1. The app describes tendencies, never destiny. "Many women notice more energy around now" is acceptable. "You will feel energetic" is not.  
2. The app must not tell a woman what she is capable of on a given day. Suggesting that hard work or important decisions belong in one phase and not another is out of scope, and runs against the premise the product is built on. Eva exists because women were excluded on the basis of assumptions about their hormones; it must not reintroduce those assumptions in friendlier language.  
3. Suggestions are offered as options, and the user's own reported state always takes precedence over the model's expectation.  
4. No comparison to other users, no scores for the person, no streaks.  
5. Copy is reviewed for cultural and language variants, not machine-translated.

#### Edge cases

1. No data at all (first open after Sign Up) — the card explains what to log first and why. No phase, no prediction, no generic tip dressed as insight.  
2. Cycle data exists but the user is late — the card acknowledges the period is later than predicted without speculating about the cause, and offers the option to log a test.  
3. Signals logged but no cycle data — the card responds to the signals alone.  
4. Multiple conditions true at once — the priority ladder decides. Only one message is shown.  
5. The user has opened the app more than once in a day — the card does not change between opens. It updates on new data, not on refresh.  
6. Sex event type hidden in Settings — no dashboard content may reference it.

#### Other requirements

1. The Today card is generated by a rules layer that selects the message and its inputs, with the model used for phrasing only. The message subject is never free-generated.  
2. All card templates, banner content and nudge rules are server-configurable and do not require an app release.  
3. The card is generated once per day and cached, so it is available offline and does not change on repeated opens.  
4. Clinical content in cards and banners follows the same review requirement as the rest of the product.  
5. Accessibility: the card is a single readable block, not a set of decorative fragments; the glance row announces values rather than relying on ring shapes.

### Eva Chat

Decided 2026-08-30 (review §8 A5). Eva Chat is the feature the product is named for; it has its own tab (§Product frame, Navigation) and a shortcut on the Dashboard.

#### Scope

1. One assistant across every domain. The Nutrition coach's chat (§Nutrition coach, Chat) is one scope of this assistant, not a separate one; that section's rules apply within it.  
2. It sees the profile, the current cycle or pregnancy phase, recent calendar logs, recent meals and the user's goals.  
3. It answers questions about nutrition, training, well-being and planning.  
4. It may create or edit calendar entries. Every entry it creates is marked `source: eva` so it can be identified and reverted (§Calendar, Other requirements).  
5. It helps phrase or expand a question for a doctor (§Doctor appointment, Questions list).  
6. Within the nutrition scope, answers reference Blog articles where one exists (§Nutrition coach, Chat). Whether that rule extends to every domain is not decided.

#### What it does not do

1. It does not interpret symptoms. A symptom question is answered by the deterministic red-flag escalation layer (§Calendar, Other requirements) and by "contact your provider" language, never by the model. §Calendar's rule stands: Eva never diagnoses and never reassures.  
2. It cannot set or change nutrition targets; target changes go through the setup flow (§Nutrition coach, Chat). It may not produce a meal plan that conflicts with the nutrition guardrails.  
3. The tone and framing rules of §Dashboard apply to every answer.  
4. The regulatory line in §Calendar, Other requirements stands: symptom interpretation may be a medical device, and the scope above holds until #26 says otherwise.

#### Decided

1. **LLM vendor, cost, and processor (A5, #267 — decided 2026-09-26): Google Gemini Flash,
   Google as data processor.** A model-phrasing prompt carries only the filled card's subject
   and inputs (cycle day, phase, logged signals) and the tone rules — **never** raw events,
   the profile, sex events or the uid (GUARDRAILS 12 applies to the prompt as to logs). The
   cost is bounded by one call per user per day (D3's once-daily cache) at a small fraction
   of a cent per call — a per-day figure of **≤ $0.001 per active user**, not "TBD". Google
   acts under a data-processing agreement; a processor without a signed DPA is a refusal,
   not a default. The key is read in one module only, declared in `api/src/config.ts` and
   `api/.env.example` (GUARDRAILS 2).

#### Open

1. History and memory; safety and refusal rules beyond the ones above.

Not yet specified — needs a /explore

### Blog

Reached from the Learn tab (§Product frame, Navigation), from Dashboard banners and from Eva Chat answers.

Constraints already binding:

1. Content is the transparent scientific basis for recommendations (feature list). Cards, banners and chat answers reference an article where one exists (§Dashboard, Banner area; §Nutrition coach, Chat).  
2. All medical content requires clinician sign-off and a documented review cycle (§Calendar, Other requirements); nutrition content requires a registered dietitian's (§Nutrition coach, Other requirements).

Content model, CMS, in-app reader versus web, video, search, and how articles are linked from cards, notes and chat: Not yet specified — needs a /explore

### Personal trainer

Reached from a Dashboard shortcut, never a tab (§Product frame, Navigation). In v1, in the last group of the build order (§Product frame, Scope and order).

Constraints already binding:

1. §Dashboard, Tone and framing rules, rule 2: "The app must not tell a woman what she is capable of on a given day. Suggesting that hard work or important decisions belong in one phase and not another is out of scope, and runs against the premise the product is built on." A training-programme generator walks straight into this rule and must be designed around it.  
2. All medical content requires clinician sign-off and a documented review cycle (§Calendar, Other requirements).

Not yet specified — needs a /explore

### Mental well-being coach

Reached from a Dashboard shortcut, never a tab (§Product frame, Navigation). In v1, in the last group of the build order (§Product frame, Scope and order).

Constraints already binding:

1. §Dashboard, Tone and framing rules, rule 2: "The app must not tell a woman what she is capable of on a given day."  
2. If it implements the Edinburgh Postnatal Depression Scale, §Phase 3 \- Postpartum, Mood screening applies: item 10 covers self-harm and requires a defined escalation path, not only a score. Whether any other screening instrument is used, and its escalation path, is not decided.  
3. All medical content requires clinician sign-off and a documented review cycle (§Calendar, Other requirements).

Not yet specified — needs a /explore

### Notifications

Decided 2026-08-30 (review §8 A9) and constrained by what the canvas draws (review §3.2 F5). These rules bind the appointment reminder (§Doctor appointment), the meal reminder (§Nutrition coach, Step 3), the fertile-window heads-up (§Phase 1 \- Planning) and the pregnancy-loss stop rule (§Pregnancy loss).

#### Transport

1. APNs, sent directly from the API. The app does not link the Firebase iOS SDK.  
2. The device token is stored against the user on `users/{uid}`; scheduled sends run as a server job. The API surface is engineering issue I5 in the review.

#### Content rules

1. A preview never shows symptoms, flow, sex or appointment details. The preview text is "Eva has an update" until the app is unlocked.  
2. Sex entries never appear in a notification (§Sex).  
3. The tone and framing rules of §Dashboard apply. In Planning, §Phase 1 \- Planning's notification tone applies. A pregnancy loss stops every pregnancy notification immediately, including anything already queued (§Pregnancy loss).  
4. Well-being check-ins are opt-in and never streak-based.

#### Categories

As drawn on the canvas (`notifications` screen). The list is what is drawn, not a catalogue:

1. Cycle reminders  
2. Appointment reminders  
3. Well-being check-ins — opt-in, never streak-based  
4. Educational content  
5. Meal reminders (Nutrition coach, from the usual meal times in Step 3)

One global switch turns notifications on or off (feature list).

#### Open

The full catalogue with triggers and copy, quiet hours, permission-prompt timing, and the notification-centre screen the feature list names: Not yet specified — needs a /explore

### Settings

The canvas draws 23 rows across its `settings`, `privacy` and `notifications` screens. Only the rows below are required by a decision, an issue or a line of this document; a row the canvas draws that nothing has decided is marked *drawn only* and is not a spec.

| Row | Status | Source |
| ----- | ----- | ----- |
| Personal profile — date of birth, weight and height, goals & lifestyle, hormonal medications, conditions, activity band, preferred sports | Decided | §Sign Up, Profile fields (A8); #19 |
| Pregnancy mode — the only entry point to the mode; "End pregnancy tracking" lives here | Decided | §Pregnancy mode, Turning it on (A6); §Pregnancy loss |
| Language — English only at launch, list to grow | Decided | §Product frame, Markets and language (A2) |
| Units — metric default, imperial as a setting | Decided | A2; §Nutrition coach, Step 4 |
| Notifications — one global switch | Decided | feature list; §Notifications |
| Notifications — per-category switches | Drawn only | canvas `notifications` |
| Calorie display — hide calorie numbers and use qualitative guidance; the disordered-eating state is reversible only here | Decided | §Nutrition coach, Other requirements |
| Privacy & security — app lock, biometric access, hide the Sex event type | Drawn only; hiding Sex is anticipated by §Sex requirement 3 and §Dashboard edge case 6 | canvas `privacy` |
| Change password | Decided; flow depends on #6 | feature list; §Account |
| Manage connected accounts — link a second sign-in provider to this account | Decided; required by #7's manual linking | #7; §Sign Up, Edge case |
| Data export | Decided; format and delivery open | #58; §Account |
| Requests for your data — opens the request policy and transparency report on the website (`/transparency`); the Privacy & security footer carries its one-sentence summary | Decided | A19; #91; `docs/REQUESTS.md`; `docs/DESIGN.md` §9a |
| Manage subscription | Decided | §Product frame, Monetisation (A14) |
| Support rows | Drawn only | §Support |
| Log out | Decided | feature list |
| Delete profile | Decided | feature list; §Account (#8) |

Other rows the canvas draws — Personalisation, Content preferences, Privacy settings, About — are drawn only.

### Support

Rows as drawn on the canvas; none has decided content:

1. Help centre  
2. Contact support  
3. Report a problem  
4. Medical and emergency information — region-aware, per country (§Calendar, Other requirements; §Product frame, Markets and language)

Channels and content: Not yet specified — needs a /explore

### Account

Account-lifecycle rules that until now lived only in `docs/ARCHITECTURE.md` and in issues.

#### Deletion

> **Decided (2026-08-30; issue #8, `docs/ARCHITECTURE.md` §4).** This document had no rule
> on deletion timing. Deletion is immediate and complete:
> `DELETE /me` removes the Auth user, the user document and every calendar entry —
> including soft-deleted entries still inside their 30-day window. There is no recovery
> window and no undo. The confirmation follows the destructive pattern in
> `docs/DESIGN.md` §5, and a deleted account's email can sign up again.

#### Password reset

1. The flow is §Log in, Restore password, built by #6.  
2. Resetting the password does not sign out other devices. The session token is stateless and cannot be revoked (`docs/ARCHITECTURE.md` §3), so the canvas' "Other devices were signed out." is not yet true and may not be shown unless #6 adds session revocation — a `users/{uid}` schema change under the always-human gate (review E2, engineering issue I2).

#### Data export

1. A signed-in user can obtain everything stored under her account in one file, readable outside Eva (#58). Format and delivery are #58's open questions.  
2. Sex entries are excluded from an export unless explicitly opted in (§Sex).

#### Privacy copy

1. The app claims encryption in transit and at rest, never "on your device" (A10). There is no client-side encryption and none is planned. The agreed wording: "encrypted in transit and at rest, never sold, never shared with advertisers, deletable in full".

#### Email change

Not yet specified — needs a /explore


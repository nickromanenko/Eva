# **Eva \- the first AI made for women**

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
| Onboarding | 1-2 screens that describe the idea of the app. Ideally, 1 screen with science facts (2-5 bullets of pain) and 1 screen about our solution |
| Sign Up | Apple ID Google account Email \+ password Age Weight and height Questionary: What do you want to improve? (multiple choices) Do you have any diseases? What is your lifestyle? What sports do you prefer? Do you take any medications that affect your hormones? |
| Dashboard | The dashboard has to contain: Shortcuts to main features (action buttons) Banner area with tips and interesting facts (by clicking the user is redirected to blog article / youtube video related to it) Chat area |
| Calendar | The calendar provides next options: Cycle tracking Sex life tracking Body signals tracking Training tracking Doctor appointments Pregnancy mode (planning, pregnancy, postpartum) |
| Nutrition adviser | A woman can specify her nutritional goals, food preferences, and deficiencies. The coach will advise on the calorie requirements for the expected activity level and cycle phase. |
| Personal trainer | Based on your desired training frequency and goals, the app creates a training program and explains the basic principles and differences of training for women. |
| Mental well-being coach | This personal coaching program helps you understand how to deal with stress, improve concentration, and get quality rest. |
| Blog | The blog is a library of articles that serve as the basis for recommendations. This means the scientific base is transparent and accessible. |
| Notifications | Push notifications, notification centre |
| Settings | Profile (change password, update personal info from questionary, delete account) Language Notifications turn on/off Log out Delete profile |
| Support |  |

## Requirements

### Onboarding

### Sign Up

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

1. If the user who has created an account with email\&password try to sign up with a Google account \- do not create a new one, proceed as log in to the existing profile.

#### Other requirements

1. All validations have to be displayed under the input fields.  
2. The activation link is valid for 24 hours.

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

Options:

1. Spotting  
2. Has flow:  
   1. Light  
   2. Medium  
   3. Heavy

After the flow level, the Body signals chip grid (Zone 2\) is shown so symptoms can be logged in the same flow. Chips selected here are written to that day's Body signals entry, not to a separate record — the app has one symptom vocabulary.

Only one flow level per day. Logging a second replaces the first, with a confirmation.

Period end is marked by the first day with no flow logged. The user can also mark it explicitly from the day detail sheet.

##### Sex

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

Zone 2 — optional, multi-select chip grid:

1. Bloating  
2. Cramps  
3. Headache  
4. Nausea  
5. Breast tenderness  
6. Back pain  
7. Acne / breakout  
8. Cravings  
9. Anxious  
10. Stressed  
11. Brain fog  
12. Poor appetite  
13. Heavy appetite  
14. Libido changes

Requirements:

1. Maximum 12 chips visible at once. The remainder sit behind "More…" (dizziness, hot flashes, constipation, loose stool, insomnia, discharge, itching).  
2. Chip order adapts: chips logged in the last 7 days float up, then the rest are weighted by cycle phase (luteal surfaces bloating and cravings, menstrual surfaces cramps and back pain).  
3. A chip logged 3 times is automatically pinned into the visible grid.  
4. Second tap on Cramps, Headache or Nausea marks it as severe (chip fills darker). No extra screen.  
5. One Body signals entry per day. Re-opening the sheet loads the existing entry for editing and never creates a second one.  
6. Discharge is the only chip that keeps a value picker: dry / sticky / creamy / watery / egg-white.

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
4. Reminder — optional, default 1 day before

Questions list:

1. The user can add questions to the next upcoming appointment at any time from the day detail or the appointment itself.  
2. On the appointment day the questions are surfaced as a list she can open in the consulting room.  
3. Eva can help phrase or expand a question from the chat.

#### Pregnancy mode

Pregnancy mode is one switch with three phases. The phases advance automatically on the triggering event — the user never selects a phase from a menu.

##### Turning it on

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

1. The system offers a mood check at approximately 6 weeks and periodically after.  
2. If the Edinburgh Postnatal Depression Scale is implemented, item 10 covers self-harm and requires a defined escalation path, not only a score.

#### Edge cases

1. Backdating is allowed for any past date, capped at 12 months by default.  
2. Logging on future dates is disabled. Tapping a future date shows predictions only.  
3. Deleting an entry is a soft delete, recoverable for 30 days.  
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
4. Entries created by Eva from chat are marked as such so they can be identified and reverted.  
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
3. Optional: usual times for each meal, used for reminders and for spacing advice

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

1. A target below BMI 18.5 is not accepted. The system explains why and offers the lowest target it will support.  
2. Rate of weight loss is capped at approximately 0.5 kg per week, or 1% of body weight per week, whichever is lower.  
3. The calculated calorie target is never set below the user's basal metabolic rate.  
4. An absolute floor of 1200 kcal applies. If the maths produces less, the timeline is extended instead of lowering the target further.  
5. Weight-change goals are unavailable in Pregnancy phase, and unavailable in Postpartum phase for the first 6 weeks after delivery.

#### Daily targets calculation

##### **Calories**

1. Basal metabolic rate uses Mifflin-St Jeor for women: BMR \= (10 × weight in kg) \+ (6.25 × height in cm) − (5 × age) − 161  
2. Total daily energy expenditure \= BMR × activity factor:  
   1. Sedentary — 1.2  
   2. Lightly active — 1.375  
   3. Moderately active — 1.55  
   4. Very active — 1.725  
   5. Extremely active — 1.9  
3. Goal adjustment applied to TDEE:  
   1. Lose weight — minus 15 to 20%  
   2. Maintain / eat better — no adjustment  
   3. Gain weight — plus 10 to 15%  
   4. Build muscle — plus 5 to 10%  
4. The result is clamped by the guardrails in Step 5\.

##### Macronutrients

1. Protein is set first, by body weight:  
   1. Lose weight — 1.6 to 2.0 g per kg  
   2. Build muscle — 1.6 to 2.2 g per kg  
   3. All other goals — 1.2 to 1.6 g per kg  
2. Fat is set second, and must not fall below 20% of total calories. This is a hard floor, not a default. Sustained low fat intake is associated with menstrual disruption, and an adviser built for women must not produce a plan that causes it.  
3. Carbohydrate is the remainder.  
4. Fibre target is set at 25–30 g per day, and is raised when focus area 1 or 11 is selected.

##### Cycle phase adjustment

This is the part that distinguishes Eva from a generic calorie tracker and it must not be dropped for scope.

1. In the luteal phase the calorie target is raised by approximately 5% (typically 100–250 kcal), reflecting the increase in resting metabolic rate.  
2. During menstruation, if focus area 3 is selected or anaemia was declared at Sign Up, iron-rich foods are prioritised in suggestions.  
3. The daily target displayed in the UI is the phase-adjusted one. The adjustment is explained in one line, not hidden.  
4. In Planning, Pregnancy and Postpartum modes the phase adjustment is replaced by the mode adjustment: pregnancy adds roughly 340 kcal in the second trimester and 450 in the third, and breastfeeding adds roughly 330–500 kcal.

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
6. Meal entries appear in the Calendar day detail alongside other events.

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
2. A pattern in her own logged data that is worth naming — for example a third consecutive day of low mood  
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


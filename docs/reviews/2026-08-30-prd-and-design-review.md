# PRD × Design × Code — completeness and conflict review

**Date:** 2026-08-30 · **Write-back to the PRD:** #69 · **Snapshot of:** `Eva app _ PRD v1.md` (870 lines), the three canvas
mirrors in `docs/design/` (App: 41 states · Nutrition: 37 states · Design System),
`docs/*.md`, the code on `main` at `4dd0112`, and issues #1–#68.

This is an analysis, not a plan. Line numbers are into the PRD; `key` names in
backticks are rail keys inside the canvas files (`home_f`, `scLow`, …).

---

## 1. Verdict in five lines

1. **The PRD is deep where it is deep and absent where it is absent.** Calendar,
   Nutrition and Dashboard are specified to acceptance-criteria level. Eva Chat, Blog,
   Personal trainer, Mental well-being coach, Notifications, Settings and Support have
   between zero and one line — and the website already sells four of them.
2. **The PRD has no product frame.** No v1 scope, no launch markets or languages, no
   pricing, no age floor, no legal/consent requirements, no non-functional requirements.
   Several downstream decisions (#25, #26, #11) are stuck on exactly these.
3. **The design covers the "happy core" of three features and the shell of a fourth.**
   Auth (8 screens), Dashboard (18 states), Calendar in Cycle mode (9), Profile (6),
   Nutrition (37). Not drawn: the whole Pregnancy-mode journey beyond the on-switch,
   every "View …" detail screen the Dashboard links to, Eva Chat, Learn, and ~15
   Settings rows that toast "out of scope".
4. **There are real conflicts, not just gaps** — 12 between PRD and canvas, 5 inside the
   design set itself, and 5 places where a canvas screen promises something the
   architecture cannot deliver (device-side encryption, remote sign-out, offline, purge
   timing, provider-aware linking).
5. **The PRD is already stale against decisions recorded in issues** on 2026-08-29:
   sign-in identity (#7), activity bands and score naming (#25), spotting (#23), chip
   vocabulary (#24), questionnaire location (#19), deletion semantics (#8). Nobody has
   written those back.

---

## 2. Coverage matrix

Spec depth: **full** = acceptance-criteria level · **partial** = requirements with holes ·
**line** = feature-list row only · **—** = nothing.

| PRD feature | PRD spec | App canvas | Nutrition canvas | Code | Tracked |
|---|---|---|---|---|---|
| Onboarding (science/solution screens) | superseded (40–46) | — (by decision) | — | — | #3 done |
| Sign up · email | full | `signup`, `signupErr`, `activation` | — | signup, no activation | #6 |
| Sign up · Apple / Google | partial (63–72) | buttons only | — | — | #7 |
| Log in · password reset | partial (79–87) | `login`, `forgot`, `forgotSent`, `newpass`, `resetDone` | — | signin only | #6 |
| Questionnaire / profile | partial (27, 48–53) | `settings`, `editProfile` | Step 4 reuses it | 4-step post-auth gate, legacy styling | #19 |
| Dashboard | full (746–870) | 18 states | — | placeholder `ContentView` | #10 (epic, unsplit) |
| Calendar · Cycle mode | full (89–285, 468–492) | `cal`, `calEmpty`, `day`, `picker`, 4 sheets | — | API C1+C2 done; **no UI** | #11 (refining) |
| Calendar · Sex event | full (178–191) | one-tap in `picker`, `privacy` toggle | — | type reserved, route rejects | #11 C10 |
| Calendar · predictions & confidence | partial (306–322, 801–806) | overlays + legend in `cal` | — | — | #11 C11/C12 |
| Pregnancy mode · switch | full (289–300) | `pregMode`, `calPreg` | — | — | out of #11 scope |
| Pregnancy mode · Planning / Pregnancy / Postpartum / Loss / Delivery / Feeding / mood screening | full (302–466) | dashboard cards only (`home_plan`, `home_preg`, `home_flag`, `home_post`, `home_loss`) | `tPreg`, `tPost` | — | **nothing** |
| Nutrition · setup + targets | full (505–627) | — | 10 + 8 states | — | #25 S1–S3, #26 |
| Nutrition · scanner / search / barcode / manual | full (629–663) | — | 15 states | — | #25 S5, S6, S9 |
| Nutrition · score, note, chat | full (665–712) | — | `scScore`, `chEmpty`, `chBusy` | — | #25 S8, S10, S11, gated on #26 |
| Nutrition · meal log day / week | partial (714–721) | — | `tLuteal`, `tWeek` (no full log) | — | #25 S4, S7 |
| **Eva Chat (general)** | **line only** (28) | shortcut + tab, "out of scope" | — | — | **nothing** |
| **Blog / Learn** | **line only** (33) | `Learn` tab "out of scope"; banners link to it | articles cited in chat | — | **nothing** |
| **Personal trainer** | **line only** (31) | — | — | — | **nothing** |
| **Mental well-being coach** | **line only** (32) | — | — | — | **nothing** |
| **Notifications** (push + centre) | **line only** (34) | `notifications` settings screen; no centre | meal reminders toggle | reminder *intent* stored | **nothing** |
| Settings | line (35) | `settings` (23 rows), `privacy`, `notifications` | `nSet` | Profile = email + log out + delete | #19 (rows), #58 (export) |
| Support | **empty** (36) | 3 rows, toast | — | — | **nothing** |
| Delete account | **—** (only in 35) | `danger` modal | — | done | #8, #55, #56, #59 |
| Data export | **—** (only 189 mentions "exports") | `danger`, `privacy` rows | — | — | #58 |
| Offline | partial (473, 729, 868) | `home_off`; DS "Couldn't sync" card | `scOff` | idempotencyKey on events, nothing else | #11 Q6, #25 S13 — **undecided** |
| Website (landing, privacy, terms) | — | — | — | landing on the **old plum/serif** design; privacy & terms are placeholders | — |

---

## 3. PRD — what is missing

### 3.1 Product-level (nothing in the PRD answers these)

| # | Gap | Why it blocks something concrete |
|---|---|---|
| P1 | **v1 scope.** The PRD reads as the whole product. Which of the 11 features ship first is only implied by which issues exist. | The website promises trainer, well-being coach, blog and chat today; the App Store listing will too. |
| P2 | **Launch markets, regions, languages.** | Food-database coverage (736), region-aware emergency guidance (487–489), the per-region appointment template (405), the Language row, copy review rule (853), and the regulatory jurisdiction in #26 all depend on it. |
| P3 | **Monetisation.** No pricing, paywall, trial, or which features are paid. | Shapes onboarding, Settings, and whether a subscription surface is needed in the canvas. |
| P4 | **Age floor and age gating.** `parseProfile` accepts 13. Nutrition uses an adult equation. | Routed to #26 for nutrition, but the *product* floor (App Store age rating, GDPR-K / COPPA) is undecided. |
| P5 | **Legal / consent.** Health data is GDPR Art. 9 special-category data; nothing states the consent flow, the lawful basis, the data-processor list (LLM, food DB, photo vendor — #25), retention, or the "Not a medical device" disclaimer the canvas footer already shows. Privacy policy and terms on the website are placeholders. | The activation screen and sign-up already link to Terms and Privacy that do not exist. |
| P6 | **Non-functional requirements.** Availability, latency, backup/restore, data retention, session length (the 30-day JWT is an architecture choice with no product mandate), account security (2FA?), accessibility target (DESIGN.md §9a applies WCAG AA de facto). | Several ARCHITECTURE.md "deliberate gaps" (§7) have no PRD line to be measured against. |
| P7 | **Platform statement.** iOS only? Android later? Widgets are mentioned twice (189, 413) and never specified. HealthKit / Apple Health import (sleep, workouts) is never mentioned — a decision either way, since it changes what Sport and Sleep logging look like. | Affects Calendar (#11) and Nutrition activity refinement (557). |
| P8 | **Analytics and success metrics.** Nothing says what "working" means, and nothing constrains telemetry on health data. | Guardrail 12 forbids logging payloads; there is no equivalent rule for analytics events. |

### 3.2 Features with no requirements section

| # | Feature | What a spec needs to answer |
|---|---|---|
| F1 | **Eva Chat** — the product's namesake and the feature list's "Chat area" (28). Only *nutrition* chat is specified. | Scope; what context it sees; safety/refusal rules; the regulatory line (491 says conversational symptom interpretation may be a medical device); model/vendor; history and memory; "entries created by Eva from chat" (486) and "Eva can help phrase a question" (285) both assume it exists. |
| F2 | **Blog / Learn** (33) | Content model, CMS, review cycle (490), in-app reader vs. web, video (28), how "basis for recommendations" is linked from cards/notes/chat, search. |
| F3 | **Personal trainer** (31) | Everything. Note the PRD's own tone rule (850) forbids telling a woman what she is capable of on a given day — a training-program generator walks straight into it. |
| F4 | **Mental well-being coach** (32) | Everything, plus the EPDS/self-harm escalation path (466) which is the one clinically-sensitive piece already named. |
| F5 | **Notifications** (34) | Catalogue of every notification, its trigger and copy; quiet hours; permission-prompt timing; the notification centre screen; transport (see C5); the preview rule the canvas already states ("Eva has an update"). Appointment reminders (279) and meal reminders (551) both depend on this and neither section says so. |
| F6 | **Settings** (35) | Which of the canvas' 23 rows exist in v1; language list; units (558 assumes a setting exists); change password; **manage connected accounts** — now *required* by #7's manual-linking decision; data export (#58); support channels. |
| F7 | **Support** (36) | Empty row. |
| F8 | **Account lifecycle** | Email change, deletion semantics (immediate vs. window — the canvas and API disagreed and only ARCHITECTURE.md records the answer), what happens on password reset (see C2), re-activation. |

### 3.3 Holes inside otherwise-full sections

| # | Where | Hole |
|---|---|---|
| H1 | Calendar · Cycle mode | **No prediction algorithm for Cycle mode.** Ovulation maths lives only under Planning (310–312); "next predicted period" is never defined (mean of last N? median? which N?). "Logged cycle" for the ≥3 gate and "varies by more than 7–9 days" (319) are undefined (#11 Q4). Whether the fertile window shows in Cycle mode, and therefore where the not-a-contraceptive notice (322) appears, is open (#11 Q5). |
| H2 | Calendar · structure | "Edge cases" (468) and "Other requirements" (481) are nested under `#### Pregnancy mode` but are calendar-wide (#11 noted this). |
| H3 | Body signals | Zone 2 lists **14** chips (205–218) and then says **"maximum 12 visible"** (222). Self-contradictory. |
| H4 | Body signals | Adaptive ordering (223), auto-pin after 3 logs (224) — a rules layer that no other doc, canvas or API reflects; `refdata` has a static `order`. |
| H5 | Menstrual cycle | "Period end … first day with no flow logged" and "mark it explicitly" (176) — no data model for an explicit end; `CyclePayload` has none. "Cycle day N" with spotting days is undefined now that spotting is a separate marker (#23). |
| H6 | Doctor appointment | Reminder (279) requires F5. "Eva can help phrase a question" (285) requires F1. Neither dependency is stated. |
| H7 | Pregnancy mode | The appointment-timeline template *content* per region (405), the "support resources" content (415), the folic-acid screen content (304), EPDS yes/no and its escalation path (466), and what "regular cycles" means (318) are all unspecified. |
| H8 | Dashboard | "Server-configurable templates" (867) — mechanism undefined (#10's open question). Priority ladder rule 2 ("a pattern worth naming") has no definition of a pattern. |
| H9 | Nutrition | Step 4 says age and activity are "not asked again" (556) — but activity *must* be shown for confirmation (557 refines it from Sport events). Meal entries "appear in the Calendar day detail" (721) but the indicator scheme (108–117) has no slot for them. |
| H10 | Sign up / Log in | "Disactivate old one" (86) is ambiguous (old link? old password? other sessions?). PRD 83 says the user *lands* on Log in; canvas and code land on Sign up. |

### 3.4 Stale against decisions already made

| # | PRD says | Decided | Where |
|---|---|---|---|
| S1 | Google sign-up with an existing email logs into the existing account (72) | Identity is provider `sub` only; **a second account is created**; linking is manual from Profile | #7, 2026-08-29 |
| S2 | Logging disabled beyond today (105, 471) | Future dates accept appointments only; API returns `FUTURE_DATE_NOT_ALLOWED` for the rest | canvas `picker`; `api/src/index.ts` |
| S3 | Spotting is a menstrual-cycle option (166) | Spotting is a separate marker that does not start a period | #23 |
| S4 | 14 + 7 chips incl. "Libido changes" (205–222) | 14 + 7 with `libido` as a value axis; "Libido changes" retired | #24 |
| S5 | Questionnaire at sign-up (27, 48–53) | Moves to Profile; post-auth gate removed; nudge on Dashboard | #19 |
| S6 | Five activity factors (584–588) | Four bands, "Extremely active" dropped | #25 Q4 |
| S7 | "Nutrition score" 0–100 (667) | Shown, renamed to something non-judgmental, gated on #26 | #25 Q1 |
| S8 | Nothing on deletion timing | Immediate and complete | #8, ARCHITECTURE §4 |
| S9 | Feature list rows 26–27 still describe the two info screens and the sign-up questionnaire | Both superseded | #3 |

---

## 4. Design — what is missing

### 4.1 App canvas: screens and states not drawn

**Calendar**
- Planning and Postpartum month views (the segmented control offers four modes; two are drawn).
- Year selection in the month picker (PRD 103 says month/year).
- Sex logging sheet and its "Add details" (protection, solo/partnered) — see C3.
- Positive test, Ovulation, Delivery, Feeding (timer + manual) — every non-Cycle event.
- Day detail: editing a cycle entry (`onEdit` has no cycle branch), explicit period end, the discharge value picker (227), the pregnancy and postpartum chip sets, meal rows (721).
- The red-flag escalation card **as triggered from the Body signals sheet** (401, 487) — only the Dashboard version (`home_flag`) exists.
- The one-time "Pregnancy mode?" prompt on the calendar (293).

**Pregnancy journey** — nothing between "Turn on Pregnancy Mode" and the Dashboard cards: confirmation and dating (LMP / doctor's date / IVF, 359–364); week counter with day, trimester, EDD range and the editable dating method (368–380); appointment-timeline pre-population (403–405); folic-acid screen (304); cycles-trying note (340–344); "End pregnancy tracking" in Settings and the post-loss support line (407–419); delivery details (421–425); feeding quick-action (429–438); mood check / EPDS (463–466).

**Dashboard** — every secondary action is a dead end: "View cycle details", "View cycle history", "View window details", "View pattern", "View contact options", "View support resources", "Review this morning's log", "Prepare questions". None of those screens is drawn. Cycle history/detail in particular is referenced from four cards.

**Profile / Settings** — rows that toast "Detail screen out of scope": Personal information, Body measurements, Goals, Lifestyle, Preferred sports, Health information, Medications (the `editProfile` screen covers only part of these, with a *different* field set — see D4), Language, Units, Personalisation, Content preferences, Change password, Manage connected accounts (+ the linking flow #7 requires), Data export, Privacy settings, Help centre, Contact support, Report a problem, Medical and emergency information, About. The app-lock **screen** (passcode entry) is missing though its toggle exists.

**Auth** — what happens when the activation link is tapped (in-app deep link? web page?); the "not activated yet" refusal at sign-in (#6 decision); expired-link states; the Apple sheet and the Google web view (66); the `429 RATE_LIMITED` state (#38); the unreachable-at-launch screen (built in code, never designed); provider-linking from Profile.

**Cross-cutting** — Eva Chat; Learn tab and an article reader; notification centre; notification permission pre-prompt; per-screen loading/error states (DS has one generic skeleton and one error card); Dynamic Type / accessibility layouts (DESIGN §9a already had to invent one); dark mode (explicitly none — fine, but the PRD should say so); widgets (189, 413).

### 4.2 Nutrition canvas: not drawn or needs reconciling

- Full meal log (the "Full meal log" link toasts), meal detail/edit, duplicate, custom water input, custom portion editor, barcode manual entry, favourites management, week-trend detail, the recalculation *push* (627).
- **Its own five-tab bar** (Today · Log · Scan · Chat · Settings). #25 Q3 decided nutrition is reached from the Dashboard shortcut and owns no tab — so where Log, Chat and Settings live inside the coach is now undesigned.
- Step 4 draws five activity bands; #25 decided four.
- The BMI guard implies 21.1 (59.5 kg at 168 cm); PRD says 18.5. Routed to #26; the canvas should not be read as the answer.
- `Fit 78` — rename pending (#25 Q1).
- Nutrition Settings repeats Units and Health conditions from Profile — one fact, two editors.
- The numbers do not reconcile with each other (#25 Risks) and will be read as spec.

---

## 5. Conflicts

### 5.1 PRD vs. App canvas

| # | Topic | PRD | Canvas | Note |
|---|---|---|---|---|
| C1 | Mode switcher | Entry point is Settings, plus a one-time dismissible calendar prompt (293) | Persistent four-way segmented control on the calendar (`modes`) | #11 Q1 — blocks whether cycle-only slices ship a control |
| C2 | Soft-delete window | 30 days (472) | `day` spec: "Undo toast stays for 5s, **the record is purged after**" | API is 30 days; #50 notes one-per-day types are not actually restorable once re-logged |
| C3 | Sex logging | A sheet: date + large Log button, optional "Add details" for protection and solo/partnered (180–185) | One tap in the picker → toast with Undo; no sheet, no details | API has no `sex` payload yet, so this is still open |
| C4 | Positive test in Cycle mode | Available (picker table, 158) | Picker has five types; `home_f`'s "Log test" action goes nowhere | |
| C5 | Body-signal chips | 14 primary + 7 more, but "max 12 visible" (H3) | 12 primary + 6 more, including Spotting, Low libido, Hot flushes | Both are stale against the shipped vocabulary (#24) |
| C6 | Five-point scale | "5-point rating with emoji" (197) | App canvas: emoji + words. **Design System canvas: dot-size only** (DESIGN.md §6) | Two components for one control — D2 |
| C7 | Month picker | Month **and year** (103) | Months of one year only | |
| C8 | Period end | Explicit "mark period end" from day detail (176) | Not drawn | No data model either (H5) |
| C9 | Discharge picker | The one chip with a value picker (227) | Not drawn | `refdata` supports it |
| C10 | Dashboard chat area | Feature list: "Chat area" on the Dashboard (28); Dashboard section: only a Chat **shortcut** (821) | Shortcut + tab, out of scope | The PRD disagrees with itself; the canvas follows the section |
| C11 | Profile fields | Age (27); ARCHITECTURE stores `age` 13–99 | `editProfile`: **Date of birth**, name, photo | A stored age is wrong within a year; Nutrition's BMR uses it. DOB is the right primitive |
| C12 | Landing screen | User lands on **Log in** (83) | Lands on **Sign up** with a cross-link | Code follows the canvas |

### 5.2 Inside the design set

| # | Conflict |
|---|---|
| D1 | **Tab bar.** Design System canvas and DESIGN.md §7: three tabs (Home · Calendar · Profile). App canvas: five (Home · Calendar · Eva Chat · Learn · Profile). Nutrition canvas: its own five. Three answers; #25 rejected only the third. |
| D2 | Five-point scale: dots (DS) vs. emoji (App) — C6. |
| D3 | "Button 15" vs. "14.5", sheet radius 30 vs. 24, no pressed state on solid destructive, no loading state, no motion — already listed in DESIGN.md §9c, still unresolved on the canvas. |
| D4 | **Three profile vocabularies inside one canvas.** `settings` rows say Lifestyle = "Sleep, work pattern, stress" and list Preferred sports; `editProfile` has Goals & lifestyle chips (Steady energy, Better sleep, Understand my cycle, Build strength, Manage stress, Conceive within a year) and Hormonal medications (Combined pill, POP, Hormonal IUD, Implant, HRT, None) and **no sports, no activity band**. The code has a fourth set (goals Energy/Sleep/Fitness/…, medications Yes/No/Not sure, lifestyle as four activity bands, eight sports). Nutrition needs the activity band; #19 is about to build "to the canvas" and there is no single list to build to. |
| D5 | Nutrition Settings duplicates Profile rows (Units, Health conditions). |

### 5.3 Canvas promises the system cannot keep

These are the same class as the "within 30 days" copy §9a already had to correct — text on a screen describing a product that does not exist.

| # | Screen | Claim | Reality |
|---|---|---|---|
| E1 | `privacy` | "Health entries are **encrypted on your device before they sync**." | No client-side encryption exists or is planned. Transport is TLS and Firestore encrypts at rest; the server reads every payload. Either this is a real E2E feature (large: key management, no server-side rules layer, no export without the key) or the copy is wrong. |
| E2 | `resetDone` | "Other devices were signed out." | The JWT is stateless, 30-day, unrevocable (ARCHITECTURE §3). Password reset cannot end other sessions unless #6 adds a token-version claim to `users/{uid}` and `requireAccount` checks it — a schema change, always-human. |
| E3 | `home_off`, DS "Couldn't sync" card, `scOff` | Cached briefing with a sync timestamp; entries saved on device and retried; queued scans. | No local store on iOS beyond the Keychain; ARCHITECTURE.md is silent on offline; #11 Q6 and #25 S13 are both "undecided". Every calendar slice from C3 depends on the answer. |
| E4 | `signupErr` | "This email already uses **Apple** sign-in — continue with Apple." | `POST /auth/signup` answers `EMAIL_EXISTS` without saying which provider; with Hide My Email the address can never match. The card needs either a provider hint in the response (an enumeration question for `security-engineer`) or generic copy. |
| E5 | `notifications` | "A notification says 'Eva has an update' until you unlock the app." | No push transport. FCM needs the Firebase iOS SDK the repo deliberately does not link (GUARDRAILS 25); APNs direct from the API needs a key, a device-token route, and a scheduler. Neither is decided. |

### 5.4 Website vs. everything

- Advertises Personal trainer, Mental well-being coach, Blog and Chat (none specified, none built) and shows a testimonials section for an unlaunched product.
- Still on the pre-canvas design (Cormorant Garamond, plum `#3A2233`) — the drift DESIGN.md §9 describes for the app, unaddressed for the site.
- `/privacy` and `/terms` are one-line placeholders while the sign-up screen links to them.

---

## 6. Actions

Grouped by who can move them. "Nick" = a product decision; "PRD" = a documentation
edit an agent can draft for review; "Canvas" = needs a session with `DesignSync`, then
re-pull the mirror; "Issue" = engineering, to be filed via `/backlog`.

### 6.1 Decisions only Nick can make (each unblocks several rows above)

> **All twelve answered by Nick on 2026-08-30 — see §8.** The table is kept as the
> question list; §8 holds the answers and what each one triggers.

| # | Decision | Unblocks |
|---|---|---|
| A1 | **Declare v1 scope** — which of the 11 features ship, in what order; explicitly park trainer, well-being coach, blog and general chat if they are parked, and fix the website copy to match. | P1, F1–F4, §5.4 |
| A2 | **Launch markets and languages.** | P2, #25 Q10, #26 jurisdiction, Language/Units rows, emergency guidance |
| A3 | **Offline: v1 or not.** If yes, a local store is an architecture decision to record in ARCHITECTURE.md before Calendar C3. | E3, #11 Q6, #25 S13 |
| A4 | **Tab bar: three or five.** | D1, and where Chat/Learn/Nutrition are reached from |
| A5 | **Eva Chat: specify or defer.** If deferred, remove the shortcut/tab from the canvas and the "chat area" from the feature list. | F1, C10 |
| A6 | **Calendar mode switcher placement** (Settings-only vs. persistent control). | C1, #11 Q1 |
| A7 | **Sex logging shape** (one-tap vs. sheet with optional details). | C3, #11 C10 |
| A8 | **Profile primitive and vocabulary**: DOB not age; one canonical list for goals, conditions, medications, activity band, sports. | C11, D4, #19, #25 S1 |
| A9 | **Push transport** (FCM + Firebase SDK, or APNs via the API). | E5, F5, appointment & meal reminders |
| A10 | **The encryption claim**: build device-side encryption (and accept its costs) or rewrite the privacy copy. | E1 |
| A11 | **Cycle-mode prediction rules**: method, "logged cycle" definition, irregularity threshold, whether the fertile window shows in Cycle mode. Health-adjacent; may belong with #26's clinician. | H1, #11 Q4/Q5, C11–C12 |
| A12 | **Age floor** for the product (not just nutrition). | P4, #26 |

### 6.2 PRD edits (draft-able now, review by Nick)

| # | Edit |
|---|---|
| B1 | Add a **Product frame** section: v1 scope, markets/languages, platform, monetisation, age floor, legal/consent, NFRs, analytics constraints (P1–P8) — filled from A1–A12 as they land. |
| B2 | Write back the nine stale decisions (S1–S9) in place, with the issue number, the way §Onboarding already does. |
| B3 | Move Calendar "Edge cases" and "Other requirements" out from under Pregnancy mode (H2). Fix the 14-vs-12 chip contradiction (H3). Reconcile feature-list rows 26–28 with their sections (S9, C10). |
| B4 | Add requirement sections, or explicit "deferred — not in v1" stubs, for Eva Chat, Blog, Trainer, Well-being coach, Notifications, Settings, Support, Account lifecycle (F1–F8). |
| B5 | Add the missing definitions inside full sections: period end model, Cycle-mode prediction, "pattern worth naming", server-configurable mechanism, region template content, EPDS decision (H1, H5, H7, H8). |
| B6 | State cross-feature dependencies where they bite: appointment and meal reminders → Notifications; "help phrase a question" and chat-created entries → Eva Chat; meal rows → Calendar indicators (H6, H9). |
| B7 | Record deletion semantics, password-reset semantics and export in the PRD so ARCHITECTURE.md is not the only spec (F8, E2, #58). |

### 6.3 Canvas updates (DesignSync session, then re-pull `docs/design/`)

| # | Update |
|---|---|
| G1 | Resolve D1 (tab bar) across all three canvases once A4 is decided; remove the Nutrition bar per #25 Q3 and draw how Log/Chat/Settings are reached. |
| G2 | Correct the five screens with unkeepable promises (E1, E2, E4 copy; E3 and E5 only after A3/A9). Same treatment as the delete-modal fix. |
| G3 | Fix the `day` spec's "purged after 5s" to the 30-day window (C2). |
| G4 | Bring chips, activity bands, BMI guard and score name in line with #24, #25, #26 (C5, §4.2). |
| G5 | Unify the profile vocabulary between `settings` and `editProfile`, add sports and activity band, switch to DOB (D4, C11). |
| G6 | Draw the missing Cycle-mode pieces: year picker, cycle-entry edit, period end, discharge picker, Sex per A7, Positive test (C4, C7–C9). |
| G7 | Draw the cycle-history / detail screen the Dashboard links to four times, and decide what the other "View …" actions open (§4.1 Dashboard). |
| G8 | Draw the auth states #6 and #38 introduce: activation landing, not-activated refusal, expired link, rate-limited, plus the provider-linking flow from Profile (#7). |
| G9 | Pregnancy journey — only once A1 confirms it is in v1. It is the largest undrawn area (§4.1). |
| G10 | Website re-skin to the canvas; real privacy/terms before the sign-up link goes live (§5.4). |

### 6.4 Engineering issues to file (via `/backlog`; none should start before its decision)

| # | Issue | Depends on |
|---|---|---|
| I1 | Period-end marker in `CyclePayload` + PATCH rule (H5) | A11 |
| I2 | Session revocation on password reset — token-version on `users/{uid}` (E2); attach to #6 | always-human schema gate |
| I3 | Provider hint or generic copy for `EMAIL_EXISTS` (E4); `security-engineer` review | #7 |
| I4 | Local store + sync queue architecture (E3) | A3 |
| I5 | Push transport + device-token route + reminder scheduler (E5) | A9 |
| I6 | Positive-test event type in Cycle mode (C4) | A1 (pregnancy in v1?) |
| I7 | DOB migration replacing `profile.age` (C11) | A8, schema gate |
| I8 | Units setting end-to-end (metric/imperial) (H9, F6) | A2 |
| I9 | Split #10 (Dashboard epic) — it still has no slices; the rules layer needs H8 answered | B5 |
| I10 | Website: fix feature claims, remove testimonials until real, re-skin, legal pages (§5.4) | A1, P5 |

### 6.5 Already tracked — no new issue needed

#6 activation & reset · #7 Apple/Google · #10 Dashboard epic · #11 Calendar epic (Q1–Q7 map onto A3, A6, A11 here) · #19 questionnaire → Profile · #25/#26 Nutrition and its clinical gate · #38 rate-limited state · #50 one-per-day restore · #58 export · #59/#56 deletion edges.

---

## 7. What this review did not do

- It did not open the live Claude Design project; the mirrors in `docs/design/` may be
  behind it (the README warns of exactly this).
- It did not audit the API against the PRD line by line — only where a PRD rule and a
  canvas rule disagreed and the code had already picked a side.
- It did not evaluate the *quality* of the drawn screens against DESIGN.md — that is
  #12/#16/#17/#60 territory.

---

## 8. Decisions — 2026-08-30

Answered by Nick in one sitting. Each row names the answer and the concrete change it
triggers, so the write-backs (§6.2–6.4) can be done from this table alone.

| # | Decision | Answer | Triggers |
|---|---|---|---|
| A1 | v1 scope | **Everything in the PRD is v1.** Order is the open question, not scope. | Website copy stands. F1–F4 need full requirement sections (not stubs). Pregnancy journey (G9) is a required canvas deliverable. §6.4 issues lose their "if in v1" conditions. |
| A2 | Markets & languages | **EU + UK, English at launch.** Localisation planned, not v1. | #26 assesses under GDPR + EU MDR + UK MHRA. Food DB must cover EU + UK (#25 Q10). Appointment template is per country (405). Emergency guidance per country (489). Language row: English only, list to grow. Units: metric default, imperial as a setting (I8). |
| A3 | Offline | **Yes — local store first.** | New ARCHITECTURE.md section (SwiftData store + sync queue over the existing `idempotencyKey`) lands **before** Calendar C3. Closes #11 Q6 and #25 S13. Canvas states `home_off`, `scOff`, DS "Couldn't sync" stay as drawn. I4 becomes the next mobile architecture issue. |
| A4 | Tab bar | **Five, per the App canvas:** Home · Calendar · Eva Chat · Learn · Profile. | Correct the Design System canvas and DESIGN.md §7 (G1). Nutrition, Trainer, Well-being are reached from Dashboard shortcuts, never a tab. Nutrition canvas' own bar is removed (#25 Q3). |
| A5 | Eva Chat | **One assistant across all domains; no symptom interpretation.** Sees profile, phase, recent logs, meals, goals; answers nutrition/training/well-being/planning; may create or edit calendar entries (`source:'eva'`, 486) and help phrase doctor questions (285). Symptom questions hit the deterministic escalation layer. | New PRD section (F1). Nutrition chat (706–712) becomes a scope of the same assistant, not a separate one. LLM vendor + data-processor question (#25 Q12) now applies product-wide. Regulatory line 491 stays satisfied until #26 says otherwise. |
| A6 | Mode switcher | **Settings-only, per PRD.** Calendar shows a read-only mode label; the segmented control is removed. | Closes #11 Q1: cycle-only slices ship no control. Canvas `modes` control removed (G6). One-time dismissible calendar prompt (293) still needs drawing. |
| A7 | Sex event | **Sheet with collapsed "Add details", per PRD.** | Canvas gains a `sex` sheet (G6). C10 payload: `{ protection?: 'protected'\|'unprotected'\|'other', type?: 'solo'\|'partnered' }`, both optional. |
| A8 | Profile | **DOB, not age. Vocabulary = canvas `editProfile` lists (goals & lifestyle chips; hormonal medications), extended with the code's four activity bands and the sports list; conditions extended with diabetes, coeliac disease, food allergies.** | Schema change on `users/{uid}` — always-human gate: `profile.age` → `profile.dateOfBirth`, new `medications` enum, new `conditions` entries (I7). #19 builds to this list. Canvas `settings` rows and `editProfile` unified to it (G5). `parseProfile` ranges re-derived from DOB. |
| A9 | Push | **APNs direct from the API.** | New API surface: device-token route on `users/{uid}`, APNs `.p8` in Secret Manager, a Cloud Run job for scheduled sends. No Firebase iOS SDK — GUARDRAILS 8/25 unchanged. Previews stay "Eva has an update". I5 is the issue. |
| A10 | Encryption claim | **Rewrite the copy.** | Canvas `privacy` footer → "encrypted in transit and at rest, never sold, never shared with advertisers, deletable in full" (G2). Add to DESIGN.md §9a as a deliberate deviation. No engineering. |
| A11 | Cycle maths | **Route the numbers to #26's clinician; engineer C11 against a fixture.** | C11 is built as an interface (cycles in → next-period date, fertile window, confidence out) with config-driven constants that **fail loudly when unset**. #26 gains: cycle definition, averaging method, irregularity threshold, whether the window shows in Cycle mode + the contraception notice. Closes #11 Q4/Q5 procedurally. |
| A12 | Age floor | **18+.** | Enforced at DOB entry and in `parseProfile` (with A8). Removes the minors question from #26. App Store age rating set accordingly. Website/legal copy states 18+. |

### What these unblock immediately (no further decision needed)

- **PRD write-backs B1–B7** can all be drafted now; B1's product frame is filled by
  A1, A2, A12 plus the still-open items P3 (pricing), P5 (legal/consent), P6 (NFRs),
  P7 (platform/HealthKit), P8 (analytics).
- **ARCHITECTURE.md** needs two new sections: the local store (A3) and push (A9).
- **Issues I1–I10** can be filed with their dependencies resolved, plus one new one:
  the `users/{uid}` schema change bundling A8 + A12 (DOB, medications, conditions).
- **#11** can move to `state:ready` for C3 once the A3 architecture section exists;
  Q1, Q4, Q5, Q6 are closed by A6, A11, A11, A3 (Q2, Q3, Q7 were already closed in code).
- **#26** gains four items (A2 jurisdiction, A11's cycle constants, A5's chat scope
  confirmation) and loses one (age floor).

### Second round, same day

| # | Decision | Answer | Triggers |
|---|---|---|---|
| A13 | v1 order | **Data first:** Auth → Profile → Calendar → Dashboard → Nutrition → Chat → Pregnancy → Learn / Trainer / Well-being. | Matches the dependency graph and the existing issue order (#6/#7 → #19 → #11 → #10 → #25). Pregnancy extends Calendar after the Dashboard exists; Chat lands once it has data to see. |
| A14 | Monetisation | **Paid subscription with a trial.** | New PRD section: StoreKit subscription, trial length and gating rule (one entitlement check at launch), a subscription/paywall screen and a "Manage subscription" Settings row for the canvas (new G-item), entitlement state on `users/{uid}` or verified server-side from App Store Server API — an API design question. Privacy/terms must cover billing. |
| A15 | HealthKit | **Not in v1; the PRD says so.** | No entitlement, no import. Revisit after Calendar logging ships. |

| A16 | Markets, revisited | **US + worldwide, English only, no localisation in v1.** Supersedes A2 (same day). | `docs/LAUNCH.md` works through what has to be true: FDA general-wellness scope, FTC HBNR and state consumer-health-data laws alongside GDPR/UK; worldwide barcode coverage for the food DB; locale-driven units; per-country emergency guidance with a neutral fallback; appointment templates only where reviewed; App Store storefront exclusions; English variant open. |

### Still open after both rounds

P5 legal/consent flow · P6 non-functional requirements · P8 analytics constraints ·
trial length and price point (A14) · whether entitlement is checked client-side
(StoreKit 2 receipts) or server-side (App Store Server API).

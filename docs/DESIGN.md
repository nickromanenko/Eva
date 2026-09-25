# Eva — Design System

**Source of truth: the Claude Design canvas** — "Eva App Design Prototype",
project `ed46e806-ffe6-43c7-9660-01c2cb4b625c`:

| Canvas file | Covers |
|---|---|
| `Eva Design System.dc.html` | Tokens, components, states, voice — transcribed below |
| `Eva App.dc.html` | Screen designs |
| `Eva Nutrition Coach.dc.html` | Nutrition coach screens |

<https://claude.ai/design/p/ed46e806-ffe6-43c7-9660-01c2cb4b625c?file=Eva+App.dc.html>

This document is the transcription of the design-system canvas, kept in the repo so
agents can read it without network access. **It does not describe the current code** —
see [§9 Drift](#9-drift-implemented-vs-designed). Where the two disagree, the canvas
wins and the code is wrong.

Before building or changing a screen, read the screen's canvas file — ask Claude to
`DesignSync get_file` it from the project above. Do not design from the existing code.

## 1. Principles

Pink and pistachio on warm off-white, layered as translucent glass. Calm, credible,
personal — never clinical, never decorative for its own sake.

- 8-pt spacing
- 44px minimum touch targets
- Never colour alone — every state carries shape, icon or text too
- 390 × 844 base frame

## 2. Colour

**Brand**

| Token | Hex |
|---|---|
| Primary Pink | `#E982A5` |
| Deep Pink | `#C95F86` |
| Soft Blush | `#F9DCE6` |
| Pistachio | `#CDE79D` |
| Deep Pistachio | `#8EAD56` |
| Light Pistachio | `#EDF6DA` |

**Neutrals**

| Token | Value |
|---|---|
| Warm Background | `#FFF9F6` |
| Secondary Background | `#F8F3F0` |
| Glass Surface 66% | `rgba(255,255,255,.66)` |
| Elevated Glass 92% | `rgba(255,252,250,.92)` |
| Primary Text | `#282126` |
| Secondary Text | `#6F656B` |
| Muted Text | `#9A9095` |
| Text on Dark | `#FFFFFF` |

**Semantic** — each is icon + text, never colour alone.

| Token | Base | Tint | Border | Ink | Mark |
|---|---|---|---|---|---|
| Success | `#7A9B45` | `rgba(205,231,157,.26)` | `rgba(142,173,86,.32)` | `#4F6630` | ✓ circle |
| Warning | `#C9913F` | `rgba(201,145,63,.10)` | `rgba(201,145,63,.3)` | `#8A6425` | ! rounded square |
| Error | `#C4645A` | `rgba(196,100,90,.08)` | `rgba(196,100,90,.26)` | `#A9524A` | ! circle |
| Information | `#5A7BA0` | `rgba(90,123,160,.09)` | `rgba(90,123,160,.26)` | `#3F5A76` | i circle |

The tint is **not** an opacity of the base — Success's is pistachio-based. Success means
saved/synced/confirmed; Warning needs attention but is not urgent; Error is always paired
with a message under the field; Information covers account linking, predictions and the
limits of data.

**Gradients** — blush→cream (`#F9DCE6`→`#FFF9F6`, 135°), pistachio→cream
(`#EDF6DA`→`#FFF9F6`, 135°), pink→pistachio (`#F3AEC4`→`#EDF6DA`, 120°), and white
highlight over pink: `rgba(255,255,255,.75)`→transparent over the full height, above a
135° `#E982A5`→`#C95F86` base. "Cream" is Warm Background.

## 3. Typography — Montserrat throughout

| Role | Spec |
|---|---|
| Display | 46/**56**, weight 400 — marketing headlines only, single-line |
| H1 · Screen title | 28/34, 600 |
| H2 · Section heading | 21/26, 600 |
| H3 · Card heading | 17/22, 600 |
| Body | 15/24, 400 |
| Body medium | 15/24, 500 — values and emphasis inside rows |
| Button | 14.5, 600 |
| Text button | 14, 600 |
| Control | 13, 600 — chips, row-level destructive, dialog buttons |
| Label | 12, 600, secondary |
| Caption | 12.5/19, muted |
| Input helper | 12/18 |
| Error text | 12, 500, with icon |
| Overline | 11, 600, letter-spacing .14em, uppercase |

Display uses the same family at weight 400; functional UI stays at 500–600.

The artboard draws Display at `46px/1.05` ≈ 48, but Montserrat's own line box at 46pt is
56.07 and SwiftUI cannot lead tighter than the font. **Display is 46/56 and single-line
by design** (#17) — at 46pt, leading tighter than the face was drawn for would be cramped
anyway, and a custom text layout for one marketing style is not worth its maintenance.

The artboard's §02 type card says "Button · 15/1 semibold" while every button in §04 is
`14.5px`. The components win.

## 4. Spacing, radius, elevation

Spacing scale: **4, 8, 12, 16, 24, 32, 40**.

Radii: **14** chips · **17** controls · **24** cards · **30** sheets (top only) ·
**pill** (999).

**Glass levels**

| Level | Fill | Blur | Use |
|---|---|---|---|
| L1 · Background glass | 40% white | 20 | Decorative only |
| L2 · Interactive card | 68% white | 24 | Body text safe |
| L3 · Sheet / modal | 92% white | 28 | Long-form content |

Standard card treatment: `linear-gradient(150deg, rgba(255,255,255,.66),
rgba(255,255,255,.36))`, blur 26 saturate 1.7, 1px `rgba(255,255,255,.72)` border,
shadow **`0 12px 30px -18px rgba(40,33,38,.35)`**, plus inset white lines at 90% top
(`inset 0 1px 0 rgba(255,255,255,.9)`) and 40% bottom (`inset 0 -1px 0 rgba(255,255,255,.4)`).

**The card shadow is a deliberate deviation, not a transcription — see §9a.** The canvas
draws it pink; we render it neutral, and the reason is how it composites, not what is drawn.

## 5. Buttons — min-height 52, radius 17

| Variant | Spec |
|---|---|
| **Primary** | `linear-gradient(180deg,#EE93B1,#C95F86)`, white, shadow `0 12px 26px -12px rgba(201,95,134,.8)` |
| Primary · pressed | Darker (`#D9799C`→`#B45276`), scale .97 |
| Primary · focused | 3px `rgba(40,33,38,.6)` ring |
| Primary · disabled | `rgba(201,95,134,.28)` fill, white text |
| **Secondary glass** | `rgba(255,255,255,.7)`, 1px `rgba(40,33,38,.1)`, blur 18 |
| Text button | min-height 48, radius 14, label 14/600 (colour: see §9a) |
| **Destructive** | Outlined `rgba(184,82,72,.5)` / text `#A9524A`; solid `#B85248` **in modals only**, disabled at 50% opacity; row-level variant at height 44, radius 13, label 13/600 |
| **Auth · Apple** | Solid `#1C1A1B`, white |
| **Auth · Google** | Glass `rgba(255,255,255,.85)` with hairline border |

Destructive-confirmed stays disabled until `DELETE` is typed.

## 6. Form controls

- **Input**: height 52, radius 17, horizontal padding 15, fill `rgba(255,255,255,.75)`,
  border `rgba(40,33,38,.1)`. Focused: fill goes opaque `#fff`, border `#C95F86` + 3px
  `rgba(201,95,134,.16)` ring. Error: fill `rgba(255,255,255,.8)`, border `#C4645A` + 3px
  `rgba(196,100,90,.14)` ring + icon-and-message below. Disabled: fill
  `rgba(248,243,240,.8)`, text `#B3A9AE`, border `rgba(40,33,38,.07)`.
- **Search**: same height, radius 26.
- **Dropdown**: same as input, caret at trailing edge.
- **Toggle**: 52×32, pistachio gradient when on.
- **Checkbox**: 22×22, radius 7, `#C95F86` when checked.
- **Radio row**: min-height 56, radius 18, title + description, selected fill
  `rgba(233,130,165,.14)` with `rgba(201,95,134,.45)` border. **Built as `EvaRadioRow` in
  #82**, where the units setting needed a single-choice list. The marks are the artboard's
  and not §6's prose: a 20×20 circle with a 6pt `#C95F86` annulus when selected and a
  1.5pt `rgba(40,33,38,.25)` hairline when not, so the two states differ in shape as well
  as in tint. The description takes Input helper (12/18) — the scale has no 11.5 row.
- **Chips**: min-height 44, radius 14. Default glass · selected pink gradient ·
  severe solid `#C95F86` with a bar glyph · disabled muted.
- **Five-point scale**: five 54-high cells, each an emoji with a word (Depleted · Low ·
  Steady · Good · High); the selected one is raised, opaque and outlined in the scale's
  ink, the rest greyed at 72%. The readout beside the label says "Low · 2 of 5" and each
  cell is announced as "Energy, 2 of 5, Low". Anchor labels at both ends. One component —
  the App canvas' `scales` — since 2026-08-30 (C6/D2). **Built as `EvaRatingScale` in
  #160**, where body signals needed it first; a scale given no glyphs falls back to the
  artboard's graduated dots.
- **Toggle** is still unbuilt. #160 needed a binary for an appointment reminder and used a
  chip rather than build a second design-system component inside a feature change — see
  §9a.

## 7. Surfaces, feedback, states

Content card, settings rows (52 min-height, chevron, destructive row in `#A9524A`),
info banner, toast (dark `rgba(40,33,38,.92)` with a pink Undo — `EvaToast`, built in
#160), alert dialog, bottom sheet (grabber, 30px top radius, L3 glass, 26px safe-area
bottom padding), empty state (dashed border), skeleton loading, and an error card with a
Retry action.

**Calendar cells** — every event carries a fixed position *and* shape as well as a
colour: sex = bottom-left circle, body signals = bottom-centre square, sport =
bottom-right diamond, appointment = top-right badge, positive test = top-left outlined
square. Flow uses three pink opacities; predictions are always dashed and patterned, and
nothing logged ever is. Today is a filled `#C95F86` circle; selected is a 2px outline.

**Tab bar & FAB** — five tabs (Home · Calendar · Eva Chat · Learn · Profile, A4) in a
`rgba(255,249,246,.8)` bar, active tab tinted; 56×56 FAB, radius 20,
`linear-gradient(160deg,#F0A0BA,#C95F86)`. The Nutrition coach, Personal trainer and
Well-being coach are pushed flows from Dashboard shortcuts and have no bar of their own.

**Calendar cells** also carry a positive-test mark: a 9px outlined square, top-left.

## 8. Voice

Eva describes, contextualises and points to care. It never diagnoses, never reassures
falsely, and never uses guilt, streaks or scores. Sensitive events stay neutral in
language *and* in indicators.

- We say: "That can be common during this phase. Here is when it is worth contacting
  your provider."
- We don't say: "You're fine!" · "Don't break your streak" · "Your fertility score
  dropped"

This applies to every user-facing string an engineer writes, not just marketing copy.
It binds the copy; [GUARDRAILS.md](GUARDRAILS.md) rule 35 binds the feature behind it —
no value that mimics a clinical measurement, and confidence shown at the point of use.

**US English, neutral roles (A17, 2026-08-30).** *anemia, hot flashes, color, fiber*; and
"your provider" / "your doctor", never GP, OB-GYN or midwife as a role the copy addresses.
Appointment *types* remain a catalogue (Scan · Primary care · Gynecologist · Obstetrician ·
Midwife · Blood test · Glucose test · Other).

## 8b. Canvas state

The canvas was updated on 2026-08-30 to the decisions in
`reviews/2026-08-30-prd-and-design-review.md` §8 (A1–A24): five tabs, the read-only mode
chip, the Sex and Positive-test sheets, the shipped chip vocabulary, the A8 profile
lists, six auth states, the consent and paywall screens, the cycle-history / contact /
support screens, US English, and the copy corrections in §9a. The mirrors in
`design/` are that upload. Placeholders remain wherever a decision fixed *that*
something changes but not *to what*: the score name (#25), the BMI floor and every
nutrition constant (#26), prices (App Store Connect).

## 9. Drift: implemented vs designed

The onboarding flow in `mobile/Eva/` was built against an earlier direction and does
**not** match the canvas.

**As of #1 the canvas tokens exist in code**, and **as of #2 the controls use them** —
buttons, chips and inputs are on the canvas system. Everything around them is not:
screens still draw their backgrounds, headings and body copy from the legacy set at the
bottom of `EvaColors.swift`, so the app currently reads as canvas controls on mauve
screens. #3 re-skins the screens and removes the legacy tokens with it.

| Aspect | Canvas | `mobile/Eva/Theme/` today |
|---|---|---|
| Typeface | Montserrat everywhere | SF Pro, serif headings |
| Primary accent | `#E982A5` / `#C95F86` pink | `#8E2C57` / `#C96A93` plum |
| Text | `#282126` / `#6F656B` / `#9A9095` | `#3A2233` / `#6E5E69` / `#98868F` |
| Background | `#FFF9F6` warm off-white | `#FBF7FA` → `#F7EEF4` mauve gradient |
| Second brand colour | Pistachio family | none |
| Surfaces | Translucent glass, 3 levels | Flat white |
| Screen title | 28/34 Montserrat 600 | 31 serif semibold |
| ~~Primary button~~ | 52 high, radius 17, 180° gradient | **done (#2)** |
| ~~Chips~~ | 44 min-height, radius 14 | **done (#2)** |
| ~~Inputs~~ | 52 high, radius 17, focus ring | **done (#2)** |
| ~~Semantic colours~~ | Four, with marks | **tokens done (#16)**; no screen uses them yet |

The rows still open are all *screen*-level: typeface, palette, background and surfaces
are what #3 changes — though #3 turned out to be a flow change, not a re-skin: the canvas
draws onboarding as one screen and has no questionnaire steps, so five screens are
replaced rather than restyled, and the questionnaire keeps its legacy styling until it
moves into Profile. The control rows are struck because the components carry the canvas
system now, even though the screens they sit on do not.

**Do not resolve this drift screen-by-screen inside unrelated work.** Re-skinning to
the canvas is its own tracked change; until it lands, match the canvas for anything
new and leave existing screens alone unless the issue says otherwise.

## 9a. Deliberate deviations from the canvas

Places the implementation knowingly differs from the artboard, and why. Each was
approved on #12; none is drift.

**The action ramp.** White on the canvas pink fails WCAG AA everywhere it carries a
label — 2.22:1 at `#EE93B1`, 3.84:1 at `#C95F86`, against 4.5:1 for a 14.5pt semibold.
Surfaces that carry a label therefore use a deepened ramp; washes, tints and decorative
fills keep the artboard's pale pink.

| Token | Value | White on it |
|---|---|---|
| `evaActionPinkTop` → `Bottom` | `#B45276` → `#96486A` | 4.76 → 6.12 |
| `evaActionPinkPressedTop` → `Bottom` | `#994664` → `#803D5A` | 6.15 → 7.68 |
| `evaActionPinkSolid` | `#A94A6C` | 5.41 |
| `evaChipSevere` | `#7E3B58` | 7.91 |

`evaChipSevere` is not simply the ramp: at `#A94A6C` the severe chip landed four
channel-units from the selected chip's midpoint and the two states became
indistinguishable. `#7E3B58` sits ~80 units deeper, so severe still reads as the more
serious of the two.

**Disabled labels on filled controls.** The artboard keeps them white. On the primary's
`rgba(201,95,134,.28)` that measures 1.45:1, and on the solid destructive's `#B85248` at
50% it measures 2.10:1. Both use `evaPrimaryText` instead — 10.87:1 and 7.49:1. Disabled
controls are exempt from WCAG 1.4.3, but the sign-up CTA sits disabled until the form
validates, so an unreadable label is the first thing a new user meets.

**The text button** uses `evaActionPinkTop` rather than `#C95F86`, which measures 3.68:1
on the warm background. **The input placeholder** uses Secondary Text rather than Muted
Text, which measures 3.07:1 on the field fill.

**The selected chip's shadow** takes the ramp's darkest stop rather than the artboard's
`rgba(201,95,134,.8)`, which is lighter than the deepened fill and renders as a glow.

**A disabled field that is also in error.** The artboard draws "Error" and "Password ·
disabled" as separate cells and never combines them, so #14 chose: the fill and the text
go quiet, and the error border, the error ring and the message stay. A message drawn with
nothing marking the field it belongs to points at nothing, and §2 asks for the mark as
well as the colour. Before #14 `EvaInputField` resolved `isEnabled` first and a disabled
field in error drew the message under the 7% disabled hairline with no ring at all.

**The password field's Show/Hide when the field is disabled** takes `evaDisabledText`,
which is the artboard's own value in that cell (`#C8BFC3`). It previously had no disabled
appearance: `.plain` faded the action pink to half, so the colour was a side effect of the
button style rather than a chosen ink.

**Settings-row meta and value take Secondary Text, where the artboard draws Muted.**
`#9A9095` measures **2.96:1** on the warm background, against the 4.5:1 WCAG 2.1 SC 1.4.3
asks of normal text; Secondary Text measures 5.37:1. Same deviation and same reason as
the input placeholder above — the row's meta line is informative text, not a placeholder,
so it is the more clear-cut of the two. The row's chevron keeps the artboard's `#C8BFC3`:
it is a mark, not text, and the row is announced as a button with or without it. (#82,
`ProfileSettingsRow`.)

**Display** is 46/56 — see §3.

**The auth screen scrolls slightly at the default content size**, where the canvas draws
it as a fixed 390 × 844 frame. The artboard's layout has about 1pt of slack (789.15pt of
content in a 790pt box), and two unavoidable costs eat it: the "Log in" / "Create an
account" cross-link is a 48pt touch target where the canvas draws a 20pt inline link
(+28pt, and §1's 44pt minimum is not negotiable), and real safe areas are 59 + 34 against
the artboard's 54 + 0 (−9pt). Net overflow ≈ 37pt. The CTA, legal note and cross-link are
pinned below the scrolling area so they stay reachable with the keyboard up; focusing a
field scrolls it and its helper into view, so the password rule is still never "revealed
as an error after failure", which is what the artboard's spec note protects.

At accessibility text sizes the screen deliberately becomes a single scrolling column —
a pinned footer at AX5 takes ~450 of 781pt and truncates the CTA.

**The delete-profile copy says what the server actually does.** The artboard's modal
reads "removes your cycle history, logs, notes and appointments from Eva's servers
**within 30 days**", and its danger card reads "Removes all logs, notes and
**predictions**". Neither is true: `DELETE /me` (#8) deletes immediately and completely,
and Eva has no predictions feature. §8 asks the product to describe rather than soften,
and the one screen where that matters most is the one telling someone their health record
is about to be destroyed. Both strings were rewritten to name what is actually removed,
and the modal says "straight away" rather than giving a window that does not exist.

**The sign-up linking banner never names a provider.** The canvas' `signupErr` reads
"This email already uses Apple sign-in — continue with Apple". `EMAIL_EXISTS` does not
reveal which provider an address uses, and a Hide My Email relay has none to name, so
"continue with Apple" would send some people to create a second account (#7). The app says
"This email already has an Eva account" and offers "Log in", never a provider button.
(#77.)

**The Privacy & security footer says only what is true — and what the request policy
says (A10, A19).** The artboard once promised device-side encryption; A10 rewrote the first
sentence to what the architecture delivers, and A19 (#91) added the second. As drawn on
the canvas since #108, and the one wording for the app:

> Your health entries are encrypted in transit and at rest, never sold, never shared with
> advertisers, and deletable in full. Eva hands data to no one without legal process, tells
> you when it does unless a court forbids it, and publishes how often it was asked.

The second sentence is the in-app statement of `REQUESTS.md`; change one only with the
other. "No one" is read against the consent screen (A21), which is where the processors
Eva does use are named and agreed — the footer is about requests from outside, and
`REQUESTS.md` §2.4 is where the two meet. The same screen carries a **"Requests for your
data"** row (value "Policy") below Data export, which opens the website's `/transparency`
page rather than an in-app copy: the policy has legal positions still marked *counsel*,
and the one place they change is the one place they are read. Neither the footer nor the
row is built yet; both are drawn.

**"Export data instead" is back (#58).** #55 dropped the export button and the "Export
your data first" card because there was no export, and an inert button next to an
irreversible action reads as an offered escape route. `GET /me/export` now exists, so both
are restored as the original artboard (`7ee0ec9`) drew them — the card under the body, the
button first in the action stack — which is what the canvas' `SPEC.danger` note asks for.
The card takes §2's Success tint, border and ink (the artboard's `#5C7434` ink and .30
border are near-misses of `evaSuccessInk` and `evaSuccessBorder`), `EvaRadius.control` for
its 16px radius, and Caption for its `500 12.5px` text. The file is saved through the
system's save-to-Files sheet rather than a share sheet — a document picker in move mode over
a file the app writes itself, protected, and removes afterwards, because SwiftUI's
`.fileExporter` was measured leaving its own copy in `tmp/` — and the button never disables
the confirm button, so offering export does not make deletion harder to reach.

**The card shadow is neutral, where the canvas draws it pink (#12).** §4 gives
`0 12px 30px -18px rgba(40,33,38,.35)`; the artboards overwhelmingly do not.

The counts, because the first version of this note got them wrong and the honest number is
the point: the Design System artboard uses `rgba(150,72,100,.45)` for cards **18 times**, and
the App artboard uses `rgba(150,72,100,…)` **16 times** across cards, tiles, banners, buttons
and sheets. The neutral value appears **twice**, both on the settings screen, and one of those
is a different geometry. So this is **26 drawn instances against 2** — pink is the design
language and the settings screen is the outlier.

We deviate anyway, and not because of the count. A saturated shadow under a **translucent**
card does not read as depth: the card's `Material` samples the shadow behind it, so the tint
comes through the card as well as around it. Measured on Profile, the pink rendered a
`#D5B2BA` ring — visibly mauve against a `#FEF8F5` ground. That is a compositing outcome the
artboard cannot show, because CSS `backdrop-filter` and SwiftUI `Material` do not sample the
same thing, and it will happen on every screen using this treatment rather than only where it
was noticed.

Two things this note deliberately does **not** claim. It is not a fix for the grey cast —
measured, the cast got marginally *worse* (card minus ground went −15 · −17 · −14 → −23 · −18
· −17), and that is #60. And the Profile card it was read from is not the §4 card: it differs
in five further properties (flat 62% fill rather than the 150° gradient, no `saturate`, an
`.85` border, a top inset line only, radius 26). The shadow is the one property taken from it.

If the artboards are ever corrected, correct them by **elevation** — the pink value originates
as the bottom sheet's shadow (`0 -22px 50px -22px`), which is right under a sheet and wrong
under a translucent card.

**L1 glass renders no `Material`.** `Material` adds its own tint beneath the white fill,
so a 40% surface read at roughly 70% and L1 was indistinguishable from L2. L1 is
decorative and needs no backdrop blur; a plain 40% fill restores the separation. L2 and
L3 keep `Material`.

**The resend cooldown counts down in the button, not in a toast.** The canvas shows a
toast for the once-per-60s limit on **Check your inbox** and **Reset link sent**. There
is no toast component in `Eva/Theme/` and an auth screen is not where one should be
designed, so `AuthResendButton` puts the wait in its own label ("Resend email · 42s") and
disables itself. That satisfies §2 better than the toast did — the state is where the
user is looking, and it says both *unavailable* and *for how long*, so it is never
dimming alone. The resend confirmation takes the toast's copy as a line in place
(`AuthStatusLine`). **The toast exists now** (#160), and both are still candidates to move
onto it — moving them is its own change, not something to fold into a calendar slice.

**"Back to log in" on Reset link sent is not on the artboard.** The canvas continues from
that screen into an in-app "Choose a new password", which v1 does not build — the reset
form is on the website. Without the extra text button the screen's only actions are "open
another app" and "send it again", which strands someone who has already set their password
in the browser. Same reasoning as `UnreachableView`'s log-out.

**The activation gate's rate-limit banner is Information, not Error.** A `429` on Resend
means the request was refused before anything happened; nothing the user typed was wrong
and nothing about the account changed, so the field-error treatment would blame the wrong
thing. `AuthRateLimitedBanner` uses `EvaInfoBanner`.

**The log-in screen can say why the session ended (#59), which the canvas does not draw.**
A delete refused because the credential had died signs the app out and takes the delete
modal with it, so the explanation has to be on the screen the user lands on.
`AuthSignedOutReasonBanner` is an `EvaInfoBanner` under the hero — Information for the
reason the rate-limit banner is: the server refused the request before acting on it and
nothing about the account changed. Its title says the profile was **not** deleted, because
a silent return to the auth screens is what a deletion that worked looks like.

**The tab bar carries three tabs, not five (#159).** The canvas draws Home · Calendar ·
Eva Chat · Learn · Profile (A4), and says itself that two of them are undrawn: its own
handlers answer "Eva Chat is not drawn yet — it is v1 (A1, A5); its own design phase
follows the Dashboard", and the same for Learn. A tab whose only content is that sentence
is worse than a tab that is not there yet, so they arrive with their screens.

**Home is the landing tab again (#99).** #159 landed on Calendar instead, and said why —
"the Dashboard is unbuilt and landing on a placeholder in front of the one real screen is
not what the tab order means". D4 built the Dashboard, so the reason is spent and the
canvas' own order stands. The three-tab count is unchanged and still waiting on Eva Chat
and Learn.

**The tab bar's marks are SF Symbols.** The artboard draws an 18pt rounded outline in
every tab — the same placeholder convention as the Google mark, whose own caption calls it
a slot for a supplied asset. Shipping it literally would put three identical squares in the
bar. Replaced wholesale when the canvas draws real marks.

**The active tab label uses `evaActionPinkTop`, not `#C95F86`.** The same §9a action-ramp
argument as the text button, and the same measurement: `#C95F86` on the warm background is
3.68:1, under AA for a 10.5pt semibold label.

**The calendar month header is H2, where the artboard draws 26/400 (#159).** The §3 scale
has no 26/400 row, and it is one of several light-weight title sizes the canvas uses that
§3 never captured — see §9c, which already reports the same gap for the auth screens' 40,
34 and 30pt rows. H1 (28/600) was tried first as the screen-title row and **wraps to two
lines** on "September 2026" in the width the two month steppers leave; H2 fits every month
on one line and is the closer match in optical weight, being smaller and heavier where the
artboard is bigger and lighter. Its day-detail heading is H2 against the artboard's 24/400
for the same reason, and
"today" is drawn at Body medium (15/500) against the artboard's 15/700, since the filled
disc and the white ink already say today without a weight the scale does not have.

**The day's entries are listed under the grid, not in a bottom sheet (#159).** The canvas
opens a large sheet on a day tap (`SPEC.day`), and that sheet is mostly Edit, Delete, Mark
period end and Add entry — all C2 or C5. A sheet with a read-only list and no action is a
surface you open to find nothing to do, and it covers the selection outline that the same
screen's criterion pairs with the listing. Its dashed empty row also lost its second line
("Add flow, body signals, sport or an appointment"), which instructed the user to use a
control C1 did not have.

This note originally promised the sheet would arrive in C2 with the actions that justify
it. **It did not, and the line below says why** — the actions arrived on the rows, and the
empty row's second line came back with them.

**The calendar's log FAB is live (#160).** It was drawn and disabled in C1 because what it
opens is `SPEC.picker`, which was this slice; C2 turns it on, and it opens the picker on
the **selected day** rather than on today, which is why the picker's header states the
date. The `calEmpty` pointer above it now points at something that works. C1's assertion
that the button is disabled did its job — turning it on had to come past a failing test and
past this note, and the assertion is now inverted rather than deleted.

**A spotting day is a ring around the number, which the canvas has not drawn (#160).** The
artboard's `mkCell` branches on flow 1–3 only, so a spotting day falls through to an
ordinary cell — announced ("Spotting logged"), listed in the day detail, and invisible on
the grid. C1 left it as drawn because nothing could log one yet. C2 can, so it is drawn,
and three constraints decided the shape:

- **not a wash**, at any strength — a fill is the grid's word for "period day", and that is
  the one thing a spotting day must not say;
- **not a corner mark** — all four corners were taken (dot, square, diamond, badge) and the
  top-left was already promised to §7's positive-test mark, which #80 has since drawn there;
- **not dashed** — dashed and patterned are reserved for *predicted* data (§7), and this is
  something the user logged.

What is left is a solid `#C95F86` ring, 32pt, around the day's own number: shape-distinct
from every flow cell rather than a paler one of them, concentric with the 28pt today disc
so a day that is both shows both, and inside the selection outline so neither hides the
other. The legend gains a row for it. **The canvas still needs to draw this** — the
implementation is ahead of the artboard here, not reading it.

The cycle sheet's own spotting swatch keeps the artboard's **dashed** ring
(`1.5px dashed rgba(201,95,134,.6)`), which is the canvas' drawing and is unambiguous
there: a sheet has no predictions on it to confuse a dashed outline with.

**The predicted cell's dash pattern is 3-on-3-off, which is not a canvas value (#206).**
The artboard writes `border:1px dashed` and CSS leaves the segment length to the renderer,
so there is nothing to transcribe. 3/3 keeps the outline visibly broken around the cell's
15pt corner radius; a longer dash closes up on the curve and reads as solid, which is the
one thing this outline may not do. The fills and outline colours *are* the artboard's, and
the legend's swatch uses the **cell's** values rather than the legend row's own — the two
differ by a few hundredths of alpha, and a swatch that is literally the cell is the whole
job of a legend.

**The calendar's summary card keeps the canvas' card and not its copy (#206).** In Cycle
mode the artboard fills the three slots with `'Cycle day 15 · follicular'`, `'Energy
usually climbs this week'` and `'Your next period is estimated around 31 Aug, based on your
last 4 logged cycles. Estimates shift as you log.'` Two of those need data no route serves
this screen: cycle day and phase come from the Today card's own analysis, and the *count*
of logged cycles is not on `GET /me/cycle/predictions` at all — it answers three lists of
days, a confidence band and a withheld reason. So the kicker is `Estimate`, the heading
names the estimated date, the body is the band's own sentence, and the artboard's closing
line is kept verbatim. Nothing restates a threshold the server owns: A27's bands are 3–5
and 6+ counted cycles, `narrowBandMinCycles` is configuration, and a number in this copy
would be a second copy of it. The canvas should draw the withheld states — it has none.

**The positive-test mark and its legend row are drawn (#80).** The artboard's legend lists
three predicted or unlogged things; #206 drew two and #80 drew the third, so the rule this
legend has followed since C1 — a row and its mark ship together — is satisfied for the last
of them and the legend describes nothing the grid cannot draw. §7's 9pt top-left outlined
square is a transcription: `9px/border-radius:3px/border:1.5px solid`, at `left:4px;top:3px`,
with `#A9436E` taking `evaActionPinkSolid` as everywhere else on this screen. The stroke is
**solid** — dashed and patterned are §7's word for a prediction, and a test result is
something she reported, which is the one distinction on this grid that a wrong stroke would
erase.

The corner was held for it from C1: it is why spotting became a ring around the number
rather than a fifth corner mark (see the note above). Spending it fills all four corners, so
the next type to want one revisits the design rather than taking "the same shape in a new
colour".

**The legend row says "outlined square" where the artboard says "mark".** The artboard's
own string is `Positive test · top-left mark`, which names the corner and not the shape —
the one rule every other row keeps, and the reason the legend exists at all in a grid whose
marks are 5–9pt. `Positive test · top-left outlined square` is what §7 specifies and what
the cell draws, and it is also what separates this row from the filled centre square above
it. A deviation, not a transcription.

**Nothing logs one yet.** #80 ships the event type, its validation, the mark and the legend
row; the picker row and the sheet that write a positive test are a further slice, so the
grid draws an entry the app itself cannot create — the same position `sex` has been in since
C1, except that here the route does store it.

**The day's entries carry Edit and Delete in place, not in a day sheet (#160).** C1's note
above promised the sheet would arrive with the actions that justify it. It has not, and the
promise is withdrawn: the log picker is itself a bottom sheet, so a day sheet that opens
one would be two sheets deep before anything is logged, and the actions attach to an entry
— moving them into a sheet moves the entries with them, off the screen where they sit under
the day that is outlined. What the day sheet would add over this is "Add entry", and the
FAB already is one for the selected day. The artboard draws both buttons at
`min-height:36px; radius:11px; font:600 12.5px`, which is under §1's 44pt floor and matches
no §5 variant; both take §5's standard 52 — the secondary glass and the outlined
destructive — which keeps them the same height as each other. The dashed empty-day row gets
its second line back, since there is now a control to point at.

**Delete asks nothing before it happens.** It is a soft delete, reversible for thirty days,
and the toast offers Undo immediately. A confirmation dialog in front of a reversible action
is what teaches people to dismiss dialogs without reading them — and the one dialog in the
app that must be read is the profile delete, which is not reversible.

**The log sheet uses the platform's date and time pickers.** `SPEC.picker` asks for "an
obvious change control" beside the target date and the artboard wires it to `noop`; the
appointment sheet draws a Date and a Time field and specifies no control for either. The
design system has no date or time picker, and inventing one is a design decision rather than
a transcription — so `DatePicker` is used, tinted `evaActionPinkSolid` and bounded to what
the route accepts (no earlier than twelve months back; forward without limit, because
appointments are made ahead).

**The appointment reminder is a chip, not §6's toggle.** §6 specifies a 52×32 pistachio
switch and the design system has never built one. Building it inside a feature change would
make this a design-system PR; a chip already carries a binary with fill, label colour and
elevation moving together (§10), and the row says in words what the reminder stores and
that nothing is scheduled yet.

**Three things the artboard's log sheets draw that C2 does not.** The cycle sheet's
"Anything else today?" chips, which are symptom chips — symptoms live on a *body signals*
entry, so drawing them there would either write a second entry nobody asked for or give one
concept two homes (the rule #24 settled for the catalogue). The sport sheet's "Recently
used" row, which is a claim about the user's habits that nothing in C2 can answer. And the
appointment sheet's two pre-written questions, which are neither reference data nor hers.

**The picker draws a Sex row it cannot open.** The canvas is specific about how that row
must look — a neutral label and a neutral dot, no imagery — and the route reserves the type
until C10 ships it with its privacy switch. It is drawn, dimmed, and says "Not available
yet", in the same treatment as a type the chosen day refuses: a type the calendar can
*display* but the picker omits entirely would read as a bug rather than as a plan. The
"Positive test" row is dropped rather than dimmed. C2 dropped it as a pregnancy-mode entry,
which the PRD's own event table contradicts — it reads *yes* in Cycle and in Planning — so
since #80 the reason is simply that there is nothing to open: that issue ships the type, the
mark and the legend row, and the sheet that writes one is the slice after it. When the row
arrives it goes after Cycle, where the artboard puts it.

**The calendar's legend lists Appointment and Spotting, and no longer drops anything.** The
artboard's legend explains period, predicted period, fertile window, sex, body signals,
sport and the positive-test mark, and never explains the appointment badge it draws. C1
dropped three rows, because the grid then drew no predictions and no test mark and a legend
entry for a mark the grid never draws is a promise; #206 and #80 drew those marks, and each
row arrived with the mark it describes. Appointment gets the row the artboard omits, and
spotting gets one in #160, because a ring and three washes that share a colour and do not
share a meaning are exactly the pair a legend exists for.

**The calendar's surfaces take the nearest named glass level and radius.** The artboard
gives the screen its own percentages — 34% on a day cell, 50% on the legend, 60% on a month
stepper, 68% on the summary card, 85% on the month picker — against §4's three levels. They
map onto L1 / L1 / L1 / L2 / L3, and the cards take `EvaRadius.card` (24) and
`EvaRadius.banner` (20) against the artboard's 22 and 20. The white hairlines run .6–.9 on
the artboard and all take §4's own .72. Same rule `ProfileView` set: the nearest named value,
and the difference reported rather than tokenised for one screen. The mode chip's ink is
`evaActionPinkSolid` (`#A94A6C`) against the artboard's `#A9436E`, and the appointment
badge's is `evaInformationInk` (`#3F5A76`) against `#4A6480`.

**Tappable things on the calendar are 44pt.** The artboard's month-picker chips are 38 high;
§1's floor is not negotiable for something you tap, so they are 44 — the same trade
`AuthScreenParts` took for the log-in cross-link. The log sheets take the same trade twice
more: their × is 44 against the artboard's 40, and the toast's Undo is 44 against its 32.
The read-only mode chip keeps the artboard's 34, because §1's floor is about interactive
elements and that one is a label.

**The Today card's fill is the artboard's, over §4's card (#99).** The canvas gives each of
the four tones its own surface (`CARDS` → `surf`). Read against the token set they are one
surface wearing three of §2's semantic families — §4's card supplies the radius, the white
hairline, the inset lines and the neutral shadow, and each tone supplies a fill:

| Tone | Artboard | Built as |
|---|---|---|
| `base` | `linear-gradient(155deg,#fff .9,#fff .74)`, `#fff .95` border | the artboard's two stops at §4's 150°, no extra border |
| `edu` | `rgba(237,246,218,.94)` → `rgba(255,255,255,.8)`, `rgba(142,173,86,.32)` border | Light Pistachio at the artboard's alphas; `evaSuccessBorder` (exact) |
| `flag` | `rgba(255,247,235,.97)` → `rgba(255,250,244,.92)`, `rgba(201,145,63,.55)` border 1.5px | `evaWarningTint`; `evaWarningBorder` (.30 against .55) at the artboard's 1.5pt |
| `quiet` | `rgba(255,255,255,.86)`, `rgba(40,33,38,.08)` border | white at the artboard's alpha; `evaControlBorder` (.10 against .08) |

The fills are carried rather than dropped in favour of §4's own 66% → 36%, and that is a
*measured* decision rather than a preference: at 66% over `Material`, the material's grey
decides the colour and the hero card of the app renders **darker than the ground it sits
on**, where the canvas draws it brighter. That is #60 at its most visible. This is not a fix
for #60 — it is the artboard's fill, which happens to be opaque enough that the material
stops deciding. The card radius takes `EvaRadius.card` (24) against the artboard's 28, and
its padding `EvaSpacing.lg` (24) against 22, on the usual rule.

**The Today card's actions are §5's buttons, and the primary style is only for an action
that works (#99).** The artboard draws them at `min-height:46px;border-radius:15px;
font:600 13.5px`, which matches no §5 variant — the same finding #160 made about the day
detail's Edit and Delete — so they take §5's standard 52/17. A §5 button is full width, so
the artboard's wrapping row becomes a column, which is also the only arrangement in which
"View contact options" and "Review what I logged" both fit unabridged.

The artboard styles the **first** action as the primary (`i === 0`). In D4 that action is
usually disabled, because every `View …` / `Review …` / `Read article` opens a screen the
canvas has not drawn (review G7) — nine of the fourteen cards have no working action at all.
A disabled §5 primary is a full-width 28%-pink slab, which made a dead control the loudest
thing on the card and put a pink one on the amber `flag` surface. So the primary style is
narrowed to an action that can be taken, and an unavailable one takes the secondary glass
wherever it sits.

**The flag tone's amber primary is unbuilt.** The artboard fills the first action `#B5822E`
on that tone. Both of `home_flag`'s actions reach D11 screens, so it is unreachable in D4,
and it has no token — a second primary fill is a design decision (GUARDRAILS 20), not a
transcription. Reported rather than taken.

**The Home header's greeting carries no name, and the avatar is the address's initial
(#99).** The artboard reads "Good morning, Maria" over a letter avatar. **Eva stores no
name** — `APIUser` is an id, an address, the activation flag, the providers and the
questionnaire `profile`, and a given name would arrive with #19's Edit profile. Rendering
"Good morning, e2e+4f1c…" would be worse than saying less, so the greeting is the time of
day alone (morning before noon, afternoon before six, evening after — the artboard draws one
greeting at one hour, beside an offline bar stamped 08:12). The avatar takes the address's
first letter, which is the same letter for the artboard's own example. The avatar's fill is
`LinearGradient.evaActionPink` rather than the artboard's `150deg,#F3AEC4,#C95F86`: it
carries a white label, and that is the §9a action-ramp rule.

**The notifications button has no unread dot.** The artboard puts a 7pt pink badge on it.
Eva sends no notifications yet, a dot is a claim that something is waiting, and §8 is about
not saying things that are not true. It arrives with §Notifications, along with the button
becoming live.

**The flag kicker's mark is a slot the canvas left empty.** `kick.flag` is an
`inline-flex` with `gap:7px` and one child — space for a glyph that is not drawn. §2 asks
every semantic state for a mark as well as a colour; nothing was invented to fill it,
because the flag card's own copy ("Contact your maternity provider … Eva cannot assess
this") is what carries the state in words. The canvas should draw the mark.

**"No card for today yet" is not canvas copy (#99).** The artboard draws fourteen cards and
no empty state for the card slot, because in the design there is always a card — `home_a` is
the zero-data one. The built system has a second way to have none: `content/` is empty until
a clinician signs its copy off (#97 refuses to seed without a reviewer), and a device cannot
fill a card out of an empty store. It uses §7's information banner and states the fact
without promising when a card will appear. Replace it with the canvas' words the moment it
draws some.

**The "Worth reading" rail takes §4's card and §2's washes (#102).** The artboard draws each
rail card at `rgba(255,255,255,.72)` with a `.9` border, a pink shadow and radius 22; it takes
§4's card surface at `EvaRadius.card` (24), the same trade the nudge slot beside it made for
the canvas' `.7` fill, with the neutral shadow above. The editorial image slot is 115° stripes
captioned "editorial image" — the canvas' placeholder for an image the payload does not carry
— so it is §2's blush→cream and pistachio→cream washes alternating by position (blush,
pistachio, blush, as drawn), with no caption. The header "Worth reading" (`600 10.5px`,
`#9A9095`) is Overline in Secondary Text, the settings-row contrast argument above; the title
(`600 13.5px/1.4`) is Control and the meta (`500 11px`) Caption. The "Learn" link is drawn as
a §5 text button, **disabled** and announced "Not available yet." until the Learn tab exists —
which also makes its row 48pt tall, so the gap between the header and the cards is wider
than the artboard's 10px. A tap on a card opens its article in `SFSafariViewController`,
full screen; the canvas draws no destination.

**An unavailable picker row is dimmed lightly, and its title is Secondary rather than the
disabled ink.** Stacking `evaDisabledText` on the row's own opacity made the sentence
explaining the refusal the least readable thing on the sheet — which defeats the point of
drawing the row instead of hiding it. Same argument as the disabled labels on filled
controls above, and it matters more here, because on those the label is decoration and here
the sentence *is* the affordance.

**The consent screen (#86) omits the canvas' two `[pending]` processors, states the
policy line without a link, and draws the block-to-continue as an inline message rather
than a toast.** A shipped screen cannot show "assistant vendor — pending" as if it were a
fact; the list grows when the vendors do, alongside the privacy policy that names them
(L3, still with counsel). "Read the health-data privacy policy" is plain text because the
site has no configured public URL for the app to open — the same limit the sign-up
footer lives with. And the canvas' toast on Continue-without-the-store-toggle ("Eva needs
the first choice to work. The second is yours either way." — kept verbatim) becomes an
inline message under the cards, because §7 reserves the toast for what *has* happened,
and this says what will not.

**Settings › Privacy (PrivacySettingsView) states the freeze in place of the canvas'
undrawn screen.** The canvas names the destination ("Both withdrawable in Settings ›
Privacy") without drawing it. Its withdrawal dialog carries the consequence the #86
decision fixed — nothing new is collected, what is stored stays — because a withdrawal
that read as "delete my data" would be as wrong as the silent opposite. Row actions use
the theme's button styles directly under row-scoped identifiers, since both rows can be
in the same state at once and title-derived identifiers would collide.

## 9b. Where iOS cannot express the canvas

Real platform limits, not decisions:

- **Blur radii are not settable.** SwiftUI has no `backdrop-filter`; L2's 24 and L3's 28
  collapse onto `.thin` and `.regular`. `saturate(1.7)` has no equivalent.
- **SwiftUI's built-in button styles dim a disabled button's whole subtree**, on top of
  whatever the label already drew. A control that paints its own appearance inside the
  label — `ChipToggleButton`, `EvaInputRevealButton` — therefore rendered its *disabled*
  state at half the values its tokens state: the chip's 80% fill came out at 40% and its
  label at 1.3:1 (#14). Both wear `EvaUndimmedButtonStyle` now, a style that adds nothing,
  so the drawn appearance is the specified one; `.disabled(_:)` is untouched and still
  makes the control inert and dimmed to VoiceOver. The `ButtonStyle`-based variants were
  never affected — a style's own `makeBody` is not dimmed.
- **CSS shadow spread has no SwiftUI expression.** Card, button and chip shadows all
  render wider and softer than their `-18px` / `-12px` contractions.
- **Address Montserrat cuts by PostScript name, not family plus weight.** The four files
  disagree in their `name` tables — Medium and SemiBold carry `"Montserrat Medium"` /
  `"Montserrat SemiBold"` in nameID 1 with subfamily `Regular`, reaching `"Montserrat"`
  only through nameID 16. Measured in the app process, Core Text prefers nameID 16 and
  collapses them into one family, so this is a naming hazard rather than a broken family
  — but PostScript names are unambiguous and `EvaTests` locks them in.

## 9c. Still unresolved on the canvas

- ~~The artboard's §02 type card says Button is 15; §04 draws 14.5.~~ Resolved 2026-08-30:
  the type card now says 14.5.
- The bottom sheet's prose says a 30px top radius; its own CSS is `24px 24px 8px 8px`.
- The solid destructive has no pressed state. The current fill measures 1.09:1 against
  its resting fill — i.e. invisible; only the 0.97 scale communicates the press.
- Buttons have no loading state. The auth buttons do (`#3A3436` with a 60% white label),
  which is the house pattern if one is wanted.
- Motion is unspecified everywhere. Input focus and error transitions are instant.
- §6's **toggle** (52×32, pistachio when on) is specified and unbuilt. #160 wanted one and
  used a chip instead rather than design a component inside a feature change.
- The log picker's "Change date" control and the appointment sheet's Date and Time fields
  are drawn with no control behind them (`noop`), and the system has no date or time
  picker. #160 uses the platform's, tinted — see §9a.
- The **appointment type catalogue is British where §8 says US English**: the live
  `refdata/appointmentTypes` serves "GP" and "Gynaecologist" against §8's "Primary care"
  and "Gynecologist". It is catalogue data, editable without an app release, so it is not
  an app change — but the two disagree today.
- The auth screens' two brand type rows (`authWordmark` 40, `authHero` 34) and the status
  screens' 30pt title sit between the scale's Display 46 and H1 28 and have no row. They
  now serve five screens — sign up, log in, the activation gate, forgot password and link
  sent — which is past the point where one-off `EvaTextStyle` values in
  `AuthScreenParts.swift` are defensible. Promoting them to scale rows is a design
  decision, so it is reported here rather than taken in a feature PR. **The Home header's
  `eva.` lockup is a fourth** (`homeWordmark`, 22/400, in `EvaHomeMetrics.swift`) — the
  same lockup as `authWordmark` at a different size, so the two also duplicate the
  `Text` + `Text` composition between `AuthScreenParts` and `HomeHeader`.
- The Today card's title is drawn `600 19.5px/1.32`, which is between H3 (17/22) and H2
  (21/26) and is neither. It takes H2, the nearer of the two in size and the same weight —
  the same trade the calendar's month header took for its 26/400 (§9a). Its `line2` at
  `400 14px/1.6` and its suggestion line at `400 13.5px/1.6` both take Body (15/24): half a
  point is below what the scale can express, and the canvas separates those two by the
  *surface* behind the suggestion rather than by size.

## 10. Implementation conventions

- Tokens live in `mobile/Eva/Theme/` — `EvaColors.swift` (palette and gradients),
  `EvaTypography.swift` (`EvaTextStyle` + `Font.eva*`; use `.evaTextStyle(.h1)` to get
  font, leading and tracking together), `EvaMetrics.swift` (`EvaSpacing`, `EvaRadius`,
  `EvaMetrics.minimumTouchTarget`) and `EvaGlass.swift` (`.evaGlass(.card)` and the
  card/sheet surfaces). Views never inline a hex, a font size or a radius.
- Type is anchored to Dynamic Type (`Font.custom(_:size:relativeTo:)` per row), so the
  canvas' exact points hold at the default content size and scale from there.
- Controls live beside the tokens: `PrimaryButton.swift` and `EvaButtons.swift`
  (secondary glass, text, destructive, authentication, plus the shared press/focus
  pieces), `EvaInputField.swift` (with `EvaInputRevealButton`), `EvaInfoBanner.swift`,
  `EvaScreenBackground.swift`, and `Onboarding/Components/ChipToggleButton.swift`.
  Heights and the focus-ring width come from `EvaControl` in `EvaMetrics.swift` — one
  home, so the buttons and the inputs cannot drift apart.
- `EVA_SPECIMEN=1` renders every token and component on one screen in DEBUG. Adding a
  token or a component means adding it there too — see `mobile/CLAUDE.md`.
- Every view file ends with a `#Preview`.
- Interactive elements need a stable `accessibilityIdentifier` — `EvaUITests` and
  screenshot tooling navigate by them. `PrimaryButton` sets `primary.<title>`,
  `ChipToggleButton` `chip.<label>`, and the other variants follow the same shape. An
  element with both an identifier and a label resolves by either, so adding one never
  breaks a lookup that used the label.
- Portrait iPhone only, iOS 18+. No dark palette is designed yet; don't invent one.
- **The website** takes the same tokens from one block, `website/src/styles/tokens.css`
  (custom properties plus the §3 roles as `t-display` … `t-overline` classes); no page or
  layout inlines a colour literal. Montserrat is self-hosted from the app's own OFL files,
  re-wrapped losslessly as woff2 (`website/public/fonts/`, with `OFL.txt`) — 400/500/600
  only, no third-party font request (#85, #316). There is no website canvas, so the site
  applies the tokens rather than a drawn page. It takes the §9a action ramp for pink text
  and for anything with a white label, Secondary Text for captions and input helpers (the
  settings-row argument), the §2 ink for the success and info marks' glyphs (the base
  measures under 4:1 on its own tint) — the error "!" takes `--eva-action-bottom`, since
  even the error ink renders ~4.4:1 on the error tint — and a light footer, since no dark palette exists. The email-link
  pages (`AuthLayout.astro`) share the block and, since #316, the same ramp.
- Selection is never colour alone — **fill, label colour and elevation move together**.
  A border is not part of it: the artboard's selected chip has fill, white label and
  shadow and no border, while the severe chip does carry one. (This sentence previously
  demanded a border and contradicted the artboard; narrowed after #2.) Semantic *status*
  is a stricter rule — those always carry a mark or a position as well as a colour.

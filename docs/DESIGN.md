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
  `rgba(233,130,165,.14)` with `rgba(201,95,134,.45)` border.
- **Chips**: min-height 44, radius 14. Default glass · selected pink gradient ·
  severe solid `#C95F86` with a bar glyph · disabled muted.
- **Five-point scale**: five 44-high cells, the selected one pink; dot size grows with
  the value, so the scale reads without colour. Anchor labels at both ends.

## 7. Surfaces, feedback, states

Content card, settings rows (52 min-height, chevron, destructive row in `#A9524A`),
info banner, toast (dark `rgba(40,33,38,.92)` with a pink Undo), alert dialog, bottom
sheet (grabber, 30px top radius, L3 glass, 26px safe-area bottom padding), empty state
(dashed border), skeleton loading, and an error card with a Retry action.

**Calendar cells** — every event carries a fixed position *and* shape as well as a
colour: sex = bottom-left circle, body signals = bottom-centre square, sport =
bottom-right diamond, appointment = top-right badge. Flow uses three pink opacities;
predictions are always dashed and patterned. Today is a filled `#C95F86` circle;
selected is a 2px outline.

**Tab bar & FAB** — three tabs (Home, Calendar, Profile) in a `rgba(255,249,246,.8)`
bar, active tab tinted; 56×56 FAB, radius 20, `linear-gradient(160deg,#F0A0BA,#C95F86)`.

## 8. Voice

Eva describes, contextualises and points to care. It never diagnoses, never reassures
falsely, and never uses guilt, streaks or scores. Sensitive events stay neutral in
language *and* in indicators.

- We say: "That can be common during this phase. Here is when it is worth contacting
  your provider."
- We don't say: "You're fine!" · "Don't break your streak" · "Your fertility score
  dropped"

This applies to every user-facing string an engineer writes, not just marketing copy.

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

**The modal drops "Export data instead".** The artboard offers an export button and an
"Export your data first" card beside the confirmation. There is no export feature (#58),
and an inert button next to an irreversible action reads as an offered escape route and
is not one. Restore both when #58 ships — not before.

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

- The artboard's §02 type card says Button is 15; §04 draws 14.5. Components win, but
  they disagree.
- The bottom sheet's prose says a 30px top radius; its own CSS is `24px 24px 8px 8px`.
- The solid destructive has no pressed state. The current fill measures 1.09:1 against
  its resting fill — i.e. invisible; only the 0.97 scale communicates the press.
- Buttons have no loading state. The auth buttons do (`#3A3436` with a 60% white label),
  which is the house pattern if one is wanted.
- Motion is unspecified everywhere. Input focus and error transitions are instant.

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
- Selection is never colour alone — **fill, label colour and elevation move together**.
  A border is not part of it: the artboard's selected chip has fill, white label and
  shadow and no border, while the severe chip does carry one. (This sentence previously
  demanded a border and contradicted the artboard; narrowed after #2.) Semantic *status*
  is a stricter rule — those always carry a mark or a position as well as a colour.

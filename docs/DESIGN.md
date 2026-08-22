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

| Token | Hex | Mark | Use |
|---|---|---|---|
| Success | `#7A9B45` | ✓ circle | Saved, synced, confirmed |
| Warning | `#C9913F` | ! rounded square | Needs attention, not urgent |
| Error | `#C4645A` | ! circle | Always paired with a message under the field |
| Information | `#5A7BA0` | i circle | Account linking, predictions, limits of data |

**Gradients** — blush→cream, pistachio→cream, pink→pistachio (`#F3AEC4`→`#EDF6DA`),
and white highlight over pink (`#E982A5`→`#C95F86` with a white top wash).

## 3. Typography — Montserrat throughout

| Role | Spec |
|---|---|
| Display | 46/48, weight 400 — marketing headlines only |
| H1 · Screen title | 28/34, 600 |
| H2 · Section heading | 21/26, 600 |
| H3 · Card heading | 17/22, 600 |
| Body | 15/24, 400 |
| Body medium | 15/24, 500 — values and emphasis inside rows |
| Button | 14.5–15, 600 |
| Label | 12, 600, secondary |
| Caption | 12.5/19, muted |
| Input helper | 12/18 |
| Error text | 12, 500, with icon |
| Overline | 11, 600, letter-spacing .14em, uppercase |

Display uses the same family at weight 400 with tight leading; functional UI stays at
500–600.

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
shadow `0 16px 36px -22px rgba(150,72,100,.45)` plus inset top/bottom white lines.

## 5. Buttons — min-height 52, radius 17

| Variant | Spec |
|---|---|
| **Primary** | `linear-gradient(180deg,#EE93B1,#C95F86)`, white, shadow `0 12px 26px -12px rgba(201,95,134,.8)` |
| Primary · pressed | Darker (`#D9799C`→`#B45276`), scale .97 |
| Primary · focused | 3px `rgba(40,33,38,.6)` ring |
| Primary · disabled | `rgba(201,95,134,.28)` fill, white text |
| **Secondary glass** | `rgba(255,255,255,.7)`, 1px `rgba(40,33,38,.1)`, blur 18 |
| Text button | `#C95F86`, min-height 48, radius 14 |
| **Destructive** | Outlined `rgba(184,82,72,.5)` / text `#A9524A`; solid `#B85248` **in modals only**; row-level variant at 44/13 |
| **Auth · Apple** | Solid `#1C1A1B`, white |
| **Auth · Google** | Glass `rgba(255,255,255,.85)` with hairline border |

Destructive-confirmed stays disabled until `DELETE` is typed.

## 6. Form controls

- **Input**: height 52, radius 17, `rgba(255,255,255,.75)`, border `rgba(40,33,38,.1)`.
  Focused: border `#C95F86` + 3px `rgba(201,95,134,.16)` ring. Error: border `#C4645A`
  + 3px ring + icon-and-message below.
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
**not** match the canvas. Known differences:

| Aspect | Canvas | `mobile/Eva/Theme/` today |
|---|---|---|
| Typeface | Montserrat everywhere | SF Pro, serif headings |
| Primary accent | `#E982A5` / `#C95F86` pink | `#8E2C57` / `#C96A93` plum |
| Text | `#282126` / `#6F656B` / `#9A9095` | `#3A2233` / `#6E5E69` / `#98868F` |
| Background | `#FFF9F6` warm off-white | `#FBF7FA` → `#F7EEF4` mauve gradient |
| Second brand colour | Pistachio family | none |
| Surfaces | Translucent glass, 3 levels | Flat white |
| Screen title | 28/34 Montserrat 600 | 31 serif semibold |
| Primary button | 52 high, radius 17, 180° gradient | 16pt padding, radius 16, 135° gradient |
| Chips | 44 min-height, radius 14 | 14pt padding, radius 14 |
| Semantic colours | Four, with marks | Green/blue tints, no marks |

**Do not resolve this drift screen-by-screen inside unrelated work.** Re-skinning to
the canvas is its own tracked change; until it lands, match the canvas for anything
new and leave existing screens alone unless the issue says otherwise.

## 10. Implementation conventions

- Tokens live in `mobile/Eva/Theme/`; views never inline a hex, a font size or a radius.
- Every view file ends with a `#Preview`.
- Interactive elements need a stable `accessibilityIdentifier` — `EvaUITests` and
  screenshot tooling navigate by them.
- Portrait iPhone only, iOS 18+. No dark palette is designed yet; don't invent one.
- Selection is never colour alone — fill, border, glyph and text move together.

# Eva — Design System

The design source of truth is the Claude Design canvas in [`design.txt`](../design.txt).
This document is the **implemented** system: the tokens and components that already
exist in `mobile/Eva/Theme/` and `mobile/Eva/Onboarding/Components/`.

Rule of thumb: a new screen should add **zero** new colors and **zero** new one-off
buttons. If it needs one, that is a design decision — raise it, don't inline it.

## 1. Color tokens

All colors live in `mobile/Eva/Theme/EvaColors.swift` as `Color` statics. Never write
`Color(hex:)`, `Color(red:green:blue:)`, or a system color in a view.

**Text**

| Token | Hex | Use |
|---|---|---|
| `.evaInk` | `#3A2233` | Headings, primary text |
| `.evaBody` | `#6E5E69` | Body copy, subtitles |
| `.evaSecondary` | `#5A4B55` | Control labels (unselected chips) |
| `.evaMuted` | `#98868F` | De-emphasised captions |
| `.evaFaint` | `#A695A0` | Placeholders, hints |

**Brand**

| Token | Hex | Use |
|---|---|---|
| `.evaPlum` | `#8E2C57` | Primary accent, selected state, gradient start |
| `.evaPink` | `#C96A93` | Gradient end |
| `.evaSoftPink` | `#FBEDF3` | Selected chip fill |
| `.evaWashPink` | `#F6DCE9` | Decorative wash |

**Surfaces & lines**

| Token | Hex | Use |
|---|---|---|
| `.evaBackgroundTop` / `.evaBackgroundBottom` | `#FBF7FA` / `#F7EEF4` | Screen gradient |
| `.evaChipBorder` | `#EBDDE7` | Chip / control border |
| `.evaCardBorder` | `#EFE1EB` | Card border |
| `.evaTrack` | `#EADCE6` | Progress track |

**Semantic tints** — `.evaGreenTint/Ink/Icon`, `.evaBlueTint/Ink/Icon`, `.evaLilacTint`.
Used for informational cards. Green is *not* "success" and blue is *not* "info" yet;
if you need real status semantics, add named tokens rather than reusing these.

**Gradients** (`LinearGradient` extension)

- `.evaPlumPink` — topLeading → bottomTrailing. Primary actions and accents.
- `.evaScreenBackground` — top → bottom. Every full screen sits on this.

## 2. Typography

SF Pro by default; **serif** (`design: .serif`) for headings. Sizes are literal and
deliberately not on a rounded scale — match them exactly.

| Role | Spec | Where |
|---|---|---|
| Screen/step heading | `.system(size: 31, weight: .semibold, design: .serif)` | `QuestionnaireHeading` |
| Heading subtitle | `.system(size: 14.5)` + `.evaBody`, `padding(.top, 10)` | `QuestionnaireHeading` |
| Primary button | `.system(size: 16.5, weight: .bold)` | `PrimaryButton` |
| Control label | `.system(size: 14.5, weight: .semibold)` | `ChipToggleButton` |

## 3. Spacing & shape

| Constant | Value | Meaning |
|---|---|---|
| Screen horizontal inset | `26` | Content and CTA both |
| Content top inset | `58` | Below the header |
| Grid gutter | `11` | Two-column chip grids |
| Section gap after heading | `22` | Heading → first control |
| Control corner radius | `14` | Chips, cards |
| Button corner radius | `16` | `PrimaryButton` |
| Control border width | `1.5` | Chips |
| Progress bar height | `7` | `EvaProgressBarStyle` |

Primary button shadow: `.evaPlum.opacity(0.45)`, radius `15`, y-offset `9`.
Progress animation: `.easeOut(duration: 0.35)`.

## 4. Components — use these, don't re-implement

| Component | File | Notes |
|---|---|---|
| `PrimaryButton` | `Theme/PrimaryButton.swift` | Full-width gradient CTA. `showsArrow`, `isLoading`. Sets `accessibilityIdentifier("primary.<title>")` — **UI tests depend on this** |
| `EvaProgressBarStyle` | `Theme/EvaProgressBarStyle.swift` | Apply via `.progressViewStyle()` |
| `OnboardingStepLayout` | `Onboarding/Steps/OnboardingStepLayout.swift` | Scrollable content pinned above the CTA. Every onboarding step uses it |
| `QuestionnaireHeading` | `Onboarding/Steps/QuestionnaireHeading.swift` | Serif title + optional subtitle |
| `ChipToggleButton` | `Onboarding/Components/ChipToggleButton.swift` | Selectable option. `isCentered` for grids. Adds `.isSelected` trait |
| `StepperCard` | `Onboarding/Components/StepperCard.swift` | Numeric input (age, weight, height) |
| `PageDots` | `Onboarding/Components/PageDots.swift` | Public-flow pagination |
| `OrbitHeroView` | `Onboarding/Components/OrbitHeroView.swift` | Welcome hero animation |

## 5. Conventions

- Every view file ends with a `#Preview`. Screens preview against
  `.background(LinearGradient.evaScreenBackground)`.
- Interactive elements carry an `accessibilityIdentifier` or an accessibility trait.
  This is not optional politeness — `EvaUITests` and screenshot tooling navigate by it.
- Portrait only, iPhone only (`TARGETED_DEVICE_FAMILY: "1"`), iOS 18+.
- No dark-mode palette exists yet. Do not add ad-hoc dark variants; that is a
  system-wide decision.
- Selection state is expressed by **fill + border + text color together**
  (`.evaSoftPink` / `.evaPlum` / `.evaPlum`), never by color alone.

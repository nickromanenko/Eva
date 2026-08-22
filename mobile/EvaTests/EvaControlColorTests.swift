import Testing
import SwiftUI
@testable import Eva

/// Issue #2 acceptance: the primary button's pressed / focused / disabled appearances,
/// the secondary-glass, text and destructive variants, the input's focus ring, and the
/// chips' four states — DESIGN.md §5 and §6.
///
/// Same shape as the §2 palette suite: every expectation is the literal CSS in the
/// document, round-tripped back out of the resolved `Color`. Only values DESIGN.md
/// actually states are asserted against a number here; the ones the canvas leaves open
/// are covered by the ordering tests further down, which is all that can honestly be
/// said about them.

/// The DESIGN.md §5/§6 state values, transcribed. Held outside the suite so the
/// `@Test(arguments:)` macro can read them without crossing main-actor isolation.
enum EvaControlPalette {

    // MARK: §5 Buttons

    /// Values §5 writes out in full. `rgba(201,95,134,…)` is Deep Pink `#C95F86`,
    /// `rgba(40,33,38,…)` is Primary Text `#282126`, and `rgba(184,82,72,…)` is the
    /// solid destructive `#B85248` — so each row is checked as hex plus alpha.
    static let buttons: [EvaColorExpectation] = [
        // "Primary · pressed | Darker (#D9799C→#B45276), scale .97"
        EvaColorExpectation("Primary pressed top", "#D9799C", .evaPrimaryButtonPressedTop),
        EvaColorExpectation("Primary pressed bottom", "#B45276", .evaPrimaryButtonPressedBottom),
        // "Primary · disabled | rgba(201,95,134,.28) fill, white text"
        EvaColorExpectation("Primary disabled fill", "#C95F86", alpha: 0.28,
                            .evaPrimaryButtonDisabled),
        // "Primary · focused | 3px rgba(40,33,38,.6) ring"
        EvaColorExpectation("Focus ring", "#282126", alpha: 0.6, .evaFocusRing),
        // "Secondary glass | rgba(255,255,255,.7), 1px rgba(40,33,38,.1), blur 18"
        EvaColorExpectation("Secondary glass fill", "#FFFFFF", alpha: 0.7, .evaSecondaryFill),
        EvaColorExpectation("Control hairline", "#282126", alpha: 0.1, .evaControlBorder),
        // "Destructive | Outlined rgba(184,82,72,.5) / text #A9524A; solid #B85248"
        EvaColorExpectation("Destructive solid", "#B85248", .evaDestructive),
        EvaColorExpectation("Destructive ink", "#A9524A", .evaDestructiveInk),
        EvaColorExpectation("Destructive outline", "#B85248", alpha: 0.5, .evaDestructiveBorder),
        // "Auth · Apple | Solid #1C1A1B, white"
        EvaColorExpectation("Apple button", "#1C1A1B", .evaAuthApple),
        // "Auth · Google | Glass rgba(255,255,255,.85) with a hairline border"
        EvaColorExpectation("Google button", "#FFFFFF", alpha: 0.85, .evaAuthGoogleFill)
    ]

    // MARK: §6 Form controls

    /// "Input: height 52, radius 17, rgba(255,255,255,.75), border rgba(40,33,38,.1).
    /// Focused: border #C95F86 + 3px rgba(201,95,134,.16) ring."
    static let inputs: [EvaColorExpectation] = [
        EvaColorExpectation("Input fill", "#FFFFFF", alpha: 0.75, .evaInputFill),
        EvaColorExpectation("Input focus ring", "#C95F86", alpha: 0.16, .evaInputFocusRing),
        // The three the transcription lost and #16 restored from the artboard: the
        // field goes fully opaque on focus, a half-step up on error, and its disabled
        // border is 7% rather than the buttons' 6%.
        EvaColorExpectation("Input fill · focused", "#FFFFFF", .evaInputFillFocused),
        EvaColorExpectation("Input fill · error", "#FFFFFF", alpha: 0.8, .evaInputFillError),
        EvaColorExpectation("Input border · disabled", "#282126", alpha: 0.07,
                            .evaInputBorderDisabled)
    ]

    /// The #12 action ramp. **Not artboard values** — an approved deviation, the whole
    /// reason this branch exists. White on the canvas pink fails WCAG AA everywhere it
    /// carries a label (2.22:1 at `#EE93B1`), so the label-bearing surfaces move to a
    /// deeper ramp and the pale brand pinks stay for washes, tints and decorative fills.
    ///
    /// The contrast these are supposed to buy is asserted in `EvaContrastTests`, on
    /// pixels. These are just the hexes.
    static let actionPink: [EvaColorExpectation] = [
        EvaColorExpectation("Action pink · resting top", "#B45276", .evaActionPinkTop),
        EvaColorExpectation("Action pink · resting bottom", "#96486A", .evaActionPinkBottom),
        EvaColorExpectation("Action pink · pressed top", "#994664", .evaActionPinkPressedTop),
        EvaColorExpectation("Action pink · pressed bottom", "#803D5A",
                            .evaActionPinkPressedBottom),
        EvaColorExpectation("Action pink · solid", "#A94A6C", .evaActionPinkSolid),
        // Severe is deeper still than the ramp: `#A94A6C` would land on the selected
        // chip's own gradient and the two states would stop being distinguishable.
        EvaColorExpectation("Chip · severe fill", "#7E3B58", .evaChipSevere),
        EvaColorExpectation("Chip · severe border", "#5F2C3F", .evaChipSevereBorder)
    ]

    static let everyDocumentedValue: [EvaColorExpectation] = buttons + inputs + actionPink
}

@MainActor
@Suite("DESIGN.md §5/§6 control states")
struct EvaControlColorTests {

    // MARK: Documented values

    @Test("Each documented state value round-trips",
          arguments: EvaControlPalette.everyDocumentedValue)
    func stateValueMatchesTheDocument(_ token: EvaColorExpectation) {
        #expect(
            token.color.evaTestHex == token.hex,
            "\(token.name) should be \(token.hex), resolves to \(token.color.evaTestHex)"
        )
        #expect(
            token.color.evaTestAlpha == token.alpha,
            "\(token.name) should be \(token.alpha) alpha, resolves to \(token.color.evaTestAlpha)"
        )
    }

    @Test("The pink-family state values are derived from Deep Pink, not re-typed")
    func pinkStatesShareTheBrandHex() {
        // §5's rgba(201,95,134,·) is Deep Pink. A hand-typed hex that drifts by a digit
        // still passes the round-trip above; this is what catches it.
        #expect(Color.evaPrimaryButtonDisabled.evaTestHex == Color.evaDeepPink.evaTestHex)
        #expect(Color.evaInputFocusRing.evaTestHex == Color.evaDeepPink.evaTestHex)
        // §5's rgba(40,33,38,·) is Primary Text.
        #expect(Color.evaFocusRing.evaTestHex == Color.evaPrimaryText.evaTestHex)
        #expect(Color.evaControlBorder.evaTestHex == Color.evaPrimaryText.evaTestHex)
        // §5's rgba(184,82,72,·) is the solid destructive.
        #expect(Color.evaDestructiveBorder.evaTestHex == Color.evaDestructive.evaTestHex)
    }

    @Test("The error ring is the §2 error hue")
    func errorRingUsesTheErrorHue() {
        // §6: "Error: border #C4645A + 3px ring". The document gives the border hex and
        // the ring's width but not the ring's opacity, so only the hue is checkable —
        // and the hue is the part that carries the meaning.
        #expect(Color.evaInputErrorRing.evaTestHex == Color.evaError.evaTestHex)
        #expect(Color.evaInputErrorRing.evaTestAlpha < 1.0)
        #expect(Color.evaDestructiveRowBorder.evaTestHex == Color.evaError.evaTestHex)
    }

    // MARK: Relationships the document states in words

    @Test("The pressed primary gradient is darker than the resting one at both stops")
    func pressedPrimaryIsDarker() {
        // §5 gives the pressed state as "Darker (#D9799C→#B45276)". The hexes are
        // checked above; this checks the word, so a future recolour that keeps both
        // rows valid hexes but inverts them cannot pass.
        #expect(
            Color.evaPrimaryButtonPressedTop.evaTestRGBA.relativeLuminance
                < Color.evaPrimaryButtonTop.evaTestRGBA.relativeLuminance
        )
        #expect(
            Color.evaPrimaryButtonPressedBottom.evaTestRGBA.relativeLuminance
                < Color.evaDeepPink.evaTestRGBA.relativeLuminance
        )
    }

    @Test("Both primary gradients run light at the top to dark at the bottom")
    func primaryGradientsDescend() {
        // The 180° direction is what makes the button read as lit from above; a swap
        // leaves both stops correct and the button wrong.
        #expect(
            Color.evaPrimaryButtonTop.evaTestRGBA.relativeLuminance
                > Color.evaDeepPink.evaTestRGBA.relativeLuminance
        )
        #expect(
            Color.evaPrimaryButtonPressedTop.evaTestRGBA.relativeLuminance
                > Color.evaPrimaryButtonPressedBottom.evaTestRGBA.relativeLuminance
        )
    }

    @Test("The disabled primary is the same hue as the enabled one, only weaker")
    func disabledPrimaryIsTheBrandHueFaded() {
        // §5 disables by dropping the fill to 28% rather than by greying it out, so the
        // control still reads as the primary action.
        #expect(Color.evaPrimaryButtonDisabled.evaTestAlpha < 1.0)
        #expect(Color.evaPrimaryButtonDisabled.evaTestAlpha == 0.28)
    }

    // MARK: Values the canvas leaves open

    @Test("The control hairline gets stronger on press and weaker when disabled")
    func controlBorderOrdering() {
        // §5 gives only the resting hairline, rgba(40,33,38,.1). The pressed and
        // disabled strengths are the implementation's choice — the *ordering* is the
        // part that has to hold, and it is what a careless edit breaks.
        let disabled = Color.evaControlBorderDisabled.evaTestAlpha
        let resting = Color.evaControlBorder.evaTestAlpha
        let pressed = Color.evaControlBorderPressed.evaTestAlpha
        #expect(disabled < resting, "disabled hairline \(disabled) is not weaker than \(resting)")
        #expect(resting < pressed, "pressed hairline \(pressed) is not stronger than \(resting)")
        for alpha in [disabled, resting, pressed] {
            #expect(alpha < 1.0)
        }
        #expect(Color.evaControlBorderPressed.evaTestHex == Color.evaPrimaryText.evaTestHex)
        #expect(Color.evaControlBorderDisabled.evaTestHex == Color.evaPrimaryText.evaTestHex)
    }

    @Test("The secondary glass fill dims on press and thins when disabled")
    func secondaryFillOrdering() {
        // Also unspecified beyond the resting rgba(255,255,255,.7).
        #expect(
            Color.evaSecondaryFillPressed.evaTestRGBA.relativeLuminance
                < Color.evaSecondaryFill.evaTestRGBA.relativeLuminance,
            "the pressed secondary is not darker than the resting one"
        )
        #expect(Color.evaSecondaryFillDisabled.evaTestAlpha < Color.evaSecondaryFill.evaTestAlpha)
    }

    @Test("Disabled ink is lighter than every ink it replaces")
    func disabledInkIsTheFaintestLabel() {
        // §5 names no disabled label colour for the unfilled variants. Whatever it is,
        // it has to be visibly quieter than the labels it stands in for, or "disabled"
        // stops reading as disabled.
        let disabled = Color.evaDisabledText.evaTestRGBA.relativeLuminance
        for (name, ink) in [("primary text", Color.evaPrimaryText),
                            ("deep pink", Color.evaDeepPink),
                            ("destructive ink", Color.evaDestructiveInk),
                            ("muted text", Color.evaMutedText)] {
            #expect(
                disabled > ink.evaTestRGBA.relativeLuminance,
                "disabled ink is not lighter than \(name)"
            )
        }
        #expect(Color.evaInputTextDisabled.evaTestRGBA.relativeLuminance
                > Color.evaPrimaryText.evaTestRGBA.relativeLuminance)
    }

    // MARK: Chips (§6)

    @Test("The severe chip is its own deep hex, and its border is darker still")
    func severeChipIsItsOwnDeepPink() {
        // §6 gives severe as solid `#C95F86` with a `#A94A6C` border. Both moved: white
        // on `#C95F86` is 3.84:1, and the #12 ramp's `#A94A6C` stand-in would have put
        // the fill onto the border's own hex. Approved deviation.
        #expect(Color.evaChipSevere.evaTestHex == "#7E3B58")
        #expect(Color.evaChipSevereBorder.evaTestHex == "#5F2C3F")
        #expect(Color.evaChipSevereBorder.evaTestRGBA.relativeLuminance
                < Color.evaChipSevere.evaTestRGBA.relativeLuminance,
                "the severe chip's border does not read as darker than its fill")
        // The brand hex it used to be is untouched — the deviation is scoped to the
        // chip, not applied to the palette.
        #expect(Color.evaDeepPink.evaTestHex == "#C95F86")
    }

    @Test("Severe is far enough below selected to read as the graver of the two")
    func severeIsDistinguishableFromSelected() {
        // The previous pass put severe at `#A94A6C` and the selected gradient's
        // midpoint at `#A54D6E` — four channel-units apart, which is not a state
        // change, it is a rounding error. This is the assertion that keeps them apart
        // whatever the two are recoloured to next.
        //
        // Measured on the *midpoint* of the selected gradient rather than either stop,
        // because that is the fairest single colour to compare a flat fill against; the
        // rendered-pixel version of this, across the whole chip, is in
        // `EvaControlRenderTests.severeAndSelectedChipsAreNotTheSameColourAnywhere`.
        let severe = Color.evaChipSevere.evaTestRGBA
        let selectedMid = EvaRGBA(
            red: (Color.evaActionPinkTop.evaTestRGBA.red
                  + Color.evaActionPinkBottom.evaTestRGBA.red) / 2,
            green: (Color.evaActionPinkTop.evaTestRGBA.green
                    + Color.evaActionPinkBottom.evaTestRGBA.green) / 2,
            blue: (Color.evaActionPinkTop.evaTestRGBA.blue
                   + Color.evaActionPinkBottom.evaTestRGBA.blue) / 2,
            alpha: 1
        )
        let distance = max(
            abs(severe.red - selectedMid.red),
            abs(severe.green - selectedMid.green),
            abs(severe.blue - selectedMid.blue)
        ) * 255
        #expect(distance >= 16,
                "severe \(severe.hexString) and the selected midpoint \(selectedMid.hexString) are \(Int(distance)) channel-units apart")
        #expect(severe.relativeLuminance < selectedMid.relativeLuminance,
                "severe is not darker than selected")
    }

    @Test("The action ramp descends, and pressed is darker than resting at both stops")
    func actionRampIsOrdered() {
        // The same two properties §5 states for the canvas ramp, which the deviation
        // has to preserve or the button stops reading as lit from above and stops
        // acknowledging a press.
        #expect(Color.evaActionPinkTop.evaTestRGBA.relativeLuminance
                > Color.evaActionPinkBottom.evaTestRGBA.relativeLuminance)
        #expect(Color.evaActionPinkPressedTop.evaTestRGBA.relativeLuminance
                > Color.evaActionPinkPressedBottom.evaTestRGBA.relativeLuminance)
        #expect(Color.evaActionPinkPressedTop.evaTestRGBA.relativeLuminance
                < Color.evaActionPinkTop.evaTestRGBA.relativeLuminance)
        #expect(Color.evaActionPinkPressedBottom.evaTestRGBA.relativeLuminance
                < Color.evaActionPinkBottom.evaTestRGBA.relativeLuminance)
    }

    @Test("Deepening the action surfaces left the brand pinks exactly where they were")
    func theBrandPinksAreUntouched() {
        // The deviation is scoped: pale pink stays for washes, tints and decorative
        // fills, which is the whole reason it was acceptable. A later pass "tidying" it
        // by overwriting `evaPrimaryButtonTop` with the ramp is the failure this
        // catches — the palette would be self-consistent and the brand would be gone.
        #expect(Color.evaPrimaryPink.evaTestHex == "#E982A5")
        #expect(Color.evaDeepPink.evaTestHex == "#C95F86")
        #expect(Color.evaPrimaryButtonTop.evaTestHex == "#EE93B1")
        #expect(Color.evaChipSelectedTop.evaTestHex == "#EE93B1")
        #expect(Color.evaChipSelectedBottom.evaTestHex == "#DC7C9E")
        #expect(Color.evaPrimaryButtonPressedTop.evaTestHex == "#D9799C")
        #expect(Color.evaPrimaryButtonPressedBottom.evaTestHex == "#B45276")
    }

    @Test("The input fill lifts from resting to error to focused")
    func inputFillsAscend() {
        // §6 as the artboard states it: 75% at rest, 80% when wrong, fully opaque when
        // focused. The ordering is the meaning — the field gets more solid as it takes
        // attention — and it is what a careless edit that sets all three to
        // `evaInputFill` would lose while every hex stayed white.
        #expect(Color.evaInputFill.evaTestAlpha == 0.75)
        #expect(Color.evaInputFillError.evaTestAlpha == 0.8)
        #expect(Color.evaInputFillFocused.evaTestAlpha == 1.0)
        let ladder = [
            Color.evaInputFill.evaTestAlpha,
            Color.evaInputFillError.evaTestAlpha,
            Color.evaInputFillFocused.evaTestAlpha
        ]
        #expect(ladder == ladder.sorted())
        #expect(Set(ladder).count == 3)
    }

    @Test("The disabled input border is its own 7%, fainter than an enabled hairline")
    func disabledInputBorderIsSeparate() {
        // The artboard gives the disabled *input* border as rgba(40,33,38,.07) where
        // the disabled *button* border is .06. Two values a hair apart is exactly the
        // kind of thing that gets folded together, so the distinctness is asserted.
        #expect(Color.evaInputBorderDisabled.evaTestHex == Color.evaPrimaryText.evaTestHex)
        #expect(Color.evaInputBorderDisabled.evaTestAlpha == 0.07)
        #expect(Color.evaInputBorderDisabled.evaTestAlpha < Color.evaControlBorder.evaTestAlpha)
        #expect(Color.evaInputBorderDisabled.evaTestAlpha
                != Color.evaControlBorderDisabled.evaTestAlpha)
    }

    @Test("The chip states are four distinct fills")
    func chipFillsAreDistinct() {
        // §6 asks for four appearances. Two that resolve to the same colour would leave
        // "selected" unreadable while every individual token still looked right.
        let fills: [(String, EvaRGBA)] = [
            ("default", Color.evaChipFill.evaTestRGBA),
            // The chip's selected gradient is the action ramp since #12, not
            // `evaChipSelected` — see `ChipToggleButton.Appearance.fill`.
            ("selected top", Color.evaActionPinkTop.evaTestRGBA),
            ("selected bottom", Color.evaActionPinkBottom.evaTestRGBA),
            ("severe", Color.evaChipSevere.evaTestRGBA),
            ("disabled", Color.evaChipFillDisabled.evaTestRGBA)
        ]
        for i in fills.indices {
            for j in fills.indices where j > i {
                #expect(fills[i].1 != fills[j].1,
                        "the \(fills[i].0) and \(fills[j].0) chips are the same colour")
            }
        }
        // §6 gives the selected chip as a gradient; a gradient whose stops match is a
        // flat fill with extra steps.
        #expect(
            Color.evaActionPinkTop.evaTestRGBA.relativeLuminance
                > Color.evaActionPinkBottom.evaTestRGBA.relativeLuminance
        )
    }
}

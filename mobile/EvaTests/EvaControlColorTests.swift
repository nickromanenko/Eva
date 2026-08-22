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
        EvaColorExpectation("Input focus ring", "#C95F86", alpha: 0.16, .evaInputFocusRing)
    ]

    static let everyDocumentedValue: [EvaColorExpectation] = buttons + inputs
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

    @Test("The severe chip is solid Deep Pink")
    func severeChipIsDeepPink() {
        // §6: "severe solid #C95F86 with a bar glyph". The only chip state the canvas
        // gives a hex for.
        #expect(Color.evaDeepPink.evaTestHex == "#C95F86")
        #expect(Color.evaChipSevereBorder.evaTestRGBA.relativeLuminance
                < Color.evaDeepPink.evaTestRGBA.relativeLuminance,
                "the severe chip's border does not read as darker than its fill")
    }

    @Test("The chip states are four distinct fills")
    func chipFillsAreDistinct() {
        // §6 asks for four appearances. Two that resolve to the same colour would leave
        // "selected" unreadable while every individual token still looked right.
        let fills: [(String, EvaRGBA)] = [
            ("default", Color.evaChipFill.evaTestRGBA),
            ("selected top", Color.evaChipSelectedTop.evaTestRGBA),
            ("selected bottom", Color.evaChipSelectedBottom.evaTestRGBA),
            ("severe", Color.evaDeepPink.evaTestRGBA),
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
            Color.evaChipSelectedTop.evaTestRGBA.relativeLuminance
                > Color.evaChipSelectedBottom.evaTestRGBA.relativeLuminance
        )
    }
}

import Testing
import SwiftUI
@testable import Eva

/// Issue #2 acceptance: "Primary button: min-height 52, radius 17", "Text button …
/// min-height 48", "row-level variant at 44/13", "Chips: min-height 44, radius 14",
/// "Inputs: 52 high" — DESIGN.md §5 and §6, and the 44pt floor from §1.
///
/// Two halves. The first asserts the tokens carry the canvas' numbers; the second
/// measures the controls, because a token nothing applies is worth nothing. Both are
/// needed: the token test says what the number is, the measurement says the control
/// wears it.

/// The §5/§6 heights, transcribed. Held outside the suite so `@Test(arguments:)` can
/// read it without crossing main-actor isolation.
struct EvaControlHeightExpectation: Sendable, CustomStringConvertible {
    let name: String
    let documented: CGFloat
    let token: CGFloat

    var description: String { "\(name) \(documented)" }
}

enum EvaControlHeights {
    static let all: [EvaControlHeightExpectation] = [
        // §5 "Buttons — min-height 52, radius 17".
        .init(name: "Primary / secondary / full-size destructive", documented: 52,
              token: EvaButtonHeight.standard),
        // §5 "Text button … min-height 48, radius 14".
        .init(name: "Text button", documented: 48, token: EvaButtonHeight.text),
        // §5 "row-level variant at 44/13", which is also §1's minimum touch target.
        .init(name: "Row-level destructive", documented: 44, token: EvaButtonHeight.row),
        // §6 "Input: height 52".
        .init(name: "Input", documented: 52, token: EvaControl.height),
        // §6 "Chips: min-height 44".
        .init(name: "Chip", documented: 44, token: EvaMetrics.minimumTouchTarget)
    ]
}

@MainActor
@Suite("DESIGN.md §5/§6 control metrics")
struct EvaControlMetricsTests {

    // MARK: Tokens

    @Test("Each documented control height has a token holding it",
          arguments: EvaControlHeights.all)
    func heightTokensMatchTheDocument(_ expectation: EvaControlHeightExpectation) {
        #expect(
            expectation.token == expectation.documented,
            "\(expectation.name) should be \(expectation.documented), token holds \(expectation.token)"
        )
    }

    @Test("EvaControl carries the shared height, text height and ring width")
    func evaControlMatchesTheDocument() {
        // §5 buttons and §6 inputs agree on 52, which is why there is one token.
        #expect(EvaControl.height == 52)
        #expect(EvaControl.textButtonHeight == 48)
        // §5 "Primary · focused | 3px … ring"; §6 repeats 3px for input focus and error.
        #expect(EvaControl.focusRingWidth == 3)
        #expect(EvaFocusRing.width == EvaControl.focusRingWidth)
    }

    @Test("The row-level destructive sits on the §1 44pt floor")
    func rowDestructiveIsTheMinimumTouchTarget() {
        // §5 gives the row variant as "44/13" and §1 sets 44 as the minimum target, so
        // this variant is exactly at the floor — it must not be allowed to drift below.
        #expect(EvaButtonHeight.row == EvaMetrics.minimumTouchTarget)
        #expect(EvaDestructiveButtonKind.row.height == 44)
        #expect(EvaDestructiveButtonKind.outlined.height == 52)
        #expect(EvaDestructiveButtonKind.solid.height == 52)
    }

    @Test("Every control height clears the 44pt minimum touch target")
    func noControlIsBelowTheTouchTarget() {
        for expectation in EvaControlHeights.all {
            #expect(
                expectation.token >= EvaMetrics.minimumTouchTarget,
                "\(expectation.name) at \(expectation.token) is under the §1 44pt floor"
            )
        }
    }

    @Test("Radii: buttons and inputs 17, chips and the text button 14")
    func controlRadiiMatchTheDocument() {
        // §5 "min-height 52, radius 17" and "Text button … radius 14"; §6 "Input:
        // height 52, radius 17" and "Chips: min-height 44, radius 14".
        #expect(EvaRadius.control == 17)
        #expect(EvaRadius.chip == 14)
        #expect(EvaDestructiveButtonKind.outlined.cornerRadius == EvaRadius.control)
        #expect(EvaDestructiveButtonKind.solid.cornerRadius == EvaRadius.control)
        // §5's "44/13" for the row variant names a radius no token has; the nearest,
        // `EvaRadius.chip`, stands in. Locked here so the substitution is visible in a
        // diff rather than silently becoming 17 or 13.
        #expect(EvaDestructiveButtonKind.row.cornerRadius == EvaRadius.chip)
    }

    @Test("Press feedback is scale .97")
    func pressScaleMatchesTheDocument() {
        // §5 "Primary · pressed | Darker … scale .97".
        #expect(EvaButtonPress.scale == 0.97)
        #expect(EvaButtonPress.duration > 0)
    }

    // MARK: Measured

    @Test("The primary button lays out 52 points high")
    func primaryButtonIsFiftyTwoHigh() {
        #expect(evaFittingHeight(PrimaryButton(title: "Continue") {}) == 52)
    }

    @Test("The primary button stays 52 high while loading")
    func loadingPrimaryButtonKeepsItsHeight() {
        // The spinner replaces the label, and a spinner that is taller or shorter than
        // the text makes the CTA jump on submit.
        #expect(evaFittingHeight(PrimaryButton(title: "Continue", isLoading: true) {}) == 52)
    }

    @Test("The primary button stays 52 high with a trailing arrow")
    func arrowPrimaryButtonKeepsItsHeight() {
        #expect(
            evaFittingHeight(PrimaryButton(title: "Get started", showsArrow: true) {}) == 52
        )
    }

    @Test("The secondary glass button lays out 52 points high")
    func secondaryButtonIsFiftyTwoHigh() {
        #expect(evaFittingHeight(SecondaryButton(title: "Not now") {}) == 52)
    }

    @Test("The text button lays out 48 points high")
    func textButtonIsFortyEightHigh() {
        #expect(evaFittingHeight(TextButton(title: "Skip for now") {}) == 48)
    }

    @Test("Each destructive shape lays out at its documented height")
    func destructiveButtonHeights() {
        #expect(
            evaFittingHeight(DestructiveButton(title: "Delete my account") {}) == 52
        )
        #expect(
            evaFittingHeight(
                DestructiveButton(title: "Delete for everyone", kind: .solid) {}
            ) == 52
        )
        #expect(
            evaFittingHeight(DestructiveButton(title: "Remove entry", kind: .row) {}) == 44
        )
    }

    @Test("A chip lays out 44 points high in every appearance")
    func chipIsFortyFourHigh() {
        // Four states, one height: the canvas draws them as one control, and a severe
        // chip that is 2pt taller than its neighbours because of the bar glyph would be
        // a layout bug in a grid of them.
        #expect(evaFittingHeight(ChipToggleButton(label: "Energy", isSelected: false) {}) == 44)
        #expect(evaFittingHeight(ChipToggleButton(label: "Energy", isSelected: true) {}) == 44)
        #expect(
            evaFittingHeight(
                ChipToggleButton(label: "Heavy flow", isSelected: true, isSevere: true) {}
            ) == 44
        )
        #expect(
            evaFittingHeight(
                ChipToggleButton(label: "Not tracked", isSelected: false, isDisabled: true) {}
            ) == 44
        )
    }

    @Test("A chip grows past 44 rather than clipping a wrapping label")
    func chipGrowsForALongLabel() {
        // 44 is a *minimum*. The questionnaire has options like "Medications that affect
        // hormones" that wrap at grid width; a fixed 44 would clip them.
        let tall = evaFittingHeight(
            ChipToggleButton(label: "Medications that affect hormones", isSelected: true) {},
            width: 150
        )
        #expect(tall > 44, "a two-line chip stayed at \(tall) — the label is being clipped")
    }
}

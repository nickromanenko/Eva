import Testing
import SwiftUI
@testable import Eva

/// Issue #2 acceptance: "pressed (scale .97, darker), focused ring, disabled fill" and
/// "Secondary glass, text and destructive variants exist".
///
/// The state a button style paints is resolved from three independent booleans, so it
/// is the one part of the button work that is logic rather than appearance — a truth
/// table, and therefore properly testable rather than merely observable.

/// One row of the state-resolution truth table.
struct EvaButtonStateCase: Sendable, CustomStringConvertible {
    let isPressed: Bool
    let isEnabled: Bool
    let isFocused: Bool
    let expected: EvaButtonState

    var description: String {
        "pressed=\(isPressed) enabled=\(isEnabled) focused=\(isFocused) → \(expected)"
    }
}

enum EvaButtonStateTable {
    /// All eight combinations, written out rather than generated, so the expected
    /// column is a statement of intent and not a re-implementation of the rule.
    ///
    /// Disabled outranks pressed (a disabled control that is being touched is still
    /// disabled) and pressed outranks focused (the press is the more recent, more
    /// deliberate signal).
    static let all: [EvaButtonStateCase] = [
        .init(isPressed: false, isEnabled: true, isFocused: false, expected: .normal),
        .init(isPressed: false, isEnabled: true, isFocused: true, expected: .focused),
        .init(isPressed: true, isEnabled: true, isFocused: false, expected: .pressed),
        .init(isPressed: true, isEnabled: true, isFocused: true, expected: .pressed),
        .init(isPressed: false, isEnabled: false, isFocused: false, expected: .disabled),
        .init(isPressed: false, isEnabled: false, isFocused: true, expected: .disabled),
        .init(isPressed: true, isEnabled: false, isFocused: false, expected: .disabled),
        .init(isPressed: true, isEnabled: false, isFocused: true, expected: .disabled)
    ]
}

@MainActor
@Suite("Button state resolution and the destructive variants")
struct EvaButtonStateTests {

    @Test("Every combination of pressed, enabled and focused resolves as documented",
          arguments: EvaButtonStateTable.all)
    func stateResolution(_ row: EvaButtonStateCase) {
        let resolved = EvaButtonState.resolved(
            isPressed: row.isPressed,
            isEnabled: row.isEnabled,
            isFocused: row.isFocused
        )
        #expect(resolved == row.expected, "\(row) resolved to \(resolved)")
    }

    @Test("A disabled control never reports pressed or focused")
    func disabledWinsOutright() {
        // Restates the precedence as a property rather than a table, so a reordering of
        // the `if`s that happens to keep six of the eight rows right still fails.
        for pressed in [true, false] {
            for focused in [true, false] {
                #expect(
                    EvaButtonState.resolved(
                        isPressed: pressed, isEnabled: false, isFocused: focused
                    ) == .disabled
                )
            }
        }
    }

    // MARK: Destructive variants

    @Test("The outlined destructive has no fill, a half-strength border and #A9524A ink")
    func outlinedDestructive() {
        // §5: "Outlined rgba(184,82,72,.5) / text #A9524A". The default shape.
        let kind = EvaDestructiveButtonKind.outlined
        #expect(kind.fill(for: .normal).evaTestAlpha == 0)
        #expect(kind.border(for: .normal).evaTestHex == "#B85248")
        #expect(kind.border(for: .normal).evaTestAlpha == 0.5)
        #expect(kind.label(for: .normal).evaTestHex == "#A9524A")
        #expect(kind.isFullWidth)
    }

    @Test("The solid destructive is #B85248 with a white label — except disabled")
    func solidDestructive() {
        // §5: "solid #B85248 in modals only", and on a filled control the label stays
        // white. Disabled is the exception and a deliberate one: the fill drops to
        // `#B85248` at 50%, which over the warm background carries white at 2.10:1, so
        // the label becomes Primary Text. Same defect and same answer as the disabled
        // primary (#12 1a / #17); measured on pixels in `EvaContrastTests`.
        let kind = EvaDestructiveButtonKind.solid
        #expect(kind.fill(for: .normal).evaTestHex == "#B85248")
        #expect(kind.fill(for: .normal).evaTestAlpha == 1.0)
        #expect(kind.border(for: .normal).evaTestAlpha == 0)
        for state in [EvaButtonState.normal, .pressed, .focused] {
            #expect(kind.label(for: state).evaTestHex == "#FFFFFF",
                    "the solid destructive's label is not white when \(state)")
        }
        #expect(kind.label(for: .disabled).evaTestHex == Color.evaPrimaryText.evaTestHex,
                "the disabled solid destructive is back on a white label at 2.10:1")
    }

    @Test("The solid destructive disables by halving its own fill, not by tinting at 28%")
    func solidDestructiveDisabledFill() {
        // #16: the artboard's rule is `background:#B85248; opacity:.5`. It shipped as
        // the primary's 28% recipe, which was borrowed rather than read — a different
        // colour, on a control the canvas does specify.
        let disabled = EvaDestructiveButtonKind.solid.fill(for: .disabled)
        #expect(disabled.evaTestHex == Color.evaDestructive.evaTestHex)
        #expect(disabled.evaTestAlpha == 0.5)
        #expect(disabled.evaTestAlpha != Color.evaPrimaryButtonDisabled.evaTestAlpha,
                "the destructive is back on the primary's 28%")
    }

    @Test("The solid destructive's pressed fill is still an invisible state change")
    func solidDestructivePressedIsBarelyVisible() {
        // Not an assertion that this is right — it is not. `#A9524A` pressed against
        // `#B85248` resting is about 1.09:1, below what anyone can see as a state
        // change, so the 0.97 press scale is carrying the whole signal. The artboard
        // gives no pressed fill for this variant, so the code left the guess in place
        // rather than inventing a value, and #12 has it logged.
        //
        // Pinned as a known gap: whoever fixes it should have to change this test, and
        // whoever changes this test has to have read why it is here.
        let resting = EvaDestructiveButtonKind.solid.fill(for: .normal).evaTestRGBA
        let pressed = EvaDestructiveButtonKind.solid.fill(for: .pressed).evaTestRGBA
        #expect(pressed.relativeLuminance < resting.relativeLuminance,
                "the pressed solid destructive is not even darker than resting")
        #expect(evaContrastRatio(resting, pressed) < 1.2,
                "the pressed fill became visible — good; update this test and close the note on #12")
    }

    @Test("The row-level destructive is unfilled, 44 high and sized to its row")
    func rowDestructive() {
        // §5: "row-level variant at 44/13". It sits inside a settings list, so unlike
        // the other two it must not stretch to the full width.
        let kind = EvaDestructiveButtonKind.row
        #expect(kind.height == EvaMetrics.minimumTouchTarget)
        #expect(kind.fill(for: .normal).evaTestAlpha == 0)
        #expect(kind.label(for: .normal).evaTestHex == "#A9524A")
        #expect(kind.isFullWidth == false)
    }

    @Test("Every destructive shape greys its label only where it has no fill")
    func destructiveDisabledLabels() {
        // The unfilled shapes fade to disabled ink. The filled one takes Primary Text
        // instead — grey on the halved red would read as an error rather than as "off",
        // and white on it is unreadable at 2.10:1.
        #expect(EvaDestructiveButtonKind.outlined.label(for: .disabled).evaTestHex
                == Color.evaDisabledText.evaTestHex)
        #expect(EvaDestructiveButtonKind.row.label(for: .disabled).evaTestHex
                == Color.evaDisabledText.evaTestHex)
        #expect(EvaDestructiveButtonKind.solid.label(for: .disabled).evaTestHex
                == Color.evaPrimaryText.evaTestHex)
    }

    @Test("No destructive shape ever borrows a non-destructive hue")
    func destructiveStaysInItsFamily() {
        // A destructive action that picks up the brand pink is the failure this guards:
        // the two families are close enough in hue to be confused in a diff.
        let destructiveHexes: Set<String> = [
            Color.evaDestructive.evaTestHex,
            Color.evaDestructiveInk.evaTestHex,
            Color.evaError.evaTestHex,
            Color.evaDisabledText.evaTestHex,
            Color.evaPrimaryText.evaTestHex,
            "#FFFFFF"
        ]
        for kind in [EvaDestructiveButtonKind.outlined, .solid, .row] {
            for state in [EvaButtonState.normal, .pressed, .focused, .disabled] {
                for (part, color) in [("fill", kind.fill(for: state)),
                                      ("border", kind.border(for: state)),
                                      ("label", kind.label(for: state))]
                where color.evaTestAlpha > 0 {
                    #expect(
                        destructiveHexes.contains(color.evaTestHex),
                        "\(kind) \(part) when \(state) is \(color.evaTestHex), outside the family"
                    )
                }
            }
        }
    }
}

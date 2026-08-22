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

    @Test("The solid destructive is #B85248 with a white label in every state")
    func solidDestructive() {
        // §5: "solid #B85248 in modals only", and on a filled control the label stays
        // white — disabled included, the same recipe as the disabled primary.
        let kind = EvaDestructiveButtonKind.solid
        #expect(kind.fill(for: .normal).evaTestHex == "#B85248")
        #expect(kind.border(for: .normal).evaTestAlpha == 0)
        for state in [EvaButtonState.normal, .pressed, .focused, .disabled] {
            #expect(kind.label(for: state).evaTestHex == "#FFFFFF",
                    "the solid destructive's label is not white when \(state)")
        }
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
        // The unfilled shapes fade to disabled ink; the filled one cannot, because
        // white on the faded red is the §5 recipe and grey on red would read as an
        // error rather than as "off".
        #expect(EvaDestructiveButtonKind.outlined.label(for: .disabled).evaTestHex
                == Color.evaDisabledText.evaTestHex)
        #expect(EvaDestructiveButtonKind.row.label(for: .disabled).evaTestHex
                == Color.evaDisabledText.evaTestHex)
        #expect(EvaDestructiveButtonKind.solid.label(for: .disabled).evaTestHex == "#FFFFFF")
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

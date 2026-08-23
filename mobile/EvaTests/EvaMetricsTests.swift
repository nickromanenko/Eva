import Testing
import SwiftUI
@testable import Eva

/// Issue #1 acceptance: "Spacing (4–40), radii (14/17/24/30/pill) and the three glass
/// levels are tokens" (DESIGN.md §4), plus the 44pt minimum target from §1.
@MainActor
@Suite("DESIGN.md §4 spacing, radii, glass")
struct EvaMetricsTests {

    // MARK: Spacing

    @Test("The spacing scale is exactly 4, 8, 12, 16, 24, 32, 40")
    func spacingScaleMatchesTheDocument() {
        let scale: [CGFloat] = [
            EvaSpacing.xxs, EvaSpacing.xs, EvaSpacing.sm,
            EvaSpacing.md, EvaSpacing.lg, EvaSpacing.xl, EvaSpacing.xxl
        ]
        #expect(scale == [4, 8, 12, 16, 24, 32, 40])
    }

    @Test("The spacing scale ascends with no repeats")
    func spacingScaleIsMonotonic() {
        // Catches a step that was edited to the wrong value in a way that still leaves
        // seven numbers on the list.
        let scale: [CGFloat] = [
            EvaSpacing.xxs, EvaSpacing.xs, EvaSpacing.sm,
            EvaSpacing.md, EvaSpacing.lg, EvaSpacing.xl, EvaSpacing.xxl
        ]
        #expect(scale == scale.sorted())
        #expect(Set(scale).count == scale.count)
    }

    @Test("Every spacing step above 4 is a multiple of the 8-pt grid's half step")
    func spacingScaleSitsOnTheGrid() {
        // DESIGN.md §1: "8-pt spacing". 4 is the deliberate half step; nothing else
        // may be off-grid.
        for step in [EvaSpacing.xs, EvaSpacing.sm, EvaSpacing.md,
                     EvaSpacing.lg, EvaSpacing.xl, EvaSpacing.xxl] {
            #expect(step.truncatingRemainder(dividingBy: 4) == 0, "\(step) is off the grid")
        }
    }

    // MARK: Radii

    @Test("Radii are 13 destructive row, 14 chip, 17 control, 24 card, 30 sheet, 999 pill")
    func radiiMatchTheDocument() {
        // 13 is off the canvas' own 14/17/24/30 ladder and belongs to exactly one
        // control — the artboard draws the row-level destructive at
        // `border-radius:13px`. Added by #16.
        #expect(EvaRadius.destructiveRow == 13)
        #expect(EvaRadius.chip == 14)
        #expect(EvaRadius.control == 17)
        #expect(EvaRadius.card == 24)
        #expect(EvaRadius.sheet == 30)
        #expect(EvaRadius.pill == 999)
    }

    @Test("The radius ladder ascends destructive row → chip → control → card → sheet → pill")
    func radiiAscend() {
        let ladder: [CGFloat] = [
            EvaRadius.destructiveRow, EvaRadius.chip, EvaRadius.control,
            EvaRadius.card, EvaRadius.sheet, EvaRadius.pill
        ]
        #expect(ladder == ladder.sorted())
        #expect(Set(ladder).count == ladder.count)
    }

    // MARK: Touch target

    @Test("The minimum touch target is 44pt")
    func minimumTouchTargetIs44() {
        // DESIGN.md §1, and the platform's own floor. Chips (§6) are specified at this
        // same height, so the token has to hold for them too.
        #expect(EvaMetrics.minimumTouchTarget == 44)
    }

    // MARK: Glass

    @Test("There are exactly three glass levels")
    func glassHasThreeLevels() {
        #expect(EvaGlassLevel.allCases.count == 3)
        #expect(EvaGlassLevel.allCases == [.background, .card, .sheet])
    }

    @Test("Each glass level carries the DESIGN.md §4 fill")
    func glassFillsMatchTheDocument() {
        #expect(EvaGlassLevel.background.tint.evaTestHex == "#FFFFFF")
        #expect(EvaGlassLevel.background.tint.evaTestAlpha == 0.40)

        #expect(EvaGlassLevel.card.tint.evaTestHex == "#FFFFFF")
        #expect(EvaGlassLevel.card.tint.evaTestAlpha == 0.68)

        // L3 is the §2 "Elevated Glass" neutral: rgba(255,252,250,.92).
        #expect(EvaGlassLevel.sheet.tint.evaTestHex == "#FFFCFA")
        #expect(EvaGlassLevel.sheet.tint.evaTestAlpha == 0.92)
    }

    @Test("Each glass level records the canvas blur radius")
    func glassBlurRadiiMatchTheDocument() {
        // SwiftUI materials cannot apply these, but the numbers are the spec and a
        // future UIVisualEffectView bridge is meant to read them.
        #expect(EvaGlassLevel.background.canvasBlurRadius == 20)
        #expect(EvaGlassLevel.card.canvasBlurRadius == 24)
        #expect(EvaGlassLevel.sheet.canvasBlurRadius == 28)
    }

    @Test("Glass gets denser and blurrier from L1 to L3")
    func glassLevelsAreOrdered() {
        // The ordering is the part that carries meaning: L1 decorative, L2 body-text
        // safe, L3 long-form. A level that is less opaque than the one below it is a
        // legibility bug, not a cosmetic one.
        let alphas = EvaGlassLevel.allCases.map(\.tint.evaTestAlpha)
        let blurs = EvaGlassLevel.allCases.map(\.canvasBlurRadius)
        #expect(alphas == alphas.sorted())
        #expect(blurs == blurs.sorted())
        #expect(Set(alphas).count == 3)
        #expect(Set(blurs).count == 3)
    }
}

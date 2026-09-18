import Testing
import SwiftUI
@testable import Eva

/// Issue #206: **a predicted day does not look like a logged one, with the colour removed.**
///
/// The canvas states the rule — *"Predicted period and fertile window use dashed outlines
/// and patterned shading so predictions can never be mistaken for logged data"* — and the
/// epic's Risks name it as the one with no verification today. It cannot be checked from
/// the enum: `EvaPredictionMark.stripe` returning a colour says nothing about whether the
/// cell drew stripes, a flat wash of that colour, or nothing at all.
///
/// **So every measurement here is in luminance, and none of them is a hue.** That is the
/// colour-blind rule expressed as a test rather than as an intention: each expectation
/// below would still hold for a reader who cannot separate the pink from the pistachio, or
/// for the screen printed in greyscale. Two properties carry it —
///
/// * **patterned**: a predicted cell's interior alternates light and dark along a scan
///   line, several times over. A logged cell's interior is one flat value.
/// * **dashed**: a predicted cell's edge alternates too. No other cell's does.
///
/// Measured: replacing `EvaPredictionSurface` with a plain `shape.fill(mark.stripe)` and a
/// solid border — the obvious simplification, and the exact defect this slice exists to
/// prevent — passes all 375 other tests in this target and fails both of the two
/// measurements below that carry the rule, with 8 issues.
///
/// Borrows `CalendarGlyphRenderTests`' `draw` harness, like `CalendarSpottingRenderTests`.
/// Not snapshot testing: nothing is recorded and every coordinate follows from the geometry.
@MainActor
@Suite("Issue #206 · what a predicted day actually draws")
struct CalendarPredictionRenderTests {

    static let cell = EvaCalendarMetrics.cellHeight
    static let scale = 4

    static func raster(
        cycleMark: EvaCycleMark? = nil,
        predictions: [EvaPredictionMark] = []
    ) throws -> EvaRaster {
        try EvaRaster(
            CalendarDayCell(
                cell: EvaMonthGrid.Cell(
                    date: EvaDay(year: 2026, month: 8, day: 12), placement: .inMonth
                ),
                isToday: false,
                isSelected: false,
                cycleMark: cycleMark,
                glyphs: [],
                predictions: predictions,
                select: {}
            )
            .frame(width: cell, height: cell),
            size: CGSize(width: cell, height: cell),
            background: .evaWarmBackground,
            scale: CGFloat(scale)
        )
    }

    // MARK: - Reading a row of pixels as light and dark only

    /// Every pixel's relative luminance along one horizontal line, in points-in, pixels-out.
    ///
    /// Sampled per *pixel* rather than per point: a 3pt stripe at 45° crosses a horizontal
    /// line in about 4pt, and a per-point scan of a 7pt repeat is close enough to the
    /// pattern's own frequency to alias it into a flat line.
    static func scan(_ raster: EvaRaster, y: Double, from: Double, to: Double) -> [Double] {
        let row = Int(y * Double(scale))
        return (Int(from * Double(scale))..<Int(to * Double(scale))).map {
            raster.pixel($0, row).relativeLuminance
        }
    }

    static func swing(_ samples: [Double]) -> Double {
        (samples.max() ?? 0) - (samples.min() ?? 0)
    }

    /// How many times the scan crosses its own midpoint — the difference between a *pattern*
    /// and a gradient, both of which swing.
    ///
    /// A gradient crosses once. Five diagonal stripes across a 50pt cell cross about ten
    /// times.
    static func crossings(_ samples: [Double]) -> Int {
        guard let low = samples.min(), let high = samples.max(), high > low else { return 0 }
        let middle = (low + high) / 2
        var count = 0
        var above = samples[0] > middle
        for sample in samples.dropFirst() where (sample > middle) != above {
            above.toggle()
            count += 1
        }
        return count
    }

    /// A line across the cell's interior, clear of the border, the corner curves and the
    /// date in the middle of the cell.
    static func interior(_ raster: EvaRaster) -> [Double] {
        scan(raster, y: 9, from: 8, to: cell - 8)
    }

    /// A line along the top edge, on the border's own path and away from the corners.
    static func edge(_ raster: EvaRaster) -> [Double] {
        scan(raster, y: 0.5, from: 14, to: cell - 14)
    }

    // MARK: - Patterned

    @Test("A predicted cell's interior is striped, and a logged one's is flat")
    func predictedCellsArePatterned() throws {
        let logged = Self.interior(try Self.raster(cycleMark: .flow(.light)))
        #expect(
            Self.swing(logged) < 0.01,
            """
            A logged light-flow cell varies by \(Self.swing(logged)) across its interior. \
            A logged day is a flat wash; anything else and "patterned means predicted" is \
            not a distinction.
            """
        )

        for mark in EvaPredictionMark.allCases {
            let predicted = Self.interior(try Self.raster(predictions: [mark]))
            #expect(
                Self.swing(predicted) > 0.02,
                """
                A predicted \(mark.rawValue) cell varies by only \(Self.swing(predicted)) \
                across its interior — it is drawn as a flat fill, which is what a logged \
                day looks like.
                """
            )
            #expect(
                Self.swing(predicted) > Self.swing(logged) * 5,
                "A predicted \(mark.rawValue) cell is no more patterned than a logged one"
            )
            #expect(
                Self.crossings(predicted) >= 4,
                """
                A predicted \(mark.rawValue) cell crossed its own midpoint \
                \(Self.crossings(predicted)) times — that is a gradient or a single band, \
                not the repeating pattern the canvas specifies.
                """
            )
        }
    }

    // MARK: - Dashed

    @Test("A predicted cell's outline is broken; no other cell's is")
    func predictedCellsAreDashed() throws {
        for mark in EvaPredictionMark.allCases {
            let predicted = Self.edge(try Self.raster(predictions: [mark]))
            #expect(
                Self.crossings(predicted) >= 4,
                """
                The \(mark.rawValue) outline crossed its midpoint \
                \(Self.crossings(predicted)) times along the top edge, so it is drawn \
                solid. Dashed is half of what keeps a prediction off the same footing as a \
                logged day.
                """
            )
        }

        // The cells that are *not* predicted: a plain day, whose hairline is solid, and a
        // logged flow day, which has no border at all.
        for cycleMark in [nil, EvaCycleMark.flow(.heavy), .spotting] as [EvaCycleMark?] {
            let edge = Self.edge(try Self.raster(cycleMark: cycleMark))
            #expect(
                Self.swing(edge) < 0.02,
                """
                A cell with \(cycleMark.map(String.init(describing:)) ?? "nothing") logged \
                has a broken-looking edge (\(Self.swing(edge))), so dashed no longer means \
                predicted.
                """
            )
        }
    }

    // MARK: - The logged day wins the surface

    /// The artboard's `else if` chain, and the product rule behind it: *"observed logs
    /// always outrank predictions"* (HOME_SPEC). A logged day inside the fertile window is
    /// drawn as the logged day.
    @Test("A logged day inside a predicted window is still drawn as logged")
    func loggedOutranksPredicted() throws {
        let both = Self.interior(
            try Self.raster(cycleMark: .flow(.heavy), predictions: [.fertileWindow])
        )
        let loggedOnly = Self.interior(try Self.raster(cycleMark: .flow(.heavy)))

        #expect(
            Self.swing(both) < 0.01,
            "A logged heavy-flow day was drawn with a prediction's stripes over it"
        )
        #expect(
            abs(Self.swing(both) - Self.swing(loggedOnly)) < 0.005,
            "The predicted window changed how a logged day is drawn"
        )
    }

    // MARK: - Nothing is drawn where nothing is predicted

    @Test("A day with no prediction draws no outline and no pattern")
    func unpredictedDaysAreUntouched() throws {
        let plain = try Self.raster()
        #expect(Self.swing(Self.interior(plain)) < 0.01)
        #expect(Self.crossings(Self.edge(plain)) < 4)
    }

    // MARK: - The words carry what the pattern cannot

    /// The pattern separates *predicted* from *logged*. It does **not** separate the
    /// predicted period from the fertile window — the canvas draws those with the same
    /// stripes in two different hues, which is exactly the pair a red-green reader cannot
    /// split. The words are what carry that distinction, on the cell and in the legend, and
    /// this is the assertion that keeps them there.
    @Test("Every predicted mark says which one it is, in words")
    func eachMarkNamesItself() {
        let labels = EvaPredictionMark.allCases.map(\.accessibilityLabel)
        #expect(Set(labels).count == EvaPredictionMark.allCases.count,
                "Two predicted marks announce themselves identically: \(labels)")
        for label in labels {
            #expect(label.localizedCaseInsensitiveContains("predicted"),
                    "\"\(label)\" does not say it is a prediction")
        }

        let legend = EvaPredictionMark.allCases.map(\.legendLabel)
        #expect(Set(legend).count == EvaPredictionMark.allCases.count)
        for label in legend {
            #expect(
                label.localizedCaseInsensitiveContains("dashed"),
                """
                The legend row "\(label)" does not name the treatment, so the legend only \
                works for a reader who can tell the two swatches apart by colour.
                """
            )
        }
    }

    /// PRD §Phase 1, at the point of use. The legend is where A27 puts it.
    @Test("The legend states that the fertile window is not a contraceptive method")
    func theLegendCarriesTheNotice() {
        let notice = CalendarLegend.notContraceptive.lowercased()
        #expect(notice.contains("not a contraceptive method"))
        #expect(notice.contains("fertile window"))
    }

    /// What makes `CalendarPredictionUITests`' notice assertion a real one.
    ///
    /// That suite cannot look the notice up by an identifier — `accessibilityIdentifier`
    /// on the legend card propagates to everything inside it and the outer one wins, so
    /// every line of the legend comes back as `calendar.legend` (read off a UI hierarchy
    /// dump). It searches the card's lines for the words instead, which is only an
    /// assertion if **no other line could satisfy it**. This is that condition, checked
    /// here where it costs nothing rather than in a twenty-minute UI run: remove the notice
    /// from the card and there is nothing left for that search to find.
    @Test("No other legend row could satisfy the notice assertion")
    func nothingElseInTheLegendSaysIt() {
        let otherRows =
            [EvaCycleMark.legendLabel, EvaCycleMark.spottingLegendLabel, "Legend"]
            + EvaPredictionMark.allCases.map(\.legendLabel)
            + EvaEventGlyph.allCases.map(\.legendLabel)

        for row in otherRows {
            #expect(
                !row.localizedCaseInsensitiveContains("not a contraceptive method"),
                """
                The legend row "\(row)" also carries the notice's words, so the UI test \
                would pass with the notice deleted.
                """
            )
        }
    }
}

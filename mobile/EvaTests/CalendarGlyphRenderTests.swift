import Testing
import SwiftUI
@testable import Eva

/// Issue #159: **position and shape, read off the pixels.**
///
/// `CalendarEventTests` pins the mapping at the enum level — which glyph a type owns, which
/// corner and outline that glyph names. That is not the property the issue is about. The
/// property is what a day cell *draws*, and it lives in the composition of
/// `EvaCalendarMetrics.inset(for:)` with `alignment(for:)`, and in
/// `EvaEventGlyphMark`'s `switch` — none of which the enum values reach. Measured: mapping
/// `.bottomLeading` to `.topTrailing`, or drawing every shape as a `Circle`, passed the
/// whole suite before this file existed.
///
/// Both halves matter for the same reason: four marks, 5–6pt across, on one 50pt cell.
/// A red-green colourblind user separates them by corner and outline or not at all
/// (DESIGN.md §1 — never colour alone).
///
/// Not snapshot testing — see `EvaRenderSupport.swift`. Nothing is recorded and nothing is
/// compared to a reference image; the expectations are corners and fill ratios that follow
/// from the geometry.
@MainActor
@Suite("Issue #159 · what a day cell's marks actually draw")
struct CalendarGlyphRenderTests {

    /// Rendered at 4–8 pixels per point, because a 5pt dot is five pixels at 1×, and a
    /// five-pixel circle is indistinguishable from a five-pixel square.
    static let positionScale: CGFloat = 4
    static let shapeScale: CGFloat = 8

    /// What a glyph drew: the bounding box of everything that is not the background, in
    /// points, and how much of that box it filled.
    struct Drawn {
        let bounds: CGRect
        /// Covered area over bounding-box area. The number that tells the four outlines
        /// apart — see `shapesAreFourDifferentOutlines`.
        let fill: Double
        var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    /// Renders `view` on white and measures what it marked.
    ///
    /// White because every glyph tint is a mid-to-dark colour, so "not the background" is
    /// unambiguous without having to know which tint was used — which is the point: the
    /// test must not be satisfied by the colour being right.
    static func draw(_ view: some View, size: CGFloat, scale: CGFloat) throws -> Drawn {
        let raster = try EvaRaster(
            view.frame(width: size, height: size),
            size: CGSize(width: size, height: size),
            background: .white,
            scale: scale
        )
        let white = Color.white.evaTestRGBA
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var covered = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                // A generous tolerance, so faint antialiasing at the very edge of a shape
                // does not count as drawn and inflate every ratio towards 1.
                guard !raster.pixel(x, y).isWithin(40, of: white) else { continue }
                covered += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard covered > 0 else { throw EvaRenderError.renderFailed }
        let bounds = CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
        let boxPixels = Double((maxX - minX + 1) * (maxY - minY + 1))
        return Drawn(bounds: bounds, fill: Double(covered) / boxPixels)
    }

    // MARK: - Position

    /// Each mark lands in its own corner of the cell, and **no two land in the same one.**
    @Test("Every mark draws in the corner its position names")
    func marksLandInTheirOwnCorner() throws {
        let cell = EvaCalendarMetrics.cellHeight
        var centres: [EvaEventGlyph: CGPoint] = [:]

        for glyph in EvaEventGlyph.allCases {
            let drawn = try Self.draw(
                CalendarDayMarks(glyphs: [glyph]),
                size: cell,
                scale: Self.positionScale
            )
            centres[glyph] = drawn.centre
            let centre = drawn.centre

            switch glyph.position {
            case .bottomLeading:
                #expect(centre.x < cell / 2, "\(glyph) drew at x \(centre.x), not on the left")
                #expect(centre.y > cell / 2, "\(glyph) drew at y \(centre.y), not at the bottom")
            case .bottomCenter:
                #expect(abs(centre.x - cell / 2) < 4,
                        "\(glyph) drew at x \(centre.x), which is not the centre of \(cell)")
                #expect(centre.y > cell / 2, "\(glyph) drew at y \(centre.y), not at the bottom")
            case .bottomTrailing:
                #expect(centre.x > cell / 2, "\(glyph) drew at x \(centre.x), not on the right")
                #expect(centre.y > cell / 2, "\(glyph) drew at y \(centre.y), not at the bottom")
            case .topTrailing:
                #expect(centre.x > cell / 2, "\(glyph) drew at x \(centre.x), not on the right")
                #expect(centre.y < cell / 2, "\(glyph) drew at y \(centre.y), not at the top")
            }
        }

        // The claim the corners exist for: a cell carrying all four is readable because no
        // two of them overlap.
        for (a, b) in Self.pairs(of: EvaEventGlyph.allCases) {
            let separation = hypot(
                centres[a]!.x - centres[b]!.x,
                centres[a]!.y - centres[b]!.y
            )
            #expect(separation > EvaCalendarMetrics.badgeSize,
                    "\(a) and \(b) drew \(separation)pt apart, close enough to read as one mark")
        }
    }

    // MARK: - Shape

    /// The four outlines are four different outlines, measured as how much of its own
    /// bounding box each one covers.
    ///
    /// The geometry, which is where the bands come from: a circle covers `π/4` ≈ .79 of its
    /// box; a rounded square nearly all of it; a square turned 45° exactly half of the box
    /// its diagonal defines; and the appointment badge is a hollow outline with a `+` in it,
    /// so it covers least of all. Draw them all as one shape and these collapse together.
    @Test("The four marks are four different outlines, not one in four colours")
    func shapesAreFourDifferentOutlines() throws {
        var fills: [EvaEventGlyph: Double] = [:]
        for glyph in EvaEventGlyph.allCases {
            fills[glyph] = try Self.draw(
                EvaEventGlyphMark(glyph: glyph),
                size: 24,
                scale: Self.shapeScale
            ).fill
        }

        #expect((0.68...0.92).contains(fills[.sex]!),
                "The sex mark covers \(fills[.sex]!) of its box, which is not a disc")
        #expect(fills[.bodySignals]! > 0.88,
                "The body-signals mark covers \(fills[.bodySignals]!), which is not a square")
        #expect((0.38...0.62).contains(fills[.sport]!),
                "The sport mark covers \(fills[.sport]!), which is not a diamond")
        #expect(fills[.appointment]! < 0.55,
                "The appointment badge covers \(fills[.appointment]!), which is not hollow")

        // And the assertion that survives someone retuning the bands: they are four
        // distinguishable numbers, however the shapes are drawn.
        for (a, b) in Self.pairs(of: EvaEventGlyph.allCases) where a.shape != b.shape {
            #expect(abs(fills[a]! - fills[b]!) > 0.06,
                    """
                    \(a.shape) and \(b.shape) cover \(fills[a]!) and \(fills[b]!) — \
                    too close to be told apart without colour
                    """)
        }
    }

    /// The marks are small, and they are the sizes the artboard draws.
    @Test("Each mark is drawn at its artboard size")
    func marksAreTheArtboardSizes() throws {
        let dot = try Self.draw(EvaEventGlyphMark(glyph: .sex), size: 24, scale: Self.shapeScale)
        #expect(abs(dot.bounds.width - EvaCalendarMetrics.dotSize) < 1)

        let square = try Self.draw(
            EvaEventGlyphMark(glyph: .bodySignals), size: 24, scale: Self.shapeScale
        )
        #expect(abs(square.bounds.width - EvaCalendarMetrics.markSize) < 1)

        let badge = try Self.draw(
            EvaEventGlyphMark(glyph: .appointment), size: 24, scale: Self.shapeScale
        )
        #expect(abs(badge.bounds.width - EvaCalendarMetrics.badgeSize) < 1)

        // The diamond is the 6pt square turned 45°, so its box is the diagonal.
        let diamond = try Self.draw(
            EvaEventGlyphMark(glyph: .sport), size: 24, scale: Self.shapeScale
        )
        #expect(abs(diamond.bounds.width - EvaCalendarMetrics.markSize * 2.squareRoot()) < 1.5)
    }

    static func pairs<T>(of values: [T]) -> [(T, T)] {
        var out: [(T, T)] = []
        for (index, a) in values.enumerated() {
            for b in values.dropFirst(index + 1) { out.append((a, b)) }
        }
        return out
    }
}

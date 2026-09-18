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
        /// Covered area over bounding-box area. The number that tells the solid outlines
        /// apart — see `shapesAreFiveDifferentOutlines`.
        let fill: Double
        /// How much of the **inner half** of the bounding box is covered: ~1 for anything
        /// solid, near 0 for a hollow outline. Added with the positive-test mark (#80),
        /// whose 9pt outlined square covers almost exactly as much of its own box as the
        /// 6pt diamond covers of its diagonal — one scalar could not separate five shapes,
        /// and this is the axis that actually distinguishes them.
        let core: Double
        var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    /// Renders `view` on white and measures what it marked.
    ///
    /// White because every glyph tint is a mid-to-dark colour, so "not the background" is
    /// unambiguous without having to know which tint was used — which is the point: the
    /// test must not be satisfied by the colour being right.
    static func draw(_ view: some View, size: CGFloat, scale: CGFloat) throws -> Drawn {
        let raster = try Self.raster(view, size: size, scale: scale)
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

        // The inner half of the box, centred: entirely inside a disc, a square and a
        // diamond, and entirely inside the hole of an outline.
        let quarterX = (maxX - minX + 1) / 4, quarterY = (maxY - minY + 1) / 4
        var coreCovered = 0, corePixels = 0
        for y in (minY + quarterY)...(maxY - quarterY) {
            for x in (minX + quarterX)...(maxX - quarterX) {
                corePixels += 1
                if !raster.pixel(x, y).isWithin(40, of: white) { coreCovered += 1 }
            }
        }

        return Drawn(
            bounds: bounds,
            fill: Double(covered) / boxPixels,
            core: corePixels > 0 ? Double(coreCovered) / Double(corePixels) : 0
        )
    }

    static func raster(_ view: some View, size: CGFloat, scale: CGFloat) throws -> EvaRaster {
        try EvaRaster(
            view.frame(width: size, height: size),
            size: CGSize(width: size, height: size),
            background: .white,
            scale: scale
        )
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
            case .topLeading:
                #expect(centre.x < cell / 2, "\(glyph) drew at x \(centre.x), not on the left")
                #expect(centre.y < cell / 2, "\(glyph) drew at y \(centre.y), not at the top")
            }
        }

        // The claim the corners exist for: a cell carrying all five is readable because no
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

    /// The five outlines are five different outlines, measured on two axes: how much of its
    /// own bounding box each one covers, and how much of the *inner half* of that box it
    /// covers — which is "is it hollow", without having to name a hue.
    ///
    /// The geometry, which is where the bands come from: a circle covers `π/4` ≈ .79 of its
    /// box; a rounded square nearly all of it; a square turned 45° exactly half of the box
    /// its diagonal defines; the appointment badge is a hollow outline with a `+` in it; and
    /// #80's positive-test mark is a hollow outline with nothing in it. Draw them all as one
    /// shape and every number here collapses together.
    ///
    /// **The second axis is why this is not one comparison any more.** A 9pt square outlined
    /// at 1.5pt covers ≈ .48 of its box and a 6pt diamond covers exactly .50 of its own —
    /// two obviously different shapes that one scalar cannot separate. They differ
    /// completely on the core, which is the property that actually matters: one is a ring
    /// and the other is solid.
    @Test("The five marks are five different outlines, not one in five colours")
    func shapesAreFiveDifferentOutlines() throws {
        var fills: [EvaEventGlyph: Double] = [:]
        var cores: [EvaEventGlyph: Double] = [:]
        for glyph in EvaEventGlyph.allCases {
            let drawn = try Self.draw(
                EvaEventGlyphMark(glyph: glyph),
                size: 24,
                scale: Self.shapeScale
            )
            fills[glyph] = drawn.fill
            cores[glyph] = drawn.core
        }

        #expect((0.68...0.92).contains(fills[.sex]!),
                "The sex mark covers \(fills[.sex]!) of its box, which is not a disc")
        #expect(fills[.bodySignals]! > 0.88,
                "The body-signals mark covers \(fills[.bodySignals]!), which is not a square")
        #expect((0.38...0.62).contains(fills[.sport]!),
                "The sport mark covers \(fills[.sport]!), which is not a diamond")
        #expect(fills[.appointment]! < 0.55,
                "The appointment badge covers \(fills[.appointment]!), which is not hollow")
        // A solid 1.5pt border on a 9pt box. A *dashed* one covers about half as much, so
        // this band is also where drawing the positive test like a prediction dies — see
        // `thePositiveTestOutlineIsUnbroken` for the direct assertion.
        #expect((0.38...0.62).contains(fills[.positiveTest]!),
                """
                The positive-test mark covers \(fills[.positiveTest]!) of its box, which is \
                not a 1.5pt solid border on a 9pt square
                """)

        // Solid or hollow, which is what separates the pair the fill ratio cannot.
        for glyph in [EvaEventGlyph.sex, .bodySignals, .sport] {
            #expect(cores[glyph]! > 0.9,
                    "The \(glyph) mark's middle is \(cores[glyph]!) covered, so it is not solid")
        }
        #expect(cores[.positiveTest]! < 0.15,
                """
                The positive-test mark's middle is \(cores[.positiveTest]!) covered — it is \
                filled or patterned rather than the outlined square §7 specifies
                """)
        #expect(cores[.appointment]! < 0.7,
                "The appointment badge's middle is \(cores[.appointment]!) covered, so it is not hollow")

        // And the assertion that survives someone retuning the bands: the five are
        // distinguishable on one axis or the other, however the shapes are drawn.
        for (a, b) in Self.pairs(of: EvaEventGlyph.allCases) where a.shape != b.shape {
            #expect(
                abs(fills[a]! - fills[b]!) > 0.06 || abs(cores[a]! - cores[b]!) > 0.25,
                """
                \(a.shape) and \(b.shape) cover \(fills[a]!)/\(fills[b]!) of their boxes and \
                \(cores[a]!)/\(cores[b]!) of their middles — too close on both to be told \
                apart without colour
                """
            )
        }
    }

    /// **The one visual mistake available here: drawing a logged fact like a prediction.**
    ///
    /// DESIGN.md §7 reserves dashed and patterned for predicted days, and #206 built the
    /// grid's two predicted treatments on exactly that rule. A positive test is something
    /// she reported, so its outline is flat and unbroken — and nothing at the value level
    /// can tell: `EvaCalendarMetrics.positiveTestStrokeWidth` is 1.5 whether the stroke
    /// carries a dash array or not.
    ///
    /// Measured against a **reference stroke drawn here**: the same path, the same width,
    /// solid by construction. A dash lays down roughly half the ink of the border it breaks
    /// up and a pattern lays down more, so either shows as a difference in covered area —
    /// and unlike counting runs along one row, this does not depend on where a dash pattern
    /// happens to start. (Counting runs was tried: a `[3, 3]` dash on a 9pt rounded square
    /// can leave the sampled row in one piece, and the assertion passed on the mutation it
    /// was written to catch.)
    @Test("The positive-test outline is unbroken: it is logged data, not a prediction")
    func thePositiveTestOutlineIsUnbroken() throws {
        let drawn = try Self.draw(
            EvaEventGlyphMark(glyph: .positiveTest), size: 24, scale: Self.shapeScale
        )
        let solid = try Self.draw(
            RoundedRectangle(
                cornerRadius: EvaCalendarMetrics.positiveTestRadius,
                style: .continuous
            )
            .strokeBorder(Color.black, lineWidth: EvaCalendarMetrics.positiveTestStrokeWidth)
            .frame(
                width: EvaCalendarMetrics.positiveTestSize,
                height: EvaCalendarMetrics.positiveTestSize
            ),
            size: 24,
            scale: Self.shapeScale
        )

        #expect(
            abs(drawn.fill - solid.fill) < 0.04,
            """
            The positive-test mark covers \(drawn.fill) of its box where an unbroken 1.5pt \
            border on the same 9pt path covers \(solid.fill). Less is a dash pattern and \
            more is a fill — §7 reserves both for predicted days, and this mark is \
            something she logged.
            """
        )
        #expect(
            abs(drawn.bounds.width - solid.bounds.width) < 0.5,
            "The mark and the reference stroke are not even the same size"
        )
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

        // `width:9px;height:9px` (#80, DESIGN.md §7) — smaller than the badge it shares an
        // outline family with, which is half of what tells the two apart.
        let positiveTest = try Self.draw(
            EvaEventGlyphMark(glyph: .positiveTest), size: 24, scale: Self.shapeScale
        )
        #expect(abs(positiveTest.bounds.width - EvaCalendarMetrics.positiveTestSize) < 1)
        #expect(EvaCalendarMetrics.positiveTestSize < EvaCalendarMetrics.badgeSize)
    }

    static func pairs<T>(of values: [T]) -> [(T, T)] {
        var out: [(T, T)] = []
        for (index, a) in values.enumerated() {
            for b in values.dropFirst(index + 1) { out.append((a, b)) }
        }
        return out
    }
}

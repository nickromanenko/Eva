import Testing
import SwiftUI
@testable import Eva

/// Issue #160: **a spotting day is marked, and is not marked as a period day.**
///
/// The mark is not on the canvas (`mkCell` branches on flow 1–3 only), so there is no
/// artboard to check it against — which makes the constraints that decided its shape the
/// only thing holding it, and those live in pixels rather than in a value anything can
/// assert. `EvaCycleMark.spottingRing` returning a colour says nothing about whether the
/// cell drew a ring, a wash, or a ring the today disc swallowed.
///
/// Measured: making `spottingRing` return the lightest flow wash, or shrinking it inside
/// the 28pt today marker, passes every value-level test in the repo.
///
/// The same rule C1's `CalendarGlyphRenderTests` established for the four corner marks, and
/// it borrows that file's `draw` harness. Not snapshot testing — nothing is recorded, and
/// every expectation is a coordinate that follows from the geometry.
@MainActor
@Suite("Issue #160 · what a spotting day actually draws")
struct CalendarSpottingRenderTests {

    static let cell = EvaCalendarMetrics.cellHeight
    static let centre = cell / 2
    /// Where the ring's stroke crosses the cell's horizontal midline.
    static let ringX = Int((cell / 2 + EvaCalendarMetrics.spottingRingSize / 2).rounded()) - 1
    static let midY = Int(centre)

    static func raster(
        _ mark: EvaCycleMark?,
        isToday: Bool = false
    ) throws -> EvaRaster {
        try EvaRaster(
            CalendarDayCell(
                cell: EvaMonthGrid.Cell(
                    date: EvaDay(year: 2026, month: 8, day: 12), placement: .inMonth
                ),
                isToday: isToday,
                isSelected: false,
                cycleMark: mark,
                glyphs: [],
                select: {}
            )
            .frame(width: cell, height: cell),
            size: CGSize(width: cell, height: cell),
            background: .evaWarmBackground,
            scale: 4
        )
    }

    /// The ring's ink where it crosses the midline. Sampled at 4× and taken as the darkest
    /// pixel in a short horizontal span, because a 1.5pt stroke antialiases across about
    /// six pixels and the exact one it centres on is a rounding detail.
    static func darkestNearRing(_ raster: EvaRaster) -> EvaRGBA {
        var darkest = EvaRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        for offset in -3...3 {
            let pixel = raster.pixel((ringX + offset) * 4, midY * 4)
            if pixel.red + pixel.green + pixel.blue < darkest.red + darkest.green + darkest.blue {
                darkest = pixel
            }
        }
        return darkest
    }

    // MARK: - It is drawn at all

    @Test("A spotting day draws something an empty day does not")
    func spottingIsVisible() throws {
        let spotting = try Self.raster(.spotting)
        let empty = try Self.raster(nil)

        let marked = Self.darkestNearRing(spotting)
        let unmarked = Self.darkestNearRing(empty)
        #expect(
            !marked.isWithin(24, of: unmarked),
            """
            A spotting day rendered \(marked.hexString) where an empty day renders \
            \(unmarked.hexString) — which is the invisible cell #159 reported and #160 is \
            supposed to have fixed.
            """
        )
        // The ring's own ink, not a tint of it.
        #expect(
            marked.isWithin(40, of: Color.evaDeepPink.evaTestRGBA),
            "The ring drew \(marked.hexString), not the deep pink it names"
        )
    }

    // MARK: - It is not a period day

    /// The distinguishing property, and the one the issue is explicit about: a wash of any
    /// strength is the grid's word for "period day".
    @Test("Spotting leaves the cell's corners alone; every flow level fills them")
    func spottingIsNotAWash() throws {
        let corner = 6 * 4
        let empty = try Self.raster(nil).pixel(corner, corner)
        let spotting = try Self.raster(.spotting).pixel(corner, corner)

        #expect(
            spotting.isWithin(6, of: empty),
            """
            A spotting cell's corner rendered \(spotting.hexString) against an empty \
            cell's \(empty.hexString) — the cell is being washed, which reads as a period \
            day.
            """
        )

        for level in EvaFlowLevel.allCases {
            let flow = try Self.raster(.flow(level)).pixel(corner, corner)
            #expect(
                !flow.isWithin(6, of: empty),
                "A \(level.rawValue) flow cell's corner is indistinguishable from an empty one"
            )
        }
    }

    @Test("No flow level draws the ring, and spotting draws no wash")
    func theTwoTreatmentsNeverOverlap() throws {
        for level in EvaFlowLevel.allCases {
            let ink = Self.darkestNearRing(try Self.raster(.flow(level)))
            #expect(
                !ink.isWithin(40, of: Color.evaDeepPink.evaTestRGBA),
                """
                A \(level.rawValue) flow day rendered \(ink.hexString) on the ring's own \
                path, so the two marks cannot be told apart.
                """
            )
        }
    }

    // MARK: - It survives the marks it shares a cell with

    /// The ring is sized to clear the 28pt today disc. A day that is both must show both,
    /// and a ring tucked inside the disc would be swallowed by it.
    @Test("A spotting day that is also today still draws its ring")
    func theRingClearsTheTodayDisc() throws {
        #expect(
            EvaCalendarMetrics.spottingRingSize > EvaCalendarMetrics.todayMarkerSize,
            "The ring is not wider than the today disc, so today would swallow it"
        )

        let ink = Self.darkestNearRing(try Self.raster(.spotting, isToday: true))
        #expect(
            ink.isWithin(40, of: Color.evaDeepPink.evaTestRGBA),
            "Today's disc hid the spotting ring — it rendered \(ink.hexString)"
        )
    }

    /// Shape, not colour: the ring encloses the number rather than filling the space it
    /// occupies, which is what makes it read differently from a wash in greyscale.
    @Test("The ring is an outline, not a disc")
    func theRingIsHollow() throws {
        let raster = try Self.raster(.spotting)
        let inside = raster.pixel((Self.ringX - 5) * 4, Self.midY * 4)
        #expect(
            !inside.isWithin(40, of: Color.evaDeepPink.evaTestRGBA),
            """
            The cell is filled \(inside.hexString) just inside the ring's path, so it is a \
            disc rather than an outline.
            """
        )
    }
}

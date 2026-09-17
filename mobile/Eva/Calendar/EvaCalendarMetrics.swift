import SwiftUI

/// The calendar's drawing geometry, read off the `cal` screen in "Eva App.dc.html".
///
/// These are literals here for the same reason `EvaScreenBackground`'s glow offsets are:
/// **they are not spacing.** A 5pt dot 8pt in from a cell's left edge is a composition at
/// the canvas' 390 × 844 frame, and rounding it to the nearest 8-pt step would move the
/// mark out of its corner. Anything that *is* spacing — the gaps between rows, the screen
/// margin, the padding inside a card — uses `EvaSpacing` and is not in this file.
///
/// Where the artboard's value collides with a named token the token wins and the
/// difference is reported rather than tokenised for one screen; that is the rule
/// `ProfileView` set. So the cards below take `EvaRadius.card` (24) against the artboard's
/// 22, and the legend takes `EvaRadius.banner` (20), which the artboard happens to draw
/// exactly.
enum EvaCalendarMetrics {

    // MARK: Day cell

    /// `height:50px`.
    static let cellHeight: CGFloat = 50
    /// `border-radius:15px`. Off the 14/17/24/30 scale — a cell is neither a chip nor a
    /// control, and 15 is what the artboard draws for all 42 of them.
    static let cellRadius: CGFloat = 15
    /// `gap:4px`, which is also `EvaSpacing.xxs`. Named here so the grid reads as one
    /// geometry rather than borrowing a spacing step for a drawing constant.
    static let cellSpacing = EvaSpacing.xxs

    /// `width:28px;height:28px;border-radius:50%` — the filled disc under today's number.
    static let todayMarkerSize: CGFloat = 28
    /// `outline:2px solid #282126`.
    static let selectionWidth: CGFloat = 2
    /// `outline-offset:1px` — the ring sits *outside* the cell, so a selected day that is
    /// also a flow day still shows its fill to the edge.
    static let selectionOffset: CGFloat = 1

    // MARK: Marks

    /// The sex dot: `width:5px;height:5px`.
    static let dotSize: CGFloat = 5
    /// The body-signals square and the sport diamond: `width:6px;height:6px`.
    static let markSize: CGFloat = 6
    /// `border-radius:2px` on the body-signals square — rounded enough to read as drawn
    /// rather than aliased, square enough not to read as the dot.
    static let squareRadius: CGFloat = 2
    /// The spotting ring, which the artboard does not draw — see `EvaCycleMark.spottingRing`.
    ///
    /// Sized to clear the 28pt today disc so that a day which is both still shows both, and
    /// drawn around the number rather than in a corner because all four corners are spoken
    /// for: dot, square, diamond, badge, and the top-left is reserved for the positive-test
    /// mark DESIGN.md §7 already specifies.
    static let spottingRingSize: CGFloat = 32
    static let spottingRingWidth: CGFloat = 1.5

    /// The appointment badge: `width:13px;height:13px`.
    static let badgeSize: CGFloat = 13
    /// `border-radius:4px`.
    static let badgeRadius: CGFloat = 4
    /// `font:700 9px` — the `+` inside the badge.
    static let badgeGlyphSize: CGFloat = 9

    /// Where each mark sits inside its cell, as the inset from the edges it hugs.
    ///
    /// `left:8px;bottom:6px` · `bottom:6px` centred · `right:8px;bottom:5px` ·
    /// `right:4px;top:3px`.
    static func inset(for glyph: EvaEventGlyph) -> EdgeInsets {
        switch glyph.position {
        case .bottomLeading: EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 0)
        case .bottomCenter: EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0)
        case .bottomTrailing: EdgeInsets(top: 0, leading: 0, bottom: 5, trailing: 8)
        case .topTrailing: EdgeInsets(top: 3, leading: 0, bottom: 0, trailing: 4)
        }
    }

    /// The SwiftUI alignment each mark's corner maps to.
    static func alignment(for glyph: EvaEventGlyph) -> Alignment {
        switch glyph.position {
        case .bottomLeading: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomTrailing: .bottomTrailing
        case .topTrailing: .topTrailing
        }
    }

    // MARK: Predicted days (#206)

    /// The stripe pattern's ink and repeat —
    /// `repeating-linear-gradient(45deg, C 0 3px, transparent 3px 7px)`. Three points of
    /// ink every seven, so four points of the surface below shows through between them.
    static let predictionStripeInk: CGFloat = 3
    static let predictionStripePeriod: CGFloat = 7

    /// `border:1px dashed`.
    static let predictionOutlineWidth: CGFloat = 1

    /// The dash pattern, which is **not a canvas value** — CSS `dashed` leaves the segment
    /// length to the renderer, so the artboard specifies none and the browsers that draw it
    /// each pick their own. 3 on, 3 off is the common reading of a 1px `dashed` border and
    /// it keeps the broken edge legible around a 15pt corner radius; a longer dash closes
    /// up on the curve and reads as solid, which is the one thing this outline may not do.
    /// Recorded in DESIGN.md §9a.
    static let predictionOutlineDash: [CGFloat] = [3, 3]

    // MARK: Surfaces

    /// The white hairline on the calendar's glass surfaces.
    ///
    /// The artboard spreads these from `rgba(255,255,255,.6)` on a day cell to `.9` on the
    /// month picker. DESIGN.md §4's own card hairline is `.72` and sits in the middle of
    /// that spread, so one value is used across the screen rather than five — the
    /// difference between them is a fraction of a point of alpha on a 1pt line.
    static let surfaceHairline = Color.white.opacity(0.72)

    /// The read-only mode chip: `min-height:34px`.
    ///
    /// Below the 44pt minimum touch target on purpose — §1's floor is for *interactive*
    /// elements, and this one is a label. A6: Pregnancy Mode is entered from Profile and
    /// the chip on the calendar is never a control.
    static let modeChipHeight: CGFloat = 34

    /// The month stepper buttons: `width:44px;height:44px`, which is also §1's minimum
    /// touch target.
    static let stepperSize = EvaMetrics.minimumTouchTarget

    /// The log FAB: `width:60px;height:60px;border-radius:22px`.
    static let fabSize: CGFloat = 60
    /// `border-radius:22px`. Off the radius scale, like the cell's 15.
    static let fabRadius: CGFloat = 22
    /// `bottom:104px` from the frame, above an 88pt tab bar.
    static let fabBottomInset: CGFloat = 16
}

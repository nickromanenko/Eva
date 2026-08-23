import Testing
import SwiftUI
@testable import Eva

/// Issue #16 and #17 acceptance for the things that are only true once they are drawn:
/// the §2 washes' angles and stops, the §4 card's inset lines, and L1 glass dropping
/// `Material`.
///
/// None of these is reachable from a value assertion. A `LinearGradient` exposes
/// neither its stops nor its unit points; `EvaGlassModifier` decides whether to draw a
/// material inside its `body`. The tokens can all be right and the surface still wrong,
/// which is exactly what happened — the white-highlight wash was 28% fading out at 55%
/// height against a canvas that says 75% fading out at the bottom, and nothing noticed
/// because there was no test that looked.
///
/// See `EvaRenderSupport.swift` for why this is not snapshot testing.
@MainActor
@Suite("DESIGN.md §2/§4 surfaces as rendered")
struct EvaSurfaceRenderTests {

    private static let tolerance = 6

    /// A square, so a CSS angle and a `UnitPoint` pair mean the same thing. `UnitPoint`
    /// space is normalised to the view's bounds, so the rendered angle only equals the
    /// CSS angle where the view is square — which is the caveat `evaUnitPoints(cssAngle:)`
    /// documents and this suite has to honour.
    private static let square = CGSize(width: 100, height: 100)

    private func square(_ gradient: LinearGradient) throws -> EvaRaster {
        try EvaRaster(Rectangle().fill(gradient), size: Self.square)
    }

    // MARK: The wash angles (#16)

    /// A 135° gradient runs corner to corner: the two off-diagonal corners both sit at
    /// the midpoint, because they are the same distance along the gradient line.
    private func expectDiagonal(
        _ raster: EvaRaster,
        from start: Color,
        to end: Color,
        _ name: String
    ) {
        #expect(raster.pixel(1, 1).isWithin(Self.tolerance, of: start.evaTestRGBA),
                "\(name) top-left is \(raster.pixel(1, 1).hexString), expected \(start.evaTestHex)")
        #expect(raster.pixel(98, 98).isWithin(Self.tolerance, of: end.evaTestRGBA),
                "\(name) bottom-right is \(raster.pixel(98, 98).hexString), expected \(end.evaTestHex)")
        #expect(raster.pixel(98, 1).isWithin(Self.tolerance, of: raster.pixel(1, 98)),
                "\(name) is not 135°: top-right \(raster.pixel(98, 1).hexString) and bottom-left \(raster.pixel(1, 98).hexString) are not the same point on the ramp")
    }

    @Test("Blush → cream runs 135°, corner to corner")
    func blushCreamIs135() throws {
        // §2: `linear-gradient(135deg, #F9DCE6, #FFF9F6)`, "cream" being Warm Background.
        expectDiagonal(try square(.evaBlushCream),
                       from: .evaSoftBlush, to: .evaWarmBackground, "blush → cream")
    }

    @Test("Pistachio → cream runs 135°, corner to corner")
    func pistachioCreamIs135() throws {
        // §2 at 135°. **The pistachio stop is `evaLightPistachio` `#EDF6DA`, not
        // Pistachio `#CDE79D`** — a change this branch made that #16's acceptance
        // criteria does not list and #12's artboard reading does not quote. Asserted
        // against what the code now does *and flagged in the review*: the artboard is
        // not mirrored into `docs/design/`, so this value cannot be checked from the
        // repo. If it turns out to be `#CDE79D`, this is the test that says so.
        expectDiagonal(try square(.evaPistachioCream),
                       from: .evaLightPistachio, to: .evaWarmBackground, "pistachio → cream")
    }

    @Test("Pink → pistachio runs 120°, which is not the plain diagonal")
    func pinkPistachioIs120() throws {
        // §2: `linear-gradient(120deg, #F3AEC4, #EDF6DA)`. It shipped on
        // `.topLeading → .bottomTrailing`, which *is* 135° — so the token looked
        // plausible and was 15° out.
        //
        // 120° still starts at the top-left corner and ends at the bottom-right (both
        // project to t = 0 and t = 1 on its gradient line), so the corners cannot tell
        // the two apart. The off-diagonal pair can: at 120° the top-right corner is
        // 63% along and the bottom-left 37%, where at 135° both are at 50%.
        let raster = try square(.evaPinkPistachio)
        #expect(raster.pixel(1, 1).isWithin(Self.tolerance, of: Color.evaGradientPink.evaTestRGBA),
                "top-left is \(raster.pixel(1, 1).hexString), expected #F3AEC4")
        #expect(raster.pixel(98, 98).isWithin(Self.tolerance, of: Color.evaLightPistachio.evaTestRGBA),
                "bottom-right is \(raster.pixel(98, 98).hexString), expected #EDF6DA")

        let topRight = raster.pixel(98, 1)
        let bottomLeft = raster.pixel(1, 98)
        #expect(!topRight.isWithin(Self.tolerance, of: bottomLeft),
                "top-right \(topRight.hexString) and bottom-left \(bottomLeft.hexString) match — this is 135°, not 120°")
        // 120° tilts the line towards the horizontal, so the top-right corner is the
        // *further* along of the two and reads as the pistachio end.
        #expect(topRight.green > bottomLeft.green,
                "the 120° gradient is tilted the wrong way")
    }

    @Test("The pink highlight base runs 135°, not straight down")
    func pinkHighlightBaseIs135() throws {
        // §2: `linear-gradient(135deg, #E982A5, #C95F86)`. It shipped as `.top → .bottom`
        // — 180° — which is the half of the correction that is actually visible.
        let raster = try square(.evaPinkHighlightBase)
        expectDiagonal(raster, from: .evaPrimaryPink, to: .evaDeepPink, "pink highlight base")
        // Under the old 180° the top-right corner was the pure top stop; under 135° it
        // is halfway down the ramp.
        #expect(!raster.pixel(98, 1).isWithin(Self.tolerance, of: Color.evaPrimaryPink.evaTestRGBA),
                "the base is still running straight down")
    }

    @Test("The white highlight wash is 75% at the top and gone at the bottom")
    func whiteHighlightWashRunsFullHeight() throws {
        // §2: `linear-gradient(180deg, rgba(255,255,255,.75), rgba(255,255,255,0))`.
        // It shipped as 28% fading out at 55% height — the invented number #12 called
        // "the weakest in the token set", and it was wrong on both counts.
        //
        // Rendered over black, so an opacity reads back directly as a grey level.
        let raster = try EvaRaster(
            Rectangle().fill(LinearGradient.evaWhiteHighlightWash),
            size: CGSize(width: 8, height: 100)
        )
        func expected(_ alpha: Double) -> EvaRGBA {
            evaComposite(.white.opacity(alpha), over: .black)
        }
        #expect(raster.pixel(4, 0).isWithin(Self.tolerance, of: expected(0.75)),
                "the wash starts at \(raster.pixel(4, 0).hexString), expected 75% white")
        // Linear over the full height: halfway down is half the opacity. Under the old
        // stops this point was already fully transparent.
        #expect(raster.pixel(4, 50).isWithin(Self.tolerance, of: expected(0.375)),
                "mid-height is \(raster.pixel(4, 50).hexString), expected 37.5% white — the wash is not running the full height")
        #expect(raster.pixel(4, 99).isWithin(Self.tolerance, of: expected(0)),
                "the wash does not reach zero at the bottom")
    }

    // MARK: L1 glass drops Material (#17)

    @Test("L1 renders no backdrop material; L2 and L3 keep theirs")
    func onlyL1DropsItsMaterial() {
        // #12 (3): `Material` adds its own tint *under* the white fill, so a 40% L1 read
        // at roughly 70% and was indistinguishable from L2 on a real backdrop — the one
        // thing three levels exist to do. L1 is decorative only, so it does not need a
        // backdrop blur; L2 and L3 keep theirs, where body text needs a stable ground.
        #expect(EvaGlassLevel.background.rendersBackdropMaterial == false)
        #expect(EvaGlassLevel.card.rendersBackdropMaterial)
        #expect(EvaGlassLevel.sheet.rendersBackdropMaterial)
    }

    @Test("L1 composites to exactly its 40% white fill and nothing else")
    func backgroundGlassIsAPlainFill() throws {
        // The flag above says what the level intends; this says what it drew. A plain
        // 40% white fill over a known backdrop has exactly one right answer, and any
        // material sitting under it moves the pixel.
        let backdrop = Color.evaDeepPink
        let raster = try EvaRaster(
            Color.clear.frame(width: 120, height: 60).evaGlass(.background, in: Rectangle()),
            size: CGSize(width: 120, height: 60),
            background: backdrop
        )
        let expected = evaComposite(.white.opacity(0.4), over: backdrop)
        #expect(raster.pixel(60, 30).isWithin(Self.tolerance, of: expected),
                "L1 over \(backdrop.evaTestHex) is \(raster.pixel(60, 30).hexString), expected \(expected.hexString) — something is rendering under the fill")
    }

    @Test("L1 and L2 are far enough apart on a backdrop to be told apart")
    func glassLevelsSeparateOnABackdrop() throws {
        // The observation that drove the decision, kept as a test. Measured on a strong
        // backdrop because that is where the levels were confusable: over the warm
        // background everything is near-white and any two of them look alike.
        let backdrop = Color.evaDeepPink
        func sample(_ level: EvaGlassLevel) throws -> EvaRGBA {
            try EvaRaster(
                Color.clear.frame(width: 120, height: 60).evaGlass(level, in: Rectangle()),
                size: CGSize(width: 120, height: 60),
                background: backdrop
            ).pixel(60, 30)
        }
        let l1 = try sample(.background)
        let l2 = try sample(.card)
        let distance = max(
            abs(l1.red - l2.red), abs(l1.green - l2.green), abs(l1.blue - l2.blue)
        ) * 255
        #expect(distance >= 24,
                "L1 \(l1.hexString) and L2 \(l2.hexString) are \(Int(distance)) channel-units apart")
        #expect(l1.relativeLuminance < l2.relativeLuminance,
                "L1 is not more transparent than L2")
    }

    // MARK: The card's inset lines (#16)

    @Test("The card's top inset line is 90% white, not the 72% it shipped at")
    func cardTopInsetLineIsNinety() throws {
        // §4: `inset 0 1px 0 rgba(255,255,255,.9)` top and
        // `inset 0 -1px 0 rgba(255,255,255,.4)` bottom. They shipped at 72% / 30% — the
        // top line reusing the border's opacity and the bottom "a fainter echo", both
        // invented. The top line is meant to be *brighter* than the 72% hairline border
        // it sits inside, which is what gives the card its lit top edge.
        //
        // Drawn in a plain `Rectangle` so the top and bottom rows are fully covered and
        // no corner curve is in the sample, and over black so the card's own fill is as
        // far from white as this surface gets.
        let size = CGSize(width: 200, height: 80)
        let raster = try EvaRaster(
            Color.clear.frame(width: size.width, height: size.height)
                .evaCardSurface(in: Rectangle()),
            size: size,
            background: .black
        )
        let bottomRow = Int(size.height) - 1
        let top = raster.pixel(100, 0)
        let bottom = raster.pixel(100, bottomRow)

        // The 1pt hairline border (72% white) is drawn *over* the inset lines, so each
        // edge row is two white veils deep: 1 − (1 − 0.72)(1 − a). Composited against
        // the card's own fill on the row immediately inside.
        func edge(_ insetOpacity: Double, over fill: EvaRGBA) -> EvaRGBA {
            let combined = 1 - (1 - 0.72) * (1 - insetOpacity)
            return evaComposite(
                .white.opacity(combined),
                over: Color(red: fill.red, green: fill.green, blue: fill.blue)
            )
        }
        let underTop = raster.pixel(100, 1)
        let canvas = edge(0.90, over: underTop)
        let invented = edge(0.72, over: underTop)

        func distance(_ a: EvaRGBA, _ b: EvaRGBA) -> Double {
            max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255
        }
        // Guard, in the shape the corner-radius tests use: if the two candidates
        // composite to the same pixel this proves nothing and should say so.
        #expect(distance(canvas, invented) > 1.5,
                "90% and 72% are \(distance(canvas, invented)) steps apart over this fill (\(underTop.hexString)) — the test cannot discriminate")
        #expect(distance(top, canvas) < distance(top, invented),
                "the top inset line drew \(top.hexString); 90% predicts \(canvas.hexString), the old 72% predicts \(invented.hexString)")

        // The card is lit from the top: whatever the exact opacities, the top line has
        // to be the brighter of the two and both have to be brighter than the fill.
        #expect(top.relativeLuminance > bottom.relativeLuminance,
                "the card's bottom line is at least as bright as its top")
        #expect(bottom.relativeLuminance > raster.pixel(100, bottomRow - 2).relativeLuminance,
                "the bottom inset line is not drawing at all")
    }

    @Test("The card's bottom inset line is under the measurement's noise floor")
    func cardBottomInsetLineIsNotSeparable() throws {
        // Recorded rather than asserted, because it is a gap and gaps should be visible.
        //
        // The bottom line is 40% white with the 72% border composited over it, which
        // leaves it 1 − (1 − 0.72)(1 − 0.4) = 83.2% white; at the old 30% it would be
        // 80.4%. Against a card fill that `Material` renders near-white whatever the
        // backdrop, those two land within about two 8-bit steps of each other — inside
        // the error of the composite itself. So this branch's 30 → 40 correction on the
        // bottom line is **not covered by any test**, and saying so here is worth more
        // than an assertion that would pass either way.
        let size = CGSize(width: 200, height: 80)
        let raster = try EvaRaster(
            Color.clear.frame(width: size.width, height: size.height)
                .evaCardSurface(in: Rectangle()),
            size: size,
            background: .black
        )
        let fill = raster.pixel(100, Int(size.height) - 3)
        func edge(_ insetOpacity: Double) -> EvaRGBA {
            let combined = 1 - (1 - 0.72) * (1 - insetOpacity)
            return evaComposite(
                .white.opacity(combined),
                over: Color(red: fill.red, green: fill.green, blue: fill.blue)
            )
        }
        let separation = max(
            abs(edge(0.40).red - edge(0.30).red),
            abs(edge(0.40).green - edge(0.30).green),
            abs(edge(0.40).blue - edge(0.30).blue)
        ) * 255
        #expect(separation < 3,
                "40% and 30% now separate by \(separation) steps — the bottom line has become measurable; assert it in `cardTopInsetLineIsNinety` and delete this test")
    }
}

import Testing
import SwiftUI
@testable import Eva

/// Issue #99: **the four tones are four surfaces, and each is the token it claims.**
///
/// The tone→token mapping is a value assertion and is made as one below. What a value
/// assertion cannot reach is whether the modifier that draws them is wired up: every token
/// can be right and all four cards still render identically, which is exactly the
/// regression #99's Risks section is about — `flag` and `quiet` are fed by data D10
/// supplies, so nothing else in the app will notice for months.
///
/// See `EvaRenderSupport.swift` for why this is not snapshot testing.
@MainActor
@Suite("Issue #99 · the Today card's four surfaces")
struct TodayCardRenderTests {

    private static let size = CGSize(width: 320, height: 260)

    /// A pixel in the card's left padding, half way down — the surface itself, clear of
    /// every glyph, and clear of the corner curves at top and bottom. The card is centred
    /// in the frame, so a point near the frame's own top edge is outside it.
    private static let surfaceSample = (x: 8, y: Int(size.height) / 2)
    /// The card's left border, at the same height.
    private static let borderSample = (x: 0, y: Int(size.height) / 2)

    private func raster(_ tone: EvaTodayCardTone) throws -> EvaRaster {
        let card = EvaTodayCard(
            tone: tone,
            kicker: "Cycle tracking",
            title: "A card",
            line2: "A line.",
            actions: [EvaTodayCardAction(label: "Open Calendar")]
        )
        // Over the warm background the screen actually uses: every tone fill is an
        // `rgba(…)` and only has a colour once it is composited over something.
        return try EvaRaster(
            TodayCardView(card: card) { _ in },
            size: Self.size,
            background: .evaWarmBackground
        )
    }

    private func surface(_ tone: EvaTodayCardTone) throws -> EvaRGBA {
        try raster(tone).pixel(Self.surfaceSample.x, Self.surfaceSample.y)
    }

    // MARK: - The mapping

    /// Each tone's tokens, as documented on `EvaTodayCardTone`. A value test, so that a
    /// token swapped for a neighbour fails here by name rather than as a colour a pixel
    /// test would have to describe.
    @Test("Every tone takes the semantic family the canvas draws it in")
    func tonesTakeTheirTokens() {
        #expect(EvaTodayCardTone.base.surfaceBorder == nil)
        #expect(EvaTodayCardTone.base.kickerInk == .evaActionPinkSolid)
        #expect(EvaTodayCardTone.base.suggestionFill == .evaSuccessTint)
        #expect(EvaTodayCardTone.base.suggestionBorder == .evaSuccessBorder)

        #expect(EvaTodayCardTone.edu.surfaceBorder == .evaSuccessBorder)
        #expect(EvaTodayCardTone.edu.kickerInk == .evaSuccessInk)
        #expect(EvaTodayCardTone.edu.suggestionFill == nil)

        #expect(EvaTodayCardTone.flag.surfaceBorder == .evaWarningBorder)
        #expect(EvaTodayCardTone.flag.surfaceBorderWidth == EvaHomeMetrics.flagBorderWidth)
        #expect(EvaTodayCardTone.flag.kickerInk == .evaWarningInk)
        #expect(EvaTodayCardTone.flag.suggestionFill == .evaWarningTint)

        #expect(EvaTodayCardTone.quiet.surfaceBorder == .evaControlBorder)
        #expect(EvaTodayCardTone.quiet.kickerInk == .evaSecondaryText)
        #expect(EvaTodayCardTone.quiet.kickerFill == nil)
    }

    // MARK: - As drawn

    /// `edu` is pistachio: green is the strongest channel, which is true of no other tone.
    @Test("The educational card is drawn pistachio")
    func eduIsGreen() throws {
        let edu = try surface(.edu)
        let base = try surface(.base)
        #expect(edu.green > edu.red && edu.green > edu.blue,
                "edu surface is \(edu.red) / \(edu.green) / \(edu.blue), not pistachio-leaning")
        #expect(!edu.isWithin(3, of: base),
                "edu and base draw the same surface — the tone is not reaching the card")
    }

    /// `flag` is amber: warm, and warmer than the warm background it sits on.
    @Test("The red-flag card is drawn amber")
    func flagIsAmber() throws {
        let flag = try surface(.flag)
        let base = try surface(.base)
        #expect(flag.red > flag.green && flag.green > flag.blue,
                "flag surface is \(flag.red) / \(flag.green) / \(flag.blue), not amber-leaning")
        #expect(flag.red - flag.blue > base.red - base.blue,
                "flag is no warmer than base — the warning tint is not reaching the card")
    }

    /// `quiet` carries no colour at all — it is white, where `base` is white too but a
    /// gradient of it — and is told apart by its border. So the claim is not "equal to
    /// base" but "not tinted": neither pistachio the way `edu` is nor amber the way `flag`
    /// is. The border is the second half, sampled at the card's own edge, where §2's
    /// `rgba(40,33,38,.1)` hairline is darker than the white one `base` draws.
    @Test("The quiet card carries no wash, and a border instead")
    func quietIsUntintedAndBordered() throws {
        let quiet = try surface(.quiet)
        #expect(quiet.green - quiet.blue < (try surface(.edu)).green - (try surface(.edu)).blue,
                "quiet leans pistachio — the canvas draws it flat")
        #expect(quiet.red - quiet.blue < (try surface(.flag)).red - (try surface(.flag)).blue,
                "quiet leans amber — the canvas draws it flat")

        let quietEdge = try raster(.quiet).pixel(Self.borderSample.x, Self.borderSample.y)
        let baseEdge = try raster(.base).pixel(Self.borderSample.x, Self.borderSample.y)
        #expect(
            quietEdge.relativeLuminance < baseEdge.relativeLuminance,
            "quiet's border is no darker than base's white hairline: \(quietEdge.relativeLuminance) against \(baseEdge.relativeLuminance)"
        )
    }
}

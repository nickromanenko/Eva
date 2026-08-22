import Testing
import SwiftUI
@testable import Eva

/// Issue #1 acceptance: "every brand, neutral and semantic colour in DESIGN.md §2
/// exists as a token".
///
/// Existence alone is not the criterion — a token holding the wrong hex satisfies
/// "exists" and fails the design. Each expectation below is the hex as written in
/// DESIGN.md §2, round-tripped back out of the resolved `Color`.
/// The DESIGN.md §2 tables, transcribed. Held outside the suite so the
/// `@Test(arguments:)` macro can read them without crossing main-actor isolation.
enum EvaPalette {

    // MARK: Brand

    static let brand: [EvaColorExpectation] = [
        EvaColorExpectation("Primary Pink", "#E982A5", .evaPrimaryPink),
        EvaColorExpectation("Deep Pink", "#C95F86", .evaDeepPink),
        EvaColorExpectation("Soft Blush", "#F9DCE6", .evaSoftBlush),
        EvaColorExpectation("Pistachio", "#CDE79D", .evaPistachio),
        EvaColorExpectation("Deep Pistachio", "#8EAD56", .evaDeepPistachio),
        EvaColorExpectation("Light Pistachio", "#EDF6DA", .evaLightPistachio)
    ]

    // MARK: Neutrals

    static let neutrals: [EvaColorExpectation] = [
        EvaColorExpectation("Warm Background", "#FFF9F6", .evaWarmBackground),
        EvaColorExpectation("Secondary Background", "#F8F3F0", .evaSecondaryBackground),
        EvaColorExpectation("Glass Surface 66%", "#FFFFFF", alpha: 0.66, .evaGlassSurface),
        EvaColorExpectation("Elevated Glass 92%", "#FFFCFA", alpha: 0.92, .evaElevatedGlass),
        EvaColorExpectation("Primary Text", "#282126", .evaPrimaryText),
        EvaColorExpectation("Secondary Text", "#6F656B", .evaSecondaryText),
        EvaColorExpectation("Muted Text", "#9A9095", .evaMutedText),
        EvaColorExpectation("Text on Dark", "#FFFFFF", .evaTextOnDark)
    ]

    // MARK: Semantic

    static let semantic: [EvaColorExpectation] = [
        EvaColorExpectation("Success", "#7A9B45", .evaSuccess),
        EvaColorExpectation("Warning", "#C9913F", .evaWarning),
        EvaColorExpectation("Error", "#C4645A", .evaError),
        EvaColorExpectation("Information", "#5A7BA0", .evaInformation)
    ]

    /// Gradient stops §2 and §5 name inside prose rather than in the token tables.
    static let gradientStops: [EvaColorExpectation] = [
        EvaColorExpectation("Pink→pistachio pink stop", "#F3AEC4", .evaGradientPink),
        EvaColorExpectation("Primary button top stop", "#EE93B1", .evaPrimaryButtonTop)
    ]

    static let everyToken: [EvaColorExpectation] =
        brand + neutrals + semantic + gradientStops
}

@MainActor
@Suite("DESIGN.md §2 palette")
struct EvaColorTests {

    @Test("Each token round-trips to its documented value", arguments: EvaPalette.everyToken)
    func tokenMatchesTheDocument(_ token: EvaColorExpectation) {
        #expect(
            token.color.evaTestHex == token.hex,
            "\(token.name) should be \(token.hex), resolves to \(token.color.evaTestHex)"
        )
        #expect(
            token.color.evaTestAlpha == token.alpha,
            "\(token.name) should be \(token.alpha) alpha, resolves to \(token.color.evaTestAlpha)"
        )
    }

    @Test("The palette holds no duplicates")
    func paletteHasNoDuplicates() {
        // Two tokens with the same value usually means one was copy-pasted and never
        // corrected. `Text on Dark` and the 66% glass share #FFFFFF but differ in alpha,
        // so compare the full RGBA.
        let resolved = EvaPalette.everyToken.map(\.color.evaTestRGBA)
        #expect(Set(EvaPalette.everyToken.map(\.name)).count == EvaPalette.everyToken.count)
        for i in resolved.indices {
            for j in resolved.indices where j > i {
                #expect(
                    resolved[i] != resolved[j],
                    "\(EvaPalette.everyToken[i].name) and \(EvaPalette.everyToken[j].name) are the same colour"
                )
            }
        }
    }

    // MARK: The hex initialiser itself

    @Test("Color(hex:) maps channels in RGB order")
    func hexInitialiserIsCorrect() {
        // Everything above is expressed through `Color(hex:)`, so a channel-swap bug in
        // the initialiser would cancel itself out. Anchor it on values that cannot.
        #expect(Color(hex: 0xFF0000).evaTestHex == "#FF0000")
        #expect(Color(hex: 0x00FF00).evaTestHex == "#00FF00")
        #expect(Color(hex: 0x0000FF).evaTestHex == "#0000FF")
        #expect(Color(hex: 0x000000).evaTestHex == "#000000")
        #expect(Color(hex: 0xFFFFFF).evaTestHex == "#FFFFFF")
        #expect(Color(hex: 0x123456).evaTestHex == "#123456")
        #expect(Color(hex: 0xFF0000).evaTestAlpha == 1.0)
    }

    // MARK: Semantic derivations

    @Test("Every semantic state has ink, tint and border companions")
    func semanticFamiliesAreComplete() {
        // DESIGN.md §2 gives one hex per state; the theme derives a fill and a stroke
        // from it. The derivations are opacity-only, so ink must equal the base hex.
        let families: [(String, Color, Color, Color, Color)] = [
            ("Success", .evaSuccess, .evaSuccessInk, .evaSuccessTint, .evaSuccessBorder),
            ("Warning", .evaWarning, .evaWarningInk, .evaWarningTint, .evaWarningBorder),
            ("Error", .evaError, .evaErrorInk, .evaErrorTint, .evaErrorBorder),
            ("Information", .evaInformation, .evaInformationInk,
             .evaInformationTint, .evaInformationBorder)
        ]
        for (name, base, ink, tint, border) in families {
            #expect(ink.evaTestHex == base.evaTestHex, "\(name) ink drifted from its base hex")
            #expect(ink.evaTestAlpha == 1.0, "\(name) ink is translucent")
            #expect(tint.evaTestHex == base.evaTestHex, "\(name) tint drifted from its base hex")
            #expect(border.evaTestHex == base.evaTestHex, "\(name) border drifted from its base hex")
            #expect(tint.evaTestAlpha < border.evaTestAlpha, "\(name) tint is not lighter than its border")
            #expect(border.evaTestAlpha < 1.0, "\(name) border is opaque")
        }
    }

    // MARK: Legacy palette

    @Test("The pre-canvas tokens are still live")
    func legacyPaletteSurvives() {
        // Issue #1 is a token-only change: the onboarding screens keep using the old
        // names until #3 re-skins them. Removing one here would break screens this
        // issue is not allowed to touch. Spot-checks the accent, text and background
        // tokens DESIGN.md §9 lists as drifted.
        #expect(Color.evaPlum.evaTestHex == "#8E2C57")
        #expect(Color.evaPink.evaTestHex == "#C96A93")
        #expect(Color.evaInk.evaTestHex == "#3A2233")
        #expect(Color.evaBody.evaTestHex == "#6E5E69")
        #expect(Color.evaMuted.evaTestHex == "#98868F")
        #expect(Color.evaBackgroundTop.evaTestHex == "#FBF7FA")
        #expect(Color.evaBackgroundBottom.evaTestHex == "#F7EEF4")
    }
}

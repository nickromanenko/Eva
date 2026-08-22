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
/// One semantic state and the three companions the artboard gives it.
///
/// `companionSharesBaseHue` records, per token in `tokens` order, whether the artboard's
/// value happens to be the base hue at some opacity. Two of the four families are; the
/// point of recording it is that Success is not, and the old code assumed all four were.
struct EvaSemanticFamily: Sendable, CustomStringConvertible {
    let name: String
    let base: Color
    let tint: EvaColorExpectation
    let border: EvaColorExpectation
    let ink: EvaColorExpectation
    let companionSharesBaseHue: [Bool]

    var tokens: [EvaColorExpectation] { [tint, border, ink] }
    var description: String { name }
}

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

    /// The artboard's discrete tint / border / ink per state, from #12's
    /// "Pulled Eva Design System.dc.html again" table. Applied by #16.
    static let semanticFamilies: [EvaSemanticFamily] = [
        EvaSemanticFamily(
            name: "Success", base: .evaSuccess,
            tint: EvaColorExpectation("Success tint", "#CDE79D", alpha: 0.26, .evaSuccessTint),
            border: EvaColorExpectation("Success border", "#8EAD56", alpha: 0.32,
                                        .evaSuccessBorder),
            ink: EvaColorExpectation("Success ink", "#4F6630", .evaSuccessInk),
            companionSharesBaseHue: [false, false, false]
        ),
        EvaSemanticFamily(
            name: "Warning", base: .evaWarning,
            tint: EvaColorExpectation("Warning tint", "#C9913F", alpha: 0.10, .evaWarningTint),
            border: EvaColorExpectation("Warning border", "#C9913F", alpha: 0.30,
                                        .evaWarningBorder),
            ink: EvaColorExpectation("Warning ink", "#8A6425", .evaWarningInk),
            companionSharesBaseHue: [true, true, false]
        ),
        EvaSemanticFamily(
            name: "Error", base: .evaError,
            tint: EvaColorExpectation("Error tint", "#C4645A", alpha: 0.08, .evaErrorTint),
            border: EvaColorExpectation("Error border", "#C4645A", alpha: 0.26, .evaErrorBorder),
            ink: EvaColorExpectation("Error ink", "#A9524A", .evaErrorInk),
            companionSharesBaseHue: [true, true, false]
        ),
        EvaSemanticFamily(
            name: "Information", base: .evaInformation,
            tint: EvaColorExpectation("Information tint", "#5A7BA0", alpha: 0.09,
                                      .evaInformationTint),
            border: EvaColorExpectation("Information border", "#5A7BA0", alpha: 0.26,
                                        .evaInformationBorder),
            ink: EvaColorExpectation("Information ink", "#3F5A76", .evaInformationInk),
            companionSharesBaseHue: [true, true, false]
        )
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

    @Test("Each semantic tint, border and ink is the artboard's own value",
          arguments: EvaPalette.semanticFamilies)
    func semanticFamilyMatchesTheArtboard(_ family: EvaSemanticFamily) {
        // Corrected by #16. These were 12% / 32% opacity derivations of the base hue,
        // which was an inference DESIGN.md's transcription invited by carrying one hex
        // per state; the artboard states all three separately, and they are *not*
        // opacities of the base. Success is the clearest case — its tint is pistachio
        // `#CDE79D` and its border deep pistachio `#8EAD56`, neither of which is
        // `#7A9B45` at any opacity. Values from #12, comment "Pulled Eva Design
        // System.dc.html again".
        for token in family.tokens {
            #expect(
                token.color.evaTestHex == token.hex,
                "\(token.name) should be \(token.hex), resolves to \(token.color.evaTestHex)"
            )
            #expect(
                token.color.evaTestAlpha == token.alpha,
                "\(token.name) should be \(token.alpha) alpha, resolves to \(token.color.evaTestAlpha)"
            )
        }
    }

    @Test("No semantic tint or border is an opacity of its own base hue any more",
          arguments: EvaPalette.semanticFamilies)
    func semanticCompanionsAreNotDerivations(_ family: EvaSemanticFamily) {
        // The specific regression #16 fixed, stated as a property so it cannot come
        // back by a different route. Warning and Error *do* keep the base hue for their
        // tint and border — the artboard says so — so this only holds where the
        // artboard gives a different hex, which is why it is driven off the family's
        // own recorded expectation rather than asserted for all four.
        for (token, isBaseHue) in zip(family.tokens, family.companionSharesBaseHue) {
            let matchesBase = token.color.evaTestHex == family.base.evaTestHex
            #expect(
                matchesBase == isBaseHue,
                "\(token.name) resolves to \(token.color.evaTestHex); base is \(family.base.evaTestHex)"
            )
        }
    }

    @Test("Every semantic family reads tint, border, ink — palest to darkest",
          arguments: EvaPalette.semanticFamilies)
    func semanticFamilyIsOrdered(_ family: EvaSemanticFamily) {
        // The ordering is what makes a banner a banner: a wash you can read on, an edge
        // you can see, and an ink dark enough to be text. It survives the exact values
        // changing, so it is the part worth stating as a rule.
        #expect(family.tint.color.evaTestAlpha < family.border.color.evaTestAlpha,
                "\(family.name) tint is not fainter than its border")
        #expect(family.border.color.evaTestAlpha < 1.0, "\(family.name) border is opaque")
        #expect(family.ink.color.evaTestAlpha == 1.0, "\(family.name) ink is translucent")
        #expect(
            family.ink.color.evaTestRGBA.relativeLuminance
                < family.base.evaTestRGBA.relativeLuminance,
            "\(family.name) ink is not darker than its base — it is the text colour"
        )
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

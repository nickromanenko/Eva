import Testing
import SwiftUI
import UIKit
@testable import Eva

/// Issue #1 acceptance: "a `Font` helper exposes the DESIGN.md §3 scale".
///
/// The expectations below are transcribed from DESIGN.md §3 rather than read back out
/// of `EvaTypography.swift`, so the test fails if the code drifts from the document.
struct EvaTypeRow: Sendable, CustomStringConvertible {
    let name: String
    let style: EvaTextStyle
    let font: Font
    let postScriptName: String
    let size: CGFloat
    let lineHeight: CGFloat?
    let tracking: CGFloat
    var description: String { name }
}

/// Every row DESIGN.md §3 lists — Display, H1, H2, H3, Body, Body medium, Button,
/// Label, Caption, Input helper, Error, Overline. Held outside the suite so the
/// `@Test(arguments:)` macro can read it without crossing main-actor isolation.
enum EvaTypeScale {
    static let rows: [EvaTypeRow] = [
        EvaTypeRow(name: "Display 46/48 · 400", style: .display, font: .evaDisplay,
            postScriptName: "Montserrat-Regular", size: 46, lineHeight: 48, tracking: 0),
        EvaTypeRow(name: "H1 28/34 · 600", style: .h1, font: .evaH1,
            postScriptName: "Montserrat-SemiBold", size: 28, lineHeight: 34, tracking: 0),
        EvaTypeRow(name: "H2 21/26 · 600", style: .h2, font: .evaH2,
            postScriptName: "Montserrat-SemiBold", size: 21, lineHeight: 26, tracking: 0),
        EvaTypeRow(name: "H3 17/22 · 600", style: .h3, font: .evaH3,
            postScriptName: "Montserrat-SemiBold", size: 17, lineHeight: 22, tracking: 0),
        EvaTypeRow(name: "Body 15/24 · 400", style: .body, font: .evaBody,
            postScriptName: "Montserrat-Regular", size: 15, lineHeight: 24, tracking: 0),
        EvaTypeRow(name: "Body medium 15/24 · 500", style: .bodyMedium, font: .evaBodyMedium,
            postScriptName: "Montserrat-Medium", size: 15, lineHeight: 24, tracking: 0),
        EvaTypeRow(name: "Button 14.5 · 600", style: .button, font: .evaButton,
            postScriptName: "Montserrat-SemiBold", size: 14.5, lineHeight: nil, tracking: 0),
        EvaTypeRow(name: "Label 12 · 600", style: .label, font: .evaLabel,
            postScriptName: "Montserrat-SemiBold", size: 12, lineHeight: nil, tracking: 0),
        EvaTypeRow(name: "Caption 12.5/19", style: .caption, font: .evaCaption,
            postScriptName: "Montserrat-Regular", size: 12.5, lineHeight: 19, tracking: 0),
        EvaTypeRow(name: "Input helper 12/18", style: .inputHelper, font: .evaInputHelper,
            postScriptName: "Montserrat-Regular", size: 12, lineHeight: 18, tracking: 0),
        EvaTypeRow(name: "Error 12 · 500", style: .error, font: .evaError,
            postScriptName: "Montserrat-Medium", size: 12, lineHeight: nil, tracking: 0),
        EvaTypeRow(name: "Overline 11 · 600 · .14em", style: .overline, font: .evaOverline,
            postScriptName: "Montserrat-SemiBold", size: 11, lineHeight: nil,
            tracking: 11 * 0.14)
    ]
}

@MainActor
@Suite("DESIGN.md §3 type scale")
struct EvaTypographyTests {

    @Test("Every row resolves to a real Montserrat face", arguments: EvaTypeScale.rows)
    func rowResolvesToMontserrat(_ row: EvaTypeRow) {
        let font = UIFont(name: row.style.fontName, size: row.style.size)
        #expect(font != nil, "\(row.name) names \(row.style.fontName), which does not resolve")

        guard let font else { return }
        // Exact-name equality, not just non-nil: a fallback would still be non-nil.
        #expect(
            font.fontName == row.postScriptName,
            "\(row.name) wanted \(row.postScriptName), Core Text gave \(font.fontName)"
        )
        #expect(font.familyName.hasPrefix("Montserrat"))
        #expect(font.pointSize == row.size)
    }

    @Test("Every row carries the DESIGN.md §3 spec", arguments: EvaTypeScale.rows)
    func rowMatchesTheDocument(_ row: EvaTypeRow) {
        #expect(row.style.fontName == row.postScriptName)
        #expect(row.style.size == row.size)
        #expect(row.style.lineHeight == row.lineHeight)
        #expect(abs(row.style.tracking - row.tracking) < 0.0001)
    }

    @Test("Each Font.eva* helper is its row's font", arguments: EvaTypeScale.rows)
    func fontHelperMatchesItsStyle(_ row: EvaTypeRow) {
        // Catches a mis-wired projection (`evaH2 = EvaTextStyle.h3.font`), which no
        // other assertion here would see.
        #expect(row.font == row.style.font)
    }

    @Test("The scale covers all twelve DESIGN.md §3 roles, with no two rows identical")
    func scaleIsComplete() {
        #expect(EvaTypeScale.rows.count == 12)
        #expect(Set(EvaTypeScale.rows.map(\.style)).count == 12)
        #expect(Set(EvaTypeScale.rows.map(\.font)).count == 12)
    }

    // MARK: Line spacing

    @Test("lineSpacing closes the gap to the canvas line height", arguments: EvaTypeScale.rows)
    func lineSpacingReachesTheCanvasLineHeight(_ row: EvaTypeRow) {
        guard let lineHeight = row.lineHeight else {
            #expect(row.style.lineSpacing == 0, "\(row.name) has no line height but adds spacing")
            return
        }
        let natural = row.size * EvaFont.naturalLineHeightRatio
        let expected = max(0, lineHeight - natural)
        #expect(abs(row.style.lineSpacing - expected) < 0.0001)
        #expect(row.style.lineSpacing >= 0)
    }

    @Test("Display's 46/48 leading is tighter than Montserrat's own line box")
    func displayLeadingIsUnreachable() {
        // Documented limitation of the SwiftUI mapping: `lineSpacing` is additive, so a
        // line height *below* the natural line box clamps to 0. If this ever stops
        // being true the Display row is being laid out differently and the note in
        // EvaTypography.swift is stale.
        #expect(EvaTextStyle.display.lineSpacing == 0)
        #expect(46 * EvaFont.naturalLineHeightRatio > 48)
    }

    @Test("The natural line-height ratio matches the shipped Montserrat metrics")
    func naturalLineHeightRatioMatchesTheFont() {
        // hhea ascender 968 − descender −251 + lineGap 0 over a 1000 upem = 1.219.
        let font = UIFont(name: EvaFont.regular, size: 1000)
        #expect(font != nil)
        guard let font else { return }
        let measured = (font.ascender - font.descender + font.leading) / 1000
        #expect(
            abs(measured - EvaFont.naturalLineHeightRatio) < 0.002,
            "EvaFont.naturalLineHeightRatio says \(EvaFont.naturalLineHeightRatio); the shipped font measures \(measured)"
        )
    }
}

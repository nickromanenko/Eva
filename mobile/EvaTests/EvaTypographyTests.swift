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

/// Every row the §3 scale lists — Display, H1, H2, H3, Body, Body medium, Button,
/// Control, Text button, Label, Caption, Input helper, Error, Overline. Held outside
/// the suite so the `@Test(arguments:)` macro can read it without crossing main-actor
/// isolation.
///
/// Two rows are newer than DESIGN.md's transcription of §3 and are taken from the
/// artboard values quoted on #12 rather than from the document, which #16 has not yet
/// caught up with:
///
/// * **Control 13/600** — the artboard sets chips, the row-level destructive button
///   and dialog buttons at `font:600 13px`. §3's written scale had no 13 row, which is
///   why chips first shipped at Label 12.
/// * **Text button 14/600** — the artboard draws that one variant at `font:600 14px`,
///   a step below the 14.5 of the filled buttons.
///
/// Display is 46/**56**, not the artboard's 46/48: decided on #12 (2) and applied by
/// #17, because Montserrat's own line box at 46pt is 56.07pt.
enum EvaTypeScale {
    static let rows: [EvaTypeRow] = [
        EvaTypeRow(name: "Display 46/56 · 400", style: .display, font: .evaDisplay,
            postScriptName: "Montserrat-Regular", size: 46, lineHeight: 56, tracking: 0),
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
        EvaTypeRow(name: "Control 13 · 600", style: .control, font: .evaControlText,
            postScriptName: "Montserrat-SemiBold", size: 13, lineHeight: nil, tracking: 0),
        // No `Font.evaTextButton` exists — this is the one row of the fourteen with no
        // `Font.eva*` projection beside it, so the row's own `.font` stands in and
        // `fontHelperMatchesItsStyle` has nothing to check for it. Reported, not fixed.
        EvaTypeRow(name: "Text button 14 · 600", style: .textButton,
            font: EvaTextStyle.textButton.font,
            postScriptName: "Montserrat-SemiBold", size: 14, lineHeight: nil, tracking: 0),
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

    @Test("The scale covers all fourteen §3 roles, with no two rows identical")
    func scaleIsComplete() {
        // Twelve until #16 added Control 13 and Text button 14. The identity checks are
        // the load-bearing half: a new row wired to an existing style (`.control` left
        // pointing at `.label`) would leave the count right and the scale wrong.
        #expect(EvaTypeScale.rows.count == 14)
        #expect(Set(EvaTypeScale.rows.map(\.style)).count == 14)
        #expect(Set(EvaTypeScale.rows.map(\.font)).count == 14)
    }

    @Test("The scale steps 14.5 → 14 → 13 → 12 with four distinct semibold rows")
    func semiboldRowsAreFourDistinctSizes() {
        // The four rows that are all Montserrat SemiBold with no line height, and so
        // are told apart by size alone. Chips at 12 instead of 13 and the text button
        // at 14.5 instead of 14 were both invisible for exactly this reason — nothing
        // in the suite looked at the sizes as a set.
        let sizes = [
            EvaTextStyle.button.size,
            EvaTextStyle.textButton.size,
            EvaTextStyle.control.size,
            EvaTextStyle.label.size
        ]
        #expect(sizes == [14.5, 14, 13, 12])
        #expect(sizes == sizes.sorted(by: >))
        for style in [EvaTextStyle.button, .textButton, .control, .label] {
            #expect(style.fontName == EvaFont.semibold)
            #expect(style.lineHeight == nil, "a single-line control row gained a line height")
        }
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

    @Test("Display is respecified to Montserrat's own line box, not to the canvas' 48")
    func displayLeadingIsTheNaturalLineBox() {
        // #12 (2), applied by #17. The artboard renders Display at `46px/1.05` ≈ 48,
        // which is *tighter* than the face was drawn for — Montserrat's line box at
        // 46pt is 56.07pt — so it is unreachable through `lineSpacing`, which is
        // additive, and a `TextRenderer` forcing it would collide ascenders.
        //
        // 56 has to be the natural box and not just "a number bigger than 48": the
        // decision was to accept what the font gives, so `lineSpacing` resolving to 0
        // must be because nothing needs adding, not because a negative was clamped.
        // This is the assertion that catches Display being respecified to, say, 60 and
        // silently rendering at 56 anyway.
        let natural = 46 * EvaFont.naturalLineHeightRatio
        #expect(EvaTextStyle.display.lineHeight == 56)
        #expect(abs(natural - 56) < 0.5, "Montserrat's line box at 46pt measures \(natural)")
        #expect(EvaTextStyle.display.lineSpacing == 0)
        // The canvas value is still out of reach, which is *why* the row was changed.
        #expect(natural > 48)
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

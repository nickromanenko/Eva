import Testing
import UIKit
@testable import Eva

/// The four cuts DESIGN.md §3 needs (weights 400/500/600/700), as
/// `(file in the bundle, PostScript name Core Text must answer to)`.
struct MontserratFace: Sendable, CustomStringConvertible {
    let file: String
    let postScriptName: String
    var description: String { postScriptName }
}

/// Held outside the suite so the `@Test(arguments:)` macro can read it without
/// crossing the suite's main-actor isolation.
enum MontserratFaces {
    static let all: [MontserratFace] = [
        MontserratFace(file: "Montserrat-Regular.ttf", postScriptName: "Montserrat-Regular"),
        MontserratFace(file: "Montserrat-Medium.ttf", postScriptName: "Montserrat-Medium"),
        MontserratFace(file: "Montserrat-SemiBold.ttf", postScriptName: "Montserrat-SemiBold"),
        MontserratFace(file: "Montserrat-Bold.ttf", postScriptName: "Montserrat-Bold")
    ]
}

/// Issue #1 acceptance: "Montserrat is bundled".
///
/// Bundling is three separate things that can each fail on their own — the TTF is in
/// the app bundle, `UIAppFonts` names it, and Core Text hands back *that* face when
/// asked for it by PostScript name. These tests check all three, in the app process,
/// because that is the only place the app bundle's registrations exist.
@MainActor
@Suite("Montserrat is bundled and registered")
struct MontserratFontTests {

    // MARK: The bundle

    @Test("UIAppFonts lists exactly the four Montserrat statics")
    func appFontsDeclaration() {
        let declared = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]
        #expect(
            declared != nil,
            "The host app's Info.plist has no UIAppFonts key — nothing is registered"
        )
        #expect(declared?.sorted() == MontserratFaces.all.map(\.file).sorted())
    }

    @Test("Each TTF ships flat at the bundle root", arguments: MontserratFaces.all)
    func fontFileIsInTheBundle(_ face: MontserratFace) {
        // `UIAppFonts` entries are resolved relative to the bundle root, so a file that
        // landed inside a `Fonts/` folder reference would be declared but not found.
        let url = Bundle.main.url(
            forResource: (face.file as NSString).deletingPathExtension,
            withExtension: "ttf"
        )
        #expect(url != nil, "\(face.file) is not at the root of the app bundle")
    }

    @Test("The OFL licence ships alongside the fonts")
    func licenceIsInTheBundle() {
        // Montserrat is OFL-1.1; shipping the faces without the licence text is a
        // licence breach, not a cosmetic omission.
        #expect(Bundle.main.url(forResource: "OFL", withExtension: "txt") != nil)
    }

    // MARK: Core Text resolution

    @Test(
        "Each PostScript name resolves to that exact face",
        arguments: MontserratFaces.all
    )
    func faceResolvesToItself(_ face: MontserratFace) {
        let font = UIFont(name: face.postScriptName, size: 17)
        #expect(font != nil, "UIFont(name: \"\(face.postScriptName)\") returned nil")

        guard let font else { return }
        // The nil check alone is not enough: Core Text answers family names and near
        // misses with a *substituted* face, which is non-nil and wrong. Only exact
        // equality proves the caller got the cut it asked for.
        #expect(
            font.fontName == face.postScriptName,
            "asked for \(face.postScriptName), got \(font.fontName)"
        )
        #expect(
            font.familyName.hasPrefix("Montserrat"),
            "\(face.postScriptName) resolved into family \(font.familyName)"
        )
    }

    @Test("The four faces are four different faces, and none is the system font")
    func facesAreDistinct() {
        let resolved = MontserratFaces.all.compactMap { UIFont(name: $0.postScriptName, size: 40) }
        #expect(resolved.count == MontserratFaces.all.count)

        let names = Set(resolved.map(\.fontName))
        #expect(names.count == MontserratFaces.all.count, "faces collapsed onto: \(names.sorted())")

        let system = UIFont.systemFont(ofSize: 40)
        #expect(!names.contains(system.fontName), "a face fell back to the system font")

        // Names can differ while the rendering does not — a substituted face keeps the
        // requested descriptor in some paths. Measuring a specimen proves the four
        // weights really are four different sets of glyphs. At 40pt the four measure
        // 520.5 / 528.3 / 537.1 / 546.9 and the system font 442.5, so the 0.5pt
        // threshold below has roughly 8pt of headroom on the tightest pair.
        let specimen = "Eva notices what changes"
        func width(_ font: UIFont) -> CGFloat {
            (specimen as NSString).size(withAttributes: [.font: font]).width
        }
        let widths = resolved.map(width) + [width(system)]
        for i in widths.indices {
            for j in widths.indices where j > i {
                #expect(
                    abs(widths[i] - widths[j]) > 0.5,
                    "two faces measure the same width (\(widths[i]) vs \(widths[j])); at least one is a substitution"
                )
            }
        }
    }

    @Test("EvaFont's constants are the PostScript names Core Text knows")
    func evaFontConstantsMatchTheBundle() {
        // Guards the indirection: views reach for `EvaFont.semibold`, not the literal.
        #expect(EvaFont.regular == "Montserrat-Regular")
        #expect(EvaFont.medium == "Montserrat-Medium")
        #expect(EvaFont.semibold == "Montserrat-SemiBold")
        #expect(EvaFont.bold == "Montserrat-Bold")
    }
}

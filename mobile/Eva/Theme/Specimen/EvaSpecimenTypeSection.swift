#if DEBUG
import SwiftUI

/// DESIGN.md §3 — the whole Montserrat scale, one row per style.
///
/// Each row is drawn with `.evaTextStyle(_:)`, so what is on screen is the same call
/// every view makes: font, leading and tracking together.
///
/// **The spec beside each row is computed from the `EvaTextStyle`, not typed from
/// DESIGN.md.** The old captions were transcribed, and duly went stale: Display was
/// still captioned 46/48 after #17 respecified it as 46/56, and Control and Text button
/// were missing entirely because nobody thought to add a line when the tokens landed.
/// A row now cannot appear without its true size, and cannot state a size it does not
/// have. What stays hand-written is the `use` — what the row is *for*.
struct EvaSpecimenTypeSection: View {

    /// Two lines, so leading is visible. Voice-safe (DESIGN.md §8): describes, does not
    /// diagnose or reassure.
    private static let sample = "Eva notices what changes\nand points you to care"

    /// Display is 46pt — the full sample wraps to four lines and swallows a whole
    /// screenshot without showing anything the short one does not.
    private static let displaySample = "Eva notices\nwhat changes"

    private let rows: [EvaSpecimenTypeRowModel] = [
        EvaSpecimenTypeRowModel(name: "Display", use: "marketing only · single-line by design", style: .display),
        EvaSpecimenTypeRowModel(name: "H1 · Screen title", use: nil, style: .h1),
        EvaSpecimenTypeRowModel(name: "H2 · Section heading", use: nil, style: .h2),
        EvaSpecimenTypeRowModel(name: "H3 · Card heading", use: nil, style: .h3),
        EvaSpecimenTypeRowModel(name: "Body", use: nil, style: .body),
        EvaSpecimenTypeRowModel(name: "Body medium", use: "values and emphasis in rows", style: .bodyMedium),
        EvaSpecimenTypeRowModel(name: "Button", use: "filled and glass buttons", style: .button),
        EvaSpecimenTypeRowModel(name: "Text button", use: "text buttons only", style: .textButton),
        EvaSpecimenTypeRowModel(
            name: "Control",
            use: "chips, row destructive, dialog buttons",
            style: .control
        ),
        EvaSpecimenTypeRowModel(name: "Label", use: "secondary colour", style: .label),
        EvaSpecimenTypeRowModel(name: "Caption", use: "muted colour", style: .caption),
        EvaSpecimenTypeRowModel(name: "Input helper", use: nil, style: .inputHelper),
        EvaSpecimenTypeRowModel(name: "Error text", use: "always with an icon", style: .error),
        EvaSpecimenTypeRowModel(name: "Overline", use: "uppercased at the call site", style: .overline)
    ]

    /// Montserrat's line box at Display's size, so the note below states a measured
    /// number rather than a remembered one.
    private static var displayNaturalLineBox: CGFloat {
        EvaTextStyle.display.size * EvaFont.naturalLineHeightRatio
    }

    var body: some View {
        EvaSpecimenSection(number: "02", title: "Typography", reference: "DESIGN.md §3") {
            EvaSpecimenNote(
                text: "Size, leading, weight and tracking are read off each `EvaTextStyle`. "
                    + "Control (13/600) and Text button (14/600) are the two rows §3's "
                    + "written scale omitted — chips shipped at Label 12 for want of the first."
            )

            VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                ForEach(rows) { row in
                    EvaSpecimenTypeRow(
                        row: row,
                        sample: row.style == .display ? Self.displaySample : Self.sample
                    )
                }
            }

            EvaSpecimenNote(
                text: "Display is 46/56 (#17), not the canvas' 46/48: Montserrat's natural "
                    + "line box at 46pt is "
                    + String(format: "%.2f", Self.displayNaturalLineBox)
                    + "pt, tighter than the face was drawn for. So its lineSpacing resolves "
                    + "to \(EvaSpecimenNumber.string(EvaTextStyle.display.lineSpacing)) — the "
                    + "font already gives the specified box, rather than a negative value "
                    + "being clamped away. Single-line by design, so the leading is not "
                    + "observable in the product either way."
            )
        }
    }
}

// MARK: - Row

/// One row of the §3 scale. Only the name and the prose are given; the numbers come
/// from the style.
struct EvaSpecimenTypeRowModel: Identifiable {
    let name: String
    /// What the row is for, where that is not obvious from its name. `nil` for the rows
    /// whose name already says it.
    let use: String?
    let style: EvaTextStyle

    var id: String { name }
}

/// A scale row: what it is called, what it measures, and the type itself.
private struct EvaSpecimenTypeRow: View {
    let row: EvaSpecimenTypeRowModel
    let sample: String

    /// Overline is uppercased at the call site — casing is a string decision, not a font
    /// one (`EvaTextStyle.overline`), so the specimen has to do it too or the row would
    /// misrepresent the style.
    private var text: String {
        row.style == .overline ? sample.uppercased() : sample
    }

    private var caption: String {
        let use = row.use.map { " · \($0)" } ?? ""
        return "\(row.name) · \(row.style.evaSpecimenSpec)\(use)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text(caption)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)
                .fixedSize(horizontal: false, vertical: true)

            Text(text)
                .evaTextStyle(row.style)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Deriving the spec

extension EvaTextStyle {

    /// The row's own numbers, written the way §3 writes them: `46/56 · 400`,
    /// `14.5 · 600`, `11 · 600 · .14em`.
    ///
    /// Leading is printed only where the row specifies one, and tracking only where it
    /// is non-zero, so a caption never claims a value the token does not carry.
    var evaSpecimenSpec: String {
        var spec = EvaSpecimenNumber.string(size)
        if let lineHeight {
            spec += "/\(EvaSpecimenNumber.string(lineHeight))"
        }
        spec += " · \(evaSpecimenWeight)"
        if tracking != 0 {
            spec += " · \(EvaSpecimenNumber.string(tracking / size))em"
        }
        return spec
    }

    /// The CSS weight of the Montserrat cut this row asks for.
    ///
    /// `EvaTextStyle` holds a PostScript name rather than a weight, because that is what
    /// resolves the face unambiguously (DESIGN.md §9b). This maps back for the caption.
    private var evaSpecimenWeight: String {
        switch fontName {
        case EvaFont.regular: "400"
        case EvaFont.medium: "500"
        case EvaFont.semibold: "600"
        case EvaFont.bold: "700"
        default: fontName
        }
    }
}

#Preview("Typography") {
    ScrollView {
        EvaSpecimenTypeSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

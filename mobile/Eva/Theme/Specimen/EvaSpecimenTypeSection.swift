#if DEBUG
import SwiftUI

/// DESIGN.md §3 — the whole Montserrat scale, one row per style.
///
/// Each row is drawn with `.evaTextStyle(_:)`, so what is on screen is the same call
/// every view makes: font, leading and tracking together. The spec caption beside it is
/// typed from DESIGN.md; `EvaTests` is what asserts the numbers, this shows the shapes.
struct EvaSpecimenTypeSection: View {

    /// Two lines, so leading is visible. Voice-safe (DESIGN.md §8): describes, does not
    /// diagnose or reassure.
    private static let sample = "Eva notices what changes\nand points you to care"

    /// Display is 46pt — the full sample wraps to four lines and swallows a whole
    /// screenshot without showing anything the short one does not.
    private static let displaySample = "Eva notices\nwhat changes"

    private let rows: [Row] = [
        Row(name: "Display", spec: "46/48 · 400 · marketing only", style: .display),
        Row(name: "H1 · Screen title", spec: "28/34 · 600", style: .h1),
        Row(name: "H2 · Section heading", spec: "21/26 · 600", style: .h2),
        Row(name: "H3 · Card heading", spec: "17/22 · 600", style: .h3),
        Row(name: "Body", spec: "15/24 · 400", style: .body),
        Row(name: "Body medium", spec: "15/24 · 500", style: .bodyMedium),
        Row(name: "Button", spec: "14.5–15 · 600", style: .button),
        Row(name: "Label", spec: "12 · 600 · secondary", style: .label),
        Row(name: "Caption", spec: "12.5/19 · muted", style: .caption),
        Row(name: "Input helper", spec: "12/18", style: .inputHelper),
        Row(name: "Error text", spec: "12 · 500 · with icon", style: .error),
        Row(name: "Overline", spec: "11 · 600 · .14em · uppercase", style: .overline)
    ]

    var body: some View {
        EvaSpecimenSection(number: "02", title: "Typography", reference: "DESIGN.md §3") {
            VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                ForEach(rows) { row in
                    EvaSpecimenTypeRow(
                        row: row,
                        sample: row.style == .display ? Self.displaySample : Self.sample
                    )
                }
            }

            EvaSpecimenNote(
                text: "§9a: Display asks for 48pt leading over a 56.07pt natural line box, "
                    + "so multi-line Display renders looser than the canvas. Single-line is exact."
            )
        }
    }
}

// MARK: - Row

/// One row of the §3 scale.
private struct Row: Identifiable {
    let name: String
    let spec: String
    let style: EvaTextStyle

    var id: String { name }
}

/// A scale row: what it is called, what it is meant to be, and the type itself.
private struct EvaSpecimenTypeRow: View {
    let row: Row
    let sample: String

    /// Overline is uppercased at the call site — casing is a string decision, not a font
    /// one (`EvaTextStyle.overline`), so the specimen has to do it too or the row would
    /// misrepresent the style.
    private var text: String {
        row.style == .overline ? sample.uppercased() : sample
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text("\(row.name) · \(row.spec)")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaMutedText)

            Text(text)
                .evaTextStyle(row.style)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

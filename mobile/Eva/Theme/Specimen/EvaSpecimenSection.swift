#if DEBUG
import SwiftUI

/// One labelled block of the specimen: an overline number and title, the DESIGN.md
/// section it renders, and the samples themselves.
///
/// Every section of the specimen goes through this so the screenshots have a consistent
/// rhythm and each block says which part of the design it is claiming to show.
struct EvaSpecimenSection<Content: View>: View {

    /// Two-digit ordinal, e.g. `"02"`. Only a label — ordering comes from the order the
    /// sections appear in `EvaSpecimenView`.
    let number: String
    /// The section's name, e.g. `"Colour"`.
    let title: String
    /// Where in DESIGN.md this comes from, e.g. `"DESIGN.md §2"`.
    let reference: String
    /// The samples.
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                Text("\(number) · \(title)")
                    .textCase(.uppercase)
                    .evaTextStyle(.overline)
                    .foregroundStyle(Color.evaDeepPink)

                Text(reference)
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaMutedText)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sub-heading inside a section, for the groups a section is made of ("Brand",
/// "Neutrals", "Semantic").
struct EvaSpecimenGroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .evaTextStyle(.h3)
            .foregroundStyle(Color.evaPrimaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line of small print under a sample — the canvas value it is meant to be, or a note
/// about where the iOS rendering cannot reach it (DESIGN.md §9a).
struct EvaSpecimenNote: View {
    let text: String

    var body: some View {
        Text(text)
            .evaTextStyle(.caption)
            .foregroundStyle(Color.evaSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Section chrome") {
    EvaSpecimenSection(number: "00", title: "Example", reference: "DESIGN.md §0") {
        EvaSpecimenGroupLabel(title: "A group")
        EvaSpecimenNote(text: "A note about what the sample above is meant to be.")
    }
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}
#endif

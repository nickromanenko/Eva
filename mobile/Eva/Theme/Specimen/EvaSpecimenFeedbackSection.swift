#if DEBUG
import SwiftUI

/// DESIGN.md §6 and §7 — the two components those sections have specified since the design
/// system was written and that nothing had built until #160.
///
/// The **toast** is §7's, and the resend cooldown deliberately did without it (§9a); the
/// calendar's soft delete could not, because Undo has nowhere else to live. The
/// **five-point scale** is §6's, named there as "one component — the App canvas' `scales`";
/// body signals is the first screen to need one and D2's "how are you feeling" is the next.
///
/// Both are shown on the warm ground rather than over a screen, which is where the toast
/// actually sits — its whole visual argument is a dark bar against a light page, and a
/// scrolling specimen is close enough to read it.
struct EvaSpecimenFeedbackSection: View {

    /// A fixed selection rather than live state: the specimen is a screenshot target, and
    /// a scale that started empty would photograph as five identical cells.
    @State private var energy: Int? = 2
    @State private var sleep: Int?

    var body: some View {
        EvaSpecimenSection(number: "10", title: "Feedback", reference: "DESIGN.md §6, §7") {
            EvaSpecimenGroupLabel(title: "Toast")
            EvaSpecimenNote(
                text: "Radius \(EvaSpecimenNumber.string(EvaRadius.control)) against the "
                    + "artboard's 18 · ink at "
                    + "\(Int(EvaToastMetrics.fillOpacity * 100))% · a pink action, 44pt "
                    + "against the artboard's 32 (§1's floor). It says what happened and "
                    + "offers the reversal; it never asks, and it never blocks."
            )

            EvaToast(message: "Menstrual cycle deleted") {
                EvaToastButton(title: "Undo") {}
            }
            .accessibilityIdentifier("specimen.toast.undo")

            EvaToast(message: "Body signals saved to 12 August")
                .accessibilityIdentifier("specimen.toast.plain")

            EvaSpecimenGroupLabel(title: "Five-point scale")
            EvaSpecimenNote(
                text: "Five \(EvaSpecimenNumber.string(54))-high cells, a word per point, "
                    + "anchors at both ends, and a readout that says \"Low · 2 of 5\". "
                    + "Nothing is preselected — \"not set\" is a state, and it is not a 3."
            )

            EvaRatingScale(
                label: "Energy",
                words: EvaBodySignalScale.energy.words,
                glyphs: EvaBodySignalScale.energy.glyphs,
                lowAnchor: EvaBodySignalScale.energy.lowAnchor,
                highAnchor: EvaBodySignalScale.energy.highAnchor,
                ink: EvaBodySignalScale.energy.ink,
                tint: EvaBodySignalScale.energy.tint,
                border: EvaBodySignalScale.energy.border,
                selection: $energy
            )
            .accessibilityIdentifier("specimen.scale.energy")

            EvaSpecimenNote(
                text: "A scale with no glyphs falls back to graduated dots, so the size "
                    + "carries the position when an emoji row would be wrong for the "
                    + "subject."
            )

            EvaRatingScale(
                label: "Sleep",
                words: EvaBodySignalScale.sleep.words,
                glyphs: nil,
                lowAnchor: EvaBodySignalScale.sleep.lowAnchor,
                highAnchor: EvaBodySignalScale.sleep.highAnchor,
                ink: EvaBodySignalScale.sleep.ink,
                tint: EvaBodySignalScale.sleep.tint,
                border: EvaBodySignalScale.sleep.border,
                selection: $sleep
            )
            .accessibilityIdentifier("specimen.scale.sleep")
        }
    }
}

#Preview("Specimen · feedback") {
    ScrollView {
        EvaSpecimenFeedbackSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

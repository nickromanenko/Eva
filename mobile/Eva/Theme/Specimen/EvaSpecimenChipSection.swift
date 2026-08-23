#if DEBUG
import SwiftUI

/// DESIGN.md §6 — the chip in all four appearances, full-width and in a grid.
///
/// The four are the canvas' own list: default glass, selected pink gradient, severe
/// solid deep pink with its bar glyph, and disabled muted. `ChipToggleButton` uses
/// `.plain`, so it has no pressed appearance to show — the canvas does not give it one.
///
/// Chips are shown selected/unselected as *drawn*, not as toggled: the specimen holds
/// no selection state, so tapping one does nothing. That is deliberate — this screen is
/// for comparing paint against the canvas, not for exercising behaviour.
struct EvaSpecimenChipSection: View {

    var body: some View {
        EvaSpecimenSection(number: "06", title: "Chips", reference: "DESIGN.md §6") {
            EvaSpecimenNote(
                text: "Min-height \(EvaSpecimenNumber.string(EvaMetrics.minimumTouchTarget)) · "
                    + "radius \(EvaSpecimenNumber.string(EvaRadius.chip)) · label is the §3 "
                    + "Control row, \(EvaTextStyle.control.evaSpecimenSpec) — not Label 12, "
                    + "which is what it first shipped as · never colour alone."
            )

            EvaSpecimenGroupLabel(title: "Full width · leading")
            VStack(spacing: EvaSpacing.sm) {
                ChipToggleButton(label: "Default", isSelected: false) {}
                ChipToggleButton(label: "Selected", isSelected: true) {}
                ChipToggleButton(label: "Severe", isSelected: true, isSevere: true) {}
                ChipToggleButton(label: "Disabled", isSelected: false, isDisabled: true) {}
            }

            EvaSpecimenGroupLabel(title: "Grid · centred")
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: EvaSpacing.sm
            ) {
                ChipToggleButton(label: "Energy", isSelected: false, isCentered: true) {}
                ChipToggleButton(label: "Cycle health", isSelected: true, isCentered: true) {}
                ChipToggleButton(
                    label: "Heavy flow",
                    isSelected: true,
                    isCentered: true,
                    isSevere: true
                ) {}
                ChipToggleButton(
                    label: "Not tracked yet",
                    isSelected: false,
                    isCentered: true,
                    isDisabled: true
                ) {}
            }

            EvaSpecimenGroupLabel(title: "Wrapping label")
            ChipToggleButton(label: "Medications that affect hormones", isSelected: true) {}

            EvaSpecimenNote(
                text: "Selected and severe both carry a white label, so both take the §9a "
                    + "action ramp rather than the canvas pink — measured side by side in "
                    + "§01. Selected has no border by design; severe carries one, plus a "
                    + "9 × 2 bar glyph at radius 1, which is the non-colour half of its cue."
            )

            EvaSpecimenNote(
                text: "No accessibilityIdentifier by design — EvaUITests finds chips by label, "
                    + "which only resolves while the identifier is empty."
            )
        }
    }
}

#Preview("Chips") {
    ScrollView {
        EvaSpecimenChipSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif

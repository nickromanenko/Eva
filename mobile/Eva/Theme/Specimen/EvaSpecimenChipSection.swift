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
            EvaSpecimenNote(text: "Min-height 44 · radius 14 · never colour alone.")

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

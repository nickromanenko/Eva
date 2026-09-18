import SwiftUI

/// The weight and height entry controls, in whichever system is set (#82).
///
/// Both are renderers over `EvaMassInput` / `EvaHeightInput`, which hold the canonical
/// value — kilograms, centimeters — and all of the arithmetic. The displayed numbers are
/// derived on every render and written back only when a button is pressed, which is the
/// property the whole issue turns on:
///
/// * Changing the units setting changes what these draw and leaves the stored value
///   byte-identical. Nothing here has an `onAppear` or a `task` that normalises, tidies
///   or re-rounds the binding — a card that rewrote 68.04 kg to 68 kg just because a
///   metric screen showed "68" would lose the pound it was storing, silently, and the
///   next imperial read would say 150 lb where 151 was typed.
/// * A compound unit is two rows. Feet steps the height by twelve inches and inches steps
///   it by one, both against the same total, so 5'11" + 1 in is 6'0" rather than 5'12".
///
/// They live beside the questionnaire's other components because they wear its legacy
/// styling — `StepperCard`, which DESIGN.md §9 keeps on the old set until the
/// questionnaire moves into Profile (#19). The conversion is in `Eva/Units/`, where
/// Nutrition's own controls (#25 S4) take it from.
struct WeightEntryCard: View {

    /// The canonical value. Kilograms, always.
    @Binding var kilograms: Double
    let system: EvaUnitSystem

    var body: some View {
        StepperCard(title: "Weight", identifier: "weight", rows: rows)
    }

    private var input: EvaMassInput {
        EvaMassInput(kilograms: kilograms, system: system)
    }

    private var rows: [StepperRow] {
        let input = input
        return input.rows.map { row in
            StepperRow(
                id: row.rawValue,
                accessibilityLabel: input.rows.count > 1
                    ? "Weight, \(row.spokenUnit)"
                    : "Weight",
                unitName: row.spokenUnit,
                value: input.value(row),
                unit: row.unit,
                spokenUnit: row.spokenUnit,
                canDecrease: input.canStep(row, by: -1),
                canIncrease: input.canStep(row, by: 1),
                step: { delta in
                    var next = input
                    next.step(row, by: delta)
                    kilograms = next.kilograms
                }
            )
        }
    }
}

/// Height, on the same construction as `WeightEntryCard`.
struct HeightEntryCard: View {

    /// The canonical value. Centimeters, always.
    @Binding var centimeters: Double
    let system: EvaUnitSystem

    var body: some View {
        StepperCard(title: "Height", identifier: "height", rows: rows)
    }

    private var input: EvaHeightInput {
        EvaHeightInput(centimeters: centimeters, system: system)
    }

    private var rows: [StepperRow] {
        let input = input
        return input.rows.map { row in
            StepperRow(
                id: row.rawValue,
                accessibilityLabel: input.rows.count > 1
                    ? "Height, \(row.spokenUnit)"
                    : "Height",
                unitName: row.spokenUnit,
                value: input.value(row),
                unit: row.unit,
                spokenUnit: row.spokenUnit,
                canDecrease: input.canStep(row, by: -1),
                canIncrease: input.canStep(row, by: 1),
                step: { delta in
                    var next = input
                    next.step(row, by: delta)
                    centimeters = next.centimeters
                }
            )
        }
    }
}

#Preview("Every system") {
    @Previewable @State var kilograms = 68.04
    @Previewable @State var centimeters = 175.3

    ScrollView {
        VStack(spacing: 14) {
            ForEach(EvaUnitSystem.allCases) { system in
                Text(system.title)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                WeightEntryCard(kilograms: $kilograms, system: system)
                HeightEntryCard(centimeters: $centimeters, system: system)
            }
        }
        .padding()
    }
    .background(LinearGradient.evaScreenBackground)
}

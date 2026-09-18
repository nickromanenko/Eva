import SwiftUI

/// Card with −/+ controls for numeric questionnaire values (weight, height).
///
/// The chrome is `QuestionnaireFieldCard`, shared with `DateOfBirthCard` since #81 replaced
/// the age stepper with a date — two cards in one stack that only nearly matched would be a
/// design defect waiting to happen.
///
/// **One row per component**, because a compound unit is two fields and not one decimal
/// (#82): a height in feet and inches is a `ft` row and an `in` row, never `5.75`. A card
/// with a single row is exactly what this drew before.
///
/// The unit is no longer in the title. It belongs beside the number, where it changes with
/// the setting — "Weight" over "141 lb", not "Weight · kg".
///
/// ## Why the buttons are their own accessibility elements now
///
/// The card used to be a single adjustable element, which reads well and cannot be driven
/// by XCUITest or told which of two compound fields it is adjusting. Each row is now an
/// accessibility container holding a labelled value and two labelled buttons — the shape a
/// platform stepper has, announced as "Height, feet: 5 feet" then "Decrease feet". The value
/// carries an identifier of its own so `EvaUITests` can read which system a screen is in
/// without depending on layout.
struct StepperCard: View {
    /// The card's heading, e.g. `"Weight"`.
    let title: String
    /// Identifier stem — rows are `stepper.<identifier>.<row id>`.
    let identifier: String
    let rows: [StepperRow]

    var body: some View {
        QuestionnaireFieldCard(title: title) {
            ForEach(rows) { row in
                stepperRow(row)
            }
        }
    }

    private func stepperRow(_ row: StepperRow) -> some View {
        HStack {
            bumpButton("minus", isEnabled: row.canDecrease) { row.step(-1) }
                .accessibilityLabel(Text("Decrease \(row.unitName)"))
                .accessibilityIdentifier("stepper.\(identifier).\(row.id).decrement")

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(row.value)")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(Color.evaInk)
                    .contentTransition(.numericText(value: Double(row.value)))
                Text(row.unit)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.evaMuted)
            }
            .animation(.snappy(duration: 0.2), value: row.value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.accessibilityLabel))
            .accessibilityValue(Text(row.spokenValue))
            .accessibilityIdentifier("stepper.\(identifier).\(row.id).value")

            Spacer()

            bumpButton("plus", isEnabled: row.canIncrease) { row.step(1) }
                .accessibilityLabel(Text("Increase \(row.unitName)"))
                .accessibilityIdentifier("stepper.\(identifier).\(row.id).increment")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stepper.\(identifier).\(row.id)")
    }

    private func bumpButton(
        _ symbol: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.evaPlum)
                .frame(width: 42, height: 42)
                .background(Color.evaBackgroundTop, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.evaChipBorder, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // `.plain` does not dim a disabled subtree the way the filled styles do, so the
        // bound is stated rather than implied. `.disabled` already takes the taps and
        // tells VoiceOver.
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// One −/+ row inside a `StepperCard`.
///
/// It carries a value and a step **closure** rather than a `Binding`, because a compound
/// row does not own its own number: `+` beside the inches of 5'11" has to produce 6'0",
/// which is a change to the height, not to the inches. The owner of the canonical value
/// decides what one step means — `EvaMassInput` and `EvaHeightInput`.
struct StepperRow: Identifiable {
    /// Row identifier suffix, and the unit it stands for: `feet`, `inches`, `stones`,
    /// `pounds`, `kilograms`, `centimeters`. `EvaUITests` asserts on these to tell which
    /// system a screen is in.
    let id: String
    /// What VoiceOver calls the row, e.g. `"Height, feet"`.
    let accessibilityLabel: String
    /// The unit as it appears in the buttons' labels — "Increase feet".
    let unitName: String
    let value: Int
    /// The mark drawn after the number: `"ft"`.
    let unit: String
    /// The same unit spoken in full: `"feet"`.
    let spokenUnit: String
    let canDecrease: Bool
    let canIncrease: Bool
    /// Applies `delta` steps of this row's own unit to whatever owns the value.
    let step: (Int) -> Void

    /// The value as VoiceOver should say it — "5 feet", not "5 ft".
    var spokenValue: String { "\(value) \(spokenUnit)" }
}

#Preview("Metric") {
    @Previewable @State var kilograms = 64.0
    @Previewable @State var centimeters = 168.0

    VStack(spacing: 14) {
        WeightEntryCard(kilograms: $kilograms, system: .metric)
        HeightEntryCard(centimeters: $centimeters, system: .metric)
    }
    .padding()
}

#Preview("Compound") {
    @Previewable @State var kilograms = 68.04
    @Previewable @State var centimeters = 175.3

    VStack(spacing: 14) {
        WeightEntryCard(kilograms: $kilograms, system: .stonesAndPounds)
        HeightEntryCard(centimeters: $centimeters, system: .imperial)
    }
    .padding()
}

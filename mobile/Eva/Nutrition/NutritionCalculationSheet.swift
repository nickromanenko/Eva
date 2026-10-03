import SwiftUI

/// The "How this is calculated" sheet (Nutrition canvas, sheet `why`) — one of the two
/// mechanisms GUARDRAILS 35 names for keeping a computed number inside the wellness line.
///
/// Its own view since #223's Nutrition Settings, which opens it from "How targets are
/// calculated" as the plan summary does: one sheet, two doors (canvas `nSet`, `nCalc`).
/// `REVIEW`: copy.
struct NutritionCalculationSheet: View {

    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EvaSpacing.md) {
                Text("How this is calculated")
                    .evaTextStyle(.h2)
                    .foregroundStyle(Color.evaPrimaryText)
                Text(
                    "Your daily target starts from an estimate of your resting energy use "
                        + "(the Mifflin-St Jeor equation), adjusted for your activity and your "
                        + "goal. During your luteal phase it is raised slightly, and it is "
                        + "clamped so it never falls below what your body needs."
                )
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                TextButton(title: "Done", action: onDone)
            }
            .padding(EvaSpacing.lg)
        }
        .accessibilityIdentifier("nutrition.calculation")
        .presentationDetents([.medium])
    }
}

#Preview("How this is calculated") {
    Text("Behind")
        .sheet(isPresented: .constant(true)) {
            NutritionCalculationSheet {}
        }
}

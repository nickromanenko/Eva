import SwiftUI

/// Profile ▸ Units — metric, imperial, or stones and pounds (#82).
///
/// ## The canvas draws the row, not this screen
///
/// "Eva App.dc.html" has `{label:'Units', meta:'Follows your region by default',
/// value:'Imperial'}` in the Settings artboard's **Eva experience** section, and its own
/// handler for rows like it answers "Detail screen not drawn yet". So the row's wording
/// and its place are the artboard's; the screen behind it is composed out of components
/// the design system does specify — the §6 radio row, the §3 scale, `EvaScreenBackground`
/// — rather than invented. The three options and their descriptions are the part that is
/// a decision rather than a transcription; `EvaUnitSystem` says why there are three.
///
/// ## What the copy promises, and why it can
///
/// "Changing this changes what you see, not what is saved" is the user-facing statement
/// of the rule the whole issue is built on: measurements are stored in kilograms and
/// centimeters and converted at the edge, so switching cannot rewrite a weight that was
/// logged. It is checked, not asserted: `EvaBodyInputTests` encodes the request body
/// before and after a tour of all three systems and compares the bytes, and that is the
/// test that fails if this sentence stops being true.
/// DESIGN.md §8: describe, do not reassure.
struct UnitsSettingsView: View {

    let units: EvaUnitPreference

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.md) {
                    Text("Units")
                        .evaTextStyle(.h1)
                        .foregroundStyle(Color.evaPrimaryText)

                    Text("Changing this changes what you see, not what is saved.")
                        .evaTextStyle(.body)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: EvaSpacing.xs) {
                        ForEach(EvaUnitSystem.allCases) { system in
                            EvaRadioRow(
                                title: system.title,
                                detail: system.detail,
                                isSelected: units.system == system
                            ) {
                                units.choose(system)
                            }
                            .accessibilityIdentifier("units.option.\(system.rawValue)")
                        }
                    }

                    // Where the default came from, said once, in the one place someone
                    // would ask. It is a fact about the device, not advice.
                    Text("Your device's region suggests \(units.localeDefault.title).")
                        .evaTextStyle(.inputHelper)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("units.localeDefault")
                }
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.xs)
                .padding(.bottom, EvaSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

#Preview("Units") {
    NavigationStack {
        UnitsSettingsView(units: EvaUnitPreference())
    }
}

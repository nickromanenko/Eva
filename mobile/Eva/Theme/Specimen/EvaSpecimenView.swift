#if DEBUG
import SwiftUI

/// The design specimen — every token and component in `Eva/Theme/` on one scrollable
/// screen, so visual review against the canvas is repeatable and screenshot-able from
/// the command line.
///
/// DEBUG only, and reached only through `EVA_SPECIMEN=1`:
///
/// ```sh
/// SIMCTL_CHILD_EVA_SPECIMEN=1 xcrun simctl launch --terminate-running-process <udid> com.evaapp.ios
/// xcrun simctl io <udid> screenshot specimen.png
/// ```
///
/// It renders DESIGN.md §2–§6, plus the §9a deviations, and nothing else. It is **not**
/// a screen: it has no navigation, no session, no network, and its controls do nothing
/// when tapped. Adding a token or a component means adding it here too, or the next
/// reviewer will not know it exists.
///
/// Captions are **derived from the tokens** wherever a token can produce them —
/// `EvaSpecimenColorReadback` for colour, `EvaTextStyle.evaSpecimenSpec` for type,
/// `EvaGlassLevel` for glass. They used to be transcribed from DESIGN.md, which let a
/// caption outlive the value it described; the screen built to show what the system is
/// was the one place that could quietly misreport it. What stays hand-written is prose:
/// what a token is for, and why it deviates.
struct EvaSpecimenView: View {

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: EvaSpacing.xl) {
                EvaSpecimenTitle()
                EvaSpecimenColorSection()
                EvaSpecimenTypeSection()
                EvaSpecimenMetricsSection()
                EvaSpecimenGlassSection()
                EvaSpecimenButtonSection()
                EvaSpecimenChipSection()
                EvaSpecimenInputSection()
                EvaSpecimenEndMarker()
            }
            .padding(.horizontal, EvaSpacing.lg)
            .padding(.vertical, EvaSpacing.xl)
        }
        .background {
            Color.evaWarmBackground.ignoresSafeArea()
        }
        .accessibilityIdentifier("specimen.root")
    }
}

// MARK: - Chrome

/// The specimen's own masthead. Uses the §3 scale so the header is itself a sample.
private struct EvaSpecimenTitle: View {

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            Text("Eva design specimen")
                .evaTextStyle(.h1)
                .foregroundStyle(Color.evaPrimaryText)

            Text("DESIGN.md §2–§6 and §9a · DEBUG only · EVA_SPECIMEN=1")
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("specimen.title")
    }
}

/// Marks the bottom of the specimen, so a screenshot sweep can tell "nothing more to
/// scroll" from "the scroll did not take".
private struct EvaSpecimenEndMarker: View {

    var body: some View {
        Text("End of specimen")
            .textCase(.uppercase)
            .evaTextStyle(.overline)
            .foregroundStyle(Color.evaMutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("specimen.end")
    }
}

#Preview("Specimen") {
    EvaSpecimenView()
}
#endif

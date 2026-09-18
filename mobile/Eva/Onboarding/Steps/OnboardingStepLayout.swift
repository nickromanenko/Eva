import SwiftUI

/// Shared scaffold for onboarding steps: scrollable content pinned above a primary CTA.
struct OnboardingStepLayout<Content: View>: View {
    let buttonTitle: String
    var isLoading = false
    /// Holds the CTA while the step's own rule is unmet. Additive and default-`true`, so
    /// every step that has no such rule is unchanged (#81 — the 18+ floor is the first one).
    var isEnabled = true
    let onContinue: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 58)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            PrimaryButton(title: buttonTitle, isLoading: isLoading, action: onContinue)
                .disabled(!isEnabled)
                .padding(.horizontal, 26)
                .padding(.bottom, 16)
        }
    }
}

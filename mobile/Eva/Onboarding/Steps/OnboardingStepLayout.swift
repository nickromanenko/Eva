import SwiftUI

/// Shared scaffold for onboarding steps: scrollable content pinned above a primary CTA.
struct OnboardingStepLayout<Content: View>: View {
    let buttonTitle: String
    var isLoading = false
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
                .padding(.horizontal, 26)
                .padding(.bottom, 16)
        }
    }
}

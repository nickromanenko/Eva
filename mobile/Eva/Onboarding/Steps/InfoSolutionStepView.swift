import SwiftUI

/// Info screen 2 of 2: how Eva closes the gap.
struct InfoSolutionStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("The solution")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(1.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.evaPink)

                    Text("Eva is built around \(Text("you").italic().foregroundStyle(Color.evaPlum))")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.evaInk)
                        .padding(.top, 10)

                    Text("One AI assistant that considers your physiology, cycle, emotions, habits and goals.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.evaBody)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    VStack(spacing: 12) {
                        featureCard(
                            icon: "calendar", tint: .evaLilacTint, iconColor: .evaPlum,
                            title: "Understands your cycle",
                            caption: "Plans your days around your real energy."
                        )
                        featureCard(
                            icon: "leaf", tint: .evaGreenTint, iconColor: .evaGreenIcon,
                            title: "Guides food & training",
                            caption: "Nutrition and workouts tuned to your phase."
                        )
                        featureCard(
                            icon: "brain.head.profile", tint: .evaBlueTint, iconColor: .evaBlueIcon,
                            title: "Supports your mind",
                            caption: "Coaching for stress, focus and rest."
                        )
                    }
                    .padding(.top, 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 58)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            PageDots(count: 2, current: 1)
                .padding(.bottom, 14)
            PrimaryButton(title: "Create my account", action: onContinue)
                .padding(.horizontal, 26)
                .padding(.bottom, 16)
        }
    }

    private func featureCard(icon: String, tint: Color, iconColor: Color, title: String, caption: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 44, height: 44)
                .background(tint, in: .rect(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.evaInk)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evaBody)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.evaCardBorder, lineWidth: 1))
    }
}

#Preview {
    InfoSolutionStepView(onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

import SwiftUI

struct WhyEvaStepView: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepLayout(buttonTitle: "Create my account", onContinue: onContinue) {
            Text("Built for women")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.evaPink)

            Text("The world wasn't built for your body. \(Text("Eva changes that.").italic().foregroundStyle(Color.evaPlum))")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(Color.evaInk)
                .padding(.top, 10)

            HStack(spacing: 10) {
                statCard(number: "47%", caption: "more likely to be hurt in a car crash.")
                statCard(number: "70%", caption: "less accurate voice tech vs. men.")
            }
            .padding(.top, 18)

            Text("Eva closes the gap on a personal level — an assistant that finally accounts for \(Text("you").italic()):")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.evaBody)
                .padding(.top, 16)

            VStack(spacing: 11) {
                featureCard(
                    icon: "calendar", tint: .evaLilacTint, iconColor: .evaPlum,
                    title: "Understands your cycle",
                    caption: "Plans your days around real energy."
                )
                featureCard(
                    icon: "leaf", tint: .evaGreenTint, iconColor: .evaGreenIcon,
                    title: "Guides food & training",
                    caption: "Tuned to your goals and phase."
                )
                featureCard(
                    icon: "brain.head.profile", tint: .evaBlueTint, iconColor: .evaBlueIcon,
                    title: "Supports your mind",
                    caption: "Coaching for stress, focus and rest."
                )
            }
            .padding(.top, 14)
        }
    }

    private func statCard(number: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number)
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundStyle(Color.evaPlum)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Color.evaBody)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.evaCardBorder, lineWidth: 1))
    }

    private func featureCard(icon: String, tint: Color, iconColor: Color, title: String, caption: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 42, height: 42)
                .background(tint, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Color.evaInk)
                Text(caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.evaBody)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.evaCardBorder, lineWidth: 1))
    }
}

#Preview {
    WhyEvaStepView(onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

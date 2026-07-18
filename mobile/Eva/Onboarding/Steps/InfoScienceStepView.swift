import SwiftUI

/// Info screen 1 of 2: the science of the gender data gap.
struct InfoScienceStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("The invisible gap")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(1.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.evaPink)

                    Text("The world wasn't built for your body")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.evaInk)
                        .padding(.top, 10)

                    Text("For decades, women were treated as the exception. The data proves it.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.evaBody)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    VStack(spacing: 12) {
                        statRow(number: "47%", text: "more likely to be seriously injured in a car crash — female dummies arrived only in 2011.")
                        statRow(number: "70%", text: "Speech systems were up to 70% more accurate at understanding male voices.")
                        statRow(number: "5°C", text: "Offices are often set ~5°C colder than what's comfortable for women.")
                    }
                    .padding(.top, 20)

                    Text("Source: Caroline Criado Perez, \(Text("Invisible Women").italic()).")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.evaFaint)
                        .padding(.top, 14)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 58)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            PageDots(count: 2, current: 0)
                .padding(.bottom, 14)
            PrimaryButton(title: "See how Eva helps", action: onContinue)
                .padding(.horizontal, 26)
                .padding(.bottom, 16)
        }
    }

    private func statRow(number: String, text: String) -> some View {
        HStack(spacing: 14) {
            Text(number)
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundStyle(Color.evaPlum)
                .frame(minWidth: 58, alignment: .leading)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.evaSecondary)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.evaCardBorder, lineWidth: 1))
    }
}

#Preview {
    InfoScienceStepView(onContinue: {})
        .background(LinearGradient.evaScreenBackground)
}

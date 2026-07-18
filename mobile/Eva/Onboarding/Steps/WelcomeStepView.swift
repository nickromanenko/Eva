import SwiftUI

struct WelcomeStepView: View {
    let onGetStarted: () -> Void
    let onLogIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            OrbitHeroView()
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Text("The first AI made for women")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evaPink)
                Text("Your \(Text("Prime Era").italic().foregroundStyle(Color.evaPlum))\nstarts here")
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.evaInk)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 12)
                Text("Meet the assistant that understands your body — your cycle, energy and goals.")
                    .font(.system(size: 15.5))
                    .foregroundStyle(Color.evaBody)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 14)
                    .padding(.horizontal, 18)
            }

            VStack(spacing: 12) {
                PrimaryButton(title: "Get started", showsArrow: true, action: onGetStarted)
                HStack(spacing: 4) {
                    Text("Already have an account?")
                        .foregroundStyle(Color(hex: 0x7A6A75))
                    Button("Log in", action: onLogIn)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.evaPlum)
                }
                .font(.system(size: 14.5))
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(alignment: .top) {
            RadialGradient(
                colors: [.evaWashPink, .evaWashPink.opacity(0)],
                center: .init(x: 0.5, y: 0.1),
                startRadius: 20,
                endRadius: 320
            )
            .frame(height: 440)
            .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeStepView(onGetStarted: {}, onLogIn: {})
        .background(LinearGradient.evaScreenBackground)
}

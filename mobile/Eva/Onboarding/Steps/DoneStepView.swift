import SwiftUI

struct DoneStepView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var badgeVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(LinearGradient.evaPlumPink, in: .circle)
                .shadow(color: .evaPlum.opacity(0.5), radius: 20, y: 14)
                .scaleEffect(badgeVisible ? 1 : 0.6)
                .opacity(badgeVisible ? 1 : 0)

            Text("You're all set")
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(Color.evaInk)
                .padding(.top, 26)

            Text("Eva has everything she needs to build your personalised plan. Welcome to your Prime Era.")
                .font(.system(size: 15.5))
                .foregroundStyle(Color.evaBody)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 12)
                .padding(.horizontal, 12)

            Spacer()

            PrimaryButton(title: "Enter Eva", action: onFinish)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
        .background {
            RadialGradient(
                colors: [.evaWashPink, .evaWashPink.opacity(0)],
                center: .init(x: 0.5, y: 0.3),
                startRadius: 30,
                endRadius: 340
            )
            .ignoresSafeArea()
        }
        .onAppear {
            if reduceMotion {
                badgeVisible = true
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.4)) {
                    badgeVisible = true
                }
            }
        }
    }

}

#Preview {
    DoneStepView(onFinish: {})
        .background(LinearGradient.evaScreenBackground)
}

import SwiftUI

/// Animated brand visual: dotted + gradient orbit rings around the Eva wordmark.
struct OrbitHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // Outer dotted ring
            Circle()
                .stroke(Color(hex: 0xE0B7CD), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 9]))
                .frame(width: 224, height: 224)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(spin(seconds: 44), value: isAnimating)

            // Mid gradient arc
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(LinearGradient.evaPlumPink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 172, height: 172)
                .rotationEffect(.degrees(isAnimating ? -360 : 0))
                .animation(spin(seconds: 30), value: isAnimating)

            // Orbiting dot
            Circle()
                .fill(Color.evaPink)
                .frame(width: 14, height: 14)
                .offset(y: -112)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(spin(seconds: 12), value: isAnimating)

            // Soft core with wordmark
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xFDF4F8), Color(hex: 0xF3DDE9)],
                        center: .init(x: 0.4, y: 0.35),
                        startRadius: 6,
                        endRadius: 110
                    )
                )
                .frame(width: 148, height: 148)
                .shadow(color: .evaPlum.opacity(0.4), radius: 22, y: 16)

            Text("Eva")
                .font(.system(size: 64, weight: .bold, design: .serif))
                .foregroundStyle(LinearGradient.evaPlumPink)

            sparkle(size: 18, color: .evaPink)
                .offset(x: 78, y: -96)
            sparkle(size: 13, color: Color(hex: 0x8FB09A))
                .offset(x: -92, y: 82)
        }
        .frame(width: 236, height: 236)
        .onAppear {
            if !reduceMotion { isAnimating = true }
        }
        .accessibilityHidden(true)
    }

    private func spin(seconds: Double) -> Animation? {
        isAnimating ? .linear(duration: seconds).repeatForever(autoreverses: false) : nil
    }

    private func sparkle(size: CGFloat, color: Color) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size))
            .foregroundStyle(color)
    }
}

#Preview {
    OrbitHeroView()
}

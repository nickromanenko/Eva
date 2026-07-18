import SwiftUI

/// Rounded gradient progress bar matching the design's plum→pink fill.
struct EvaProgressBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let fraction = configuration.fractionCompleted ?? 0
            Capsule()
                .fill(Color.evaTrack)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.evaPlum, .evaPink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(7, proxy.size.width * fraction))
                }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.35), value: configuration.fractionCompleted)
    }
}

#Preview {
    ProgressView(value: 0.43)
        .progressViewStyle(EvaProgressBarStyle())
        .padding()
}

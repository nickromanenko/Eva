import SwiftUI

/// Elongated-active-dot page indicator used on the info screens.
struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.evaPlum : Color(hex: 0xE4C8D6))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

#Preview {
    PageDots(count: 2, current: 0)
}

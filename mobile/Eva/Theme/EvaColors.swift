import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    // Brand palette from the Eva design system
    static let evaInk = Color(hex: 0x3A2233)
    static let evaPlum = Color(hex: 0x8E2C57)
    static let evaPink = Color(hex: 0xC96A93)
    static let evaBody = Color(hex: 0x6E5E69)
    static let evaSecondary = Color(hex: 0x5A4B55)
    static let evaMuted = Color(hex: 0x98868F)
    static let evaFaint = Color(hex: 0xA695A0)
    static let evaSoftPink = Color(hex: 0xFBEDF3)
    static let evaChipBorder = Color(hex: 0xEBDDE7)
    static let evaCardBorder = Color(hex: 0xEFE1EB)
    static let evaTrack = Color(hex: 0xEADCE6)
    static let evaBackgroundTop = Color(hex: 0xFBF7FA)
    static let evaBackgroundBottom = Color(hex: 0xF7EEF4)
    static let evaWashPink = Color(hex: 0xF6DCE9)
    static let evaGreenTint = Color(hex: 0xE6F0E9)
    static let evaGreenInk = Color(hex: 0x4E7A5E)
    static let evaGreenIcon = Color(hex: 0x6E9C7E)
    static let evaBlueTint = Color(hex: 0xE7EDF5)
    static let evaBlueInk = Color(hex: 0x4E6C8E)
    static let evaBlueIcon = Color(hex: 0x6E8CB0)
    static let evaLilacTint = Color(hex: 0xEFEAF6)
}

extension LinearGradient {
    /// Signature plum→pink gradient used for primary actions and accents.
    static let evaPlumPink = LinearGradient(
        colors: [.evaPlum, .evaPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let evaScreenBackground = LinearGradient(
        colors: [.evaBackgroundTop, .evaBackgroundBottom],
        startPoint: .top,
        endPoint: .bottom
    )
}

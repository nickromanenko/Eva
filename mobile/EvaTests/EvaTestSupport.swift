import SwiftUI
import UIKit

// Shared helpers for the design-token tests.
//
// These tests are hosted in the Eva app process (`TEST_HOST` in mobile/project.yml).
// That is load-bearing: `Bundle.main` must be the app bundle, and Core Text must have
// the app's `UIAppFonts` registrations, for anything here to mean what it says.

/// Concrete colour components, resolved out of a SwiftUI `Color`.
struct EvaRGBA: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// 0–255 channels as they would be written in the design doc.
    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

extension Color {
    /// Resolves the token to concrete components in the light appearance.
    ///
    /// The palette has no dark variant by design (DESIGN.md §10), so resolving against
    /// a fixed light trait collection is the whole story rather than half of it.
    var evaTestRGBA: EvaRGBA {
        let resolved = UIColor(self)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return EvaRGBA(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        }
        // Greyscale-backed colours (`Color.white`) answer `getWhite` instead.
        var w: CGFloat = 0
        resolved.getWhite(&w, alpha: &a)
        return EvaRGBA(red: Double(w), green: Double(w), blue: Double(w), alpha: Double(a))
    }

    /// The token as `#RRGGBB`, for comparison against DESIGN.md §2.
    var evaTestHex: String { evaTestRGBA.hexString }

    /// The token's alpha, rounded to the two decimals DESIGN.md quotes.
    var evaTestAlpha: Double { (evaTestRGBA.alpha * 100).rounded() / 100 }
}

/// A DESIGN.md §2 palette entry: the documented name, the documented value, and the
/// token that is supposed to carry it.
struct EvaColorExpectation: Sendable, CustomStringConvertible {
    let name: String
    let hex: String
    let alpha: Double
    let color: Color

    init(_ name: String, _ hex: String, alpha: Double = 1.0, _ color: Color) {
        self.name = name
        self.hex = hex
        self.alpha = alpha
        self.color = color
    }

    var description: String {
        alpha == 1.0 ? "\(name) \(hex)" : "\(name) \(hex) @ \(alpha)"
    }
}

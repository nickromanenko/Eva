#if DEBUG
import SwiftUI

/// A token's own colour, read back out of the token.
///
/// ## Why this exists
///
/// The specimen's captions used to be typed out from DESIGN.md beside each swatch. That
/// makes the screen able to lie: change `evaChipSevere` and the swatch moves while the
/// caption goes on claiming the old hex, and the one screen whose entire job is to show
/// what the design system currently *is* becomes the least trustworthy thing in the
/// repo. `EvaTests` catches a token that drifts from the canvas; nothing caught a
/// caption that drifted from its token.
///
/// `Color` will not say what hex it was built from, but iOS 17's `Color.resolve(in:)`
/// hands back the sRGB components it resolves to, and a hex reconstructed from those
/// cannot disagree with the swatch beside it — both are the same token, read twice.
/// So every caption the specimen *can* derive is derived, and what stays hand-written
/// is prose: what a token is for, and why it deviates. No readback produces that.
///
/// ## Colour space
///
/// Components are sRGB-encoded (gamma), not linear, matching how `Color(hex:)` builds
/// them and how the framebuffer stores them. Compositing therefore happens in that same
/// encoded space — which is what Core Animation actually does, and what
/// `EvaContrastTests` measures off real pixels — while WCAG relative luminance
/// linearises first, as SC 1.4.3 specifies.
struct EvaSpecimenColorReadback: Hashable, Sendable {

    /// sRGB-encoded red, 0…1.
    let red: Double
    /// sRGB-encoded green, 0…1.
    let green: Double
    /// sRGB-encoded blue, 0…1.
    let blue: Double
    /// Alpha, 0…1. Not premultiplied into the components above.
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ resolved: Color.Resolved) {
        self.init(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            alpha: Double(resolved.opacity)
        )
    }
}

// MARK: - Captions

extension EvaSpecimenColorReadback {

    /// `#RRGGBB`, ignoring alpha.
    var hex: String {
        func channel(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    /// Alpha as whole percent, e.g. `66`.
    var alphaPercent: Int {
        Int((alpha * 100).rounded())
    }

    /// The caption a swatch prints: `#EE93B1`, or `#FFFFFF · 66%` when translucent.
    ///
    /// The percent is only shown when there is one to show, so an opaque token does not
    /// carry a redundant `· 100%` in a 96-point-wide tile.
    var caption: String {
        alphaPercent >= 100 ? hex : "\(hex) · \(alphaPercent)%"
    }
}

// MARK: - WCAG

extension EvaSpecimenColorReadback {

    /// WCAG 2.1 relative luminance. Linearises each channel first, per SC 1.4.3.
    ///
    /// Meaningful only on an opaque colour — composite with `composited(over:)` first.
    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The opaque colour this produces when drawn over `background`.
    func composited(over background: Self) -> Self {
        func mix(_ foreground: Double, _ ground: Double) -> Double {
            foreground * alpha + ground * (1 - alpha)
        }
        return Self(
            red: mix(red, background.red),
            green: mix(green, background.green),
            blue: mix(blue, background.blue),
            alpha: 1
        )
    }

    /// A point on the straight line between two colours, interpolated in the same
    /// encoded space `LinearGradient` blends in.
    func blended(towards other: Self, amount: Double) -> Self {
        func mix(_ from: Double, _ to: Double) -> Double { from + (to - from) * amount }
        return Self(
            red: mix(red, other.red),
            green: mix(green, other.green),
            blue: mix(blue, other.blue),
            alpha: mix(alpha, other.alpha)
        )
    }

    /// WCAG 2.1 contrast ratio, `(L1 + .05) / (L2 + .05)` with `L1` the lighter.
    /// Symmetric, so the caller need not know which colour is the label.
    static func contrastRatio(_ a: Self, _ b: Self) -> Double {
        let lighter = max(a.relativeLuminance, b.relativeLuminance)
        let darker = min(a.relativeLuminance, b.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The worst ratio `label` reaches anywhere along a ramp of `stops`, every colour
    /// first composited over `ground`.
    ///
    /// The worst point of a gradient is not in general either of its stops, and #12's
    /// finding — that the primary button fails AA at its *top* stop while passing near
    /// its bottom — is exactly the kind of thing a two-endpoint check reports as fine.
    /// Sampling between them is cheap and does not need to know which way the ramp runs.
    /// A single stop degenerates to one sample, so solid fills use the same call.
    static func worstRatio(
        label: Self,
        alongRamp stops: [Self],
        over ground: Self,
        samplesPerSegment: Int = 8
    ) -> Double {
        guard let first = stops.first else { return 1 }
        let labelOnGround = label.composited(over: ground)
        var worst = Double.greatestFiniteMagnitude

        func consider(_ stop: Self) {
            worst = min(worst, contrastRatio(labelOnGround, stop.composited(over: ground)))
        }

        consider(first)
        for (from, to) in zip(stops, stops.dropFirst()) {
            for step in 1...samplesPerSegment {
                consider(from.blended(towards: to, amount: Double(step) / Double(samplesPerSegment)))
            }
        }
        return worst
    }
}

// MARK: - Reading a token

extension Color {

    /// This colour's sRGB components, resolved in the current environment.
    func evaSpecimenReadback(in environment: EnvironmentValues) -> EvaSpecimenColorReadback {
        EvaSpecimenColorReadback(resolve(in: environment))
    }
}

// MARK: - Formatting

/// Prints a design metric the way the canvas writes it: `46`, `14.5`, `.14`.
///
/// `Int(_:)` would turn 14.5 into 14 and `"\(CGFloat)"` would turn 46 into `46.0`;
/// both misrepresent the scale in a caption that exists to state it exactly.
enum EvaSpecimenNumber {

    static func string(_ value: CGFloat) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%g", Double(value))
    }

    /// `4.76:1`, the way WCAG ratios are written.
    static func ratio(_ value: Double) -> String {
        String(format: "%.2f:1", value)
    }
}

#Preview("Readback") {
    let tokens: [(String, Color)] = [
        ("evaPrimaryPink", .evaPrimaryPink),
        ("evaGlassSurface", .evaGlassSurface),
        ("evaElevatedGlass", .evaElevatedGlass),
        ("evaChipSevere", .evaChipSevere),
        ("evaInputBorderDisabled", .evaInputBorderDisabled)
    ]

    return EvaSpecimenReadbackPreview(tokens: tokens)
}

/// Preview body for the readback — a view rather than inline code so it can hold the
/// `@Environment(\.self)` the readback needs.
private struct EvaSpecimenReadbackPreview: View {
    let tokens: [(String, Color)]

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            ForEach(tokens, id: \.0) { name, color in
                HStack(spacing: EvaSpacing.sm) {
                    RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                        .fill(color)
                        .frame(width: 44, height: 28)
                    Text(name)
                        .evaTextStyle(.label)
                    Text(color.evaSpecimenReadback(in: environment).caption)
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaMutedText)
                }
            }
        }
        .padding(EvaSpacing.lg)
        .background(Color.evaWarmBackground)
    }
}
#endif

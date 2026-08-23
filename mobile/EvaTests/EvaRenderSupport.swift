import SwiftUI
import UIKit

// Helpers that look at what a control actually *drew* and how tall it actually *is*,
// rather than at the constants it was built from.
//
// Issue #2 is mostly appearance, and most of that appearance is unreachable from a
// value assertion: `EvaPrimaryButtonStyle.fill(for:)` and `ChipToggleButton.Appearance`
// are both private, so "the primary button is filled with the §5 gradient" and "a severe
// chip is solid #C95F86" cannot be asked of the type. They can be asked of the pixels.
//
// This is **not** snapshot testing. Nothing here compares whole images, nothing is
// recorded, and there is no reference to re-baseline: every expectation is a hex, an
// opacity or a height transcribed from DESIGN.md, checked at a named coordinate.
// `ImageRenderer` and `UIHostingController` are both first-party — no new dependency
// (GUARDRAILS §25).

// MARK: - Rasterising

enum EvaRenderError: Error, CustomStringConvertible {
    case renderFailed
    case contextFailed

    var description: String {
        switch self {
        case .renderFailed: "ImageRenderer produced no image"
        case .contextFailed: "could not create the sampling bitmap context"
        }
    }
}

/// A rendered view, addressable pixel by pixel.
///
/// Rendered at one pixel per point by default so a coordinate in the test is a point in
/// the layout, and with `colorMode = .nonLinear` so translucent fills composite the way
/// `evaComposite(_:over:)` predicts.
@MainActor
struct EvaRaster {
    let width: Int
    let height: Int
    /// RGBA8, row-major, no padding.
    private let pixels: [UInt8]

    /// Pixels per point. 1 for every geometry assertion, so a coordinate in the test is
    /// a point in the layout.
    let scale: CGFloat

    /// Renders `view` over an opaque `background` in a `size`-point frame.
    ///
    /// The background matters: every control state in §5/§6 that is specified as an
    /// `rgba(…)` only has a concrete colour once it is composited over something, and
    /// the test has to know what that something was. `.black` is the default because it
    /// is the furthest from every fill in the palette, so a wrong alpha moves the
    /// sampled pixel the most.
    ///
    /// `scale` stays at 1 for everything that names a coordinate. The contrast suite
    /// raises it, because there it is glyph *interiors* being sampled: at one pixel per
    /// point a 13pt stem is under two pixels wide and may never be fully covered, which
    /// would have the label read back lighter than it is.
    init(
        _ view: some View,
        size: CGSize,
        background: Color = .black,
        scale: CGFloat = 1
    ) throws {
        let renderer = ImageRenderer(
            content: ZStack {
                background
                view
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = scale
        renderer.isOpaque = true
        renderer.colorMode = .nonLinear
        self.scale = scale

        guard let cgImage = renderer.cgImage else { throw EvaRenderError.renderFailed }

        let w = cgImage.width
        let h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EvaRenderError.contextFailed }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.width = w
        self.height = h
        self.pixels = buffer
    }

    /// The pixel at `(x, y)`, origin top-left.
    func pixel(_ x: Int, _ y: Int) -> EvaRGBA {
        let i = (y * width + x) * 4
        return EvaRGBA(
            red: Double(pixels[i]) / 255,
            green: Double(pixels[i + 1]) / 255,
            blue: Double(pixels[i + 2]) / 255,
            alpha: Double(pixels[i + 3]) / 255
        )
    }

    /// The lightest and the darkest pixel inside the raster, inset by `dx`/`dy` points.
    ///
    /// This is how the contrast suite reads a control without being told what it
    /// painted. A control that puts a label on a fill draws exactly two opaque colours
    /// in its interior; every other pixel is an antialiased blend of the two, and a
    /// blend is a convex combination, so it can never be lighter than the lighter of
    /// them nor darker than the darker. The two extremes are therefore the label and
    /// the worst point of the fill — whichever way round they happen to be, which is
    /// the point: a white label on a dark fill and a dark label on a pale one are the
    /// same measurement.
    ///
    /// Inset past the border and the corner curve, or a border darker than the fill
    /// (the severe chip's) is what comes back instead of the fill.
    func luminanceExtremes(insetBy dx: Int, _ dy: Int) -> (lightest: EvaRGBA, darkest: EvaRGBA) {
        luminanceExtremes(top: dy, leading: dx, bottom: dy, trailing: dx)
    }

    /// As above, with each edge trimmed separately — for a component whose label sits
    /// outside the surface being measured, such as the input's field name above its box.
    func luminanceExtremes(
        top: Int, leading: Int, bottom: Int, trailing: Int
    ) -> (lightest: EvaRGBA, darkest: EvaRGBA) {
        func px(_ points: Int) -> Int { Int((CGFloat(points) * scale).rounded()) }
        let yRange = px(top)..<(height - px(bottom))
        let xRange = px(leading)..<(width - px(trailing))
        var lightest = pixel(xRange.lowerBound, yRange.lowerBound)
        var darkest = lightest
        for y in yRange {
            for x in xRange {
                let sample = pixel(x, y)
                if sample.relativeLuminance > lightest.relativeLuminance { lightest = sample }
                if sample.relativeLuminance < darkest.relativeLuminance { darkest = sample }
            }
        }
        return (lightest, darkest)
    }

    /// Height in points of the tallest unbroken run of rows in column `x` whose pixel
    /// is not the background.
    ///
    /// Used to measure a control's drawn band — the input's 52 (DESIGN.md §6) is a
    /// height of *fill*, which the fitting size of the whole labelled field does not
    /// expose on its own.
    func tallestNonBackgroundRun(inColumn x: Int, background: EvaRGBA, tolerance: Int = 6) -> Int {
        var best = 0
        var run = 0
        for y in 0..<height {
            if pixel(x, y).isWithin(tolerance, of: background) {
                run = 0
            } else {
                run += 1
                best = max(best, run)
            }
        }
        return best
    }

    /// Width in points of the tallest unbroken run of columns in row `y` whose pixel is
    /// not the background — the horizontal counterpart of the above, used to read a
    /// corner curve off the shape's first row.
    func tallestNonBackgroundRun(inRow y: Int, background: EvaRGBA, tolerance: Int = 6) -> Int {
        var best = 0
        var run = 0
        for x in 0..<width {
            if pixel(x, y).isWithin(tolerance, of: background) {
                run = 0
            } else {
                run += 1
                best = max(best, run)
            }
        }
        return best
    }
}

// MARK: - Comparing colours

extension EvaRGBA {
    /// Whether every channel is within `tolerance` 0–255 steps of `other`.
    ///
    /// A tolerance is unavoidable: gradients are sampled a pixel inside their end stop,
    /// and CoreGraphics rounds compositing. It is kept small enough that no two values
    /// in the §5/§6 set are within it of each other.
    func isWithin(_ tolerance: Int, of other: EvaRGBA) -> Bool {
        func close(_ a: Double, _ b: Double) -> Bool {
            abs(a - b) * 255 <= Double(tolerance) + 0.001
        }
        return close(red, other.red) && close(green, other.green) && close(blue, other.blue)
    }

    /// WCAG 2.1 relative luminance — `0.2126R + 0.7152G + 0.0722B` on linearised sRGB.
    ///
    /// Used two ways: as an ordering ("the pressed fill is darker") and, since #12, as
    /// a value, through `evaContrastRatio(_:_:)`.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// WCAG 2.1 contrast ratio, `(L1 + 0.05) / (L2 + 0.05)` with `L1` the lighter.
///
/// Symmetric, so callers need not know which of the two is the label.
func evaContrastRatio(_ a: EvaRGBA, _ b: EvaRGBA) -> Double {
    let lighter = max(a.relativeLuminance, b.relativeLuminance)
    let darker = min(a.relativeLuminance, b.relativeLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

/// The opaque colour `foreground` produces when drawn over `background`.
///
/// DESIGN.md quotes the translucent control fills as `rgba(…)`; this is the arithmetic
/// that turns one of them into the pixel a test can look for.
@MainActor
func evaComposite(_ foreground: Color, over background: Color) -> EvaRGBA {
    let f = foreground.evaTestRGBA
    let b = background.evaTestRGBA
    func mix(_ fc: Double, _ bc: Double) -> Double { fc * f.alpha + bc * (1 - f.alpha) }
    return EvaRGBA(
        red: mix(f.red, b.red),
        green: mix(f.green, b.green),
        blue: mix(f.blue, b.blue),
        alpha: 1
    )
}

// MARK: - Measuring

/// The height a view settles at when offered `width` and unlimited height.
///
/// This is the number the canvas' "min-height 52" is about — an assertion on
/// `EvaControl.height` only proves the token, not that the control wears it.
@MainActor
func evaFittingHeight(_ view: some View, width: CGFloat = 320) -> CGFloat {
    let controller = UIHostingController(rootView: view)
    controller.view.backgroundColor = .clear
    controller.view.layoutIfNeeded()
    return controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
}

/// The width a view settles at when offered unlimited space.
///
/// Paired with `evaLabelAdvance(…)` below, this is how a test reads the *type size* a
/// control gave its label. Nothing else can: `.evaTextStyle(.control)` is applied
/// inside the component, the appearance types are private, and 12pt and 13pt differ by
/// less than a rendered pixel in cap height.
@MainActor
func evaFittingWidth(_ view: some View) -> CGFloat {
    let controller = UIHostingController(rootView: view)
    controller.view.backgroundColor = .clear
    controller.view.layoutIfNeeded()
    return controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
}

/// The advance width of `repeats` copies of one glyph, as `build` lays them out.
///
/// Measured as the *difference* between a long label and a short one, so every fixed
/// cost — the control's padding, its border, a leading glyph — cancels exactly and
/// what is left is `repeats × the glyph's advance at whatever size the label was set
/// in`. Compare a control's number against the same measurement taken on a bare
/// `Text` at a candidate `EvaTextStyle` and the control's type row is identified.
@MainActor
func evaLabelAdvance<V: View>(
    repeats: Int = 10,
    _ build: (String) -> V
) -> CGFloat {
    let short = "M"
    let long = String(repeating: "M", count: repeats + 1)
    return evaFittingWidth(build(long)) - evaFittingWidth(build(short))
}

import SwiftUI

// How a predicted day is drawn, read off the `cal` screen in "Eva App.dc.html".
//
// **Dashed and patterned, never a plain fill.** The canvas states the rule in its own
// notes — *"Predicted period and fertile window use dashed outlines and patterned shading
// so predictions can never be mistaken for logged data"* — and DESIGN.md §7 carries it:
// "predictions are always dashed and patterned". A logged day is a flat wash; a predicted
// day is a stripe pattern inside a broken outline. Neither treatment is available to the
// other, which is what makes the distinction survive being printed in greyscale, being
// looked at by someone who cannot separate the two hues, and being 50pt wide.
//
// That is the reason this is not "the same wash at a lower opacity". A paler pink is
// exactly the thing a prediction must not be: it says "a bit of a period", which is a
// sentence about her body rather than about Eva's confidence.

/// A day the API predicted. Two, because the canvas draws two.
///
/// `peak` is not here: the route serves it, it is a subset of the fertile window, and the
/// canvas gives it no treatment of its own — see `EvaCyclePredictions`.
///
/// **`allCases` is the legend's order and `drawingOrder` is the grid's, and they differ.**
/// Both are the artboard's: its legend lists predicted period above the fertile window,
/// and its `mkCell` tries the fertile window *first* when a day is both.
enum EvaPredictionMark: String, Hashable, Sendable, CaseIterable {
    case period
    case fertileWindow

    /// The order a day's marks are collected in, which decides two things at once: which
    /// one wins the cell's surface (the first), and the order the cell announces them in.
    ///
    /// Fertile window first, from `mkCell`'s `else if(isFert) … else if(isPred)`.
    static let drawingOrder: [EvaPredictionMark] = [.fertileWindow, .period]

    /// The stripe ink. `rgba(233,130,165,.20)` / `rgba(205,231,157,.42)` on the artboard,
    /// which are Primary Pink and Pistachio at those alphas.
    var stripe: Color {
        switch self {
        case .period: Color.evaPrimaryPink.opacity(0.20)
        case .fertileWindow: Color.evaPistachio.opacity(0.42)
        }
    }

    /// The broken outline. `rgba(201,95,134,.55)` / `rgba(142,173,86,.6)` — Deep Pink and
    /// Deep Pistachio.
    var outline: Color {
        switch self {
        case .period: Color.evaDeepPink.opacity(0.55)
        case .fertileWindow: Color.evaDeepPistachio.opacity(0.60)
        }
    }

    /// What a day cell announces. The artboard's own `aria-label` strings, verbatim.
    ///
    /// **Each one says "Predicted".** This is the colour-blind rule made assertable rather
    /// than asserted (#206): the drawing carries the distinction in its pattern, and the
    /// label carries it in a word, so a test can hold the app to it without measuring a hue.
    var accessibilityLabel: String {
        switch self {
        case .period: "Predicted period"
        case .fertileWindow: "Predicted fertile window"
        }
    }

    /// What the legend calls it.
    ///
    /// The artboard's own legend strings — `'Predicted period (dashed)'` and
    /// `'Fertile window (predicted)'` — with the treatment added to the second, because the
    /// rest of this legend names the shape in the words and the artboard's fertile row is
    /// the one that does not. Same edit, and the same reason, as Appointment being added to
    /// the glyph rows (`EvaEventGlyph.legendLabel`).
    var legendLabel: String {
        switch self {
        case .period: "Predicted period (dashed)"
        case .fertileWindow: "Fertile window (predicted, dashed)"
        }
    }
}

// MARK: - Drawing

/// The diagonal stripes of `repeating-linear-gradient(45deg, C 0 3px, transparent 3px 7px)`.
///
/// A `Shape` rather than a `Gradient`, because SwiftUI has no repeating gradient and a
/// `LinearGradient` with repeated stops would need one stop pair per stripe at a size the
/// shape does not know. The bands run top-left to bottom-right, which is where CSS' 45°
/// gradient line puts them: the line points to the top-right, and colour bands are
/// perpendicular to it.
struct EvaPredictionStripes: Shape {

    /// Painted width of one stripe, across the bands. `0 3px`.
    var ink: CGFloat = EvaCalendarMetrics.predictionStripeInk
    /// Stripe plus gap. `3px 7px` — so 3 on, 4 off.
    var period: CGFloat = EvaCalendarMetrics.predictionStripePeriod

    func path(in rect: CGRect) -> Path {
        // Vertical bars in a space centred on the origin, then rotated. `reach` is generous
        // on purpose: after a 45° turn the bars have to cover a square of side
        // `width + height`, and a stripe pattern that stops short of a corner is a cell
        // that looks half-drawn.
        let reach = rect.width + rect.height
        var path = Path()
        var offset = -reach
        while offset < reach {
            path.addRect(CGRect(x: offset, y: -reach, width: ink, height: 2 * reach))
            offset += period
        }
        return path
            .applying(CGAffineTransform(rotationAngle: -.pi / 4))
            .applying(CGAffineTransform(translationX: rect.midX, y: rect.midY))
    }
}

/// One predicted day's surface: striped fill inside a dashed outline, in a given shape.
///
/// Shared by the day cell and the legend so the swatch is literally the cell, at 16pt
/// instead of 50 — the one property a legend has to have.
struct EvaPredictionSurface: View {

    let mark: EvaPredictionMark
    var cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            EvaPredictionStripes()
                .fill(mark.stripe)
                .clipShape(shape)
            shape.strokeBorder(
                mark.outline,
                style: StrokeStyle(
                    lineWidth: EvaCalendarMetrics.predictionOutlineWidth,
                    dash: EvaCalendarMetrics.predictionOutlineDash
                )
            )
        }
        .allowsHitTesting(false)
    }
}

#Preview("Predicted days") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        VStack(spacing: EvaSpacing.lg) {
            HStack(spacing: EvaSpacing.xs) {
                ForEach(EvaPredictionMark.allCases, id: \.self) { mark in
                    EvaPredictionSurface(mark: mark, cornerRadius: EvaCalendarMetrics.cellRadius)
                        .frame(width: 44, height: EvaCalendarMetrics.cellHeight)
                        .overlay {
                            Text(verbatim: "24")
                                .font(.evaBodyMedium)
                                .foregroundStyle(Color.evaPrimaryText)
                        }
                }
            }

            HStack(spacing: EvaSpacing.sm) {
                ForEach(EvaPredictionMark.allCases, id: \.self) { mark in
                    HStack(spacing: EvaSpacing.xs) {
                        EvaPredictionSurface(mark: mark, cornerRadius: 5)
                            .frame(width: 16, height: 16)
                        Text(mark.legendLabel)
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaSecondaryText)
                    }
                }
            }
        }
        .padding(EvaSpacing.lg)
    }
}

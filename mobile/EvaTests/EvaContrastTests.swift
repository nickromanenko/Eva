import Testing
import SwiftUI
@testable import Eva

// The test this design system did not have, and the reason this branch exists.
//
// #12 found that white on the canvas pink fails WCAG AA everywhere it carries a label —
// 2.22:1 on the primary button's top stop, against the 4.5:1 AA asks for normal text.
// Nothing in `EvaTests` could have caught that. Every suite checked that a token held
// the value the canvas states, and the canvas states an unreadable one; a transcription
// test cannot find a defect in the thing it is transcribing.
//
// So this suite does not transcribe. It renders each surface that puts a label on a
// fill, reads the two colours back out of the pixels, and computes the ratio. It has no
// opinion about which pink is correct; it only asks whether the label can be read.
//
// ## How a ratio is read off a control
//
// Two samples per control, both from the same render.
//
// **The ground** comes from a narrow vertical strip inside the control that no label
// reaches — the labels are centred or 16-point-padded, so a strip a few points in is
// pure fill for the control's whole height. Taking the strip's lightest *and* darkest
// pixel is what makes this work on a gradient: the worst point of a ramp is not either
// stop in general, and it is precisely the thing #12 found and a token comparison
// cannot see. Controls with no fill of their own — the text button, the outlined and
// row destructives — take the page as their ground, which is what they actually sit on.
//
// **The label** is whichever extreme of the control's whole interior falls outside the
// ground's own luminance band. Antialiased edge pixels are convex blends of the two
// colours, so they are always inside the band and never win. The direction does not
// have to be declared: a white label on a dark fill and a dark label on a pale one are
// found the same way.
//
// The reported ratio is then the *worst* of the label against either end of the ground,
// which for a gradient is its own lightest point under a white label.
//
// Rendered at 4 pixels per point so glyph interiors are solidly covered. At one pixel
// per point a 13pt semibold stem is under two pixels wide and may never be fully
// opaque, which would read the label back paler than it is and understate the ratio.
//
// ## The bar
//
// WCAG 2.1 SC 1.4.3 (AA): 4.5:1 for normal text, 3:1 for large text — 18pt, or 14pt
// bold. Every Eva label is 14.5pt or smaller, so every one of them is normal text and
// every bar here is 4.5. Disabled controls are exempt under 1.4.3, and are handled
// separately below.

/// One label-on-a-fill surface, and the ratio its label has to clear.
@MainActor
struct EvaContrastCase {
    let name: String
    /// The control, already sized. Rendered over `backdrop` in a raster of `size`.
    let make: () -> AnyView
    let size: CGSize
    let backdrop: Color
    /// Points trimmed off each edge before the label is looked for, to keep the border,
    /// the corner curve, the press scale and any text outside the surface out of it.
    let inset: (top: Int, leading: Int, bottom: Int, trailing: Int)
    /// A vertical strip of pure fill, in points from the raster's left edge. `nil` for a
    /// control with no fill of its own, whose ground is `backdrop`.
    let fillStrip: (leading: Int, width: Int)?
    let bar: Double

    init(
        name: String,
        size: CGSize,
        backdrop: Color,
        inset: (top: Int, leading: Int, bottom: Int, trailing: Int),
        fillStrip: (leading: Int, width: Int)?,
        bar: Double = 4.5,
        make: @escaping () -> AnyView
    ) {
        self.name = name
        self.size = size
        self.backdrop = backdrop
        self.inset = inset
        self.fillStrip = fillStrip
        self.bar = bar
        self.make = make
    }

    struct Measurement {
        let ratio: Double
        let label: EvaRGBA
        let worstGround: EvaRGBA
    }

    func measure() throws -> Measurement {
        let raster = try EvaRaster(make(), size: size, background: backdrop, scale: 4)
        let interior = raster.luminanceExtremes(
            top: inset.top, leading: inset.leading,
            bottom: inset.bottom, trailing: inset.trailing
        )
        let ground: (lightest: EvaRGBA, darkest: EvaRGBA)
        if let strip = fillStrip {
            ground = raster.luminanceExtremes(
                top: inset.top,
                leading: strip.leading,
                bottom: inset.bottom,
                trailing: Int(size.width) - strip.leading - strip.width
            )
        } else {
            ground = (backdrop.evaTestRGBA, backdrop.evaTestRGBA)
        }
        // The label is the extreme that the ground cannot account for.
        let label = interior.lightest.relativeLuminance > ground.lightest.relativeLuminance + 0.004
            ? interior.lightest
            : interior.darkest
        let againstLightest = evaContrastRatio(label, ground.lightest)
        let againstDarkest = evaContrastRatio(label, ground.darkest)
        return Measurement(
            ratio: min(againstLightest, againstDarkest),
            label: label,
            worstGround: againstLightest < againstDarkest ? ground.lightest : ground.darkest
        )
    }
}

@MainActor
enum EvaContrastSurfaces {

    /// Everything is measured over the Warm Background, which is what the app puts
    /// behind its controls (DESIGN.md §2). It matters for the unfilled variants, whose
    /// ground *is* the page.
    private static let page = Color.evaWarmBackground

    private static let button = CGSize(width: 200, height: 52)
    private static let chip = CGSize(width: 160, height: 44)

    /// 24 points in clears the radius-17 corners; 3 clears the edge antialiasing and the
    /// 3-point shrink a pressed control draws at.
    private static let buttonInset = (top: 3, leading: 24, bottom: 3, trailing: 24)
    /// Inside the corner curve at every row, and well left of a centred label.
    private static let buttonStrip = (leading: 22, width: 10)

    private static func primary(_ state: EvaButtonState) -> EvaContrastCase {
        EvaContrastCase(
            name: "Primary button · \(state)",
            size: button, backdrop: page, inset: buttonInset, fillStrip: buttonStrip
        ) {
            AnyView(
                Button("Continue") {}
                    .buttonStyle(EvaPrimaryButtonStyle(previewState: state))
                    .frame(width: button.width)
            )
        }
    }

    private static func solidDestructive(_ state: EvaButtonState) -> EvaContrastCase {
        EvaContrastCase(
            name: "Destructive · solid · \(state)",
            size: button, backdrop: page, inset: buttonInset, fillStrip: buttonStrip
        ) {
            // A short title on purpose: the fill strip is 22 points in, and a label
            // wide enough to reach it would put white pixels in the sample and the
            // ground would come back as the label.
            AnyView(
                Button("Delete") {}
                    .buttonStyle(EvaDestructiveButtonStyle(kind: .solid, previewState: state))
                    .frame(width: button.width)
            )
        }
    }

    /// The unfilled destructive shapes. Their fill is `.clear`, so the page is the
    /// ground and there is no strip to take.
    private static func unfilledDestructive(
        _ kind: EvaDestructiveButtonKind,
        _ state: EvaButtonState
    ) -> EvaContrastCase {
        EvaContrastCase(
            name: "Destructive · \(kind) · \(state)",
            size: button, backdrop: page,
            inset: (top: 6, leading: 24, bottom: 6, trailing: 24),
            fillStrip: nil
        ) {
            AnyView(
                Button("Delete my account") {}
                    .buttonStyle(EvaDestructiveButtonStyle(kind: kind, previewState: state))
                    .frame(width: button.width)
            )
        }
    }

    private static func chipCase(
        _ name: String,
        isSelected: Bool = false,
        isSevere: Bool = false,
        isDisabled: Bool = false
    ) -> EvaContrastCase {
        EvaContrastCase(
            name: "Chip · \(name)",
            size: chip, backdrop: page,
            // 3 vertically clears the 1pt border, which on the severe chip is darker
            // than the fill and would otherwise come back as the ground.
            inset: (top: 3, leading: 18, bottom: 3, trailing: 18),
            // Left of the centred label, and left of the severe chip's white bar glyph,
            // which would otherwise read as fill.
            fillStrip: (leading: 18, width: 8)
        ) {
            AnyView(
                ChipToggleButton(
                    label: "Heavy flow",
                    isSelected: isSelected,
                    isCentered: true,
                    isSevere: isSevere,
                    isDisabled: isDisabled
                ) {}
                .frame(width: chip.width)
            )
        }
    }

    /// The real `EvaInputField`, sampled over one band of it.
    ///
    /// `ImageRenderer` paints a `TextField` as a flat `#FFCC00` placeholder rather than
    /// drawing it, so the field's own text and its placeholder never reach the raster —
    /// see the note in `EvaControlRenderTests`. What *is* real here is the field's name
    /// above the box and its error message below it, so those are what these cases
    /// measure; the placeholder is covered separately, and says so.
    private static func inputBand(
        _ name: String,
        errorMessage: String? = nil,
        band: (_ total: CGFloat, _ withoutMessage: CGFloat) -> (top: Int, bottom: Int)
    ) -> EvaContrastCase {
        let width: CGFloat = 240
        func field(_ message: String?) -> some View {
            EvaInputField(
                label: "EMAIL", placeholder: "you@example.com", errorMessage: message
            ) { prompt in
                TextField("EMAIL", text: .constant(""), prompt: prompt)
            }
            .frame(width: width)
        }
        let total = evaFittingHeight(field(errorMessage), width: width)
        let withoutMessage = evaFittingHeight(field(nil), width: width)
        let edges = band(total, withoutMessage)
        return EvaContrastCase(
            name: "Input · \(name)",
            size: CGSize(width: width, height: total),
            backdrop: page,
            inset: (top: edges.top, leading: 0, bottom: edges.bottom, trailing: 0),
            fillStrip: nil
        ) {
            AnyView(field(errorMessage))
        }
    }

    /// Every enabled surface that puts a label on a ground. All must clear AA.
    static var enabled: [EvaContrastCase] {
        [
            primary(.normal),
            primary(.pressed),
            primary(.focused),
            solidDestructive(.normal),
            solidDestructive(.pressed),
            unfilledDestructive(.outlined, .normal),
            unfilledDestructive(.row, .normal),
            chipCase("default"),
            chipCase("selected", isSelected: true),
            chipCase("severe", isSelected: true, isSevere: true),
            EvaContrastCase(
                name: "Secondary glass button",
                size: button, backdrop: page, inset: buttonInset, fillStrip: buttonStrip
            ) {
                AnyView(
                    Button("Not now") {}
                        .buttonStyle(EvaSecondaryButtonStyle(previewState: .normal))
                        .frame(width: button.width)
                )
            },
            EvaContrastCase(
                name: "Text button",
                size: CGSize(width: 160, height: 48), backdrop: page,
                inset: (top: 2, leading: 2, bottom: 2, trailing: 2),
                // No surface of its own — §5 gives it no fill, so it sits on the page.
                fillStrip: nil
            ) {
                AnyView(
                    Button("Skip for now") {}
                        .buttonStyle(EvaTextButtonStyle(previewState: .normal))
                )
            },
            // The field's name, above the box.
            // The label row is the top ~15 points; anything below it is the field's own
            // fill, which is lighter than the page and would be mistaken for the ink.
            inputBand("field name") { total, _ in
                (top: 0, bottom: Int(total) - 14)
            },
            // The error message, below it. §6 pairs it with the `!` circle from §2; both
            // are `evaErrorInk`, which #16 moved from `#C4645A` to `#A9524A`.
            inputBand("error message", errorMessage: "Check that address.") { total, without in
                (top: Int(without) + 2, bottom: 0)
            },
            // Synthetic, and the only case here that is: `ImageRenderer` will not draw a
            // `TextField`, so the placeholder cannot be measured on the real control.
            // The ink and the fill are the component's own tokens, composited the way
            // the component composites them.
            EvaContrastCase(
                name: "Input · placeholder ink on the field fill (synthetic)",
                size: CGSize(width: 200, height: 40), backdrop: page,
                inset: (top: 2, leading: 2, bottom: 2, trailing: 2),
                fillStrip: (leading: 2, width: 8)
            ) {
                // `Text(verbatim:)`: a string *literal* goes through SwiftUI's Markdown
                // parser, which turns an address into a link and renders it in the
                // accent blue. The component itself is safe — its placeholder arrives as
                // a variable — but a literal here would measure the wrong ink.
                // Must match `EvaInputField.prompt(_:)`, which uses Secondary Text.
                // Muted Text was the *rejected* option — it measures 3.07:1 on this
                // fill, which is why DESIGN.md §9a records the swap. Mocking the
                // rejected colour here made this case assert the wrong thing.
                AnyView(
                    Text(verbatim: "you@example.com")
                        .font(.evaBody)
                        .foregroundStyle(Color.evaSecondaryText)
                        .frame(width: 170, height: 40, alignment: .trailing)
                        .padding(.leading, 30)
                        .background(Color.evaInputFill)
                )
            }
        ]
    }

    /// The two disabled labels #12 and #17 deliberately changed. WCAG 1.4.3 exempts
    /// inactive controls, so these are held to the AA bar by the project's own decision
    /// rather than by the guideline: the sign-up CTA sits disabled until the form
    /// validates, which makes it the first thing a new user reads.
    static var deliberatelyFixedDisabled: [EvaContrastCase] {
        [primary(.disabled), solidDestructive(.disabled)]
    }

    /// Disabled states nobody has ruled on. Exempt under 1.4.3, and measured here so the
    /// numbers are on the record rather than in a comment.
    static var unruledDisabled: [EvaContrastCase] {
        [
            chipCase("disabled", isDisabled: true),
            unfilledDestructive(.outlined, .disabled),
            unfilledDestructive(.row, .disabled)
        ]
    }
}

@MainActor
@Suite("WCAG AA contrast, measured on what each control draws")
struct EvaContrastTests {

    /// Checked one surface at a time so a failure names the surface, both colours and
    /// the ratio. `arguments:` is not used because these cases are main-actor bound —
    /// they build real views — and the parameterised form wants its arguments outside
    /// that isolation.
    private func check(
        _ surfaces: [EvaContrastCase],
        _ verdict: (EvaContrastCase, Double) -> (ok: Bool, message: String)
    ) throws {
        for surface in surfaces {
            let measured = try surface.measure()
            let outcome = verdict(surface, measured.ratio)
            #expect(
                outcome.ok,
                "\(surface.name): \(measured.label.hexString) on \(measured.worstGround.hexString) measures \(String(format: "%.2f", measured.ratio)):1 — \(outcome.message)"
            )
        }
    }

    @Test("Every enabled label clears 4.5:1 against the ground it sits on")
    func enabledLabelsClearAA() throws {
        try check(EvaContrastSurfaces.enabled) { surface, ratio in
            (ratio >= surface.bar, "needs \(surface.bar):1")
        }
    }

    @Test("The disabled labels #12 and #17 fixed are still fixed")
    func fixedDisabledLabelsStayFixed() throws {
        // §5 specifies a white label on both of these fills. White measures 1.45:1 on
        // the primary's `rgba(201,95,134,.28)` and 2.10:1 on the solid destructive's
        // halved `#B85248`; both use Primary Text instead. Reverting either — by
        // "restoring the canvas value", which is exactly how it would be described —
        // fails here.
        try check(EvaContrastSurfaces.deliberatelyFixedDisabled) { surface, ratio in
            (ratio >= surface.bar, "the deliberate fix has been undone")
        }
    }

    @Test("The remaining disabled labels are unreadable, and nobody has ruled on that")
    func theRemainingDisabledLabelsAreOnTheRecord() throws {
        // Not an assertion that this is right. WCAG 1.4.3 exempts inactive controls, so
        // these are not failures — but the project decided twice, on the primary and on
        // the solid destructive, that a disabled label a user has to read should be
        // readable, and then left `evaDisabledText` on three more controls at under 2:1.
        // Either that decision generalises or it does not; nobody has said which.
        //
        // Pinned at the state of affairs rather than at a bar, so fixing one of these
        // fails here and forces the note to be updated instead of leaving a stale
        // comment behind.
        try check(EvaContrastSurfaces.unruledDisabled) { _, ratio in
            (ratio < 4.5, "it was fixed — move it into `deliberatelyFixedDisabled` and say so on #12")
        }
    }

    @Test("The measurement can actually fail")
    func theMeasurementIsSensitive() throws {
        // A contrast test that returns a comfortable number for everything is worse than
        // no contrast test. This is the control: the canvas ramp this branch replaced,
        // measured the same way, has to come back below the bar — 2.22:1 at its top
        // stop, which is the defect #12 found and the reason the branch exists.
        let probe = EvaContrastCase(
            name: "The canvas primary ramp under a white label",
            size: CGSize(width: 200, height: 52),
            backdrop: .evaWarmBackground,
            inset: (top: 2, leading: 2, bottom: 2, trailing: 2),
            fillStrip: (leading: 4, width: 10)
        ) {
            AnyView(
                ZStack {
                    Rectangle().fill(LinearGradient.evaPrimaryButton)
                    Text("Continue").evaTextStyle(.button).foregroundStyle(Color.evaTextOnDark)
                }
            )
        }
        let measured = try probe.measure()
        #expect(measured.ratio < 4.5,
                "white on the canvas primary ramp measured \(String(format: "%.2f", measured.ratio)):1 — the harness is not finding the worst point of the fill")
        #expect(abs(measured.ratio - 2.22) < 0.15,
                "expected #12's 2.22:1 at the ramp's top stop, measured \(String(format: "%.2f", measured.ratio)):1 against \(measured.worstGround.hexString)")
    }
}

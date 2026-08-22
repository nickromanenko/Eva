import Testing
import SwiftUI
@testable import Eva

/// Issue #2 acceptance, checked against what the controls actually draw:
/// "Primary button: … `linear-gradient(180°, #EE93B1→#C95F86)` … pressed (scale .97,
/// darker), focused ring, disabled fill", "Chips: … four states", "Inputs: 52 high …
/// focus ring".
///
/// The token suites prove the values exist and are right. They cannot prove a control
/// uses them — `EvaPrimaryButtonStyle.fill(for:)` and `ChipToggleButton.Appearance` are
/// both private, so a style that silently painted `Color.red` would pass every other
/// test in this bundle. These read the pixels back.
///
/// See `EvaRenderSupport.swift` for why this is not snapshot testing: no reference
/// images, nothing recorded, every expectation a hex from DESIGN.md at a named point.
@MainActor
@Suite("DESIGN.md §5/§6 controls as rendered")
struct EvaControlRenderTests {

    /// Sampling tolerance in 0–255 steps. Covers gradient interpolation a pixel inside
    /// the end stop and CoreGraphics' compositing rounding; far tighter than the gap
    /// between any two values in the §5/§6 set.
    private static let tolerance = 6

    // MARK: The gradients themselves

    @Test("The primary fill is #EE93B1 at the top and #C95F86 at the bottom")
    func primaryGradientIsVerticalAndCorrect() throws {
        // §5: `linear-gradient(180deg,#EE93B1,#C95F86)`. 180° in CSS is top-to-bottom,
        // which is the half of the spec a stop-only assertion cannot see.
        let raster = try EvaRaster(
            Rectangle().fill(LinearGradient.evaPrimaryButton),
            size: CGSize(width: 8, height: 100)
        )
        #expect(raster.pixel(4, 0).isWithin(Self.tolerance, of: Color(hex: 0xEE93B1).evaTestRGBA),
                "gradient top is \(raster.pixel(4, 0).hexString), expected #EE93B1")
        #expect(raster.pixel(4, 99).isWithin(Self.tolerance, of: Color(hex: 0xC95F86).evaTestRGBA),
                "gradient bottom is \(raster.pixel(4, 99).hexString), expected #C95F86")
    }

    @Test("The pressed primary fill is #D9799C at the top and #B45276 at the bottom")
    func pressedGradientIsVerticalAndCorrect() throws {
        // §5: "Primary · pressed | Darker (#D9799C→#B45276)".
        let raster = try EvaRaster(
            Rectangle().fill(LinearGradient.evaPrimaryButtonPressed),
            size: CGSize(width: 8, height: 100)
        )
        #expect(raster.pixel(4, 0).isWithin(Self.tolerance, of: Color(hex: 0xD9799C).evaTestRGBA),
                "pressed gradient top is \(raster.pixel(4, 0).hexString), expected #D9799C")
        #expect(raster.pixel(4, 99).isWithin(Self.tolerance, of: Color(hex: 0xB45276).evaTestRGBA),
                "pressed gradient bottom is \(raster.pixel(4, 99).hexString), expected #B45276")
    }

    @Test("The selected-chip fill runs light to dark down the chip")
    func chipGradientIsVertical() throws {
        // §6 asks for a "selected pink gradient" without stops, so only the direction
        // and the fact that it *is* a gradient can be asserted from the document.
        let raster = try EvaRaster(
            Rectangle().fill(LinearGradient.evaChipSelected),
            size: CGSize(width: 8, height: 100)
        )
        let top = raster.pixel(4, 0)
        let bottom = raster.pixel(4, 99)
        #expect(top.relativeLuminance > bottom.relativeLuminance,
                "selected chip gradient is \(top.hexString) → \(bottom.hexString)")
    }

    // MARK: The primary button

    /// 200 × 52 with no margin, so the button fills the raster and a coordinate needs
    /// no arithmetic. x = 60 is well inside the radius-17 corner and well clear of the
    /// centred label.
    private func primaryRaster(_ style: EvaPrimaryButtonStyle, background: Color = .black) throws
        -> EvaRaster {
        try EvaRaster(
            Button("Continue") {}.buttonStyle(style).frame(width: 200),
            size: CGSize(width: 200, height: 52),
            background: background
        )
    }

    @Test("The primary button paints the action ramp, top to bottom")
    func primaryButtonUsesTheActionRamp() throws {
        // **Not the §5 gradient.** #12 (1b): white on the canvas ramp measures 2.22:1 at
        // its top stop, and no arrangement of that ramp with a white label clears AA, so
        // the button takes `LinearGradient.evaActionPink` — `#B45276`→`#96486A`. The
        // canvas ramp is still a token and still correct for washes; what this asserts
        // is that the *button* no longer reaches for it. See `EvaContrastTests` for the
        // measurement that justifies the swap.
        let raster = try primaryRaster(EvaPrimaryButtonStyle(previewState: .normal))
        #expect(raster.pixel(60, 1).isWithin(Self.tolerance, of: Color(hex: 0xB45276).evaTestRGBA),
                "button top is \(raster.pixel(60, 1).hexString), expected #B45276")
        #expect(raster.pixel(60, 50).isWithin(Self.tolerance, of: Color(hex: 0x96486A).evaTestRGBA),
                "button bottom is \(raster.pixel(60, 50).hexString), expected #96486A")
        // The canvas pink must not be what got painted — the failure mode this whole
        // branch exists to prevent, stated directly.
        #expect(!raster.pixel(60, 1).isWithin(Self.tolerance, of: Color(hex: 0xEE93B1).evaTestRGBA),
                "the primary button is still painting the canvas pink")
    }

    @Test("The pressed primary button paints the darker action ramp")
    func pressedPrimaryButtonUsesThePressedActionRamp() throws {
        // #12's pressed ramp, `#994664`→`#803D5A`, not §5's `#D9799C`→`#B45276`.
        let raster = try primaryRaster(EvaPrimaryButtonStyle(previewState: .pressed))
        #expect(raster.pixel(60, 1).isWithin(Self.tolerance, of: Color(hex: 0x994664).evaTestRGBA),
                "pressed button top is \(raster.pixel(60, 1).hexString), expected #994664")
        #expect(raster.pixel(60, 50).isWithin(Self.tolerance, of: Color(hex: 0x803D5A).evaTestRGBA),
                "pressed button bottom is \(raster.pixel(60, 50).hexString), expected #803D5A")
    }

    @Test("The pressed primary is visibly darker than the resting one, as drawn")
    func pressedPrimaryReadsAsAPress() throws {
        // The token suite compares the two ramps; this compares the two buttons. A press
        // whose fill change is imperceptible — the state the solid destructive is in —
        // leaves the 0.97 scale doing all the work, and that is a finding, not a design.
        let resting = try primaryRaster(EvaPrimaryButtonStyle(previewState: .normal))
        let pressed = try primaryRaster(EvaPrimaryButtonStyle(previewState: .pressed))
        let ratio = evaContrastRatio(resting.pixel(60, 26), pressed.pixel(60, 26))
        #expect(ratio > 1.2, "resting \(resting.pixel(60, 26).hexString) and pressed \(pressed.pixel(60, 26).hexString) differ by only \(ratio):1")
    }

    @Test("The disabled primary button paints Deep Pink at 28%")
    func disabledPrimaryButtonUsesTheDisabledFill() throws {
        // §5: "rgba(201,95,134,.28) fill". Rendered over the canvas' own warm
        // background, which is what it will sit on.
        let background = Color.evaWarmBackground
        let raster = try primaryRaster(
            EvaPrimaryButtonStyle(previewState: .disabled),
            background: background
        )
        let expected = evaComposite(.evaPrimaryButtonDisabled, over: background)
        for y in [1, 26, 50] {
            #expect(raster.pixel(60, y).isWithin(Self.tolerance, of: expected),
                    "disabled fill at y=\(y) is \(raster.pixel(60, y).hexString), expected \(expected.hexString)")
        }
    }

    @Test("The disabled primary button's label is Primary Text, not white")
    func disabledPrimaryLabelIsReadable() throws {
        // #12 (1a), applied by #17. §5 says `color:#fff` on the 28% fill, which measures
        // 1.45:1 over the warm background — the canvas asking for something invisible,
        // on the first control a new user meets, because the sign-up CTA sits disabled
        // until the form validates.
        //
        // The label colour is decided in a private `label(for:)`, so this reads it off
        // the pixels: the darkest thing inside a disabled button has to be the ink.
        let background = Color.evaWarmBackground
        let raster = try primaryRaster(
            EvaPrimaryButtonStyle(previewState: .disabled),
            background: background
        )
        let darkest = raster.luminanceExtremes(insetBy: 24, 3).darkest
        #expect(darkest.isWithin(Self.tolerance, of: Color.evaPrimaryText.evaTestRGBA),
                "the darkest ink in the disabled button is \(darkest.hexString), expected #282126")
        // …and white is not in there at all: the fill composites to about #F0CED7, so
        // anything at or near #FFFFFF would be a white label still being drawn.
        let lightest = raster.luminanceExtremes(insetBy: 24, 3).lightest
        #expect(!lightest.isWithin(Self.tolerance, of: Color.white.evaTestRGBA),
                "the disabled button still has a white label on it")
    }

    @Test("A genuinely disabled primary button reaches the same disabled fill")
    func actuallyDisabledPrimaryButtonUsesTheDisabledFill() throws {
        // The test above forces the state; this one is the path a screen takes —
        // `.disabled(true)` in the environment, resolved through `\.isEnabled`. They can
        // diverge: `previewState` bypasses the resolver entirely.
        let background = Color.evaWarmBackground
        let raster = try EvaRaster(
            Button("Continue") {}
                .buttonStyle(EvaPrimaryButtonStyle())
                .disabled(true)
                .frame(width: 200),
            size: CGSize(width: 200, height: 52),
            background: background
        )
        let expected = evaComposite(.evaPrimaryButtonDisabled, over: background)
        #expect(raster.pixel(60, 26).isWithin(Self.tolerance, of: expected),
                "disabled fill is \(raster.pixel(60, 26).hexString), expected \(expected.hexString)")
    }

    @Test("A loading primary button keeps the enabled fill")
    func loadingPrimaryButtonStaysEnabledLooking() throws {
        // `PrimaryButton` disables itself while a request is in flight so it cannot be
        // double-tapped. The canvas has no loading state, and the style deliberately
        // keeps the enabled gradient — a spinner on the 28% disabled fill would say
        // "nothing is happening" when something is. Deliberate deviations need a test
        // more than transcriptions do, because nothing else records them.
        let background = Color.evaWarmBackground
        let raster = try EvaRaster(
            PrimaryButton(title: "Continue", isLoading: true) {}.frame(width: 200),
            size: CGSize(width: 200, height: 52),
            background: background
        )
        let disabled = evaComposite(.evaPrimaryButtonDisabled, over: background)
        #expect(!raster.pixel(30, 26).isWithin(Self.tolerance, of: disabled),
                "the loading button is wearing the disabled fill")
        #expect(raster.pixel(30, 1).isWithin(Self.tolerance, of: Color(hex: 0xB45276).evaTestRGBA),
                "loading button top is \(raster.pixel(30, 1).hexString), expected #B45276")
    }

    @Test("The focused primary button draws a 3pt ring outside its edge")
    func focusedPrimaryButtonDrawsTheRing() throws {
        // §5: "Primary · focused | 3px rgba(40,33,38,.6) ring". Drawn *outside* the
        // control, so focus never reflows the layout — which is why the ring is looked
        // for in the margin rather than on the button.
        //
        // The margin is not plain background: the button's `0 12px 26px` pink shadow
        // reaches into it. So the two renders are compared against each other instead —
        // the shadow is identical in both, and the ring has to be exactly the §5 colour
        // laid over whatever the unfocused button already put there.
        let background = Color.evaWarmBackground
        let size = CGSize(width: 240, height: 92)
        func raster(_ state: EvaButtonState) throws -> EvaRaster {
            try EvaRaster(
                Button("Continue") {}
                    .buttonStyle(EvaPrimaryButtonStyle(previewState: state))
                    .frame(width: 200),
                size: size,
                background: background
            )
        }
        let focused = try raster(.focused)
        let normal = try raster(.normal)

        // The button is centred: 200 × 52 in 240 × 92 puts its left edge at x = 20 and
        // its vertical centre at y = 46. The ring occupies x = 17...19.
        for x in [17, 18, 19] {
            let under = normal.pixel(x, 46)
            let expected = evaComposite(.evaFocusRing, over: Color(
                red: under.red, green: under.green, blue: under.blue
            ))
            #expect(focused.pixel(x, 46).isWithin(Self.tolerance, of: expected),
                    "ring pixel at x=\(x) is \(focused.pixel(x, 46).hexString), expected \(expected.hexString)")
        }
        // …and stops there: 4 points out is untouched.
        #expect(focused.pixel(16, 46).isWithin(Self.tolerance, of: normal.pixel(16, 46)),
                "the ring is wider than 3 points — x=16 differs between the two states")
        #expect(!focused.pixel(18, 46).isWithin(Self.tolerance, of: normal.pixel(18, 46)),
                "an unfocused and a focused button drew the same thing at the ring's position")
    }

    @Test("Pressing scales the control to .97 of its width without changing its layout")
    func pressShrinksTheDrawnControl() throws {
        // §5: "scale .97". Measured on the solid destructive because it is the one
        // variant with a flat fill and no drop shadow, so the drawn edge is the
        // control's edge; every Eva button style applies the same
        // `EvaButtonPress.scale`.
        let size = CGSize(width: 240, height: 92)
        func drawnWidth(_ state: EvaButtonState) throws -> Int {
            let raster = try EvaRaster(
                Button("Delete") {}
                    .buttonStyle(EvaDestructiveButtonStyle(kind: .solid, previewState: state))
                    .frame(width: 200),
                size: size,
                background: .black
            )
            // Black, not the warm background: the label is white, and white against
            // `#FFF9F6` is inside the sampling tolerance, so the band would read as
            // broken where the letters are.
            return raster.tallestNonBackgroundRun(
                inRow: 46, background: Color.black.evaTestRGBA
            )
        }
        let resting = try drawnWidth(.normal)
        let pressed = try drawnWidth(.pressed)
        #expect(abs(resting - 200) <= 1, "the resting control drew \(resting) points wide")
        // 200 × .97 = 194.
        #expect(abs(pressed - 194) <= 1,
                "the pressed control drew \(pressed) points wide, expected 194")
        // The layout must not move: the press is a draw-time effect only.
        #expect(evaFittingHeight(
            Button("Delete") {}
                .buttonStyle(EvaDestructiveButtonStyle(kind: .solid, previewState: .pressed))
        ) == 52)
    }

    // MARK: Chips

    /// 160 × 44, centred label, so x = 20 is inside the fill and clear of the text.
    private func chipRaster(
        isSelected: Bool = false,
        isSevere: Bool = false,
        isDisabled: Bool = false,
        background: Color = .black
    ) throws -> EvaRaster {
        try EvaRaster(
            ChipToggleButton(
                label: "A",
                isSelected: isSelected,
                isCentered: true,
                isSevere: isSevere,
                isDisabled: isDisabled
            ) {}
            .frame(width: 160),
            size: CGSize(width: 160, height: 44),
            background: background
        )
    }

    @Test("The default chip paints the glass fill")
    func defaultChipFill() throws {
        let background = Color.black
        let raster = try chipRaster(background: background)
        let expected = evaComposite(.evaChipFill, over: background)
        #expect(raster.pixel(20, 22).isWithin(Self.tolerance, of: expected),
                "default chip is \(raster.pixel(20, 22).hexString), expected \(expected.hexString)")
    }

    @Test("The severe chip is solid #7E3B58 and carries its bar glyph")
    func severeChipFillAndGlyph() throws {
        // §6 draws severe as solid `#C95F86`; it is `evaChipSevere` `#7E3B58` since #12,
        // because white on `#C95F86` is 3.84:1 and the approved ramp's `#A94A6C` would
        // have collided with the selected chip. The glyph is the non-colour half of the
        // cue §1 requires, so its absence is a guardrail failure and not a cosmetic one
        // — it is looked for as white pixels on the field.
        let raster = try chipRaster(isSelected: true, isSevere: true)
        #expect(raster.pixel(20, 22).isWithin(Self.tolerance, of: Color.evaChipSevere.evaTestRGBA),
                "severe chip is \(raster.pixel(20, 22).hexString), expected #7E3B58")

        var sawWhite = false
        for x in 0..<raster.width where raster.pixel(x, 22).isWithin(8, of: Color.white.evaTestRGBA) {
            sawWhite = true
        }
        #expect(sawWhite, "the severe chip drew no white glyph or label on its centre line")
    }

    @Test("The severe chip's bar glyph is 9 × 2, not the 10 × 2 it was drawn at")
    func severeChipGlyphIsNineByTwo() throws {
        // #16: the artboard gives `9×2px, radius 1`; 10 × 2 was sized by eye. One point,
        // and the only way to see it is to count the pixels — which is also the only way
        // to notice if the glyph quietly stops being drawn.
        //
        // Measured on a leading-aligned chip so the glyph is the first thing in the row
        // and nothing else white sits on the centre line before the label: the run is
        // read from the left edge inwards, and stops at the first gap.
        let raster = try EvaRaster(
            ChipToggleButton(label: "A", isSelected: true, isSevere: true) {}.frame(width: 160),
            size: CGSize(width: 160, height: 44)
        )
        let centre = 22
        var runs: [(start: Int, length: Int)] = []
        var run = 0
        for x in 0..<raster.width {
            if raster.pixel(x, centre).isWithin(10, of: Color.white.evaTestRGBA) {
                run += 1
            } else {
                if run > 0 { runs.append((x - run, run)) }
                run = 0
            }
        }
        if run > 0 { runs.append((raster.width - run, run)) }
        let glyph = try #require(runs.first, "no white run on the severe chip's centre line")
        #expect(abs(glyph.length - 9) <= 1,
                "the bar glyph drew \(glyph.length) points wide, expected 9")

        // Its height, read down the middle of that run.
        var tall = 0
        for y in 0..<raster.height
        where raster.pixel(glyph.start + glyph.length / 2, y).isWithin(10, of: Color.white.evaTestRGBA) {
            tall += 1
        }
        #expect(abs(tall - 2) <= 1, "the bar glyph drew \(tall) points tall, expected 2")
    }

    @Test("Severe and selected are different colours everywhere down the chip")
    func severeAndSelectedChipsAreNotTheSameColourAnywhere() throws {
        // The reason severe is `#7E3B58` and not the ramp's `#A94A6C`: at `#A94A6C` it
        // sat four channel-units from the selected gradient's midpoint, so the two
        // states were the same chip with a bar on it.
        //
        // Selected is a gradient, so "different" has to hold against every row of it,
        // not against one sample — a flat fill can match a gradient at exactly one
        // height and be obviously different everywhere else.
        let severe = try chipRaster(isSelected: true, isSevere: true)
        let selected = try chipRaster(isSelected: true)
        var worst = Double.greatestFiniteMagnitude
        var worstY = 0
        for y in 4..<40 {
            let distance = max(
                abs(severe.pixel(20, y).red - selected.pixel(20, y).red),
                abs(severe.pixel(20, y).green - selected.pixel(20, y).green),
                abs(severe.pixel(20, y).blue - selected.pixel(20, y).blue)
            ) * 255
            if distance < worst { worst = distance; worstY = y }
        }
        #expect(worst >= 16,
                "at y=\(worstY) severe \(severe.pixel(20, worstY).hexString) and selected \(selected.pixel(20, worstY).hexString) are \(Int(worst)) channel-units apart")
    }

    @Test("The selected chip paints the action ramp, not the canvas chip gradient")
    func selectedChipFill() throws {
        // #12: the selected chip carries a white label, so it moves to the action ramp
        // with the primary button. `LinearGradient.evaChipSelected` is still a token —
        // it is the canvas value and it is still right for anything decorative — but the
        // chip must not be using it, because its `#EE93B1` top stop is 2.22:1.
        let raster = try chipRaster(isSelected: true)
        let top = raster.pixel(20, 2)
        let bottom = raster.pixel(20, 41)
        #expect(top.isWithin(Self.tolerance, of: Color.evaActionPinkTop.evaTestRGBA),
                "selected chip top is \(top.hexString), expected #B45276")
        #expect(bottom.isWithin(Self.tolerance, of: Color.evaActionPinkBottom.evaTestRGBA),
                "selected chip bottom is \(bottom.hexString), expected #96486A")
        #expect(top.relativeLuminance > bottom.relativeLuminance)
        #expect(!top.isWithin(Self.tolerance, of: Color.evaChipSelectedTop.evaTestRGBA),
                "the selected chip is still painting the canvas #EE93B1")
    }

    @Test("The disabled chip paints the muted neutral")
    func disabledChipFill() throws {
        // §6 asks for a "disabled muted" chip without giving a value, so the hue is the
        // checkable part: it must be Secondary Background `#F8F3F0` and not, say, a
        // desaturated pink.
        //
        // The *opacity* is deliberately not asserted. `ChipToggleButton` is a
        // `.plain`-styled `Button` with `.disabled(true)`, and SwiftUI's plain style
        // dims a disabled button on top of whatever the label already drew — the token
        // says 80%, the chip renders at 40%. That is reported as a finding rather than
        // pinned here, because the canvas gives no number to call it wrong against.
        let (hue, alpha) = try chipDisabledFillSolvedFromTwoBackgrounds()
        #expect(hue.isWithin(Self.tolerance, of: Color(hex: 0xF8F3F0).evaTestRGBA),
                "disabled chip hue is \(hue.hexString), expected #F8F3F0 (rendered at \(alpha) alpha)")
    }

    /// Recovers a translucent fill's colour and its *rendered* opacity by drawing it
    /// twice, on black and on white, and solving the two compositing equations.
    private func chipDisabledFillSolvedFromTwoBackgrounds() throws -> (EvaRGBA, Double) {
        let onBlack = try chipRaster(isDisabled: true, background: .black).pixel(20, 22)
        let onWhite = try chipRaster(isDisabled: true, background: .white).pixel(20, 22)
        // onWhite − onBlack = 1 − alpha, per channel.
        let alpha = 1 - (
            (onWhite.red - onBlack.red)
            + (onWhite.green - onBlack.green)
            + (onWhite.blue - onBlack.blue)
        ) / 3
        guard alpha > 0.01 else { return (onBlack, alpha) }
        return (
            EvaRGBA(
                red: onBlack.red / alpha,
                green: onBlack.green / alpha,
                blue: onBlack.blue / alpha,
                alpha: 1
            ),
            (alpha * 100).rounded() / 100
        )
    }

    @Test("The four chip states are four different fills on screen")
    func chipStatesAreVisiblyDistinct() throws {
        // The token suite proves the four colours differ. This proves the component
        // actually reaches all four — a broken `appearance` that collapsed severe onto
        // selected would leave every token correct.
        let samples: [(String, EvaRGBA)] = [
            ("default", try chipRaster().pixel(20, 22)),
            ("selected", try chipRaster(isSelected: true).pixel(20, 22)),
            ("severe", try chipRaster(isSelected: true, isSevere: true).pixel(20, 22)),
            ("disabled", try chipRaster(isDisabled: true).pixel(20, 22))
        ]
        for i in samples.indices {
            for j in samples.indices where j > i {
                #expect(
                    !samples[i].1.isWithin(Self.tolerance, of: samples[j].1),
                    "the \(samples[i].0) and \(samples[j].0) chips render the same: \(samples[i].1.hexString)"
                )
            }
        }
    }

    @Test("The chip's corners are the radius-14 curve, not the radius-17 one")
    func chipCornerRadius() throws {
        // §6 gives chips radius 14 while §5 gives every other control 17. Three points
        // is a small difference in a token diff and an invisible one in a screenshot,
        // so it is measured: on the topmost row a rounded rectangle is inset by its
        // corner curve, and the inset is a function of the radius.
        let chip = try chipRaster()
        let filled = chip.tallestNonBackgroundRun(inRow: 0, background: Color.black.evaTestRGBA)

        func reference(_ radius: CGFloat) throws -> Int {
            try EvaRaster(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 160, height: 44),
                size: CGSize(width: 160, height: 44)
            ).tallestNonBackgroundRun(inRow: 0, background: Color.black.evaTestRGBA)
        }

        let atFourteen = try reference(14)
        let atSeventeen = try reference(17)
        #expect(atFourteen != atSeventeen, "the two reference radii are indistinguishable here")
        #expect(abs(filled - atFourteen) <= 1,
                "the chip's top row is \(filled) wide; radius 14 gives \(atFourteen), radius 17 gives \(atSeventeen)")
    }

    // MARK: Inputs

    /// The input's own band, measured down the middle of the field where neither the
    /// label (leading, above) nor the placeholder (leading, inside) reaches.
    private func inputBandHeight(
        isFocused: Bool = false,
        errorMessage: String? = nil
    ) throws -> Int {
        let field = EvaInputField(
            label: "E",
            placeholder: "x",
            isFocused: isFocused,
            errorMessage: errorMessage
        ) { prompt in
            TextField("E", text: .constant(""), prompt: prompt)
        }
        .frame(width: 200)

        let height = evaFittingHeight(field, width: 200)
        let raster = try EvaRaster(
            field,
            size: CGSize(width: 240, height: height + 40),
            background: .black
        )
        return raster.tallestNonBackgroundRun(inColumn: 120, background: Color.black.evaTestRGBA)
    }

    @Test("The input's field is 52 points tall")
    func inputIsFiftyTwoHigh() throws {
        // §6: "Input: height 52". The labelled component is taller than that, so the
        // number lives in the band the component draws rather than in its fitting size.
        #expect(try inputBandHeight() == 52)
    }

    @Test("Focus adds exactly 3 points of ring on each side and nothing to the layout")
    func inputFocusRingIsThreePointsAndFree() throws {
        // §6: "Focused: border #C95F86 + 3px … ring", drawn outside the field like a
        // CSS `box-shadow: 0 0 0 3px`, so the form must not reflow when a field is
        // tapped.
        #expect(try inputBandHeight(isFocused: true) == 58)

        func fittingHeight(isFocused: Bool) -> CGFloat {
            evaFittingHeight(
                EvaInputField(label: "E", placeholder: "x", isFocused: isFocused) { prompt in
                    TextField("E", text: .constant(""), prompt: prompt)
                },
                width: 200
            )
        }
        #expect(fittingHeight(isFocused: false) == fittingHeight(isFocused: true))
    }

    @Test("An error draws its own ring and adds a message row below the field")
    func inputErrorAddsAMessageRow() throws {
        // §6: "Error: border #C4645A + 3px ring + icon-and-message below."
        #expect(try inputBandHeight(errorMessage: "Check that address.") == 58)

        func fittingHeight(_ errorMessage: String?) -> CGFloat {
            evaFittingHeight(
                EvaInputField(
                    label: "E",
                    placeholder: "x",
                    errorMessage: errorMessage,
                    errorIdentifier: "preview.error"
                ) { prompt in
                    TextField("E", text: .constant(""), prompt: prompt)
                },
                width: 200
            )
        }
        let clean = fittingHeight(nil)
        let wrong = fittingHeight("Check that address.")
        #expect(wrong > clean,
                "the error message added \(wrong - clean) points — it is not being drawn")
    }

    @Test("An unfocused, error-free input draws no ring")
    func restingInputHasNoRing() throws {
        // The ring is one view that changes colour rather than two that swap, so
        // "`.clear` when resting" is the thing that keeps a permanent pink halo off
        // every field.
        #expect(try inputBandHeight() == 52)
    }

    // MARK: Input details the transcription lost (#16)

    // `ImageRenderer` cannot draw a `TextField`: it paints the control's frame as a flat
    // `#FFCC00` placeholder instead. That is a limitation and also a lever — the yellow
    // box is exactly the field's content frame, so its left edge *is* the horizontal
    // padding, measured with no glyph metrics in the way. What it costs is the
    // placeholder itself, which never reaches the raster; the placeholder's contrast is
    // measured in `EvaContrastTests` on the ink and the fill separately, and says so.

    /// The input at 4 pixels per point, with the row down the middle of the field band.
    ///
    /// Everything below is a sub-point measurement — 15 against 16 points of padding, a
    /// 7% border against a 10% one — so it is rendered up rather than sampled at one
    /// pixel per point and rounded into agreement.
    @MainActor
    private struct InputProbe {
        let raster: EvaRaster
        let fieldCentre: Int
        let scale: CGFloat

        /// The pixel `points` in from the field's left edge, on its centre line.
        func sample(at points: CGFloat) -> EvaRGBA {
            raster.pixel(Int(points * scale), fieldCentre)
        }
    }

    private func inputProbe(
        isFocused: Bool = false,
        errorMessage: String? = nil,
        isEnabled: Bool = true,
        background: Color = .black,
        scale: CGFloat = 4
    ) throws -> InputProbe {
        let width: CGFloat = 240
        func field(_ message: String?) -> some View {
            EvaInputField(
                label: "E", placeholder: "x", isFocused: isFocused, errorMessage: message
            ) { prompt in
                TextField("E", text: .constant(""), prompt: prompt)
            }
            .disabled(!isEnabled)
            .frame(width: width)
        }
        let height = evaFittingHeight(field(errorMessage), width: width)
        let raster = try EvaRaster(
            field(errorMessage),
            size: CGSize(width: width, height: height),
            background: background,
            scale: scale
        )
        // The layout is label · spacing · field(52) · [spacing · message]. Without a
        // message the field band is flush with the bottom, so measuring the same field
        // without one gives the band's bottom edge in every case; its centre is 26
        // points up from there.
        let bandBottom = evaFittingHeight(field(nil), width: width)
        return InputProbe(
            raster: raster,
            fieldCentre: Int(((bandBottom - 26) * scale).rounded()),
            scale: scale
        )
    }

    @Test("The input's inner padding is 15 points, not the 16 of the spacing scale")
    func inputHorizontalPaddingIsFifteen() throws {
        // #16: the artboard gives `padding:0 15px`. It shipped as `EvaSpacing.md` (16)
        // on the note that §6 gave no inner padding — the artboard does give one, and 15
        // is deliberately off the 4/8/12/16 scale, which is why nobody would guess it.
        //
        // One point, read as the column where the field's own fill stops and its content
        // frame begins.
        let probe = try inputProbe()
        let fill = evaComposite(.evaInputFill, over: .black)
        var padding: CGFloat?
        for x in Int(3 * probe.scale)..<(probe.raster.width / 2)
        where !probe.raster.pixel(x, probe.fieldCentre).isWithin(Self.tolerance, of: fill) {
            padding = CGFloat(x) / probe.scale
            break
        }
        let measured = try #require(padding, "the field's content frame never began")
        #expect(abs(measured - 15) < 0.5,
                "the field insets its content by \(measured) points, expected 15 (it shipped at 16)")
    }

    @Test("The input fill goes opaque on focus and 80% on error")
    func inputFillsFollowTheState() throws {
        // #16: 75% at rest, 80% when wrong, opaque `#fff` when focused. All three were
        // one token before, so a focused field looked exactly like a resting one and
        // focus read only as a ring.
        //
        // Sampled over black. Over the warm background the three composite to within two
        // 8-bit steps of each other and of white, so a test run there would pass whatever
        // the code did — the same near-white trap that hides the card's inset lines.
        let background = Color.black
        func fill(isFocused: Bool = false, errorMessage: String? = nil) throws -> EvaRGBA {
            // 8 points in: inside the 1pt border, outside the 15pt content inset.
            try inputProbe(
                isFocused: isFocused, errorMessage: errorMessage, background: background
            ).sample(at: 8)
        }
        let resting = try fill()
        let focused = try fill(isFocused: true)
        let wrong = try fill(errorMessage: "Check that address.")
        #expect(resting.isWithin(Self.tolerance, of: evaComposite(.evaInputFill, over: background)),
                "the resting fill is \(resting.hexString), expected 75% white")
        #expect(focused.isWithin(Self.tolerance, of: Color.white.evaTestRGBA),
                "the focused fill is \(focused.hexString), expected opaque white")
        #expect(wrong.isWithin(Self.tolerance, of: evaComposite(.evaInputFillError, over: background)),
                "the error fill is \(wrong.hexString), expected 80% white")
        // The three have to be three, or the state is not being carried by the surface.
        #expect(!resting.isWithin(Self.tolerance, of: focused))
        #expect(!resting.isWithin(Self.tolerance, of: wrong))
        #expect(!focused.isWithin(Self.tolerance, of: wrong))
    }

    @Test("A disabled input's border is the 7% hairline, not the 10% an enabled field wears")
    func disabledInputBorderIsFainter() throws {
        // #16: `rgba(40,33,38,.07)`. It shipped as `evaControlBorder`, so a disabled
        // field was outlined exactly like a live one.
        //
        // 3% of the distance between the ink and the fill is about six 8-bit steps, so
        // this cannot be asserted as "within tolerance of 7%" — both candidates would
        // pass. It is asserted as "nearer 7% than 10%", the same shape as the corner
        // radius tests, which is what six steps of separation can honestly support.
        let background = Color.evaWarmBackground
        let probe = try inputProbe(isEnabled: false, background: background)
        let fill = evaComposite(.evaInputFillDisabled, over: background)
        let over = Color(red: fill.red, green: fill.green, blue: fill.blue)
        let atSeven = evaComposite(.evaInputBorderDisabled, over: over)
        let atTen = evaComposite(.evaControlBorder, over: over)
        // Half a point in, in the middle of the 1pt stroke.
        let drawn = probe.sample(at: 0.5)

        func distance(_ a: EvaRGBA, _ b: EvaRGBA) -> Double {
            max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255
        }
        #expect(distance(atSeven, atTen) > 3,
                "7% and 10% differ by only \(distance(atSeven, atTen)) steps here — the test cannot discriminate")
        #expect(distance(drawn, atSeven) < distance(drawn, atTen),
                "the disabled border drew \(drawn.hexString); 7% predicts \(atSeven.hexString), 10% predicts \(atTen.hexString)")
    }

    // MARK: The row-level destructive (#16)

    @Test("The row-level destructive's corners are radius 13, not the chip's 14")
    func rowDestructiveCornerRadius() throws {
        // #16: `border-radius:13px`. One point off the chip's 14, so it is measured at
        // 4 pixels per point — at 1 the two radii round to the same integer.
        //
        // The measurement is the *corner inset*: how much narrower the shape's top row
        // is than its middle. That is a function of the radius alone, which matters
        // here because the row variant sizes to its label rather than filling the width,
        // so a fixed-width reference could not be compared against it directly.
        let scale: CGFloat = 4
        let size = CGSize(width: 240, height: 44)
        let black = Color.black.evaTestRGBA

        func cornerInset(_ raster: EvaRaster) -> Int {
            let top = raster.tallestNonBackgroundRun(inRow: Int(scale), background: black)
            let middle = raster.tallestNonBackgroundRun(
                inRow: raster.height / 2, background: black
            )
            return middle - top
        }

        let button = try EvaRaster(
            Button("Remove entry") {}
                .buttonStyle(EvaDestructiveButtonStyle(kind: .row, previewState: .normal)),
            size: size,
            background: .black,
            scale: scale
        )
        func reference(_ radius: CGFloat) throws -> Int {
            cornerInset(try EvaRaster(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 160, height: 44),
                size: size,
                background: .black,
                scale: scale
            ))
        }
        let drawn = cornerInset(button)
        let atThirteen = try reference(13)
        let atFourteen = try reference(14)
        #expect(atThirteen != atFourteen,
                "radius 13 and 14 are indistinguishable at this scale — the test cannot discriminate")
        #expect(abs(drawn - atThirteen) < abs(drawn - atFourteen),
                "the row destructive's corner inset is \(drawn) pixels; radius 13 gives \(atThirteen), radius 14 gives \(atFourteen)")
    }
}

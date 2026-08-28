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

    /// The disabled chip, named so the #14 regression test can measure the same case the
    /// `unruledDisabled` list carries.
    static var disabledChip: EvaContrastCase { chipCase("disabled", isDisabled: true) }

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
        helperText: String? = nil,
        isHelperUnmet: Bool = false,
        isEnabled: Bool = true,
        band: (
            _ total: CGFloat,
            _ withoutHelper: CGFloat,
            _ withoutEither: CGFloat
        ) -> (top: Int, bottom: Int)
    ) -> EvaContrastCase {
        let width: CGFloat = 240
        func field(error: String?, helper: String?) -> some View {
            EvaInputField(
                label: "EMAIL",
                placeholder: "you@example.com",
                errorMessage: error,
                helperText: helper,
                isHelperUnmet: isHelperUnmet
            ) { prompt in
                TextField("EMAIL", text: .constant(""), prompt: prompt)
            }
            .disabled(!isEnabled)
            .frame(width: width)
        }
        let total = evaFittingHeight(field(error: errorMessage, helper: helperText), width: width)
        // The two heights a band can be measured from: with the helper row removed, and
        // with both rows removed. Subtracting one of them from the whole is what isolates
        // the row a case is about, since neither row's height is a constant — both wrap.
        let withoutHelper = evaFittingHeight(field(error: errorMessage, helper: nil), width: width)
        let withoutEither = evaFittingHeight(field(error: nil, helper: nil), width: width)
        let edges = band(total, withoutHelper, withoutEither)
        return EvaContrastCase(
            name: "Input · \(name)",
            size: CGSize(width: width, height: total),
            backdrop: page,
            inset: (top: edges.top, leading: 0, bottom: edges.bottom, trailing: 0),
            fillStrip: nil
        ) {
            AnyView(field(error: errorMessage, helper: helperText))
        }
    }

    // MARK: - The auth screens (#3)
    //
    // Everything below is a surface #3 built or newly put on screen, and none of it had a
    // case here. That is the same shape of hole #12 found: the components were checked
    // against the values the artboard states, and for three of these strings the artboard
    // states `#9A9095` — Muted Text, which measures 2.96:1 on the warm background. The
    // screens ship Secondary Text instead (DESIGN.md §9a); these cases are what holds
    // that swap in place, and `mutedTextWouldStillFail` below is the proof they can see
    // it going back.

    /// A provider button, on the fill it paints for itself.
    private static func authButton(_ provider: EvaAuthProvider) -> EvaContrastCase {
        // Wider than the other buttons deliberately: "Continue with Google" plus its mark
        // is close to 200 points, and at the shared 200 the label would reach into the
        // fill strip and come back as the ground.
        let size = CGSize(width: 320, height: EvaButtonHeight.standard)
        return EvaContrastCase(
            name: "Auth button · \(provider.rawValue)",
            size: size, backdrop: page,
            inset: buttonInset,
            // Left of a centred label and inside the radius-17 curve at every row the
            // 3-point vertical inset leaves.
            fillStrip: (leading: 20, width: 12)
        ) {
            AnyView(
                EvaAuthButton(provider: provider) {}
                    .frame(width: size.width)
            )
        }
    }

    /// The §7 information banner, which the sign-up screen uses for account linking.
    ///
    /// Measured without its action button. The compact provider button the linking banner
    /// puts there is the same `#1C1A1B` fill and the same white label as the full-width
    /// one above, and it would be the darkest thing in the raster if it were included —
    /// the banner's own ink is what has no case anywhere else.
    private static var infoBanner: EvaContrastCase {
        let width: CGFloat = 320
        func banner() -> some View {
            EvaInfoBanner(
                title: "This email already uses Apple sign-in",
                message: "We won't create a second profile. Continue with Apple and "
                    + "everything you've logged stays in one place."
            )
            .frame(width: width)
        }
        return EvaContrastCase(
            name: "Info banner · ink on the information tint",
            size: CGSize(width: width, height: evaFittingHeight(banner(), width: width)),
            backdrop: page,
            // 12 points vertically puts the sample strip inside the radius-20 corner at
            // every row it reaches, and still leaves the whole title and message — which
            // start 16 points in — inside the scan.
            inset: (top: 12, leading: 3, bottom: 12, trailing: 3),
            fillStrip: (leading: 4, width: 8)
        ) {
            AnyView(banner())
        }
    }

    /// The Show/Hide control, on the field fill it sits inside.
    ///
    /// Not measured through `EvaInputField`, for the reason `inputBand` gives: an
    /// `ImageRenderer` paints a `TextField` as a flat `#FFCC00` block, which would be the
    /// ground the button was read against. The control here is the real one and the fill
    /// is the component's own token, composited over the page the way the field does it.
    private static func inputRevealButton(isEnabled: Bool = true) -> EvaContrastCase {
        let size = CGSize(width: 96, height: EvaMetrics.minimumTouchTarget)
        return EvaContrastCase(
            name: "Input · reveal button\(isEnabled ? "" : " · disabled") on the field fill",
            size: size, backdrop: page,
            inset: (top: 2, leading: 2, bottom: 2, trailing: 2),
            fillStrip: (leading: 2, width: 10)
        ) {
            AnyView(
                EvaInputRevealButton(isRevealed: false) {}
                    .disabled(!isEnabled)
                    .frame(width: size.width, height: size.height)
                    // The fill the accessory sits on moves with the field, so the
                    // disabled case is measured on the disabled fill — otherwise it
                    // would be reading an ink the artboard never puts there.
                    .background(isEnabled ? Color.evaInputFill : Color.evaInputFillDisabled)
            )
        }
    }

    /// A string an auth screen draws straight onto the page, with no surface of its own —
    /// so the page is its ground, the way it is for the text button.
    private static func pageText(
        _ name: String,
        width: CGFloat = 320,
        _ make: @escaping () -> AnyView
    ) -> EvaContrastCase {
        EvaContrastCase(
            name: name,
            size: CGSize(width: width, height: evaFittingHeight(make(), width: width)),
            backdrop: page,
            // One point off every edge. These views fit their own content exactly, so
            // their height is usually fractional, and `ImageRenderer` leaves the last
            // part-covered pixel row unpainted — which is `#000000` in a premultiplied
            // buffer and would come back as the darkest pixel, i.e. as the label. Caught
            // by the legal note reading 20.13:1 against a black it never draws.
            inset: (top: 1, leading: 1, bottom: 1, trailing: 1),
            fillStrip: nil
        ) {
            AnyView(make().frame(width: width))
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
            inputBand("field name") { total, _, _ in
                (top: 0, bottom: Int(total) - 14)
            },
            // The error message, below it. §6 pairs it with the `!` circle from §2; both
            // are `evaErrorInk`, which #16 moved from `#C4645A` to `#A9524A`.
            inputBand("error message", errorMessage: "Check that address.") { _, _, without in
                (top: Int(without) + 2, bottom: 0)
            },
            // The same message on a *disabled* field, which #14 made a state that draws
            // itself properly. It is here and not in `unruledDisabled` on purpose: the
            // message is not a disabled label. Nothing about it is inactive — it is the
            // sentence explaining why, in the same `evaErrorInk` on the same page, and it
            // has to be as readable as it is on a live field.
            inputBand(
                "error message · field disabled",
                errorMessage: "Check that address.",
                isEnabled: false
            ) { _, _, without in
                (top: Int(without) + 2, bottom: 0)
            },
            // The helper rule, in its two states. Both are #3's, and neither had a case.
            //
            // At rest the artboard sets it in `#9A9095` (`pwHelpColor`); the screen sets
            // it in Secondary Text, and that is the swap this case holds.
            inputBand(
                "helper rule · met",
                helperText: "At least 8 characters, including one number."
            ) { _, withoutHelper, _ in
                (top: Int(withoutHelper) + 2, bottom: 0)
            },
            // Unmet is `evaErrorInk` on the page, plus the `!` mark — the artboard's
            // `pwHelpColor` when `errs` is true. Same ink as the error row above, but a
            // different row on a different field state, and it is the one #3 introduced.
            inputBand(
                "helper rule · unmet",
                helperText: "At least 8 characters, including one number.",
                isHelperUnmet: true
            ) { _, withoutHelper, _ in
                (top: Int(withoutHelper) + 2, bottom: 0)
            },
            authButton(.apple),
            authButton(.google),
            infoBanner,
            inputRevealButton(),
            pageText("Auth divider label") {
                AnyView(AuthMethodDivider(title: "or continue with email"))
            },
            pageText("Auth legal note") {
                AnyView(AuthLegalNote())
            },
            // The question, with the link rendered but empty.
            //
            // `AuthSwitchPrompt` draws two inks: Secondary Text for the question and the
            // text button's action pink for "Log in". Only the darker of the two is
            // found, and which one that is depends on the colours — with the shipped
            // tokens it is the question, but on Muted Text it flips to the pink and the
            // case starts passing on a string it is no longer measuring. Verified: with
            // `evaMutedText` restored the other three cases fail at 2.96:1 and this one
            // stayed green at the text button's 4.57.
            //
            // Giving the link an empty title leaves the real component with exactly one
            // ink in the raster, so this case can only ever be about the question. The
            // pink half is the "Text button" case above, on the same page ground.
            pageText("Auth cross-link question") {
                AnyView(
                    AuthSwitchPrompt(question: "Already have an account?", actionTitle: "") {}
                )
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
            disabledChip,
            // #14 gave the reveal button the artboard's own disabled ink (`#C8BFC3` in
            // the "Password · disabled" cell) in place of a half-faded action pink. That
            // is the canvas value, and on the canvas' disabled fill it lands in the same
            // place as every other `evaDisabledText` label — under the bar, and part of
            // the same unruled question.
            inputRevealButton(isEnabled: false),
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

    @Test("The disabled chip reads at the contrast its own tokens predict, not half of it")
    func theDisabledChipIsNotDimmedTwice() throws {
        // #14. `ChipToggleButton` painted the canvas' disabled chip inside a `.plain`
        // button's label, and the built-in styles dim a disabled subtree on top of
        // whatever the label drew — so the chip rendered at half the alpha its token
        // states and its label measured 1.3:1.
        //
        // The bar here is not a WCAG number: neither 1.3 nor what the tokens predict
        // clears AA, and disabled labels are exempt. It is that the *drawn* appearance is
        // the *specified* appearance — `evaDisabledText` on `evaChipFillDisabled` over
        // the page, arithmetic anyone can redo — so a style change that starts dimming
        // the chip again fails here with both numbers in the message.
        let measured = try EvaContrastSurfaces.disabledChip.measure()
        let predicted = evaContrastRatio(
            Color.evaDisabledText.evaTestRGBA,
            evaComposite(.evaChipFillDisabled, over: .evaWarmBackground)
        )
        #expect(
            abs(measured.ratio - predicted) < 0.1,
            "the disabled chip measures \(String(format: "%.2f", measured.ratio)):1 — its tokens predict \(String(format: "%.2f", predicted)):1, and 1.3:1 is what the plain style's dimming produced"
        )
    }

    @Test("Muted Text, which is what the artboard states for three of #3's strings, still fails")
    func mutedTextWouldStillFail() throws {
        // The auth screens draw the divider label, the legal note and the password rule
        // in `#9A9095` on the artboard — Muted Text. They ship in Secondary Text instead
        // (DESIGN.md §9a), and the cases above pin that. This is the other half: the
        // colour the artboard actually states, measured the same way on the same ground,
        // has to come back under the bar. Without it, "Muted Text passes too" would be an
        // untested assumption and every one of those cases would be free to regress to it.
        let regressed = EvaContrastCase(
            name: "Muted Text on the page, as the artboard states it",
            size: CGSize(width: 320, height: 24),
            backdrop: .evaWarmBackground,
            inset: (top: 0, leading: 0, bottom: 0, trailing: 0),
            fillStrip: nil
        ) {
            // `Text(verbatim:)` for the same reason the placeholder case gives: a string
            // literal goes through SwiftUI's Markdown parser.
            AnyView(
                Text(verbatim: "or continue with email")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaMutedText)
                    .frame(width: 320, height: 24)
            )
        }
        let measured = try regressed.measure()
        #expect(measured.ratio < 4.5,
                "Muted Text measured \(String(format: "%.2f", measured.ratio)):1 on the page — if this now passes, §9a's swap is no longer load-bearing and the note should say so")
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

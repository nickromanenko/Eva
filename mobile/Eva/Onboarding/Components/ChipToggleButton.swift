import SwiftUI

/// Selectable chip used for questionnaire options — DESIGN.md §6.
///
/// The canvas gives four appearances: **default** glass, **selected** pink gradient,
/// **severe** solid pink with a bar glyph, and **disabled** muted. Metrics are
/// min-height 44 (`EvaMetrics.minimumTouchTarget`, the canvas' minimum touch target)
/// and radius 14 (`EvaRadius.chip`).
///
/// The label is the §3 **Control** row, 13/600 — the row the artboard actually draws
/// chips at. It first shipped at Label 12, because §3's transcription had no 13 row;
/// #16 added one and this reverses the shrink.
///
/// ## The pink is deepened where a white label sits on it — #12, not the canvas
///
/// Selected and severe are the two appearances that put white on pink, and both fail
/// WCAG AA at the canvas' values: white on the selected gradient's `#EE93B1` top stop
/// measures **2.22:1**, and on severe's `#C95F86` **3.84:1**, against 4.5:1. So selected
/// takes `LinearGradient.evaActionPink` (`#B45276`→`#96486A`, 4.76:1 at its worst point)
/// and severe takes `Color.evaChipSevere` (`#7E3B58`, 7.91:1). Default and disabled
/// are unchanged — nothing white sits on either. See the `evaActionPink…` note in
/// `EvaColors.swift`.
///
/// `isSevere` and `isDisabled` are additive and default to `false`, so the existing
/// `ChipToggleButton(label:isSelected:action:)` and
/// `ChipToggleButton(label:isSelected:isCentered:action:)` call sites in
/// `GoalsStepView`, `HealthStepView` and `LifestyleStepView` are unchanged.
///
/// ## The disabled chip is drawn, not dimmed — #14
///
/// The four appearances are painted inside the button's *label*, so the style the
/// button wears must not touch it. `.plain` does: every built-in style dims a disabled
/// subtree on top of whatever the label drew, which halved the whole chip — the 80%
/// fill token rendered at 40% and the label measured 1.3:1 against it. It wears
/// `EvaUndimmedButtonStyle` instead, which draws nothing of its own, so the token
/// values are what appear. `.disabled(isDisabled)` stays exactly as it was: the chip
/// takes no taps and VoiceOver still announces it as dimmed.
///
/// The label ink is still the canvas' `evaDisabledText` on the canvas' muted fill,
/// which measures 1.65:1 — readable-ish rather than readable. Whether the #12/#17
/// decision to make disabled labels legible generalises off the filled buttons is an
/// open canvas question, explicitly out of scope for #14 and pinned by
/// `EvaContrastTests.theRemainingDisabledLabelsAreOnTheRecord`.
///
/// ## Identifier
///
/// `chip.<label>`, following `PrimaryButton`'s `primary.<title>`. It was omitted on the
/// belief that it would break `EvaUITests`' `app.buttons["Energy"]` lookups; it does
/// not — an element with both an identifier and a label resolves by either — and
/// GUARDRAILS §22 asks for one. The tests moved to the identifiers in the same change.
struct ChipToggleButton: View {
    /// The option this chip stands for. Also its accessibility label.
    let label: String
    /// Whether the option is currently chosen.
    let isSelected: Bool
    /// Centres the label instead of leading-aligning it. Grid chips centre; full-width
    /// list chips do not.
    var isCentered: Bool = false
    /// Renders the canvas' "severe" appearance: solid `evaChipSevere` with a bar
    /// glyph before the label. The glyph is the non-colour half of the cue required by
    /// DESIGN.md §1 ("never colour alone").
    var isSevere: Bool = false
    /// Renders the muted, non-interactive appearance and turns the button off.
    var isDisabled: Bool = false
    /// Invoked on tap. Not called while `isDisabled`.
    let action: () -> Void

    init(
        label: String,
        isSelected: Bool,
        isCentered: Bool = false,
        isSevere: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.isSelected = isSelected
        self.isCentered = isCentered
        self.isSevere = isSevere
        self.isDisabled = isDisabled
        self.action = action
    }

    /// The canvas state this chip renders, resolved from the flags.
    ///
    /// Precedence is disabled → severe → selected → default. The canvas lists severe
    /// as a peer of selected rather than a modifier on it and does not say whether a
    /// severe chip must also be selected, so the caller decides: `isSevere` paints the
    /// severe appearance on its own. The `.isSelected` accessibility trait still
    /// follows `isSelected` alone.
    private var appearance: Appearance {
        if isDisabled { return .disabled }
        if isSevere { return .severe }
        return isSelected ? .selected : .default
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: EvaSpacing.xs) {
                if appearance == .severe {
                    Capsule(style: .continuous)
                        .fill(Color.evaTextOnDark)
                        .frame(
                            width: ChipSevereGlyph.width,
                            height: ChipSevereGlyph.height
                        )
                }

                Text(label)
                    .evaTextStyle(.control)
                    .foregroundStyle(appearance.labelColor)
                    .multilineTextAlignment(isCentered ? .center : .leading)
            }
            .padding(.horizontal, EvaSpacing.md)
            .padding(.vertical, EvaSpacing.xs)
            .frame(
                maxWidth: .infinity,
                minHeight: EvaMetrics.minimumTouchTarget,
                alignment: isCentered ? .center : .leading
            )
            .background {
                shape
                    .fill(appearance.fill)
                    .shadow(
                        color: appearance.shadow?.color ?? .clear,
                        radius: appearance.shadow?.radius ?? 0,
                        x: 0,
                        y: appearance.shadow?.offsetY ?? 0
                    )
            }
            .overlay {
                if let border = appearance.borderColor {
                    shape.strokeBorder(border, lineWidth: ChipBorder.width)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.evaUndimmed)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chip.\(label)")
    }
}

// MARK: - Appearance

extension ChipToggleButton {

    /// One of the four chip appearances in DESIGN.md §6.
    fileprivate enum Appearance: Equatable {
        /// Glass fill, hairline border, primary-text label.
        case `default`
        /// Action-pink gradient fill, white label, pink drop shadow.
        case selected
        /// Solid `evaChipSevere`, border, white label, bar glyph.
        case severe
        /// Muted fill and border, disabled-ink label.
        case disabled

        /// Selected and severe use the action ramp rather than the canvas pinks
        /// (`LinearGradient.evaChipSelected` / `Color.evaDeepPink`), because both carry
        /// a white label. See the `ChipToggleButton` type comment for the measurements.
        var fill: AnyShapeStyle {
            switch self {
            case .default: AnyShapeStyle(Color.evaChipFill)
            case .selected: AnyShapeStyle(LinearGradient.evaActionPink)
            case .severe: AnyShapeStyle(Color.evaChipSevere)
            case .disabled: AnyShapeStyle(Color.evaChipFillDisabled)
            }
        }

        /// `nil` where the canvas specifies no border. Selected carries its contrast
        /// in the fill, the white label and the shadow instead.
        ///
        /// Severe carries `evaChipSevereBorder` (`#5F2C3F`), deepened alongside its fill
        /// so it still draws an edge. The artboard's pairing (`#C95F86` fill, `#A94A6C`
        /// border) does not survive the #12 action ramp: the ramp moves the fill onto the
        /// border's hex. Severe is told apart from selected by being flat rather than a
        /// gradient, by this border, by its bar glyph, and by sitting ~80 channel-units
        /// deeper.
        var borderColor: Color? {
            switch self {
            case .default: Color.evaControlBorder
            case .selected: nil
            case .severe: Color.evaChipSevereBorder
            case .disabled: Color.evaControlBorderDisabled
            }
        }

        var labelColor: Color {
            switch self {
            case .default: Color.evaPrimaryText
            case .selected, .severe: Color.evaTextOnDark
            case .disabled: Color.evaDisabledText
            }
        }

        var shadow: ChipShadow? {
            self == .selected ? ChipShadow.selected : nil
        }
    }
}

// MARK: - Chip constants

/// Hairline width on the default, severe and disabled chips (DESIGN.md §6 — 1px).
private enum ChipBorder {
    static let width: CGFloat = 1
}

/// The severe chip's bar glyph — 9 × 2, radius 1.
///
/// DESIGN.md §6 only says "a bar glyph"; the artboard draws `9×2px, radius 1`, and the
/// 10 × 2 this first shipped as was a guess sized by eye. Corrected by #16.
///
/// The radius needs no constant: the glyph is drawn as a `Capsule`, whose radius is half
/// the shorter side, and half of 2 is exactly the 1 the artboard asks for.
private enum ChipSevereGlyph {
    static let width: CGFloat = 9
    static let height: CGFloat = 2
}

/// Selected-chip drop shadow: `0 8px 18px -12px rgba(201,95,134,.8)` (DESIGN.md §6).
///
/// SwiftUI's shadow has no spread, so the -12px contraction cannot be expressed and
/// the shadow renders wider than the canvas — the same limitation `EvaGlass` records
/// for the card shadow. CSS blur 18 maps to SwiftUI radius 9 on that file's convention.
///
/// The colour is the ramp's darkest stop at 70%, not the artboard's
/// `rgba(201,95,134,.8)`. That value is *lighter* than the deepened fill it sits under,
/// so it renders as a glow rather than a shadow — mildly true at the canvas values too,
/// and plainly wrong once #12's ramp darkened the chip.
private struct ChipShadow {
    let color: Color
    let radius: CGFloat
    let offsetY: CGFloat

    static let selected = ChipShadow(
        color: .evaActionPinkPressedBottom.opacity(0.7),
        radius: 9,
        offsetY: 8
    )
}

// MARK: - Preview

#Preview("Chip states") {
    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.lg) {
            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("Full width · leading")
                    .evaTextStyle(.overline)
                    .foregroundStyle(Color.evaSecondaryText)

                ChipToggleButton(label: "Default", isSelected: false) {}
                ChipToggleButton(label: "Selected", isSelected: true) {}
                ChipToggleButton(label: "Severe", isSelected: true, isSevere: true) {}
                ChipToggleButton(label: "Disabled", isSelected: false, isDisabled: true) {}
            }

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("Grid · centred")
                    .evaTextStyle(.overline)
                    .foregroundStyle(Color.evaSecondaryText)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: EvaSpacing.sm
                ) {
                    ChipToggleButton(label: "Energy", isSelected: false, isCentered: true) {}
                    ChipToggleButton(label: "Cycle health", isSelected: true, isCentered: true) {}
                    ChipToggleButton(
                        label: "Heavy flow",
                        isSelected: true,
                        isCentered: true,
                        isSevere: true
                    ) {}
                    ChipToggleButton(
                        label: "Not tracked yet",
                        isSelected: false,
                        isCentered: true,
                        isDisabled: true
                    ) {}
                }
            }

            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                Text("Wrapping label")
                    .evaTextStyle(.overline)
                    .foregroundStyle(Color.evaSecondaryText)

                ChipToggleButton(
                    label: "Medications that affect hormones",
                    isSelected: true
                ) {}
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}

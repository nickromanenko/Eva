import SwiftUI

/// Selectable chip used for questionnaire options — DESIGN.md §6.
///
/// The canvas gives four appearances: **default** glass, **selected** pink gradient,
/// **severe** solid deep pink with a bar glyph, and **disabled** muted. Metrics are
/// min-height 44 (`EvaMetrics.minimumTouchTarget`, the canvas' minimum touch target)
/// and radius 14 (`EvaRadius.chip`).
///
/// `isSevere` and `isDisabled` are additive and default to `false`, so the existing
/// `ChipToggleButton(label:isSelected:action:)` and
/// `ChipToggleButton(label:isSelected:isCentered:action:)` call sites in
/// `GoalsStepView`, `HealthStepView` and `LifestyleStepView` are unchanged.
///
/// No `accessibilityIdentifier` is set. `EvaUITests` navigates these chips by their
/// label (`app.buttons["Energy"]`), and adding one would not break that — an element
/// with both resolves by either, as `PrimaryButton` demonstrates. GUARDRAILS §22 asks
/// for identifiers on interactive elements, so this is an omission inherited from
/// before the canvas re-spec, not a decision.
struct ChipToggleButton: View {
    /// The option this chip stands for. Also its accessibility label.
    let label: String
    /// Whether the option is currently chosen.
    let isSelected: Bool
    /// Centres the label instead of leading-aligning it. Grid chips centre; full-width
    /// list chips do not.
    var isCentered: Bool = false
    /// Renders the canvas' "severe" appearance: solid `evaDeepPink` with a bar glyph
    /// before the label. The glyph is the non-colour half of the cue required by
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
                    .evaTextStyle(.label)
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
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Appearance

extension ChipToggleButton {

    /// One of the four chip appearances in DESIGN.md §6.
    fileprivate enum Appearance: Equatable {
        /// Glass fill, hairline border, primary-text label.
        case `default`
        /// Pink gradient fill, white label, pink drop shadow.
        case selected
        /// Solid `evaDeepPink`, darker border, white label, bar glyph.
        case severe
        /// Muted fill and border, disabled-ink label.
        case disabled

        var fill: AnyShapeStyle {
            switch self {
            case .default: AnyShapeStyle(Color.evaChipFill)
            case .selected: AnyShapeStyle(LinearGradient.evaChipSelected)
            case .severe: AnyShapeStyle(Color.evaDeepPink)
            case .disabled: AnyShapeStyle(Color.evaChipFillDisabled)
            }
        }

        /// `nil` where the canvas specifies no border. Selected carries its contrast
        /// in the fill, the white label and the shadow instead.
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

/// The severe chip's bar glyph.
///
/// DESIGN.md §6 calls for "a bar glyph" but gives no dimensions. These are sized to
/// read beside the 12pt label without competing with it; confirm against
/// "Eva Design System.dc.html" §05 before a screen leans on them.
private enum ChipSevereGlyph {
    static let width: CGFloat = 10
    static let height: CGFloat = 2
}

/// Selected-chip drop shadow: `0 8px 18px -12px rgba(201,95,134,.8)` (DESIGN.md §6).
///
/// SwiftUI's shadow has no spread, so the -12px contraction cannot be expressed and
/// the shadow renders wider than the canvas — the same limitation `EvaGlass` records
/// for the card shadow. CSS blur 18 maps to SwiftUI radius 9 on that file's convention.
private struct ChipShadow {
    let color: Color
    let radius: CGFloat
    let offsetY: CGFloat

    static let selected = ChipShadow(
        color: .evaDeepPink.opacity(0.8),
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

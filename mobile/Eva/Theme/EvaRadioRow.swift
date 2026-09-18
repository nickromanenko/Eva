import SwiftUI

/// The DESIGN.md §6 radio row: one option in a single-choice list, with a title, a
/// description of what choosing it does, and a mark that is a shape as well as a colour.
///
/// Read off `docs/design/Eva Design System.dc.html` rather than §6's prose, which gives
/// the geometry but not the two marks:
///
/// ```
/// min-height:56px; gap:12px; padding:10px 14px; border-radius:18px
/// selected    background:rgba(233,130,165,.14)  border:1px rgba(201,95,134,.45)
///             mark 20×20 circle, border:6px solid #C95F86, background:#fff
/// unselected  background:rgba(255,255,255,.66)  border:1px rgba(255,255,255,.9)
///             mark 20×20 circle, border:1.5px solid rgba(40,33,38,.25), background:#fff
/// title       600 13px            → §3 Control
/// description 400 11.5px #6F656B  → §3 Input helper, Secondary Text
/// ```
///
/// Two places the artboard is not followed literally, both already-settled calls rather
/// than new ones:
///
/// * **The description is §3's Input helper (12/18)**, where the artboard draws 11.5/400.
///   The scale has no 11.5 row and half a point is not worth adding one — the same call
///   `EvaTabBar` made for its 10.5px label.
/// * **The mark keeps the artboard's `#C95F86`**, because it is a mark and not a label:
///   §9a deepens the pink only where white text sits on it, and this pink measures
///   3.84:1 against the warm background — past the 3:1 WCAG 2.1 SC 1.4.11 asks of a
///   non-text control boundary.
///
/// The filled ring is also the "never colour alone" half of §1: selected is a solid
/// annulus and unselected is a hairline, so the two differ in shape at any tint.
struct EvaRadioRow<Label: View>: View {

    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: EvaSpacing.sm) {
                mark
                label
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: EvaMetrics.radioRowHeight, alignment: .leading)
            .background(
                isSelected ? Color.evaRadioSelectedFill : Color.evaGlassSurface,
                in: .rect(cornerRadius: EvaRadius.radioRow, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EvaRadius.radioRow, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.evaRadioSelectedBorder : Color.evaRadioBorder,
                        lineWidth: 1
                    )
            }
            .contentShape(.rect)
        }
        // The row paints every part of its own appearance; a style that dimmed it on press
        // would fight the tokens above, the way `.plain` fought `ChipToggleButton`.
        .buttonStyle(.evaUndimmed)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// `20×20` circle; 6pt annulus when selected, 1.5pt hairline when not.
    private var mark: some View {
        Circle()
            .fill(Color.white)
            .overlay {
                Circle()
                    .strokeBorder(
                        isSelected ? Color.evaDeepPink : Color.evaRadioMarkBorder,
                        lineWidth: isSelected ? 6 : 1.5
                    )
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

extension EvaRadioRow where Label == EvaRadioRowLabel {
    /// The artboard's own label: a title and the line under it saying what it does.
    init(title: String, detail: String, isSelected: Bool, action: @escaping () -> Void) {
        self.init(isSelected: isSelected, action: action) {
            EvaRadioRowLabel(title: title, detail: detail)
        }
    }
}

/// Title over description, at the two rows of §3 the artboard draws.
struct EvaRadioRowLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .evaTextStyle(.control)
                .foregroundStyle(Color.evaPrimaryText)
            Text(detail)
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
    }
}

#Preview("Radio rows") {
    @Previewable @State var selection = EvaUnitSystem.metric

    VStack(spacing: EvaSpacing.xs) {
        ForEach(EvaUnitSystem.allCases) { system in
            EvaRadioRow(
                title: system.title,
                detail: system.detail,
                isSelected: selection == system
            ) {
                selection = system
            }
        }
    }
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}

import SwiftUI

/// The DESIGN.md §6 toggle: a 52×32 track, pistachio when on, with a white 26pt knob.
///
/// Read off `docs/design/Eva Design System.dc.html`, which draws the three states side by
/// side, and matched against the Nutrition canvas' own `track()` / `knob()` (`nSet`):
///
/// ```
/// track    width:52px; height:32px; border-radius:16px; padding:3px
/// on       linear-gradient(180deg,#B7CF86,#8EAD56), knob at the trailing edge
/// off      rgba(40,33,38,.16), knob at the leading edge
/// disabled rgba(40,33,38,.08), opacity .5, knob without its shadow
/// knob     26×26 circle, #fff, box-shadow:0 2px 6px rgba(40,33,38,.28)
/// ```
///
/// Built in #223, where Nutrition Settings needed the switch the canvas draws. #160 had
/// used a chip instead rather than build a design-system component inside a feature slice;
/// here the screen *is* a row of switches, and every value is on the artboard.
///
/// **Never colour alone** (§1): on and off differ in the knob's position as well as the
/// track's fill.
///
/// It is a `ToggleStyle`, so the control stays a SwiftUI `Toggle` — announced as a switch
/// with its on/off value, and found by UI tests among `app.switches`, exactly as the system
/// style is.
struct EvaToggleStyle: ToggleStyle {

    func makeBody(configuration: Configuration) -> some View {
        EvaToggleRow(configuration: configuration)
    }
}

extension ToggleStyle where Self == EvaToggleStyle {
    /// The §6 pistachio switch.
    static var eva: Self { EvaToggleStyle() }
}

/// The label and the track, laid out as a settings row lays them: label leading, switch
/// trailing.
private struct EvaToggleRow: View {

    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    /// `width:52px;height:32px` — the hit area is the whole row, which is always taller.
    private static let trackSize = CGSize(width: 52, height: 32)
    /// `padding:3px` around the 26pt knob.
    private static let inset: CGFloat = 3
    private static var knobDiameter: CGFloat { trackSize.height - inset * 2 }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: EvaSpacing.sm) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                track
            }
            .frame(minHeight: EvaMetrics.minimumTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.evaUndimmed)
    }

    private var track: some View {
        Capsule()
            .fill(trackFill)
            .frame(width: Self.trackSize.width, height: Self.trackSize.height)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .shadow(
                        color: isEnabled ? Color.evaToggleKnobShadow : .clear,
                        radius: 3,
                        y: 2
                    )
                    .padding(Self.inset)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityHidden(true)
    }

    private var trackFill: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Color.evaToggleTrackDisabled) }
        return configuration.isOn
            ? AnyShapeStyle(LinearGradient.evaToggleOn)
            : AnyShapeStyle(Color.evaToggleTrackOff)
    }
}

#Preview("Toggle") {
    @Previewable @State var on = true
    @Previewable @State var off = false

    VStack(spacing: EvaSpacing.sm) {
        Toggle("On", isOn: $on)
        Toggle("Off", isOn: $off)
        Toggle("Disabled", isOn: .constant(false))
            .disabled(true)
    }
    .toggleStyle(.eva)
    .evaTextStyle(.bodyMedium)
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}

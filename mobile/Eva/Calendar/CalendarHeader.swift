import SwiftUI

/// The month title, which opens the picker, and the two month steppers beside it.
struct CalendarHeader: View {

    let month: EvaMonth
    let isPickerOpen: Bool
    let togglePicker: () -> Void
    let showPrevious: () -> Void
    let showNext: () -> Void

    var body: some View {
        HStack(spacing: EvaSpacing.sm) {
            Button(action: togglePicker) {
                HStack(spacing: EvaSpacing.xs) {
                    Text(Self.title(for: month))
                        // The artboard draws 26/400, which the §3 scale has no row for —
                        // it sits between H1 (28/600) and H2 (21/600) in size and below
                        // both in weight. H1 was tried first, as the screen-title row, and
                        // **"September 2026" wraps to two lines** at 28/600 in the width
                        // left by the two steppers. H2 fits on one line at every month, and
                        // is the closer match in optical weight anyway: smaller and heavier
                        // against bigger and lighter. Reported on #159.
                        .evaTextStyle(.h2)
                        .foregroundStyle(Color.evaPrimaryText)
                        // At accessibility text sizes it shrinks rather than wrapping or
                        // truncating — a month name cut to "Septem…" is worse than a small
                        // one, and a wrapping title moves the whole grid.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: isPickerOpen ? "chevron.up" : "chevron.down")
                        .font(.evaLabel)
                        .foregroundStyle(Color.evaSecondaryText)
                }
                .frame(minHeight: EvaMetrics.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.evaUndimmed)
            .accessibilityIdentifier("calendar.monthPicker")
            .accessibilityLabel("\(Self.title(for: month)). Jump to month")
            .accessibilityAddTraits(.isButton)

            Spacer(minLength: 0)

            CalendarStepperButton(
                systemImage: "chevron.left",
                label: "Previous month",
                identifier: "calendar.previousMonth",
                action: showPrevious
            )
            CalendarStepperButton(
                systemImage: "chevron.right",
                label: "Next month",
                identifier: "calendar.nextMonth",
                action: showNext
            )
        }
    }

    /// "August 2026", in the user's locale.
    static func title(for month: EvaMonth) -> String {
        month.firstDay.formattingDate.formatted(EvaDay.formatStyle.month(.wide).year())
    }
}

/// A 44 × 44 glass square. The artboard's `‹` / `›` beside the month title.
///
/// Swiping also pages the grid, and this is why swiping is not the only way: a drag is
/// invisible to anyone reading the screen with VoiceOver, unavailable to a switch user,
/// and undiscoverable to everyone else. The artboard draws both.
struct CalendarStepperButton: View {

    let systemImage: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.evaControlText)
                .foregroundStyle(Color.evaSecondaryText)
                .frame(
                    width: EvaCalendarMetrics.stepperSize,
                    height: EvaCalendarMetrics.stepperSize
                )
                .background {
                    let shape = RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                    shape
                        .fill(EvaGlassLevel.background.material)
                        .overlay { shape.fill(Color.evaSecondaryFill) }
                        .overlay {
                            shape.strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}

/// The current mode, as a label.
///
/// **Never a control (A6).** Pregnancy Mode is entered from Profile and the phases advance
/// on events, so there is nothing here to switch — the artboard draws a chip and a line of
/// text saying where the switch actually is. It is deliberately not a `Button`, not
/// focusable, and announced as static text, because a chip that looks tappable and is not
/// is the same defect as an inert button.
struct CalendarModeChip: View {

    var body: some View {
        HStack(spacing: EvaSpacing.xs) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.evaDeepPink)
                    .frame(width: 7, height: 7)
                Text("Cycle tracking")
                    .evaTextStyle(.label)
                    // `#A9436E` on the artboard; the action ramp's solid stop is `#A94A6C`
                    // and already named. One channel apart, and no new token for one chip.
                    .foregroundStyle(Color.evaActionPinkSolid)
            }
            .padding(.horizontal, EvaSpacing.sm)
            .frame(minHeight: EvaCalendarMetrics.modeChipHeight)
            .background {
                let shape = RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                shape
                    .fill(Color.evaPrimaryPink.opacity(0.12))
                    .overlay { shape.strokeBorder(Color.evaDeepPink.opacity(0.3), lineWidth: 1) }
            }

            Text("Change in Profile › Pregnancy Mode")
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current mode: Cycle tracking. Change in Profile, Pregnancy Mode.")
        .accessibilityIdentifier("calendar.modeChip")
    }
}

#Preview("Header") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            CalendarHeader(
                month: EvaMonth(year: 2026, month: 8),
                isPickerOpen: false,
                togglePicker: {},
                showPrevious: {},
                showNext: {}
            )
            CalendarModeChip()
        }
        .padding(EvaSpacing.lg)
    }
}

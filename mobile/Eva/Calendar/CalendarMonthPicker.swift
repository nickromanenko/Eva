import SwiftUI

/// The "Jump to month" card the header opens: a year stepper over twelve month chips.
///
/// A card that expands in place, not a sheet — the artboard draws it inside the screen,
/// under the header, with the grid still visible below it.
struct CalendarMonthPicker: View {

    let year: Int
    /// The month the grid is showing, so the chip for it reads as selected.
    let selected: EvaMonth
    let showPreviousYear: () -> Void
    let showNextYear: () -> Void
    let select: (EvaMonth) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: EvaSpacing.xs), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            HStack(spacing: EvaSpacing.xxs) {
                Text("Jump to month")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)

                Spacer(minLength: 0)

                CalendarStepperButton(
                    systemImage: "chevron.left",
                    label: "Previous year",
                    identifier: "calendar.previousYear",
                    action: showPreviousYear
                )
                Text(verbatim: String(year))
                    .evaTextStyle(.control)
                    .foregroundStyle(Color.evaPrimaryText)
                    .frame(minWidth: 48)
                    .accessibilityIdentifier("calendar.pickerYear")
                CalendarStepperButton(
                    systemImage: "chevron.right",
                    label: "Next year",
                    identifier: "calendar.nextYear",
                    action: showNextYear
                )
            }

            LazyVGrid(columns: columns, spacing: EvaSpacing.xs) {
                ForEach(1...12, id: \.self) { index in
                    let month = EvaMonth(year: year, month: index)
                    monthChip(month, label: Self.shortName(for: month))
                }
            }
        }
        .padding(EvaSpacing.md)
        .evaGlass(.sheet, cornerRadius: EvaRadius.card)
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
                .strokeBorder(EvaCalendarMetrics.surfaceHairline, lineWidth: 1)
        }
        .accessibilityIdentifier("calendar.monthPickerCard")
    }

    private func monthChip(_ month: EvaMonth, label: String) -> some View {
        let isSelected = month == selected
        return Button { select(month) } label: {
            Text(label)
                .evaTextStyle(.control)
                .foregroundStyle(isSelected ? Color.evaTextOnDark : Color.evaSecondaryText)
                // The artboard's chip is 38 high. §1's 44pt floor is not negotiable for
                // something you tap, so it is 44 — the same trade `AuthScreenParts` took
                // for the log-in cross-link.
                .frame(maxWidth: .infinity, minHeight: EvaMetrics.minimumTouchTarget)
                .background {
                    let shape = RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                    // `#C95F86` filled with a white label on the artboard; the action ramp
                    // is the token for pink that carries one (#12).
                    isSelected
                        ? AnyView(shape.fill(Color.evaActionPinkSolid))
                        : AnyView(shape.fill(Color.evaChipFill))
                }
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier("calendar.month.\(month.description)")
        .accessibilityLabel(CalendarHeader.title(for: month))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Aug", in the user's locale.
    static func shortName(for month: EvaMonth) -> String {
        month.firstDay.formattingDate.formatted(EvaDay.formatStyle.month(.abbreviated))
    }
}

#Preview("Month picker") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        CalendarMonthPicker(
            year: 2026,
            selected: EvaMonth(year: 2026, month: 8),
            showPreviousYear: {},
            showNextYear: {},
            select: { _ in }
        )
        .padding(EvaSpacing.lg)
    }
}

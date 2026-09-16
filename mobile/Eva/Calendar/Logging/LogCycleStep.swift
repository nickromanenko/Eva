import SwiftUI

/// The canvas' `cycle` sheet: one marker for the day.
///
/// **One value per day, and the sheet says so.** The server stores a cycle entry at an id
/// derived from its day, so a second save replaces the first. The artboard handles that
/// with a "Replace medium flow?" modal; this says it in the subtitle and in the rows
/// instead — the choice is a radio, the current value is ticked, and changing it is one
/// tap on a sheet the user opened in order to change it. A confirmation dialog in front of
/// a reversible, visible, one-tap change is friction that teaches people to dismiss
/// dialogs.
///
/// ## What is not here
///
/// The artboard's "Anything else today?" chips, which appear once a flow is chosen. They
/// are symptom chips, and symptoms are stored on a **body signals** entry, not on a cycle
/// one — so drawing them here would either write a second entry the user did not ask for
/// or give one concept two homes. #24 settled that rule for the catalogue and it applies
/// to the sheets as well. Reported on #160.
struct LogCycleStep: View {

    @Binding var draft: LogCycleDraft
    let day: EvaDay
    let isEditing: Bool
    let isSaving: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let save: () -> Void

    /// The artboard's four options, in its order, with its hints.
    private static let options: [(mark: EvaCycleMark, hint: String)] = [
        (.spotting, "Marker only · doesn't start a period"),
        (.flow(.light), "1–2 changes"),
        (.flow(.medium), "3–4 changes"),
        (.flow(.heavy), "5+ changes")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            LogStepHeader(
                title: CalendarEntryPresentation.typeName(for: .cycle),
                subtitle: "\(day.shortLabel) · one value per day",
                back: back,
                close: close
            )

            VStack(spacing: EvaSpacing.xs) {
                ForEach(Self.options, id: \.mark) { option in
                    row(option.mark, hint: option.hint)
                }
            }

            LogNoteField(note: $draft.note, identifier: "log.cycle.note")

            PrimaryButton(
                title: isEditing ? "Save changes" : "Save",
                isLoading: isSaving,
                action: save
            )
            .disabled(draft.payload == nil)
        }
    }

    private func row(_ mark: EvaCycleMark, hint: String) -> some View {
        let isSelected = draft.mark == mark
        return Button {
            draft.mark = mark
        } label: {
            HStack(spacing: EvaSpacing.sm) {
                swatch(mark)
                Text(CalendarEntryPresentation.summary(for: mark))
                    .evaTextStyle(.button)
                    .foregroundStyle(Color.evaPrimaryText)
                Spacer(minLength: EvaSpacing.xs)
                Text(hint)
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .multilineTextAlignment(.trailing)
                if isSelected {
                    // The tick is the non-colour half of the selected state (§1): fill and
                    // border move too, but neither survives greyscale on its own.
                    Image(systemName: "checkmark")
                        .font(.evaControlText)
                        .foregroundStyle(Color.evaActionPinkSolid)
                }
            }
            .padding(.horizontal, EvaSpacing.md)
            .padding(.vertical, EvaSpacing.xs)
            .frame(minHeight: LogCycleMetrics.rowHeight)
            .background(
                isSelected ? Color.evaPrimaryPink.opacity(0.16) : Color.white.opacity(0.7),
                in: .rect(cornerRadius: EvaRadius.banner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.evaDeepPink.opacity(0.5) : Color.white.opacity(0.9),
                        lineWidth: 1
                    )
            }
            .contentShape(.rect(cornerRadius: EvaRadius.banner, style: .continuous))
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("log.flow.\(LogCycleStep.identifier(for: mark))")
    }

    /// The artboard's swatches: a dashed ring for spotting, a filled square at the flow's
    /// own opacity for the three levels. Spotting is drawn as an outline rather than as a
    /// paler fill for the same reason the grid does it — a wash of any strength would read
    /// as a period day, and a spotting day does not start a period.
    @ViewBuilder
    private func swatch(_ mark: EvaCycleMark) -> some View {
        switch mark {
        case .spotting:
            Circle()
                .strokeBorder(
                    Color.evaDeepPink.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                .frame(width: LogCycleMetrics.swatchSize, height: LogCycleMetrics.swatchSize)
        case .flow(let level):
            RoundedRectangle(cornerRadius: EvaSpacing.xs, style: .continuous)
                .fill(Color.evaDeepPink.opacity(LogCycleMetrics.swatchOpacity(level)))
                .overlay {
                    RoundedRectangle(cornerRadius: EvaSpacing.xs, style: .continuous)
                        .strokeBorder(Color.evaDeepPink.opacity(0.35), lineWidth: 1)
                }
                .frame(width: LogCycleMetrics.swatchSize, height: LogCycleMetrics.swatchSize)
        }
    }

    /// A stable, lower-case name for an accessibility identifier — `spotting`, `light`,
    /// `medium`, `heavy`. Not the visible label, which is prose and would carry a space.
    static func identifier(for mark: EvaCycleMark) -> String {
        switch mark {
        case .spotting: "spotting"
        case .flow(let level): level.rawValue
        }
    }
}

enum LogCycleMetrics {
    /// `min-height:58px` on a flow row.
    static let rowHeight: CGFloat = 58
    /// `width:22px;height:22px` on its swatch.
    static let swatchSize: CGFloat = 22
    /// `rgba(201,95,134,…)` at the artboard's four steps, minus spotting's.
    static func swatchOpacity(_ level: EvaFlowLevel) -> Double {
        switch level {
        case .light: 0.24
        case .medium: 0.36
        case .heavy: 0.50
        }
    }
}

#Preview("Log cycle") {
    @Previewable @State var draft = LogCycleDraft(mark: .flow(.medium))

    return ScrollView {
        LogCycleStep(
            draft: $draft,
            day: EvaDay(year: 2026, month: 8, day: 12),
            isEditing: false,
            isSaving: false,
            back: {},
            close: {},
            save: {}
        )
        .padding(EvaSpacing.lg)
    }
    .background { EvaScreenBackground().ignoresSafeArea() }
}

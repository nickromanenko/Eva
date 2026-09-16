import SwiftUI

/// The canvas' `sport` sheet: an activity, a duration and an intensity.
///
/// The artboard opens with a "Recently used" row above the full list. It is dropped here:
/// what counts as recent is a question about the user's history that nothing in C2
/// answers, and three chips picked arbitrarily would be a claim about her habits rather
/// than a shortcut. Reported on #160.
struct LogSportStep: View {

    @Binding var draft: LogSportDraft
    let day: EvaDay
    /// `/refdata`'s active sport activities, already in catalogue order.
    let catalogue: [EvaRefData.Item]
    let isEditing: Bool
    let isSaving: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let save: () -> Void

    @FocusState private var isTypingActivity: Bool

    private let chipColumns = [
        GridItem(.adaptive(minimum: LogBodySignalsMetrics.chipMinimumWidth), spacing: EvaSpacing.xs)
    ]
    private let durationColumns = [
        GridItem(.adaptive(minimum: LogSportMetrics.durationChipWidth), spacing: EvaSpacing.xs)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            LogStepHeader(
                title: CalendarEntryPresentation.typeName(for: .sport),
                subtitle: day.shortLabel,
                back: back,
                close: close
            )

            activities
            duration
            intensity

            LogNoteField(note: $draft.note, identifier: "log.sport.note")

            PrimaryButton(
                title: isEditing ? "Save changes" : "Save",
                isLoading: isSaving,
                action: save
            )
            .disabled(draft.payload(in: catalogue) == nil)
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activities: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            LogSectionHeading("Activity")

            if catalogue.isEmpty {
                Text("Eva couldn't load the activity list. Try again in a moment.")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("log.activities.unavailable")
            } else {
                LazyVGrid(columns: chipColumns, spacing: EvaSpacing.xs) {
                    ForEach(catalogue) { item in
                        ChipToggleButton(
                            label: item.label,
                            isSelected: draft.activityCode == item.code,
                            isCentered: true
                        ) {
                            draft.activityCode = draft.activityCode == item.code ? nil : item.code
                            isTypingActivity = item.freeText && draft.activityCode != nil
                        }
                    }
                }
                // Addressable as a field — see the same note on the appointment sheet. This
                // one shares a sheet with the duration chips.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("log.activities")

                if isFreeTextChosen {
                    // The catalogue's own `freeText` flag decides this, not a hard-coded
                    // "Other": the code behind it belongs to the catalogue and can change
                    // without an app release.
                    EvaInputField(
                        label: "What was it?",
                        placeholder: "Trampolining",
                        isFocused: isTypingActivity
                    ) { prompt in
                        TextField("", text: $draft.otherActivity, prompt: prompt)
                            .focused($isTypingActivity)
                            .accessibilityIdentifier("log.sport.other")
                    }
                }
            }
        }
    }

    private var isFreeTextChosen: Bool {
        guard let code = draft.activityCode else { return false }
        return catalogue.first { $0.code == code }?.freeText == true
    }

    // MARK: - Duration

    private var duration: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            LogSectionHeading("Duration")

            LazyVGrid(columns: durationColumns, spacing: EvaSpacing.xs) {
                ForEach(LogSportDraft.durationPresets, id: \.self) { minutes in
                    ChipToggleButton(
                        label: Self.minutesLabel(minutes),
                        isSelected: draft.durationMin == minutes,
                        isCentered: true
                    ) {
                        draft.durationMin = minutes
                    }
                }
            }

            HStack(spacing: EvaSpacing.sm) {
                Text("Custom")
                    .evaTextStyle(.control)
                    .foregroundStyle(Color.evaSecondaryText)
                Spacer(minLength: EvaSpacing.xs)
                stepper(
                    "minus", label: "Decrease duration",
                    isEnabled: draft.durationMin > LogSportDraft.durationRange.lowerBound
                ) {
                    draft.adjustDuration(by: -LogSportDraft.durationStep)
                }
                Text(Self.minutesLabel(draft.durationMin))
                    .evaTextStyle(.button)
                    .foregroundStyle(Color.evaPrimaryText)
                    .frame(minWidth: LogSportMetrics.durationReadoutWidth)
                    .contentTransition(.numericText(value: Double(draft.durationMin)))
                    .accessibilityIdentifier("log.sport.duration")
                stepper(
                    "plus", label: "Increase duration",
                    isEnabled: draft.durationMin < LogSportDraft.durationRange.upperBound
                ) {
                    draft.adjustDuration(by: LogSportDraft.durationStep)
                }
            }
            .padding(.leading, EvaSpacing.md)
            .padding(.trailing, EvaSpacing.xs)
            .padding(.vertical, EvaSpacing.xs)
            .background(
                Color.white.opacity(0.65),
                in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            }
            // One adjustable element for VoiceOver, so the value can be changed by swipe
            // rather than by finding two 44pt buttons.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Duration")
            .accessibilityValue(Self.minutesLabel(draft.durationMin))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: draft.adjustDuration(by: LogSportDraft.durationStep)
                case .decrement: draft.adjustDuration(by: -LogSportDraft.durationStep)
                @unknown default: break
                }
            }
        }
    }

    private func stepper(
        _ symbol: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.evaControlText)
                .foregroundStyle(isEnabled ? Color.evaSecondaryText : Color.evaDisabledText)
                .frame(
                    width: EvaMetrics.minimumTouchTarget,
                    height: EvaMetrics.minimumTouchTarget
                )
                .background(
                    Color.white.opacity(0.8),
                    in: .rect(cornerRadius: EvaRadius.destructiveRow, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: EvaRadius.destructiveRow, style: .continuous
                    )
                    .strokeBorder(Color.evaControlBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.evaUndimmed)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier("log.sport.\(symbol)")
    }

    /// "45 min" in the user's own locale, the way `CalendarEntryPresentation` writes a
    /// logged duration — so the chip, the readout and the day list all agree.
    static func minutesLabel(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    // MARK: - Intensity

    private var intensity: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            LogSectionHeading("Intensity")
            ForEach(EvaSportIntensity.allCases, id: \.self) { option in
                intensityRow(option)
            }
        }
    }

    private func intensityRow(_ option: EvaSportIntensity) -> some View {
        let isSelected = draft.intensity == option
        return Button {
            draft.intensity = option
        } label: {
            HStack(spacing: EvaSpacing.sm) {
                // §6's radio: 20pt, filled to a 6pt ring when chosen.
                Circle()
                    .fill(Color.evaTextOnDark)
                    .overlay {
                        Circle().strokeBorder(
                            isSelected ? Color.evaDeepPink : Color.evaPrimaryText.opacity(0.25),
                            lineWidth: isSelected ? LogSportMetrics.radioRingWidth : 1.5
                        )
                    }
                    .frame(width: LogSportMetrics.radioSize, height: LogSportMetrics.radioSize)

                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text(option.label)
                        .evaTextStyle(.control)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text(option.effortDescription)
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, EvaSpacing.md)
            .padding(.vertical, EvaSpacing.xs)
            .frame(minHeight: LogSportMetrics.intensityRowHeight)
            .background(
                isSelected ? Color.evaPrimaryPink.opacity(0.14) : Color.white.opacity(0.65),
                in: .rect(cornerRadius: EvaRadius.banner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.evaDeepPink.opacity(0.45) : Color.white.opacity(0.9),
                        lineWidth: 1
                    )
            }
            .contentShape(.rect(cornerRadius: EvaRadius.banner, style: .continuous))
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("log.intensity.\(option.rawValue)")
    }
}

extension EvaSportIntensity {

    var label: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .hard: "Hard"
        }
    }

    /// The artboard's descriptions — an effort the user can check against how it felt,
    /// rather than a number she has to translate. §8: describe, do not score.
    var effortDescription: String {
        switch self {
        case .light: "Easy pace — you could hold a conversation"
        case .medium: "Breathing harder — short sentences only"
        case .hard: "Near maximum — you cannot talk"
        }
    }
}

enum LogSportMetrics {
    /// Wide enough for "1 hr 30 min" in the longest locale form.
    static let durationChipWidth: CGFloat = 92
    /// `min-width:64px` on the custom readout.
    static let durationReadoutWidth: CGFloat = 72
    /// `min-height:60px` on an intensity row.
    static let intensityRowHeight: CGFloat = 60
    /// `width:20px;height:20px`, `border:6px solid` when chosen (§6's radio row).
    static let radioSize: CGFloat = 20
    static let radioRingWidth: CGFloat = 6
}

#Preview("Log sport") {
    @Previewable @State var draft = LogSportDraft()

    return ScrollView {
        LogSportStep(
            draft: $draft,
            day: EvaDay(year: 2026, month: 8, day: 12),
            catalogue: [
                EvaRefData.Item(code: "walking", label: "Walking"),
                EvaRefData.Item(code: "yoga", label: "Yoga"),
                EvaRefData.Item(code: "hiit", label: "HIIT"),
                EvaRefData.Item(code: "other", label: "Other", freeText: true)
            ],
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

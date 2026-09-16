import SwiftUI

/// The canvas' `body` sheet: three five-point scales, the symptom chips, and a note.
///
/// **Nothing is preselected, and the subtitle says so.** An unanswered rating is not a 3 —
/// the API stores it as absent — and a sheet that opened with three middles would put
/// numbers nobody entered into a health record every time someone logged a single symptom.
///
/// **The chips come from `/refdata` and nowhere else.** Their codes are validated
/// server-side (`UNKNOWN_SYMPTOM_CODE`), their labels can be corrected without an app
/// release, and a retired one still resolves for an entry that already carries it. So this
/// file contains no symptom, no label and no value: if the catalogue has not arrived, it
/// says that instead of inventing a vocabulary the route would refuse.
struct LogBodySignalsStep: View {

    @Binding var draft: LogBodySignalsDraft
    let day: EvaDay
    /// `/refdata`'s active symptoms, already in catalogue order.
    let catalogue: [EvaRefData.Item]
    let isEditing: Bool
    let isSaving: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let save: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: LogBodySignalsMetrics.chipMinimumWidth), spacing: EvaSpacing.xs)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            LogStepHeader(
                title: CalendarEntryPresentation.typeName(for: .bodySignals),
                subtitle: "\(day.shortLabel) · nothing preselected",
                back: back,
                close: close
            )

            VStack(spacing: EvaSpacing.sm) {
                ForEach(EvaBodySignalScale.allCases, id: \.self) { scale in
                    EvaRatingScale(
                        label: scale.label,
                        words: scale.words,
                        glyphs: scale.glyphs,
                        lowAnchor: scale.lowAnchor,
                        highAnchor: scale.highAnchor,
                        ink: scale.ink,
                        tint: scale.tint,
                        border: scale.border,
                        selection: binding(for: scale)
                    )
                }
            }

            symptoms

            LogNoteField(note: $draft.note, identifier: "log.bodySignals.note")

            HStack(spacing: EvaSpacing.xs) {
                SecondaryButton(title: "Clear") { draft = LogBodySignalsDraft() }
                PrimaryButton(
                    title: isEditing ? "Save changes" : "Save",
                    isLoading: isSaving,
                    action: save
                )
                .disabled(draft.payload(in: catalogue) == nil)
            }
        }
    }

    // MARK: - Symptoms

    @ViewBuilder
    private var symptoms: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            // The artboard's heading carries the instruction, and it is only true when the
            // catalogue actually marks something severable — the second tap is per chip.
            LogSectionHeading(
                hasSeverableChip ? "Symptoms · tap twice for severe" : "Symptoms"
            )

            if catalogue.isEmpty {
                // Honest rather than empty-handed. A hard-coded fallback list would be
                // codes this build invented, and the route would refuse every one of them.
                Text("Eva couldn't load the symptom list. Everything else still saves.")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("log.symptoms.unavailable")
            } else {
                LazyVGrid(columns: columns, spacing: EvaSpacing.xs) {
                    ForEach(visibleSymptoms) { item in
                        ChipToggleButton(
                            label: item.label,
                            isSelected: draft.state(of: item.code).isOn,
                            isCentered: true,
                            isSevere: draft.state(of: item.code).isSevere
                        ) {
                            draft.tap(item)
                        }
                    }
                }
                // Addressable as a field — see the same note on the appointment sheet. This
                // one shares a sheet with the value pickers a selected chip reveals.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("log.symptoms")

                if hasMoreGroup {
                    Button {
                        draft.showsMoreSymptoms.toggle()
                    } label: {
                        Text(draft.showsMoreSymptoms ? "Show fewer" : "More…")
                            .evaTextStyle(.control)
                            .foregroundStyle(Color.evaSecondaryText)
                            .padding(.horizontal, EvaSpacing.md)
                            .frame(minHeight: EvaMetrics.minimumTouchTarget)
                            .overlay {
                                RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                                    .strokeBorder(
                                        Color.evaPrimaryText.opacity(0.2),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                                    )
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.evaUndimmed)
                    .accessibilityIdentifier("log.symptoms.more")
                }

                ForEach(valuePickers) { item in
                    valuePicker(item)
                }
            }
        }
    }

    /// The chips on screen: the primary group, plus the "More…" group once it is revealed.
    private var visibleSymptoms: [EvaRefData.Item] {
        draft.showsMoreSymptoms ? catalogue : catalogue.filter { $0.group == .primary }
    }

    private var hasMoreGroup: Bool { catalogue.contains { $0.group == .more } }

    private var hasSeverableChip: Bool { catalogue.contains(where: \.severable) }

    /// Every selected chip that has a value axis. Shown under the grid rather than in a
    /// popover, which is what the artboard draws — the choice stays visible beside the chip
    /// it belongs to, so an entry with two value chips reads as two questions rather than
    /// one that changed.
    private var valuePickers: [EvaRefData.Item] {
        visibleSymptoms.filter { $0.values != nil && draft.state(of: $0.code).isOn }
    }

    private func valuePicker(_ item: EvaRefData.Item) -> some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            Text(item.label)
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)

            LazyVGrid(columns: columns, spacing: EvaSpacing.xs) {
                ForEach(item.values ?? [], id: \.self) { value in
                    ChipToggleButton(
                        label: EvaRefData.valueLabel(value),
                        isSelected: draft.state(of: item.code).value == value,
                        isCentered: true
                    ) {
                        draft.choose(value, for: item.code)
                    }
                }
            }
        }
        .padding(EvaSpacing.sm)
        .background(
            Color.white.opacity(0.66),
            in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
        }
        .accessibilityIdentifier("log.symptomValues.\(item.code)")
    }

    private func binding(for scale: EvaBodySignalScale) -> Binding<Int?> {
        switch scale {
        case .energy: $draft.energy
        case .mood: $draft.mood
        case .sleep: $draft.sleep
        }
    }
}

enum LogBodySignalsMetrics {
    /// Wide enough for "Breast tenderness" to reach two lines rather than four, and narrow
    /// enough for three short chips on a 390pt frame. The artboard flow-wraps chips at
    /// their natural width, which `ChipToggleButton` cannot do — it is full-width by
    /// design, so the grid decides the column instead (see `GoalsStepView`, same pattern).
    static let chipMinimumWidth: CGFloat = 104
}

// MARK: - How a scale looks

extension EvaBodySignalScale {

    /// The artboard's emoji row for this scale, or `nil` for one drawn as graduated dots.
    var glyphs: [String]? {
        switch self {
        case .energy: ["😴", "🥱", "😐", "🙂", "⚡"]
        case .mood: ["😢", "😕", "😐", "🙂", "😄"]
        case .sleep: ["😩", "😪", "😶", "😌", "💤"]
        }
    }

    /// The words under the two ends. Not `words.first`/`words.last`: the artboard anchors
    /// Energy with "Depleted … Energized" where its fifth word is "High".
    var lowAnchor: String {
        switch self {
        case .energy: "Depleted"
        case .mood: "Low"
        case .sleep: "Restless"
        }
    }

    var highAnchor: String {
        switch self {
        case .energy: "Energized"
        case .mood: "Bright"
        case .sleep: "Deep"
        }
    }

    /// The readout's ink and the selected cell's outline.
    ///
    /// Two of the three are the nearest named token rather than the artboard's literal, the
    /// same rounding DESIGN.md §9a records for the mode chip: `evaActionPinkSolid`
    /// (`#A94A6C`) for the artboard's `#A9436E`, and `evaSuccessInk` (`#4F6630`) for
    /// `#5C7434`. Sleep's `evaInformationInk` is the artboard's own `#3F5A76`.
    var ink: Color {
        switch self {
        case .energy: .evaActionPinkSolid
        case .mood: .evaSuccessInk
        case .sleep: .evaInformationInk
        }
    }

    /// `linear-gradient(150deg, …)` behind the cells.
    var tint: LinearGradient {
        switch self {
        case .energy:
            EvaRatingScaleMetrics.tint(
                .evaPrimaryPink.opacity(0.22), .evaPrimaryPink.opacity(0.08)
            )
        case .mood:
            EvaRatingScaleMetrics.tint(
                .evaPistachio.opacity(0.42), .evaPistachio.opacity(0.14)
            )
        case .sleep:
            EvaRatingScaleMetrics.tint(
                .evaInformation.opacity(0.20), .evaInformation.opacity(0.06)
            )
        }
    }

    var border: Color {
        switch self {
        case .energy: .evaDeepPink.opacity(0.28)
        case .mood: .evaDeepPistachio.opacity(0.34)
        case .sleep: .evaInformation.opacity(0.28)
        }
    }
}

#Preview("Log body signals") {
    @Previewable @State var draft = LogBodySignalsDraft(energy: 2, sleep: 4)

    return ScrollView {
        LogBodySignalsStep(
            draft: $draft,
            day: EvaDay(year: 2026, month: 8, day: 12),
            catalogue: [
                EvaRefData.Item(code: "bloating", label: "Bloating"),
                EvaRefData.Item(code: "cramps", label: "Cramps", severable: true),
                EvaRefData.Item(code: "headache", label: "Headache", severable: true),
                EvaRefData.Item(code: "cravings", label: "Cravings"),
                EvaRefData.Item(
                    code: "discharge", label: "Discharge", group: .more,
                    values: ["dry", "sticky", "creamy", "watery", "egg-white"]
                )
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

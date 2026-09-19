import SwiftUI

/// The shared frame the Profile personalisation editors are drawn in: a title over
/// scrollable content, with a Save that re-sends the whole profile.
///
/// Every editor is the same shape — title, one field group, one Save — because #19 kept
/// `PUT /me/questionnaire` as the bulk write. Each Save re-sends the full profile, so an
/// edit in one row carries the untouched rest of the profile along with it.
struct ProfileEditorScreen<Content: View>: View {

    let editor: ProfileEditorModel
    let session: AppSession
    let title: String
    var subtitle: String? = nil
    let buttonTitle: String
    /// Holds Save while the editor's own rule is unmet (18+ floor, medication answered).
    var isSaveEnabled: Bool = true
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.md) {
                    Text(title)
                        .evaTextStyle(.h1)
                        .foregroundStyle(Color.evaPrimaryText)

                    if let subtitle {
                        Text(subtitle)
                            .evaTextStyle(.body)
                            .foregroundStyle(Color.evaSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    content

                    if let errorMessage {
                        Text(errorMessage)
                            .evaTextStyle(.error)
                            .foregroundStyle(Color.evaErrorInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryButton(title: buttonTitle, isLoading: isSaving, action: save)
                        .disabled(!isSaveEnabled)
                        .padding(.top, EvaSpacing.sm)
                }
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.xs)
                .padding(.bottom, EvaSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await session.submitQuestionnaire(editor.profilePayload)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// Personal profile ▸ Body measurements — date of birth, height and weight (#19).
///
/// Reuses the questionnaire's body-metric cards, which wear the legacy styling DESIGN.md
/// §9 keeps on them. The canvas draws no body-measurements editor, so the existing
/// controls stand rather than an invented one.
struct BodyMeasurementsSettingsView: View {

    @Bindable var editor: ProfileEditorModel
    let units: EvaUnitPreference
    let session: AppSession

    var body: some View {
        ProfileEditorScreen(
            editor: editor,
            session: session,
            title: "Body measurements",
            subtitle: "Eva uses these to make what you see about you.",
            buttonTitle: "Save",
            isSaveEnabled: editor.isOldEnough
        ) {
            VStack(spacing: EvaSpacing.sm) {
                DateOfBirthCard(value: $editor.dateOfBirth, errorMessage: editor.dateOfBirthError)
                WeightEntryCard(kilograms: $editor.weightKg, system: units.system)
                HeightEntryCard(centimeters: $editor.heightCm, system: units.system)
            }
            .padding(.top, EvaSpacing.xs)
        }
    }
}

/// Personal profile ▸ Goals — what she wants to improve (#19). Multi-select, two columns.
struct GoalsSettingsView: View {

    @Bindable var editor: ProfileEditorModel
    let session: AppSession

    private let columns = [GridItem(.flexible(), spacing: EvaSpacing.sm), GridItem(.flexible(), spacing: EvaSpacing.sm)]

    var body: some View {
        ProfileEditorScreen(
            editor: editor,
            session: session,
            title: "Goals",
            subtitle: "Choose all that matter to you.",
            buttonTitle: "Save"
        ) {
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                ForEach(ProfileEditorModel.goalOptions, id: \.self) { goal in
                    ChipToggleButton(
                        label: goal,
                        isSelected: editor.goals.contains(goal),
                        isCentered: true
                    ) {
                        if editor.goals.contains(goal) {
                            editor.goals.remove(goal)
                        } else {
                            editor.goals.insert(goal)
                        }
                    }
                }
            }
            .padding(.top, EvaSpacing.xs)
        }
    }
}

/// Personal profile ▸ Activity — how active her day-to-day is (#19). One of four.
struct ActivitySettingsView: View {

    @Bindable var editor: ProfileEditorModel
    let session: AppSession

    var body: some View {
        ProfileEditorScreen(
            editor: editor,
            session: session,
            title: "Activity",
            subtitle: "How active is your day-to-day?",
            buttonTitle: "Save"
        ) {
            VStack(spacing: EvaSpacing.sm) {
                ForEach(ProfileEditorModel.lifestyleOptions, id: \.self) { option in
                    ChipToggleButton(
                        label: option,
                        isSelected: editor.lifestyle == option
                    ) {
                        editor.lifestyle = option
                    }
                }
            }
            .padding(.top, EvaSpacing.xs)
        }
    }
}

/// Personal profile ▸ Preferred sports (#19). Multi-select, two columns.
struct SportsSettingsView: View {

    @Bindable var editor: ProfileEditorModel
    let session: AppSession

    private let columns = [GridItem(.flexible(), spacing: EvaSpacing.sm), GridItem(.flexible(), spacing: EvaSpacing.sm)]

    var body: some View {
        ProfileEditorScreen(
            editor: editor,
            session: session,
            title: "Preferred sports",
            subtitle: "Choose the ones you like.",
            buttonTitle: "Save"
        ) {
            LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                ForEach(ProfileEditorModel.sportOptions, id: \.self) { sport in
                    ChipToggleButton(
                        label: sport,
                        isSelected: editor.sports.contains(sport),
                        isCentered: true
                    ) {
                        if editor.sports.contains(sport) {
                            editor.sports.remove(sport)
                        } else {
                            editor.sports.insert(sport)
                        }
                    }
                }
            }
            .padding(.top, EvaSpacing.xs)
        }
    }
}

/// Personal profile ▸ Health information — conditions (#19). Multi-select, with "None of
/// these" exclusive in both directions.
struct HealthSettingsView: View {

    @Bindable var editor: ProfileEditorModel
    let session: AppSession

    var body: some View {
        ProfileEditorScreen(
            editor: editor,
            session: session,
            title: "Health information",
            subtitle: "Any conditions we should know about? Eva never diagnoses and never shares this.",
            buttonTitle: "Save"
        ) {
            VStack(spacing: EvaSpacing.sm) {
                ForEach(ProfileEditorModel.conditionOptions) { condition in
                    ChipToggleButton(
                        label: condition.label,
                        isSelected: editor.conditions.contains(condition.code)
                    ) {
                        toggleCondition(condition.code)
                    }
                }
            }
            .padding(.top, EvaSpacing.xs)
        }
    }

    /// "None of these" is exclusive in both directions: choosing it clears the rest, and
    /// choosing anything else clears it.
    private static let noConditions = "noneOfThese"

    private func toggleCondition(_ code: String) {
        if editor.conditions.contains(code) {
            editor.conditions.remove(code)
        } else if code == Self.noConditions {
            editor.conditions = [code]
        } else {
            editor.conditions.remove(Self.noConditions)
            editor.conditions.insert(code)
        }
    }
}

/// Personal profile ▸ Hormonal medications (#19). One of a closed list that ends in None.
struct MedicationsSettingsView: View {

    @Bindable var editor: ProfileEditorModel
    let session: AppSession

    private let columns = [GridItem(.flexible(), spacing: EvaSpacing.sm), GridItem(.flexible(), spacing: EvaSpacing.sm)]

    var body: some View {
        ProfileEditorScreen(
            editor: editor,
            session: session,
            title: "Hormonal medications",
            subtitle: "Do you take any hormonal medication?",
            buttonTitle: "Save",
            isSaveEnabled: editor.hasMedicationAnswer
        ) {
            VStack(alignment: .leading, spacing: EvaSpacing.sm) {
                LazyVGrid(columns: columns, spacing: EvaSpacing.sm) {
                    ForEach(ProfileEditorModel.medicationOptions) { option in
                        ChipToggleButton(
                            label: option.label,
                            isSelected: editor.medications == option.code,
                            isCentered: true
                        ) {
                            editor.medications = option.code
                        }
                    }
                }

                // The rule stated up front, the way §6's password helper states its rule —
                // rather than a refusal after Save. Recolours while unmet (DESIGN.md §2).
                HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.xxs) {
                    if !editor.hasMedicationAnswer {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.evaError)
                            .accessibilityHidden(true)
                    }
                    Text(ProfileEditorModel.medicationRule)
                        .evaTextStyle(.inputHelper)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            editor.hasMedicationAnswer
                                ? ProfileEditorModel.medicationRule
                                : "Not met yet: \(ProfileEditorModel.medicationRule)"
                        )
                        .accessibilityIdentifier("profile.medications.rule")
                }
                .foregroundStyle(
                    editor.hasMedicationAnswer ? Color.evaSecondaryText : Color.evaErrorInk
                )
            }
            .padding(.top, EvaSpacing.xs)
        }
    }
}

#Preview("Editors") {
    NavigationStack {
        BodyMeasurementsSettingsView(
            editor: ProfileEditorModel(profile: nil),
            units: EvaUnitPreference(),
            session: AppSession()
        )
    }
}

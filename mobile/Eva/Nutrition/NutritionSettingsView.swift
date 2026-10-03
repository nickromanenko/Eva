import SwiftUI

/// Nutrition Settings (canvas `nSet`, #223) — the one place the hide-numbers preference is
/// reversed.
///
/// ## How it is reached, and what it draws
///
/// The canvas opens this screen from the gear on the coach's Today header, which is not
/// built. Until it is, Profile ▸ Eva experience ▸ Nutrition Settings is the door, so the
/// screen takes Profile's detail-screen frame (an H1 over the column, as Units does) rather
/// than the artboard's 14pt bar title.
///
/// Drawn, because the API supports them:
/// * **Hide calorie numbers** — #212's one preference. The artboard draws a second switch,
///   "Qualitative guidance mode"; #212 decided they are one setting (hiding the numbers *is*
///   the full qualitative mode), so there is one switch. Its description is the setup flow's
///   own sentence: the artboard's ("Macros and food guidance stay") is not true of a mode
///   that hides the macros too.
/// * The rows the `nSet` note says deep-link to Profile — body metrics, activity, units,
///   health conditions — push Profile's own editors: one fact, one editor. While the numbers
///   are hidden, Body metrics says "Set in Profile" rather than her height and weight (owner
///   decision on #381); Profile still shows and edits them.
/// * **How targets are calculated** opens the same sheet the plan summary does.
///
/// Not drawn, because nothing behind them exists: Water tracking, Meal reminders, and the
/// Goal / Focus areas / Meal pattern rows, which the canvas sends back into setup — a "change
/// my answers" path the flow does not have.
///
/// `REVIEW`: every string here is copy awaiting sign-off.
struct NutritionSettingsView: View {

    let session: AppSession
    let units: EvaUnitPreference
    let editor: ProfileEditorModel

    @State private var model: NutritionSettingsModel
    @State private var showsCalculation = false

    init(session: AppSession, units: EvaUnitPreference, editor: ProfileEditorModel) {
        self.session = session
        self.units = units
        self.editor = editor
        _model = State(initialValue: NutritionSettingsModel(source: session))
    }

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.md) {
                    Text("Nutrition Settings")
                        .evaTextStyle(.h1)
                        .foregroundStyle(Color.evaPrimaryText)
                        .accessibilityIdentifier("nutrition.settings.title")

                    preferenceCard
                    profileRows
                    EvaInfoBanner(
                        message: "Qualitative guidance can only be turned off here — never "
                            + "from a banner or a prompt inside the app."
                    )
                }
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.xs)
                .padding(.bottom, EvaSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("nutrition.settings.scroll")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await model.load() }
        .sheet(isPresented: $showsCalculation) {
            NutritionCalculationSheet { showsCalculation = false }
        }
    }

    // MARK: - The preference

    private var preferenceCard: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            Toggle(isOn: hideNumbersBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide calorie numbers")
                        .evaTextStyle(.bodyMedium)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text("You'd still get guidance and meal logging, just without the numbers.")
                        .evaTextStyle(.inputHelper)
                        .foregroundStyle(Color.evaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.eva)
            // Inert until the server's answer is on screen, and while a change is in flight.
            .disabled(model.phase != .ready || model.isSaving)
            .accessibilityIdentifier("nutrition.settings.hideNumbers")

            if model.phase == .failed {
                HStack {
                    Text("Your settings couldn't be loaded.")
                        .evaTextStyle(.error)
                        .foregroundStyle(Color.evaErrorInk)
                    Spacer(minLength: 0)
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(EvaTextButtonStyle())
                        .accessibilityIdentifier("nutrition.settings.retry")
                }
            }
            if let error = model.errorMessage {
                Text(error)
                    .evaTextStyle(.error)
                    .foregroundStyle(Color.evaErrorInk)
                    .accessibilityIdentifier("nutrition.settings.error")
            }
        }
        .padding(.vertical, EvaSpacing.xs)
        .padding(.horizontal, EvaSpacing.md)
        .evaCardSurface()
    }

    /// The switch shows the server's value and asks the model to change it — it never holds
    /// a state of its own the account does not.
    private var hideNumbersBinding: Binding<Bool> {
        Binding(
            get: { model.hideNumbers },
            set: { hide in Task { await model.setHideNumbers(hide) } }
        )
    }

    // MARK: - Rows edited in Profile

    private var profileRows: some View {
        VStack(spacing: 0) {
            ProfileSettingsRow(
                label: "Body metrics",
                value: bodyMetricsValue,
                identifier: "nutrition.settings.bodyMetrics"
            ) {
                BodyMeasurementsSettingsView(editor: editor, units: units, session: session)
            }
            ProfileSettingsRow(
                label: "Activity level",
                value: editor.lifestyleLabel.map { "\($0) · set in Profile" } ?? "Set in Profile",
                identifier: "nutrition.settings.activity"
            ) {
                ActivitySettingsView(editor: editor, session: session)
            }
            ProfileSettingsRow(
                label: "Units",
                value: "Set in Profile",
                identifier: "nutrition.settings.units"
            ) {
                UnitsSettingsView(units: units)
            }
            ProfileSettingsRow(
                label: "Health conditions",
                value: "Set in Profile",
                identifier: "nutrition.settings.health"
            ) {
                HealthSettingsView(editor: editor, session: session)
            }
            calculationRow
        }
        .evaCardSurface()
    }

    /// "168 cm · 73 kg" in her units, or "Set in Profile" while the numbers are hidden.
    private var bodyMetricsValue: String {
        model.bodyMetricsValue(session.user?.profile, system: units.system)
    }

    /// A row that opens the sheet rather than pushing a screen — `ProfileSettingsRow`'s look,
    /// as a button.
    private var calculationRow: some View {
        Button {
            showsCalculation = true
        } label: {
            HStack(spacing: EvaSpacing.sm) {
                Text("How targets are calculated")
                    .evaTextStyle(.bodyMedium)
                    .foregroundStyle(Color.evaPrimaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.evaDisabledText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, EvaSpacing.xs)
            .padding(.horizontal, EvaSpacing.md)
            .frame(maxWidth: .infinity, minHeight: EvaControl.height)
            .contentShape(.rect)
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier("nutrition.settings.calculation")
    }
}

#Preview("Nutrition Settings") {
    NavigationStack {
        NutritionSettingsView(
            session: AppSession(),
            units: EvaUnitPreference(),
            editor: ProfileEditorModel(profile: nil)
        )
    }
}

import SwiftUI

/// The Nutrition coach's setup flow (S3, #223): five steps, the guard cards, and the plan
/// summary, drawn from `docs/design/Eva Nutrition Coach.dc.html` (rail `s1`–`s5`, `sGuard`,
/// `sCap`, `sRate`, `sPreg`, `sSum`, sheet `why`).
///
/// **Copy is a draft.** The goal options' wording, the four guard cards and the hide-numbers
/// question are the most delicate copy in the product (the issue's own risks); they are
/// marked `REVIEW` and must be signed off by a human before this ships. Tokens only
/// (GUARDRAILS 20), a stable `accessibilityIdentifier` on every interactive element
/// (GUARDRAILS 22).
///
/// **One qualitative mode** (#212, A31). Hiding the numbers and A28's Pregnancy/postpartum
/// mode both reach `NutritionSummary.qualitative`, whose type carries no numeric field —
/// a screen that forgets to hide the numbers cannot hide them.
struct NutritionSetupView: View {
    @State private var model: NutritionSetupModel

    /// `units` defaults to the app's own setting — Step 4 confirms her metrics in it and
    /// Step 5 takes the target in it (#82).
    init(session: AppSession, units: EvaUnitPreference = .shared) {
        #if DEBUG
        // `EVA_NUTRITION_PLAN` seeds the plan only; answers still go to the API.
        let source: any NutritionSource = EvaNutritionPlanLaunch.source(wrapping: session) ?? session
        #else
        let source: any NutritionSource = session
        #endif
        _model = State(initialValue: NutritionSetupModel(source: source, units: units))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                    switch model.phase {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    case .failed:
                        retry
                    case .editing:
                        stepHeader
                        stepContent
                        if let error = model.errorMessage {
                            Text(error)
                                .evaTextStyle(.error)
                                .foregroundStyle(Color.evaErrorInk)
                                .accessibilityIdentifier("nutrition.error")
                        }
                    case .summary:
                        summary
                    }
                }
                .padding(EvaSpacing.lg)
            }
            // A number pad has no return key; scrolling is how the keyboard gets out of the
            // way of "See my plan".
            .scrollDismissesKeyboard(.immediately)
            // The flow is a sheet over Home, whose column is a scroll view too.
            .accessibilityIdentifier("nutrition.scroll")
            .background(Color.evaWarmBackground)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if model.phase == .editing, model.step != .goal {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { model.back() }
                            .accessibilityIdentifier("nutrition.back")
                    }
                }
            }
        }
        .task { await model.load() }
    }

    // MARK: - The current step

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .goal: goalStep
        case .focusAreas: focusAreasStep
        case .mealPattern: mealPatternStep
        case .bodyMetrics: bodyMetricsStep
        case .targetWeight: targetWeightStep
        case .done: EmptyView()
        }
    }

    /// "Step 1 of 5" — progress stated, never a completion percentage ("x of y steps" is the
    /// one framing `SPEC.home_setup` forbids for the setup card).
    private var stepHeader: some View {
        Text("Step \(model.step.ordinal) of 5")
            .evaTextStyle(.overline)
            .foregroundStyle(Color.evaSecondaryText)
            .accessibilityIdentifier("nutrition.step")
    }

    private var retry: some View {
        VStack(spacing: EvaSpacing.md) {
            Text("Your setup couldn't be loaded.")
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaPrimaryText)
            PrimaryButton(title: "Try again") {
                Task { await model.load() }
            }
        }
    }

    // MARK: - Step 1 · Goal

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("What would you like to focus on?")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.goal.title")
            ForEach(APINutritionGoal.allCases, id: \.self) { goal in
                EvaRadioRow(
                    title: goal.title,
                    detail: goal.detail,
                    isSelected: model.profile?.goal == goal
                ) {
                    Task { await model.choose(goal) }
                }
                .accessibilityIdentifier("nutrition.goal.\(goal.rawValue)")
            }
        }
    }

    // MARK: - Step 2 · Focus areas

    private var focusAreasStep: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("What matters most to you?")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.focus.title")
            Text("Choose up to three. The rest stay available, not removed.")
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaSecondaryText)
            ForEach(NutritionFocusArea.all, id: \.code) { area in
                ChipToggleButton(
                    label: area.label,
                    isSelected: model.selectedFocusAreas.contains(area.code),
                    isDisabled: model.isFocusAreaDisabled(area.code)
                ) {
                    model.toggleFocusArea(area.code)
                }
                // By code, so a test survives the labels' review (`REVIEW` below).
                .accessibilityIdentifier("nutrition.focus.\(area.code)")
            }
            // Optional (PRD Step 2): Continue with none chosen is an answer too.
            PrimaryButton(title: "Continue") {
                Task { await model.advance() }
            }
            .accessibilityIdentifier("nutrition.focus.continue")
        }
    }

    // MARK: - Step 3 · Meal pattern

    private var mealPatternStep: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("How many meals a day?")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.meals.title")
            ForEach([2, 3, 4, 5], id: \.self) { count in
                EvaRadioRow(
                    title: "\(count) meals",
                    detail: "",
                    isSelected: model.profile?.mealPattern?.mealsPerDay == count
                ) {
                    Task { await model.chooseMeals(count) }
                }
                .accessibilityIdentifier("nutrition.meals.\(count)")
            }
        }
    }

    // MARK: - Step 4 · Body metrics (confirmation)

    private var bodyMetricsStep: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Is this still you?")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.body.title")
            Text(
                "\(model.heightText) · \(model.weightText) · \(model.bandText)"
            )
            .evaTextStyle(.body)
            .foregroundStyle(Color.evaSecondaryText)
            .accessibilityIdentifier("nutrition.body.metrics")
            // Goals 4 and 5 end here (Step 5 is skipped), so the preference is asked here.
            if model.isFinalStep {
                hideNumbersToggle
            }
            PrimaryButton(title: "That's me") {
                Task { await model.advance() }
            }
            .accessibilityIdentifier("nutrition.body.confirm")
            TextButton(title: "Edit in Profile") {
                model.editInProfile()
            }
        }
    }

    // MARK: - Step 5 · Target weight

    private var targetWeightStep: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Where would you like to be?")
                .evaTextStyle(.h3)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.target.title")
            if let current = model.currentWeightText {
                Text("Current: \(current)")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
                    .accessibilityIdentifier("nutrition.target.current")
            }
            // One field per unit the setting asks for — stones *and* pounds are two (#82).
            HStack(alignment: .top, spacing: EvaSpacing.xs) {
                ForEach(model.targetEntry.rows, id: \.self) { row in
                    targetField(row)
                }
            }
            if let refusal = model.refusal {
                guardCard(refusal)
            }
            PrimaryButton(title: "See my plan", showsArrow: true) {
                Task { await model.finish() }
            }
            .disabled(!model.canFinish)
            .accessibilityIdentifier("nutrition.target.finish")
            // The hide-numbers preference is asked on the path, not only in Settings (#212).
            hideNumbersToggle
        }
    }

    /// One entry field of the target, in its row's unit. Whole units for pounds and stones,
    /// as the Profile editor takes them; a decimal for kilograms, the canonical unit.
    private func targetField(_ row: EvaMassInput.Row) -> some View {
        let text: Binding<String> = switch row {
        case .kilograms: $model.targetEntry.kilogramsText
        case .stones: $model.targetEntry.stonesText
        case .pounds: $model.targetEntry.poundsText
        }
        return EvaInputField(label: "Target weight (\(row.unit))", placeholder: row == .kilograms ? "e.g. 62" : "") { prompt in
            TextField("Target weight, \(row.spokenUnit)", text: text, prompt: prompt)
                .keyboardType(row == .kilograms ? .decimalPad : .numberPad)
                .accessibilityIdentifier("nutrition.target.\(row.rawValue)")
        }
    }

    /// The guard card (canvas `sGuard` / `sCap`): a message **and** an offered value, and the
    /// field stays editable — Eva never locks it, and never implies a diagnosis from a single
    /// input. `REVIEW`: copy.
    private func guardCard(_ refusal: APINutritionRefusal) -> some View {
        HStack(spacing: EvaSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.evaInformationInk)
            Text(refusal.message)
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaInformationInk)
                .accessibilityIdentifier("nutrition.guard.message")
            Spacer(minLength: 0)
            // The offered value in her units, rounded so it clears the guard (#82).
            Button("Use \(model.offeredText(refusal))") {
                model.useOffered(refusal)
            }
            .buttonStyle(EvaTextButtonStyle())
            .accessibilityIdentifier("nutrition.guard.offer")
        }
        .padding(EvaSpacing.sm)
        .background(Color.evaInformationTint, in: .rect(cornerRadius: EvaRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nutrition.guard")
    }

    private var hideNumbersToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $model.hideNumbers) {
                Text("Would you rather not see calorie numbers?")
                    .evaTextStyle(.control)
                    .foregroundStyle(Color.evaPrimaryText)
            }
            .accessibilityIdentifier("nutrition.hideNumbers")
            Text("You'd still get guidance and meal logging, just without the numbers.")
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaSecondaryText)
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            Text("Your plan")
                .evaTextStyle(.h2)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.summary.title")

            switch model.summary {
            case .numbers(let numbers):
                VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                    Text("\(numbers.calorieTargetKcal, specifier: "%.0f") kcal a day")
                        .evaTextStyle(.h3)
                        .foregroundStyle(Color.evaPrimaryText)
                    Text(
                        String(
                            format: "%.0f g protein · %.0f g fat · %.0f g carbs",
                            numbers.proteinG, numbers.fatG, numbers.carbG
                        )
                    )
                    .evaTextStyle(.body)
                    .foregroundStyle(Color.evaSecondaryText)
                    if let weeks = numbers.timelineWeeks {
                        Text("About \(weeks) weeks to your goal.")
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaSecondaryText)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nutrition.summary.numbers")
            case .qualitative(let qualitative):
                VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                    Text(qualitative.goal.title)
                        .evaTextStyle(.h3)
                        .foregroundStyle(Color.evaPrimaryText)
                    ForEach(qualitative.guidance, id: \.self) { line in
                        Text(line)
                            .evaTextStyle(.body)
                            .foregroundStyle(Color.evaSecondaryText)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nutrition.summary.qualitative")
            }

            Button("How this is calculated") {
                model.showCalculation = true
            }
            .buttonStyle(EvaTextButtonStyle())
            .accessibilityIdentifier("nutrition.howCalculated")

            // The dietitian disclaimer appears once, here, not on every screen (canvas `sSum`).
            Text("Plans are reviewed by a registered dietitian and are a guide, not advice.")
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
        }
        .sheet(isPresented: $model.showCalculation) {
            calculationSheet
        }
    }

    /// The "How this is calculated" sheet — one of the two mechanisms GUARDRAILS 35 names for
    /// keeping a computed number inside the wellness line. `REVIEW`: copy.
    private var calculationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EvaSpacing.md) {
                Text("How this is calculated")
                    .evaTextStyle(.h2)
                    .foregroundStyle(Color.evaPrimaryText)
                Text(
                    "Your daily target starts from an estimate of your resting energy use "
                        + "(the Mifflin-St Jeor equation), adjusted for your activity and your "
                        + "goal. During your luteal phase it is raised slightly, and it is "
                        + "clamped so it never falls below what your body needs."
                )
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                TextButton(title: "Done") { model.showCalculation = false }
            }
            .padding(EvaSpacing.lg)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Copy (draft, `REVIEW`)

extension APINutritionGoal {
    /// `REVIEW`: the five goal options' titles and descriptions.
    var title: String {
        switch self {
        case .lose: "Lose weight"
        case .gain: "Gain weight"
        case .buildMuscle: "Build muscle"
        case .maintain: "Maintain my weight"
        case .eatBetter: "Eat better without changing my weight"
        }
    }

    var detail: String {
        switch self {
        case .lose: "A steady, gentle deficit."
        case .gain: "Grow stronger, not just heavier."
        case .buildMuscle: "More protein, more strength."
        case .maintain: "Keep your weight where it is."
        case .eatBetter: "Better habits, without a scale."
        }
    }
}

extension APINutritionRefusal {
    /// `REVIEW`: the guard card's message — states the rule, never implies a diagnosis.
    var message: String {
        switch reason {
        case "below-bmi-floor":
            "A target below that is under a healthy weight for your height."
        default:
            "That's more than this plan can reach in one step."
        }
    }
}

/// The focus areas (PRD Step 2), with their labels. `REVIEW`: labels.
struct NutritionFocusArea {
    let code: String
    let label: String

    static let all: [NutritionFocusArea] = [
        NutritionFocusArea(code: "vegetablesAndFibre", label: "Vegetables and fibre"),
        NutritionFocusArea(code: "lessUltraProcessed", label: "Less fast food"),
        NutritionFocusArea(code: "ironDeficiencyAnaemia", label: "Iron"),
        NutritionFocusArea(code: "moreProtein", label: "More protein"),
        NutritionFocusArea(code: "lessSugar", label: "Less sugar"),
        NutritionFocusArea(code: "regularMeals", label: "More regular meals"),
        NutritionFocusArea(code: "moreWater", label: "More water"),
        NutritionFocusArea(code: "lessCaffeine", label: "Less caffeine"),
        NutritionFocusArea(code: "lessAlcohol", label: "Less alcohol"),
        NutritionFocusArea(code: "boneHealth", label: "Bone health"),
        NutritionFocusArea(code: "digestion", label: "Digestion"),
        NutritionFocusArea(code: "pmsCravings", label: "PMS cravings"),
        NutritionFocusArea(code: "eatEnoughOnPeriod", label: "Eat enough on my period"),
        NutritionFocusArea(code: "lessSalt", label: "Less salt"),
        NutritionFocusArea(code: "vegetarianVeganBalance", label: "Vegetarian or vegan"),
        NutritionFocusArea(code: "steadyEnergy", label: "Steady energy"),
        NutritionFocusArea(code: "skin", label: "Skin"),
    ]
}

extension SetupStep {
    var ordinal: Int {
        switch self {
        case .goal: 1
        case .focusAreas: 2
        case .mealPattern: 3
        case .bodyMetrics: 4
        case .targetWeight: 5
        case .done: 5
        }
    }
}

#Preview("Setup flow") {
    NutritionSetupView(session: AppSession())
}

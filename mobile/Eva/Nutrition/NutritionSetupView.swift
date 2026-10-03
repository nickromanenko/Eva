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
                    case .resuming:
                        resumeCard
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

    // MARK: - Step 4 · Confirm your details (canvas `s4`)

    /// Her Sign Up metrics, confirmed rather than re-asked: height and weight in her units,
    /// age from her date of birth, and her activity band among the four. All of it is edited
    /// in Profile — one fact, one editor (canvas `nSet` note) — so nothing here takes input.
    ///
    /// Not drawn: the artboard's pistachio note that logged Calendar workouts refine the
    /// band. PRD trigger 5 — logged activity shifting the band — does not exist yet
    /// (`nutrition-adjustment.ts`' `PlanBasis`), and the screen would be promising it.
    private var bodyMetricsStep: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Confirm your details")
                .evaTextStyle(.h1)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.body.title")
            // `REVIEW`: new string, the canvas' own.
            Text("From your Eva profile. Units follow your account setting.")
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: EvaSpacing.xs) {
                profileField("Height", value: model.heightText, identifier: "nutrition.body.height")
                profileField(
                    "Current weight", value: model.weightText, identifier: "nutrition.body.weight"
                )
            }

            ageRow

            HStack(alignment: .firstTextBaseline) {
                Text("Activity level")
                    .evaTextStyle(.label)
                    .foregroundStyle(Color.evaSecondaryText)
                Spacer(minLength: EvaSpacing.xs)
                // `REVIEW`: new string, the canvas' own.
                Text("From your profile — change it there")
                    .evaTextStyle(.caption)
                    .foregroundStyle(Color.evaSecondaryText)
            }
            .padding(.top, EvaSpacing.xs)

            VStack(spacing: EvaSpacing.xs) {
                ForEach(ProfileEditorModel.lifestyleOptions, id: \.code) { option in
                    EvaRadioRow(
                        title: option.label,
                        detail: Self.activityDetail[option.code] ?? "",
                        isSelected: model.bandCode == option.code
                    ) {}
                    // Read here, changed in Profile ▸ Activity — the same band the plan uses.
                    .disabled(true)
                    .accessibilityIdentifier("nutrition.body.activity.\(option.code)")
                }
            }

            // Goals 4 and 5 end here (Step 5 is skipped), so the preference is asked here.
            if model.isFinalStep {
                hideNumbersToggle
            }
            PrimaryButton(title: "Confirm details") {
                Task { await model.advance() }
            }
            .accessibilityIdentifier("nutrition.body.confirm")
        }
    }

    /// One read-only value in the §6 input's disabled treatment — the canvas draws Step 5's
    /// "Current" the same way, for the same reason: the value is shown, not taken.
    private func profileField(_ label: String, value: String, identifier: String) -> some View {
        EvaInputField(label: label, placeholder: "") { prompt in
            TextField(label, text: .constant(value), prompt: prompt)
                .accessibilityIdentifier(identifier)
        }
        .disabled(true)
        .frame(maxWidth: .infinity)
    }

    /// "Age · 32 · from your profile" — the artboard's quiet row, never a question.
    private var ageRow: some View {
        HStack {
            Text("Age")
                .evaTextStyle(.control)
                .foregroundStyle(Color.evaSecondaryText)
            Spacer(minLength: EvaSpacing.xs)
            // `REVIEW`: new string, the canvas' own.
            Text(model.ageYears.map { "\($0) · from your profile" } ?? "Not set in your profile")
                .evaTextStyle(.control)
                .foregroundStyle(Color.evaSecondaryText)
        }
        .padding(.horizontal, EvaSpacing.md)
        .frame(maxWidth: .infinity, minHeight: EvaControl.height)
        .background(
            Color.evaInputFillDisabled,
            in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.control, style: .continuous)
                .strokeBorder(Color.evaInputBorderDisabled, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nutrition.body.age")
    }

    /// The canvas' `ACTS` descriptions, by band code. `REVIEW`: new strings, the canvas' own.
    private static let activityDetail: [String: String] = [
        "mostlySitting": "Mostly seated with little regular exercise.",
        "lightlyActive": "Light activity or exercise around 1–3 times per week.",
        "active": "Moderate exercise around 3–5 times per week.",
        "veryActive": "Hard exercise most days.",
    ]

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
    /// input. §2's Warning family: tint, border and ink, with the "!" rounded square as its
    /// mark. `REVIEW`: copy — the titles are new strings, the canvas' own.
    ///
    /// Where it rounds the artboard off: the border is `evaWarningBorder` (.30 against the
    /// artboard's .40), the body takes the Warning ink rather than its `#7A5A22`, the radius
    /// is `EvaRadius.radioRow` (18, exact), and the offer is §5's secondary glass button —
    /// the artboard draws a 40-high amber-outlined one that matches no §5 variant, and a new
    /// variant is a design decision, not a transcription.
    private func guardCard(_ refusal: APINutritionRefusal) -> some View {
        HStack(alignment: .top, spacing: EvaSpacing.sm) {
            Text("!")
                .evaTextStyle(.control)
                .foregroundStyle(Color.evaTextOnDark)
                .frame(width: 20, height: 20)
                .background(Color.evaWarning, in: .rect(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                Text(refusal.title(offered: model.offeredText(refusal)))
                    .evaTextStyle(.control)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition.guard.title")
                Text(refusal.message)
                    .evaTextStyle(.inputHelper)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition.guard.message")
                // The offered value in her units, rounded so it clears the guard (#82).
                Button("Use \(model.offeredText(refusal))") {
                    model.useOffered(refusal)
                }
                .buttonStyle(EvaSecondaryButtonStyle())
                .padding(.top, EvaSpacing.xs)
                .accessibilityIdentifier("nutrition.guard.offer")
            }
            .foregroundStyle(Color.evaWarningInk)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EvaSpacing.md)
        .background(
            Color.evaWarningTint,
            in: .rect(cornerRadius: EvaRadius.radioRow, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.radioRow, style: .continuous)
                .strokeBorder(Color.evaWarningBorder, lineWidth: 1)
        }
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
            .toggleStyle(.eva)
            .accessibilityIdentifier("nutrition.hideNumbers")
            Text("You'd still get guidance and meal logging, just without the numbers.")
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaSecondaryText)
        }
    }

    // MARK: - Resume (canvas `sResume`)

    /// A setup she started and left: what is done, what remains, and the promise the canvas
    /// makes beside it — nothing calculated from partial answers (PRD line 677).
    ///
    /// The artboard's body names the day she stopped ("…on August 9"). The API serves no
    /// such date, so the sentence ends at what she completed. `REVIEW`: copy — new strings,
    /// the canvas' own apart from that.
    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            Text("Resume setup")
                .evaTextStyle(.overline)
                .foregroundStyle(Color.evaSecondaryText)

            VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                Text("Pick up where you left off")
                    .evaTextStyle(.h2)
                    .foregroundStyle(Color.evaPrimaryText)
                    .accessibilityIdentifier("nutrition.resume.title")
                Text(Self.resumeSentence(model.resumeSteps))
                    .evaTextStyle(.body)
                    .foregroundStyle(Color.evaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition.resume.body")

                VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                    ForEach(model.resumeSteps) { item in
                        resumeRow(item.step, isDone: item.isDone)
                    }
                }
                .padding(.top, EvaSpacing.xs)

                PrimaryButton(title: "Continue setup · step \(model.step.ordinal)") {
                    model.continueSetup()
                }
                .accessibilityIdentifier("nutrition.resume.continue")
                .padding(.top, EvaSpacing.xs)
            }
            .padding(EvaSpacing.lg)
            .evaCardSurface()

            Text(
                "No targets, notes or suggestions are shown until setup is complete. "
                    + "Nothing was calculated from your partial answers."
            )
            .evaTextStyle(.inputHelper)
            .foregroundStyle(Color.evaSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EvaSpacing.md)
            .evaCardSurface()
        }
    }

    /// A done step is a filled pistachio disc with a tick; one that remains is a dashed
    /// ring — shape as well as colour (§1), and the words say it too.
    private func resumeRow(_ step: SetupStep, isDone: Bool) -> some View {
        HStack(spacing: EvaSpacing.sm) {
            ZStack {
                if isDone {
                    Circle().fill(Color.evaDeepPistachio)
                    Image(systemName: "checkmark")
                        .font(.evaCaption.weight(.bold))
                        .foregroundStyle(Color.evaTextOnDark)
                } else {
                    Circle()
                        .strokeBorder(
                            Color.evaRadioMarkBorder,
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        )
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)

            Text(step.resumeLabel)
                .evaTextStyle(.control)
                .foregroundStyle(isDone ? Color.evaPrimaryText : Color.evaSecondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(step.resumeLabel), \(isDone ? "done" : "not done yet")"))
        .accessibilityIdentifier("nutrition.resume.step.\(step.rawValue)")
    }

    /// The summary's disclaimer — the owner's decision on #374, in the canvas' wording. The
    /// line it replaced claimed every plan is "reviewed by a registered dietitian"; none is,
    /// so it said something untrue on the one screen that states her targets.
    static let disclaimer = "Eva's plan is a guide. It does not replace personalized advice "
        + "from a doctor or registered dietitian."

    /// "You completed goal and focus areas. Two steps remain before Eva can show any targets."
    static func resumeSentence(_ steps: [ResumeStep]) -> String {
        let done = steps.filter(\.isDone).map { $0.step.resumeLabel.lowercased() }
        let remaining = steps.count - done.count
        let count = ["One", "Two", "Three", "Four", "Five"][max(0, min(remaining, 5) - 1)]
        let remain = remaining == 1 ? "step remains" : "steps remain"
        return "You completed \(done.formatted(.list(type: .and))). "
            + "\(count) \(remain) before Eva can show any targets."
    }

    // MARK: - Summary (canvas `sSum`)

    /// Every target, then the cycle-adjustment status, as the artboard's row table — before
    /// anything is activated. The qualitative arm has no numeric field to draw (#212), so its
    /// table is the goal and the focus areas only.
    ///
    /// Not drawn: the artboard's "Start my plan" — there is nothing to activate yet (the
    /// Today screen is unbuilt) — and its amber "illustrative numbers" line, which is a note
    /// on the canvas, not product copy. The timeline the summary used to state is Step 5's
    /// "Estimated plan" card on the canvas, not a summary row.
    private var summary: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.md) {
            Text("Your plan")
                .evaTextStyle(.h1)
                .foregroundStyle(Color.evaPrimaryText)
                .accessibilityIdentifier("nutrition.summary.title")

            switch model.summary {
            case .numbers(let numbers):
                // `REVIEW`: new string, the canvas' own.
                Text(
                    "Estimates based on Mifflin–St Jeor, your activity level and your goal. "
                        + "Nothing here is fixed."
                )
                .evaTextStyle(.body)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

                summaryCard(rows: numberRows(numbers))
                    .accessibilityIdentifier("nutrition.summary.numbers")
            case .qualitative(let qualitative):
                VStack(alignment: .leading, spacing: EvaSpacing.xs) {
                    ForEach(qualitative.guidance, id: \.self) { line in
                        Text(line)
                            .evaTextStyle(.body)
                            .foregroundStyle(Color.evaSecondaryText)
                    }
                }
                summaryCard(rows: [
                    SummaryRow(id: "goal", key: "Goal", value: qualitative.goal.title),
                    focusRow,
                ])
                .accessibilityIdentifier("nutrition.summary.qualitative")
            }

            // The dietitian disclaimer appears once, here, not on every screen (canvas `sSum`),
            // on the artboard's Information tint.
            EvaInfoBanner(message: Self.disclaimer)
                .accessibilityIdentifier("nutrition.summary.disclaimer")
        }
        .sheet(isPresented: $model.showCalculation) {
            NutritionCalculationSheet { model.showCalculation = false }
        }
    }

    /// The artboard's card: rows of key and value over hairlines, and "How this is
    /// calculated" at its foot.
    private func summaryCard(rows: [SummaryRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    if row.id != rows.first?.id {
                        // The artboard's `rgba(40,33,38,.05)` hairline; the nearest token.
                        Rectangle()
                            .fill(Color.evaControlBorderDisabled)
                            .frame(height: 1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.sm) {
                        Text(row.key)
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaSecondaryText)
                        Spacer(minLength: EvaSpacing.xs)
                        Text(row.value)
                            .evaTextStyle(.control)
                            .foregroundStyle(Color.evaPrimaryText)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, EvaSpacing.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("nutrition.summary.\(row.id)")
                }
            }

            Button("How this is calculated") {
                model.showCalculation = true
            }
            .buttonStyle(EvaSecondaryButtonStyle())
            .padding(.top, EvaSpacing.sm)
            .accessibilityIdentifier("nutrition.howCalculated")
        }
        .padding(EvaSpacing.md)
        .evaCardSurface()
        .accessibilityElement(children: .contain)
    }

    private struct SummaryRow: Identifiable {
        let id: String
        let key: String
        let value: String
    }

    /// `REVIEW`: the keys are the canvas' own; the value formats are new.
    private func numberRows(_ numbers: NutritionNumbers) -> [SummaryRow] {
        var rows = [
            SummaryRow(id: "goal", key: "Goal", value: (model.profile?.goal ?? .maintain).title),
            SummaryRow(id: "targetWeight", key: "Target weight", value: targetWeightValue(numbers)),
            SummaryRow(
                id: "calories", key: "Daily calories",
                value: "approximately \(Self.whole(numbers.calorieTargetKcal)) kcal"
            ),
            SummaryRow(id: "protein", key: "Protein", value: "\(Self.whole(numbers.proteinG)) g"),
            SummaryRow(id: "fat", key: "Fat", value: "\(Self.whole(numbers.fatG)) g"),
            SummaryRow(id: "carbs", key: "Carbohydrates", value: "\(Self.whole(numbers.carbG)) g"),
            SummaryRow(id: "fibre", key: "Fiber", value: "\(Self.whole(numbers.fibreG)) g"),
        ]
        if let adjustment = numbers.cycleAdjustment {
            rows.append(SummaryRow(
                id: "cycleAdjustment", key: "Cycle-aware adjustment", value: adjustment.status
            ))
        }
        rows.append(focusRow)
        return rows
    }

    /// A weight-change goal's target in her units, "(estimate)" as the canvas words it;
    /// goals 4 and 5 have none (PRD line 745).
    private func targetWeightValue(_ numbers: NutritionNumbers) -> String {
        guard let kilograms = numbers.targetWeightKg else { return "Not applicable" }
        return "\(model.targetEntry.display(kilograms: kilograms)) (estimate)"
    }

    private var focusRow: SummaryRow {
        let labels = (model.profile?.focusAreas ?? []).compactMap { code in
            NutritionFocusArea.all.first { $0.code == code }?.label
        }
        return SummaryRow(
            id: "focusAreas", key: "Focus areas",
            value: labels.isEmpty ? "None selected" : labels.joined(separator: ", ")
        )
    }

    private static func whole(_ value: Double) -> String {
        Int(value.rounded()).formatted()
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

extension NutritionCycleAdjustment {
    /// The summary row's status. `REVIEW`: new strings — the canvas draws only
    /// "On · luteal phase +5%", and a percentage would restate a constant the server owns.
    /// The confidence travels with the word (GUARDRAILS 35), and `none` has to be true both
    /// when she is not luteal and when no phase could be estimated, because the route does not
    /// say which (`APINutritionAdjustment`).
    var status: String {
        switch self {
        case .luteal(confidence: "wide"): "On · luteal phase (wide estimate)"
        case .luteal: "On · luteal phase (estimated)"
        case .none: "Not applied today · needs an estimated luteal phase"
        }
    }
}

extension APINutritionRefusal {
    /// The guard card's title. `REVIEW`: new strings, the canvas' own (`sGuard`, `sCap`).
    func title(offered: String) -> String {
        switch reason {
        case "below-bmi-floor": "That target falls below the range Eva can support"
        default: "One plan goes down to \(offered)"
        }
    }

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
    /// The step's name on the resume card (canvas `sResume`). `REVIEW`: new strings.
    var resumeLabel: String {
        switch self {
        case .goal: "Goal"
        case .focusAreas: "Focus areas"
        case .mealPattern: "Meal pattern"
        case .bodyMetrics: "Body metrics"
        case .targetWeight, .done: "Target weight"
        }
    }

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

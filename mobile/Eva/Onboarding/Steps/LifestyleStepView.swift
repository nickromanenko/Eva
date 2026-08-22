import SwiftUI

struct LifestyleStepView: View {
    @Bindable var model: OnboardingModel
    let onSubmit: () async throws -> Void

    @State private var isLoading = false
    @State private var errorMessage: String?

    private let sportColumns = [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]

    var body: some View {
        OnboardingStepLayout(buttonTitle: "Build my plan", isLoading: isLoading, onContinue: submit) {
            QuestionnaireHeading(title: "Your lifestyle")

            sectionLabel("How active is your day-to-day?")
                .padding(.top, 22)
            VStack(spacing: 10) {
                ForEach(OnboardingModel.lifestyleOptions, id: \.self) { option in
                    ChipToggleButton(
                        label: option,
                        isSelected: model.lifestyle == option
                    ) {
                        model.lifestyle = option
                    }
                }
            }
            .padding(.top, 12)

            sectionLabel("Which sports do you prefer?")
                .padding(.top, 24)
            LazyVGrid(columns: sportColumns, spacing: 11) {
                ForEach(OnboardingModel.sportOptions, id: \.self) { sport in
                    ChipToggleButton(
                        label: sport,
                        isSelected: model.sports.contains(sport),
                        isCentered: true
                    ) {
                        toggleSport(sport)
                    }
                }
            }
            .padding(.top, 12)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.evaPlum)
                    .padding(.top, 14)
            }
        }
    }

    private func submit() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.evaPlum)
    }

    private func toggleSport(_ sport: String) {
        if model.sports.contains(sport) {
            model.sports.remove(sport)
        } else {
            model.sports.insert(sport)
        }
    }
}

#Preview {
    LifestyleStepView(model: OnboardingModel(), onSubmit: {})
        .background(LinearGradient.evaScreenBackground)
}

import SwiftUI

struct EmailSignUpStepView: View {
    @Bindable var model: OnboardingModel

    private enum Field { case email, password }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sign up with email")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.evaInk)
                    Text("Create your login — you can add the rest in a moment.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.evaBody)
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 16) {
                        field(label: "Email") {
                            TextField("you@email.com", text: $model.email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        field(label: "Password") {
                            SecureField("At least 8 characters", text: $model.password)
                                .textContentType(.newPassword)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.done)
                                .onSubmit { model.submitEmailForm() }
                        }
                        Text(model.isEmailFormValid
                             ? "Looks good — you're ready to continue."
                             : "Enter a valid email and a password of 8+ characters.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(model.isEmailFormValid ? Color.evaGreenIcon : Color.evaFaint)
                    }
                    .padding(.top, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 58)
            }
            .scrollIndicators(.hidden)

            Button(action: model.submitEmailForm) {
                Text("Create account")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(background, in: .rect(cornerRadius: 16))
                    .shadow(color: model.isEmailFormValid ? .evaPlum.opacity(0.45) : .clear, radius: 15, y: 9)
            }
            .buttonStyle(.plain)
            .disabled(!model.isEmailFormValid)
            .padding(.horizontal, 26)
            .padding(.bottom, 16)
        }
    }

    private var background: AnyShapeStyle {
        model.isEmailFormValid
            ? AnyShapeStyle(LinearGradient.evaPlumPink)
            : AnyShapeStyle(Color(hex: 0xD7C3D1))
    }

    private func field(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.evaMuted)
            content()
                .font(.system(size: 15.5))
                .foregroundStyle(Color.evaInk)
                .padding(15)
                .background(.white, in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.evaChipBorder, lineWidth: 1.5)
                )
        }
    }
}

#Preview {
    EmailSignUpStepView(model: OnboardingModel())
        .background(LinearGradient.evaScreenBackground)
}

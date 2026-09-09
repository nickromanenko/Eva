import SwiftUI

/// The Apple and Google buttons, plus the thing that makes them work: one place that
/// knows how to run a provider flow, show it running, and say what happened if it failed.
///
/// ## Why it lives here and not in `Theme/` or `AuthScreenParts.swift`
///
/// It is not a design-system component — it is two `EvaAuthButton`s, which are. And it is
/// not auth-screen furniture either, because Profile's connected-accounts card uses the
/// same two buttons to *attach* a provider rather than to sign in. So it sits beside the
/// controllers it drives, and the three call sites differ only in which providers they
/// offer and what they do with the credential.
///
/// ## Cancelling shows nothing
///
/// Both controllers answer `nil` for a cancellation, and this draws nothing for it. A user
/// who dismisses Apple's sheet has not failed at anything, and an error under the buttons
/// would tell them they had.
struct ProviderSignInButtons: View {

    /// Which buttons to draw. Profile passes only the providers that are not attached yet.
    var providers: [EvaAuthProvider] = EvaAuthProvider.allCases

    /// Prefix for the buttons and the failure line — `auth` on the sign-up and log-in
    /// screens, `profile.connect` in Profile, so a test can tell "sign in with Apple" and
    /// "attach Apple" apart.
    var identifierPrefix = "auth"

    /// What to do with the credential the provider handed back. `signInWithProvider` on
    /// the auth screens, `attachProvider` in Profile.
    let onCredential: (ProviderCredential) async throws -> Void

    /// Which button is waiting, if any. One at a time: a second provider sheet cannot be
    /// presented over the first, so the other button goes inert while one is in flight.
    @State private var pending: EvaAuthProvider?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: EvaSpacing.sm) {
            ForEach(providers) { provider in
                EvaAuthButton(
                    provider: provider,
                    identifier: "\(identifierPrefix).\(provider.rawValue)",
                    isLoading: pending == provider
                ) {
                    start(provider)
                }
            }

            if let errorMessage {
                AuthStatusLine(
                    message: errorMessage,
                    kind: .error,
                    identifier: "\(identifierPrefix).error"
                )
                .padding(.top, EvaSpacing.xxs)
            }
        }
        // The provider that is *not* waiting. The waiting one draws itself as enabled —
        // see `EvaAuthButtonStyle.isLoading` — so this dims the other rather than both.
        .disabled(pending != nil)
    }

    private func start(_ provider: EvaAuthProvider) {
        guard pending == nil else { return }
        pending = provider
        errorMessage = nil
        Task {
            do {
                let credential: ProviderCredential? = switch provider {
                case .apple: try await AppleSignInController.shared.signIn()
                case .google: try await GoogleSignInController.shared.signIn()
                }
                // `nil` is a cancellation. Nothing to say and nothing to do.
                if let credential {
                    try await onCredential(credential)
                }
            } catch {
                // Safe to show and safe to keep: `ProviderSignInError` interpolates no
                // token, code or nonce, and an `APIError` carries the server's own
                // message, which carries none either (GUARDRAILS 12).
                errorMessage = error.localizedDescription
            }
            pending = nil
        }
    }
}

#Preview("Provider sign-in buttons") {
    VStack(spacing: EvaSpacing.lg) {
        ProviderSignInButtons { _ in }
        ProviderSignInButtons(
            providers: [.google],
            identifierPrefix: "preview.connect"
        ) { _ in }
    }
    .padding(EvaSpacing.lg)
    .background {
        EvaScreenBackground().ignoresSafeArea()
    }
}

import SwiftUI

/// What the app shows when launch could not validate the stored token — no signal, a
/// captive portal, a 5xx — and therefore **kept** it (`AppSession.State.unreachable`,
/// #61).
///
/// ## This screen is a decision, not a transcription
///
/// The canvas draws no launch-blocked state. "Eva App.dc.html" has an offline home
/// (`home_off`), but that screen exists because there is cached content to show; here
/// there is nothing yet — the session has not resolved — so there is no artboard to
/// build from and the layout below is a choice.
///
/// Two smaller choices inside it, both worth contesting on review:
///
/// * **Not the §7 error card.** The design system draws a retry affordance
///   ("Couldn't sync your last entry" / "Retry now"), but it is an inline card in the
///   error red, sized to sit inside a screen that is otherwise working. Nothing here is
///   wrong with the user's data and nothing is destructive; borrowing that treatment
///   would make bad signal look like a fault.
/// * **The frame is the auth screens' frame.** Message centred on
///   `EvaScreenBackground`, single call to action against the bottom edge — the shape
///   `AuthScreenLayout` gives sign-up and log-in, which are the other screens a launch
///   can land on.
///
/// The last line of the body copy is the load-bearing one. "You're still signed in" is
/// only true because `AppSession.bootstrap()` no longer clears the Keychain on a failure
/// that never reached the server; it is a description of what the app did, not
/// reassurance (DESIGN.md §8). If that behaviour ever changes, this sentence goes with
/// it.
struct UnreachableView: View {
    let session: AppSession

    /// Local, not on `AppSession`: it is this screen's button that is busy, and the
    /// session state stays `.unreachable` throughout a retry that fails again.
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: EvaSpacing.sm) {
                Text("Can't reach Eva")
                    .evaTextStyle(.h1)
                    .foregroundStyle(Color.evaPrimaryText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("unreachable.title")

                Text("Check your connection and try again. You're still signed in.")
                    .evaTextStyle(.body)
                    .foregroundStyle(Color.evaSecondaryText)
                    .accessibilityIdentifier("unreachable.body")
            }
            .multilineTextAlignment(.center)
            // Both strings wrap; without this the stack measures them at one line and
            // clips the second.
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: EvaSpacing.xl)

            VStack(spacing: EvaSpacing.xxs) {
                PrimaryButton(title: "Try again", isLoading: isRetrying, action: retry)

                // The escape hatch, and the reason it is here: before #61 *every* launch
                // failure signed the user out, so being stuck was impossible — you were
                // simply ejected. Keeping the token removes that exit, and a retry is not
                // a substitute for it. A `/me` that fails for this account specifically,
                // or an API that is never coming back, would otherwise leave the user on
                // a screen whose only button never works, with no way to reach sign-in
                // and nothing to do but delete the app.
                //
                // It is a text button, not a second primary: retrying is the expected
                // action and this is the way out, not a competing choice.
                // Deliberately NOT disabled while a retry runs. A connection that is
                // accepted and then never answered — a captive portal, one of the cases
                // this screen exists for — hangs on URLSession's 60s default, and an
                // escape hatch that is unavailable for a minute at exactly the moment
                // it is wanted is not an escape hatch. `logOut()` bumps the session
                // generation, so the in-flight bootstrap cannot land on top of it.
                TextButton(title: "Log out", action: session.logOut)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, EvaSpacing.lg)
        .padding(.bottom, EvaSpacing.md)
        .background {
            EvaScreenBackground().ignoresSafeArea()
        }
    }

    /// `PrimaryButton` disables itself while `isLoading`, so the second of two quick
    /// taps never reaches this. `AppSession.bootstrap()` refuses overlapping runs
    /// anyway — belt and braces, because only one of the two is visible from here.
    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            await session.retry()
            isRetrying = false
        }
    }
}

#Preview("Unreachable") {
    UnreachableView(session: AppSession())
}

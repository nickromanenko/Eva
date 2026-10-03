import SwiftUI

/// What the app shows when launch could not validate the stored token — no signal, a
/// captive portal, a 5xx — and therefore **kept** it (`AppSession.State.unreachable`,
/// #61).
///
/// The `unreachable` artboard in "Eva App.dc.html", built as drawn since #375: the
/// auth frame with the `eva.` wordmark, an Information `i` tile, "Eva can't reach its
/// servers" over the canvas' sentence, then Retry, Continue offline and a text-button Log
/// out in destructive ink, pinned to the bottom edge.
///
/// **Information, not the §7 error card.** Nothing is wrong with the user's data and
/// nothing is destructive; the error treatment would make bad signal look like a fault.
/// The artboard draws the same call.
///
/// The first line of the body copy is the load-bearing one. "You're still signed in" is
/// only true because `AppSession.bootstrap()` no longer clears the Keychain on a failure
/// that never reached the server; it is a description of what the app did, not
/// reassurance (DESIGN.md §8). If that behaviour ever changes, this sentence goes with
/// it. The second half is true because Continue offline runs the app from the local
/// store (#78).
struct UnreachableView: View {
    let session: AppSession

    /// Local, not on `AppSession`: it is this screen's button that is busy, and the
    /// session state stays `.unreachable` throughout a retry that fails again.
    @State private var isRetrying = false

    var body: some View {
        AuthScreenLayout {
            AuthWordmark()

            AuthNoticeHero(
                title: "Eva can't reach its servers",
                subtitle: "You're still signed in. Anything you log now is saved on this "
                    + "device and syncs when the connection is back.",
                identifier: "unreachable"
            )
            // The artboard's 70pt from the wordmark to the tile; 72 is the nearest the
            // §4 scale reaches.
            .padding(.top, EvaSpacing.xxl + EvaSpacing.xl)
        } footer: {
            VStack(spacing: EvaSpacing.xs) {
                PrimaryButton(title: "Retry", isLoading: isRetrying, action: retry)

                // A3 (#78): the canvas' second action. The app runs from the local store
                // with the token kept and unvalidated; entries queue and sync later.
                // Only for an account that has passed the consent gate on this device: with
                // no `/me` there is no consent record to read (#86).
                if session.canContinueOffline {
                    SecondaryButton(title: "Continue offline", action: session.continueOffline)
                }

                // The escape hatch, and the reason it is here: before #61 *every* launch
                // failure signed the user out, so being stuck was impossible — you were
                // simply ejected. Keeping the token removes that exit, and a retry is not
                // a substitute for it. A `/me` that fails for this account specifically,
                // or an API that is never coming back, would otherwise leave the user on
                // a screen whose only button never works, with no way to reach sign-in
                // and nothing to do but delete the app.
                //
                // A text button, not a second primary: retrying is the expected action and
                // this is the way out. Destructive ink because the artboard draws it so —
                // logging out wipes the local store (ARCHITECTURE §8.5).
                // Deliberately NOT disabled while a retry runs. A connection that is
                // accepted and then never answered — a captive portal, one of the cases
                // this screen exists for — hangs on URLSession's 60s default, and an
                // escape hatch that is unavailable for a minute at exactly the moment
                // it is wanted is not an escape hatch. `logOut()` bumps the session
                // generation, so the in-flight bootstrap cannot land on top of it.
                TextButton(title: "Log out", role: .destructive, action: session.logOut)
            }
        }
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

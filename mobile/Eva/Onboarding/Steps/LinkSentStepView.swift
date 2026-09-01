import SwiftUI

/// "Link sent" — "Eva App.dc.html", rail item **Reset link sent** (#6).
///
/// The reset form itself is on the website in v1, so this is where the app's part of the
/// flow ends: the link expires in 60 minutes, the website sets the password and then
/// tries `eva://open`, and the user logs in here with the new one.
///
/// Resend has the same 60-second cooldown as the activation screen and, as the artboard's
/// spec note asks, confirms in place rather than navigating away.
///
/// **"Back to log in" is not on the artboard.** It is here because without it the screen
/// has no exit: the canvas continues into an in-app "Choose a new password" screen that
/// v1 does not build, and `eva://open` only brings the app forward. A screen whose only
/// actions are "open another app" and "send it again" would strand someone who has
/// already changed their password on the website. Same reasoning as `UnreachableView`'s
/// log-out.
struct LinkSentStepView: View {

    let email: String
    let onResend: (_ email: String) async throws -> Void
    let onBackToLogIn: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var cooldownEnds: Date?
    @State private var isResending = false
    @State private var status: Status?

    private enum Status: Equatable {
        case sentAgain
        case rateLimited
        case failed(String)
    }

    var body: some View {
        AuthScreenLayout {
            AuthStatusHero(
                title: "Link sent",
                subtitle: "Check \(email). The link expires in 60 minutes.",
                tileSize: 88,
                envelopeColor: .evaDeepPistachio
            )
            .padding(.top, EvaSpacing.xxl)

            statusLine
                .padding(.top, EvaSpacing.md)
        } footer: {
            VStack(spacing: EvaSpacing.xs) {
                PrimaryButton(title: "Open email app", action: openMail)

                AuthResendButton(
                    title: "Resend link",
                    identifier: "linkSent.resend",
                    cooldownEnds: cooldownEnds,
                    action: resend
                )

                TextButton(title: "Back to log in", action: onBackToLogIn)
            }
        }
        .onAppear {
            // The link was sent on the way here, so the count starts at once.
            if cooldownEnds == nil {
                cooldownEnds = AuthResendCooldown.endingNow()
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .sentAgain:
            AuthStatusLine(
                message: "Email sent again. Check spam if it hasn't arrived.",
                kind: .plain,
                identifier: "linkSent.status"
            )
        case .rateLimited:
            AuthRateLimitedBanner(identifier: "linkSent.rateLimited")
        case .failed(let message):
            AuthStatusLine(message: message, kind: .error, identifier: "linkSent.error")
        case nil:
            EmptyView()
        }
    }

    // MARK: - Behaviour

    private func openMail() {
        guard let url = URL(string: "message://") else { return }
        openURL(url) { _ in }
    }

    private func resend() {
        guard !isResending else { return }
        isResending = true
        status = nil
        Task {
            do {
                try await onResend(email)
                status = .sentAgain
                cooldownEnds = AuthResendCooldown.endingNow()
            } catch let error as APIError where error.isRateLimited {
                status = .rateLimited
                cooldownEnds = AuthResendCooldown.endingNow()
            } catch {
                status = .failed(error.localizedDescription)
            }
            isResending = false
        }
    }
}

#Preview("Link sent") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        LinkSentStepView(email: "maria.ferreira@gmail.com", onResend: { _ in }, onBackToLogIn: {})
    }
}

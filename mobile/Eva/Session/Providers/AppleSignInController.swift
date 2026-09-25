import AuthenticationServices
import UIKit

/// Sign in with Apple, reduced to two `async` calls (#7).
///
/// ## The nonce pairing is the point
///
/// Every sign-in generates a fresh raw nonce, sends **`sha256(rawNonce)`** to Apple in
/// `ASAuthorizationOpenIDRequest.nonce`, and sends the **raw** value to the Eva API
/// beside the `identityToken`. Apple copies the hash it was given into the token's
/// `nonce` claim, so the API can prove the token was minted for the request the app just
/// made. Send the hash to the API instead and the check becomes "this hash equals this
/// hash", which any replayed token also passes. `AppleSignInNonce` owns that pairing, so
/// this file never handles either string.
///
/// ## Cancelling is not an error
///
/// `ASAuthorizationError.canceled` comes back as `nil`, not as a throw. The user dismissed
/// a sheet; there is nothing to tell them. That distinction is why both methods return an
/// optional rather than throwing everything.
///
/// ## Nothing here can run in the simulator
///
/// Sign in with Apple needs a device signed in to an Apple ID; the simulator answers
/// `ASAuthorizationError.unknown`. So the flow is exercised by hand on a device, and
/// `EvaUITests` does not drive it — the same honest gap `docs/PROVIDER-SIGNIN.md` names.
@MainActor
final class AppleSignInController {

    static let shared = AppleSignInController()

    /// Held for the lifetime of one request. `ASAuthorizationController` does not retain
    /// itself and its delegate is `weak`, so without this both are released at the end of
    /// the call that starts them and the sheet never answers.
    private var session: Session?

    /// Authorizes and returns the credential `/auth/idp` and `/me/auth/providers` take.
    ///
    /// `nil` means the user cancelled.
    ///
    /// The email and the name Apple may attach are **not** forwarded. They arrive only on
    /// the very first authorization, so the server has to capture them then or never
    /// (#7's decision) — and it can: the address is a claim inside the `identityToken`
    /// this returns. The full name is not, and Eva has no field for a name today, so
    /// nothing is lost by leaving `.fullName` out of the request entirely.
    func signIn() async throws -> ProviderCredential? {
        // The pair, not two strings: which one goes where is `AppleSignInNonce`'s to
        // decide, and it is tested there (#118).
        let nonce = AppleSignInNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        nonce.configure(request)

        guard let credential = try await authorize(request) else { return nil }
        guard let token = credential.identityToken,
              let identityToken = String(data: token, encoding: .utf8) else {
            throw ProviderSignInError.malformedProviderResponse
        }
        return nonce.credential(identityToken: identityToken)
    }

    /// A fresh `authorizationCode`, for the one thing an Eva JWT cannot buy: revoking
    /// Apple's token when the account is deleted.
    ///
    /// Apple requires an app that offers both Sign in with Apple and in-app account
    /// deletion to revoke on delete, and revocation needs either a stored refresh token
    /// or a fresh authorization code. Eva deliberately stores no refresh token, so it
    /// asks for a code at the moment of deletion.
    ///
    /// `nil` means cancelled, and the caller must delete the account anyway — see
    /// `DeleteAccountModal`. No scopes are requested: this authorization exists to be
    /// exchanged for a revocation, not to identify anyone, and asking for an address in
    /// order to destroy an account would be absurd.
    func reauthorizationCode() async throws -> String? {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        guard let credential = try await authorize(request) else { return nil }
        guard let code = credential.authorizationCode,
              let authorizationCode = String(data: code, encoding: .utf8) else {
            throw ProviderSignInError.malformedProviderResponse
        }
        return authorizationCode
    }

    /// Runs one request to completion. `nil` for a cancellation, and `nil` too if another
    /// request is already on screen — a second sheet is not a thing that can happen, and
    /// "nothing happened" is the truthful outcome for the tap that asked for one.
    private func authorize(
        _ request: ASAuthorizationAppleIDRequest
    ) async throws -> ASAuthorizationAppleIDCredential? {
        guard session == nil else { return nil }
        let session = Session()
        self.session = session
        defer { self.session = nil }
        return try await session.run(request)
    }

    /// One authorization: the delegate, the presentation anchor and the continuation that
    /// turns three callbacks into one `await`.
    @MainActor
    private final class Session: NSObject,
                                 ASAuthorizationControllerDelegate,
                                 ASAuthorizationControllerPresentationContextProviding {

        private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential?, Error>?
        private var controller: ASAuthorizationController?

        func run(
            _ request: ASAuthorizationAppleIDRequest
        ) async throws -> ASAuthorizationAppleIDCredential? {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                self.controller = controller
                controller.performRequests()
            }
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            // A request built from `ASAuthorizationAppleIDProvider` can only answer with
            // this credential type, so anything else is a framework contract break rather
            // than a case to handle.
            finish(.success(authorization.credential as? ASAuthorizationAppleIDCredential))
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithError error: any Error
        ) {
            // `.canceled` is the user dismissing the sheet. Everything else — no Apple ID
            // on the device, a failed request, an entitlement that is not on the profile —
            // is a failure the screen should say something about, and Apple's own message
            // is not the thing to say: it is a developer string, sometimes just a number.
            if (error as? ASAuthorizationError)?.code == .canceled {
                finish(.success(nil))
            } else {
                finish(.failure(ProviderSignInError.providerFailed))
            }
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            EvaPresentationAnchor.current()
        }

        /// Resumes exactly once. `ASAuthorizationController` is not documented to call
        /// back twice, and a checked continuation resumed twice traps — so this is the
        /// difference between a framework surprise and a crash in front of a user.
        private func finish(_ result: Result<ASAuthorizationAppleIDCredential?, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            self.controller = nil
            continuation.resume(with: result)
        }
    }
}

/// The window Apple's sheet and Google's web session are anchored to.
///
/// Shared by both controllers because both protocols ask the same question, and because
/// getting it wrong is the same bug twice: an anchor from a background scene presents
/// nothing and the flow hangs on an `await` that never returns.
enum EvaPresentationAnchor {

    /// The foreground scene's key window.
    ///
    /// The fallback is an empty `UIWindow`, which is what Apple's own sample code does:
    /// there is no useful failure here — a nil anchor is not expressible — and the app is
    /// portrait, single-scene and in the foreground whenever either of these flows starts.
    @MainActor
    static func current() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}

import AuthenticationServices

/// Google sign-in as the OAuth 2.0 authorization-code flow with PKCE, run by the app
/// itself in an `ASWebAuthenticationSession` (#7).
///
/// ## Why there is no SDK here
///
/// Adding a dependency is an always-human gate (`docs/AUTONOMY.md`) and this one was
/// decided against: the app has zero Swift Package dependencies and GoogleSignIn brings
/// its own plus two transitive ones, to run a flow that is four parameters and a redirect.
/// An iOS OAuth client is a public client with no secret, so PKCE is what protects the
/// exchange, and `ASWebAuthenticationSession` is what presents it.
///
/// ## And why not a plain web view
///
/// The PRD asks for "a web view, not a browser redirect", and this is what that means in
/// practice. Google refuses to authorize inside an embedded `WKWebView` — it answers
/// `disallowed_useragent` — so a real in-app web view is not an option at all.
/// `ASWebAuthenticationSession` is the sanctioned middle: a sheet over the app, not a
/// trip out to Safari and back, and the app never sees the password.
///
/// The session is **not** ephemeral. An ephemeral one would hide the "…wants to use
/// google.com to sign in" prompt at the cost of ignoring the Google session the user is
/// already in, turning one tap into a full password-and-2FA login every time.
@MainActor
final class GoogleSignInController {

    static let shared = GoogleSignInController()

    /// Retained for the length of one flow: `ASWebAuthenticationSession` does not keep
    /// itself alive, and a released session takes its sheet with it.
    private var session: ASWebAuthenticationSession?

    /// Held strongly because `presentationContextProvider` is a weak reference.
    private let anchorProvider = AnchorProvider()

    /// Runs the flow and returns the credential `/auth/idp` and `/me/auth/providers` take.
    ///
    /// `nil` means the user cancelled — closing the sheet, or declining on Google's own
    /// consent screen. Both are choices, not failures.
    ///
    /// The `code` is single-use and is spent by the **API**, not here: the app has no
    /// client secret and no business holding a Google token. It forwards the code, the
    /// verifier that unlocks it and the redirect Google was given, and gets an Eva JWT
    /// back (ARCHITECTURE §2).
    func signIn(bundle: Bundle = .main) async throws -> ProviderCredential? {
        let configuration = try GoogleOAuthConfiguration.resolve(bundle: bundle)
        // Both are generated per attempt and neither outlives this function. A reused
        // verifier would let a code intercepted once be spent twice.
        let verifier = AuthCrypto.codeVerifier()
        let state = AuthCrypto.oauthState()

        let url = configuration.authorizationURL(
            codeChallenge: AuthCrypto.codeChallenge(for: verifier),
            state: state
        )
        guard let callback = try await present(url, scheme: configuration.redirectScheme),
              let code = try GoogleOAuthConfiguration.authorizationCode(
                  from: callback, expectedState: state
              )
        else { return nil }

        return .google(
            code: code,
            codeVerifier: verifier,
            redirectUri: configuration.redirectURI
        )
    }

    /// Presents the sheet and waits for the redirect. `nil` for a cancellation, and `nil`
    /// too if a session is already up — a second sheet cannot be presented, and "nothing
    /// happened" is the truthful outcome for the tap that asked for one.
    private func present(_ url: URL, scheme: String) async throws -> URL? {
        guard session == nil else { return nil }
        defer { session = nil }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(scheme)
            ) { callbackURL, error in
                guard let error else {
                    continuation.resume(returning: callbackURL)
                    return
                }
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: ProviderSignInError.providerFailed)
                }
            }
            session.presentationContextProvider = anchorProvider
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            // `start()` answering `false` means the sheet never appeared, so the
            // completion handler never will either. Resuming here is the only thing
            // between that and an `await` that hangs for the life of the process.
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: ProviderSignInError.providerFailed)
                return
            }
        }
    }

    /// The one method `ASWebAuthenticationSession` needs a whole object for.
    @MainActor
    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            EvaPresentationAnchor.current()
        }
    }
}

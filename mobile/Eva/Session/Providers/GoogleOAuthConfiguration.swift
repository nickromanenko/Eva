import Foundation

/// Everything the Google authorization-code flow needs that is not a secret: the iOS
/// OAuth client id, the redirect it implies, and the URL the app opens (#7).
///
/// Split out of `GoogleSignInController` because all of it is pure — a string in, a
/// string out — and because every value here is one a mistake in produces a *working
/// looking* request that Google refuses at the far end, with an error that names none of
/// this. `GoogleOAuthConfigurationTests` is where the shapes are pinned.
///
/// **There is no client secret**, and that is the design rather than an omission. An iOS
/// OAuth client is a public client, so the flow is protected by PKCE instead — which is
/// what lets Eva run it with `ASWebAuthenticationSession` and keep its dependency count
/// at zero (GUARDRAILS 25, `docs/PROVIDER-SIGNIN.md` §4).
struct GoogleOAuthConfiguration: Equatable, Sendable {

    /// Info.plist key carrying the client id, written by XcodeGen from
    /// `GOOGLE_IOS_CLIENT_ID` in `mobile/project.yml`.
    static let clientIDInfoKey = "GoogleIOSClientID"

    /// The suffix every Google OAuth client id ends in.
    static let clientIDSuffix = ".apps.googleusercontent.com"

    /// The prefix its reversed form starts with. Google's iOS convention, not ours.
    static let redirectSchemePrefix = "com.googleusercontent.apps."

    /// The path Google's iOS documentation appends to the reversed-client-id scheme.
    /// One slash, not two: the scheme has no authority component, so `scheme:/path` is
    /// the correct shape and `scheme://path` would make `path` a host.
    static let redirectPath = "/oauth2redirect"

    let clientID: String

    /// `com.googleusercontent.apps.<numeric>` — derived, never read from configuration,
    /// so it cannot disagree with the client id it is supposed to reverse.
    let redirectScheme: String

    /// The `redirect_uri` sent to Google and echoed to the Eva API, which must present
    /// the identical string at the token exchange or Google rejects the grant.
    var redirectURI: String { redirectScheme + ":" + Self.redirectPath }

    // MARK: - Resolution

    /// Reads the build's configuration, or says why there isn't one.
    ///
    /// Both failures are deliberate and neither has a fallback. An empty client id means
    /// nobody has done `docs/PROVIDER-SIGNIN.md` §4 yet; a placeholder in its place would
    /// send a real request to Google and fail there, several layers from the cause. A
    /// scheme the bundle does not register means the two settings in `project.yml` have
    /// drifted, and the flow would open, complete, and hand the callback to nobody.
    static func resolve(bundle: Bundle = .main) throws -> GoogleOAuthConfiguration {
        try resolve(
            clientID: bundle.object(forInfoDictionaryKey: clientIDInfoKey) as? String,
            registeredSchemes: registeredURLSchemes(in: bundle)
        )
    }

    /// The decision itself, with the bundle already read.
    ///
    /// Split out so the rule can be tested without a bundle: `Bundle` has no public
    /// initializer to subclass and building one on disk to check two string comparisons
    /// would be a fixture with more moving parts than the thing it covers.
    static func resolve(
        clientID: String?,
        registeredSchemes: [String]
    ) throws -> GoogleOAuthConfiguration {
        guard let clientID, !clientID.isEmpty,
              let scheme = redirectScheme(forClientID: clientID) else {
            throw ProviderSignInError.googleNotConfigured
        }
        guard registeredSchemes.contains(scheme) else {
            throw ProviderSignInError.googleRedirectSchemeMismatch
        }
        return GoogleOAuthConfiguration(clientID: clientID, redirectScheme: scheme)
    }

    /// The reversed client id: drop `.apps.googleusercontent.com`, prepend
    /// `com.googleusercontent.apps.`. `nil` for anything that is not a Google client id.
    static func redirectScheme(forClientID clientID: String) -> String? {
        guard clientID.hasSuffix(clientIDSuffix) else { return nil }
        let identifier = String(clientID.dropLast(clientIDSuffix.count))
        guard !identifier.isEmpty else { return nil }
        return redirectSchemePrefix + identifier
    }

    /// Every scheme in the bundle's `CFBundleURLTypes` — `eva` and, once provisioned,
    /// the Google redirect.
    static func registeredURLSchemes(in bundle: Bundle) -> [String] {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    // MARK: - The request

    /// Google's OAuth 2.0 authorization endpoint.
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    /// What Eva asks for, and no more: enough to identify the account, nothing about the
    /// person. `openid` and `email` are what the API needs to key the account; `profile`
    /// is what makes the consent screen name the app rather than list a bare address.
    static let scopes = "openid email profile"

    /// The URL `ASWebAuthenticationSession` opens.
    ///
    /// `code_challenge_method=S256` — never `plain`. A plain challenge is the verifier
    /// itself, so an attacker who can read the authorization request can complete the
    /// exchange, which is the entire attack PKCE exists to stop.
    func authorizationURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(string: Self.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        // Force-unwrapped because every component is a constant or a base64url string:
        // there is no input that makes this fail, and a `nil` here would be a programming
        // error rather than a runtime condition.
        return components.url!
    }

    // MARK: - The redirect

    /// The authorization code out of Google's callback.
    ///
    /// `nil` means the user declined on Google's own consent screen — `error=access_denied`
    /// — which is a cancellation and not a failure, exactly like dismissing the sheet.
    /// Any other `error` is a real failure, and its value is deliberately not carried into
    /// the message: it is a developer string, and pasting a provider's error in front of
    /// someone trying to sign in explains nothing.
    static func authorizationCode(from callback: URL, expectedState: String) throws -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        // Checked before anything else in the callback is read — including `error` — so a
        // callback that is not ours is never partially trusted. It used to come second, and
        // a forged callback carrying `error=access_denied` was reported to the user as their
        // own cancellation without any state check having happened. No credential was ever
        // accepted on that path, but the comment claimed a property the order did not have.
        // OAuth requires `state` to come back on the error response too, so this costs the
        // real cancellation nothing.
        guard value("state") == expectedState else {
            throw ProviderSignInError.callbackNotForThisRequest
        }
        if let error = value("error") {
            guard error == "access_denied" else { throw ProviderSignInError.providerFailed }
            return nil
        }
        guard let code = value("code"), !code.isEmpty else {
            throw ProviderSignInError.malformedProviderResponse
        }
        return code
    }
}

import Foundation
import Testing
@testable import Eva

/// Issue #7: the Google flow's pure parts — the reversed client id, the authorization
/// URL, and what comes back on the redirect.
///
/// None of this can be exercised by a UI test: it needs a real Google account and a real
/// OAuth client, and the client is not provisioned yet. So the shapes are pinned here,
/// where a wrong one is a failing assertion rather than an `invalid_request` at Google.
@Suite("Issue #7 Google OAuth configuration")
struct GoogleOAuthConfigurationTests {

    private static let clientID = "1234567890-abcdefghijklmnop.apps.googleusercontent.com"
    private static let scheme = "com.googleusercontent.apps.1234567890-abcdefghijklmnop"

    private static var configuration: GoogleOAuthConfiguration {
        GoogleOAuthConfiguration(clientID: clientID, redirectScheme: scheme)
    }

    // MARK: - The reversed client id

    @Test("The redirect scheme is the client id reversed")
    func redirectSchemeDerivation() {
        #expect(GoogleOAuthConfiguration.redirectScheme(forClientID: Self.clientID) == Self.scheme)
    }

    @Test("Anything that is not a Google client id has no scheme")
    func redirectSchemeRejectsOtherStrings() {
        for value in [
            "",
            "1234567890-abc",
            "1234567890-abc.apps.googleusercontent.com.evil.example",
            ".apps.googleusercontent.com",
            "com.googleusercontent.apps.1234567890-abc"
        ] {
            #expect(
                GoogleOAuthConfiguration.redirectScheme(forClientID: value) == nil,
                "\"\(value)\" should not produce a redirect scheme"
            )
        }
    }

    /// One slash. `scheme://oauth2redirect` would make `oauth2redirect` the *host* and an
    /// empty path, which is a different string to Google — and the token exchange compares
    /// `redirect_uri` character for character.
    @Test("The redirect URI is scheme, one colon, one slash, the path")
    func redirectURIShape() {
        #expect(Self.configuration.redirectURI == "\(Self.scheme):/oauth2redirect")
    }

    // MARK: - Resolution from the bundle

    @Test("An unconfigured build reports itself as unconfigured")
    func unconfiguredBuildThrows() {
        // The state this repo ships in today: `GOOGLE_IOS_CLIENT_ID` is empty until a
        // human does docs/PROVIDER-SIGNIN.md §4.
        #expect(throws: ProviderSignInError.googleNotConfigured) {
            try GoogleOAuthConfiguration.resolve(clientID: "", registeredSchemes: [])
        }
        #expect(throws: ProviderSignInError.googleNotConfigured) {
            try GoogleOAuthConfiguration.resolve(clientID: nil, registeredSchemes: [])
        }
        #expect(throws: ProviderSignInError.googleNotConfigured) {
            try GoogleOAuthConfiguration.resolve(clientID: "not-a-google-client", registeredSchemes: [])
        }
    }

    @Test("A client id whose scheme the bundle does not register is refused")
    func schemeMismatchThrows() {
        // The failure mode the runtime check exists for: `GOOGLE_IOS_CLIENT_ID` and
        // `GOOGLE_IOS_REDIRECT_SCHEME` are two settings in project.yml and can drift. The
        // flow would otherwise open, complete, and hand the callback to nobody.
        #expect(throws: ProviderSignInError.googleRedirectSchemeMismatch) {
            try GoogleOAuthConfiguration.resolve(
                clientID: Self.clientID, registeredSchemes: ["eva"]
            )
        }
    }

    @Test("A configured build resolves to the client id and its scheme")
    func configuredBuildResolves() throws {
        let configuration = try GoogleOAuthConfiguration.resolve(
            clientID: Self.clientID, registeredSchemes: ["eva", Self.scheme]
        )
        #expect(configuration.clientID == Self.clientID)
        #expect(configuration.redirectScheme == Self.scheme)
    }

    @Test("The app's own bundle registers the eva scheme")
    func appBundleRegistersEva() {
        // These tests are hosted in the Eva app process, so this is the shipped plist.
        // It is the guard that `registeredURLSchemes(in:)` reads the real key shape —
        // a typo there would make every scheme check pass vacuously.
        #expect(GoogleOAuthConfiguration.registeredURLSchemes(in: .main).contains("eva"))
    }

    // MARK: - The authorization request

    @Test("The authorization URL carries PKCE, S256 and nothing else surprising")
    func authorizationURLParameters() throws {
        let url = Self.configuration.authorizationURL(codeChallenge: "CHALLENGE", state: "STATE")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )

        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        #expect(items["client_id"] == Self.clientID)
        #expect(items["redirect_uri"] == Self.configuration.redirectURI)
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "openid email profile")
        #expect(items["code_challenge"] == "CHALLENGE")
        // `plain` would send the verifier itself and defeat the whole mechanism.
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "STATE")
        // A public client has no secret, and one in a query string would be in Google's
        // request logs and in the app binary.
        #expect(items["client_secret"] == nil)
    }

    // MARK: - The redirect

    @Test("The code is read out of the callback")
    func callbackYieldsTheCode() throws {
        let url = URL(string: "\(Self.scheme):/oauth2redirect?state=STATE&code=THE_CODE")!
        #expect(try GoogleOAuthConfiguration.authorizationCode(from: url, expectedState: "STATE") == "THE_CODE")
    }

    @Test("Declining on Google's consent screen is a cancellation, not a failure")
    func accessDeniedIsACancellation() throws {
        let url = URL(string: "\(Self.scheme):/oauth2redirect?error=access_denied&state=STATE")!
        #expect(try GoogleOAuthConfiguration.authorizationCode(from: url, expectedState: "STATE") == nil)
    }

    @Test("Any other error is a failure")
    func otherErrorsThrow() {
        let url = URL(string: "\(Self.scheme):/oauth2redirect?error=invalid_request&state=STATE")!
        #expect(throws: ProviderSignInError.providerFailed) {
            try GoogleOAuthConfiguration.authorizationCode(from: url, expectedState: "STATE")
        }
    }

    @Test("A callback with the wrong state is refused before its code is read")
    func stateMismatchThrows() {
        let url = URL(string: "\(Self.scheme):/oauth2redirect?state=OTHER&code=THE_CODE")!
        #expect(throws: ProviderSignInError.callbackNotForThisRequest) {
            try GoogleOAuthConfiguration.authorizationCode(from: url, expectedState: "STATE")
        }
    }

    @Test("A callback with no code is malformed")
    func missingCodeThrows() {
        for query in ["state=STATE", "state=STATE&code="] {
            let url = URL(string: "\(Self.scheme):/oauth2redirect?\(query)")!
            #expect(throws: ProviderSignInError.malformedProviderResponse) {
                try GoogleOAuthConfiguration.authorizationCode(from: url, expectedState: "STATE")
            }
        }
    }
}

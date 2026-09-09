import Foundation

/// What can go wrong on the app's side of a provider sign-in, before the Eva API is
/// involved at all.
///
/// A cancellation is deliberately **not** in here: tapping away from Apple's sheet or
/// closing the Google page is not a failure, and it is modelled as a `nil` credential by
/// the two controllers rather than as an error a screen would have to remember to
/// swallow. The one thing worse than an unexplained failure on a sign-in screen is an
/// error message for something the user chose to do.
///
/// Every message here is safe to show and safe to keep: none of them interpolates a
/// token, a code, a nonce, an address or a provider identifier (GUARDRAILS 12).
enum ProviderSignInError: LocalizedError, Equatable {

    /// `GOOGLE_IOS_CLIENT_ID` is empty in this build — nobody has provisioned the Google
    /// OAuth client yet (`docs/PROVIDER-SIGNIN.md` §4).
    case googleNotConfigured

    /// The build registers a redirect scheme that is not the one the client id implies,
    /// so the callback would be claimed by nothing. Only reachable by editing one of the
    /// two settings in `mobile/project.yml` without the other.
    case googleRedirectSchemeMismatch

    /// Apple or Google answered, but without the field the API needs — no identity token
    /// on the Apple credential, no `code` on the redirect. Not a user error, and not
    /// something a retry usually fixes.
    case malformedProviderResponse

    /// The redirect came back without the `state` this request sent.
    ///
    /// `ASWebAuthenticationSession` only delivers the callback of the session it opened,
    /// so reaching this should not be possible — which is exactly why it is checked and
    /// why it is its own case rather than folded into "malformed". If it ever fires,
    /// something answered for a request the app did not make, and the right response is
    /// to throw the code away unspent.
    case callbackNotForThisRequest

    /// The provider itself refused or failed. Its own message is deliberately dropped:
    /// provider errors are written for developers, and Apple's in particular are opaque
    /// numbers.
    case providerFailed

    var errorDescription: String? {
        switch self {
        case .googleNotConfigured:
            "Google sign-in isn't available in this build yet. Continue with Apple or your email."
        case .googleRedirectSchemeMismatch:
            "Google sign-in isn't set up correctly in this build. Continue with Apple or your email."
        case .malformedProviderResponse, .callbackNotForThisRequest:
            "That sign-in didn't complete. Try again, or continue with your email."
        case .providerFailed:
            "That sign-in didn't complete. Try again, or continue with your email."
        }
    }
}

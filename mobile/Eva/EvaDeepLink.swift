import Foundation

/// The two `eva://` URLs the website opens after an emailed link has done its work (#6).
///
/// A custom scheme rather than universal links in v1 — no associated-domains file, no
/// entitlement. The scheme is registered under `CFBundleURLTypes` in `mobile/project.yml`.
/// Both URLs carry no data: a token never travels through either, which is what keeps
/// the activation and reset tokens on the API and the website only.
enum EvaDeepLink: Equatable {
    /// `eva://activated` — the activation link has been opened and the account can sign
    /// in. The activation screen answers it by retrying sign-in with the credentials it
    /// still holds; nothing else needs to.
    case activated
    /// `eva://open` — the website has finished a password reset and hands back to the
    /// app. Opening the URL is the whole effect: the system brings the app forward, and
    /// the user logs in with the password they just set. No view handles it.
    case open

    init?(url: URL) {
        guard url.scheme == "eva" else { return nil }
        switch url.host() {
        case "activated": self = .activated
        case "open": self = .open
        default: return nil
        }
    }
}

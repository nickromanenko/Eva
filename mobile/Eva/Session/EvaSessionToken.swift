import Foundation

/// What the app reads out of its own session token: the account's uid, and nothing else.
///
/// Used for exactly one thing — choosing which local store to open when there is no `/me`
/// to ask (`AppSession.continueOffline()`, #78). The signature is **not** checked, and does
/// not need to be: the uid only names a file on this device, and the server validates the
/// token on every request the queue sends. Nothing here is trusted as identity.
enum EvaSessionToken {

    /// The `sub` claim of a JWT, or `nil` if the token is not one — or if the claim is not a
    /// plain identifier, since it becomes a file name (`EvaStore.isValid(uid:)`).
    static func subject(of token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String, EvaStore.isValid(uid: sub)
        else { return nil }
        return sub
    }
}

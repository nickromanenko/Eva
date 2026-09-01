import Foundation

enum APIError: LocalizedError {
    /// Structured error from the API: `{ error: { code, message } }`.
    case server(code: String, message: String, status: Int)
    /// A 401 on a request that actually carried a bearer token: the credential is dead,
    /// not the call. Only `APIClient.send` can tell the two apart — see the note there.
    case sessionExpired(message: String)
    /// `POST /auth/signin` answered `403 NOT_ACTIVATED`: the password was right and the
    /// address has not been confirmed yet (#6). Its own case rather than a `.server` the
    /// screen inspects, because it is not a failure to show under a field — it is a
    /// route to the activation screen. Only `AppSession.signIn` produces it.
    case notActivated(message: String)
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .server(_, let message, _): message
        case .sessionExpired(let message): message
        case .notActivated(let message): message
        case .network: "Can't reach Eva right now. Check your connection."
        case .decoding: "Something went wrong. Please try again."
        }
    }

    var code: String? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }

    /// A `429 RATE_LIMITED`. The auth screens show this as an information banner rather
    /// than a field error: nothing the user typed was wrong and nothing about the account
    /// changed (DESIGN.md §7, canvas change list `rateLimited`).
    var isRateLimited: Bool {
        if case .server(let code, _, let status) = self {
            return status == 429 || code == "RATE_LIMITED"
        }
        return false
    }
}

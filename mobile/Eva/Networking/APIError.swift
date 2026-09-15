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
    /// `429 RATE_LIMITED` (#5), with the moment the server says to come back.
    ///
    /// Its own case rather than a `.server` the screen inspects, for the reason
    /// `.notActivated` has one: nothing the user typed was wrong, nothing about the
    /// account changed, and the request was refused *before* anything happened — so it is
    /// not a failure to show under a field, it is a state the screen has to sit in until
    /// it passes. A screen that only had a string could show the message and would still
    /// leave its CTA enabled, which is the defect #38 is about: the natural response to
    /// "too many attempts" is to tap again, and tapping again spends another attempt.
    ///
    /// `retryAt` is an absolute instant, computed from `Retry-After` at the moment the
    /// response arrived, never a duration a screen counts down from. A duration ticks
    /// while the app is backgrounded and outlives the server's window; wall-clock does
    /// not. `nil` when the server sent no usable header — the banner then says less
    /// rather than guessing.
    case rateLimited(message: String, retryAt: Date?)
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .server(_, let message, _): message
        case .sessionExpired(let message): message
        case .notActivated(let message): message
        case .rateLimited(let message, _): message
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
    ///
    /// Kept as a property, rather than replaced by `if case`, because three screens
    /// already branch on it (`ActivationStepView`, `ForgotPasswordStepView`,
    /// `LinkSentStepView`) and none of them needs the window — they have a cooldown of
    /// their own. The `.server` arm stays as a floor: `APIClient` turns every 429 into
    /// `.rateLimited`, so it is unreachable today, and it costs one line to keep it true
    /// if some future path maps one differently.
    var isRateLimited: Bool {
        switch self {
        case .rateLimited: true
        case .server(let code, _, let status): status == 429 || code == "RATE_LIMITED"
        default: false
        }
    }

    /// When the server said to come back, for the screens that hold a CTA until then.
    var retryAt: Date? {
        if case .rateLimited(_, let retryAt) = self { return retryAt }
        return nil
    }
}

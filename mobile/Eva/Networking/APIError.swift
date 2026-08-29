import Foundation

enum APIError: LocalizedError {
    /// Structured error from the API: `{ error: { code, message } }`.
    case server(code: String, message: String, status: Int)
    /// A 401 on a request that actually carried a bearer token: the credential is dead,
    /// not the call. Only `APIClient.send` can tell the two apart — see the note there.
    case sessionExpired(message: String)
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .server(_, let message, _): message
        case .sessionExpired(let message): message
        case .network: "Can't reach Eva right now. Check your connection."
        case .decoding: "Something went wrong. Please try again."
        }
    }

    var code: String? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }
}

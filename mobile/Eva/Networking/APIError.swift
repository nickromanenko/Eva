import Foundation

enum APIError: LocalizedError {
    /// Structured error from the API: `{ error: { code, message } }`.
    case server(code: String, message: String, status: Int)
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .server(_, let message, _): message
        case .network: "Can't reach Eva right now. Check your connection."
        case .decoding: "Something went wrong. Please try again."
        }
    }

    var code: String? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }
}

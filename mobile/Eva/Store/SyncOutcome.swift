import Foundation

/// What the sync engine does with an operation after one attempt (§8.4).
///
/// - `acknowledged` — the server accepted it; the operation is done.
/// - `retry` — a 5xx, a 429 or a network failure: back off and try again, because **order
///   matters** and the queue blocks on it.
/// - `failed` — a 4xx (except the session's 401): the server will never accept it; mark the
///   row failed and move on so one bad entry cannot block the rest.
/// - `paused` — a 401 on a request that carried the token: the session ended, which is
///   `AppSession`'s business; the queue pauses until there is a session again, and nothing
///   is discarded.
enum SyncOutcome: Equatable {
    case acknowledged
    case retry(after: TimeInterval?)
    case failed
    case paused
}

/// What the "Couldn't sync" card says, by the class of failure behind it (owner decision,
/// 2026-10-03). A temporary failure — no connection, a 5xx, a 429 — is retried on its own;
/// a rejected entry (a 4xx) never is, and she has to look at it.
enum SyncTrouble: Equatable {
    case temporary
    case rejected

    /// The card for an outcome, or `nil` when there is nothing to say: an acknowledged
    /// operation, or a paused queue — which is the session's business, not the entry's.
    init?(_ outcome: SyncOutcome) {
        switch outcome {
        case .retry: self = .temporary
        case .failed: self = .rejected
        case .acknowledged, .paused: return nil
        }
    }

    var message: String {
        switch self {
        case .temporary: "It's saved on this device. Eva will retry automatically."
        case .rejected: "This entry couldn't be saved. Check it and try again."
        }
    }
}

/// Classifies one failure into what the engine should do. Pure — no store, and the clock is
/// `now`, so the `Retry-After` wait is exact under test rather than a few microseconds short.
func syncOutcome(for error: APIError, now: Date = Date()) -> SyncOutcome {
    switch error {
    case .sessionExpired:
        return .paused
    case .rateLimited(_, let retryAt):
        let interval = retryAt.map { max($0.timeIntervalSince(now), 0) }
        return .retry(after: interval)
    case .server(_, _, let status) where status >= 500:
        return .retry(after: nil)
    case .server, .notActivated:
        return .failed
    case .network:
        return .retry(after: nil)
    case .decoding:
        return .failed
    }
}

/// The backoff schedule: 1 s, 2 s, 4 s … capped at five minutes (§8.4). `attempts` is the
/// number of consecutive failed attempts, so the first retry waits 1 s.
func syncBackoff(attempts: Int) -> TimeInterval {
    let steps = max(0, attempts)
    // 2^9 = 512 is the first doubling past the cap, so clamping the exponent there keeps the
    // shift from overflowing without stopping the schedule short at 256.
    let seconds = Double(1 << min(steps, 9))
    return min(seconds, 300)
}

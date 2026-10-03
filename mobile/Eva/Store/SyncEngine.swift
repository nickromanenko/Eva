import Foundation
import SwiftData

/// The sync engine (A3, #78): drains the outbound queue FIFO, one operation at a time, and
/// never reorders. `perform` is the seam that actually talks to the API — injectable so the
/// queue's semantics are unit-testable without a network; in the app it is `EventSync`
/// sending through `AppSession`, which owns the token and the 401 rule.
///
/// The rules it enforces (§8.4): an acknowledged operation is removed; a 4xx is handed to
/// `failed` (which marks the row) and the queue moves on — one bad entry cannot block the
/// rest; a 5xx / 429 / network failure blocks, because order matters, and the caller is told
/// how long to back off; a 401 pauses until there is a session again, and nothing is
/// discarded.
///
/// **One pass, not a loop with a sleep in it.** The wait between attempts belongs to the
/// caller (`EventSync`), which can cut it short when the app comes back to the foreground —
/// a `Task.sleep` buried in here could only be cancelled, and a cancelled `try? await
/// Task.sleep` returns at once, which turns a backoff into a busy loop.
@MainActor
final class SyncEngine {

    /// How one pass ended.
    enum Pass: Equatable {
        /// The queue is empty.
        case drained
        /// The head failed in a way worth retrying; try again after this long.
        case blocked(retryAfter: TimeInterval)
        /// The session ended. Nothing was discarded; the head is still the head.
        case paused
    }

    private let context: ModelContext
    private let perform: @MainActor (PendingOperation) async throws -> Void
    private let failed: @MainActor (PendingOperation, APIError) -> Void

    init(
        context: ModelContext,
        perform: @escaping @MainActor (PendingOperation) async throws -> Void,
        failed: @escaping @MainActor (PendingOperation, APIError) -> Void = { _, _ in }
    ) {
        self.context = context
        self.perform = perform
        self.failed = failed
    }

    /// The head of the queue: the lowest `sequence` still pending.
    private func head() -> PendingOperation? {
        var descriptor = FetchDescriptor<PendingOperation>(sortBy: [SortDescriptor(\.sequence)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Sends operations until the queue is empty, one blocks, or the session pauses.
    func drain() async -> Pass {
        while let operation = head() {
            do {
                try await perform(operation)
                // `perform` may have removed the operation itself (a wipe mid-flight).
                if !operation.isDeleted { context.delete(operation) }
                try? context.save()
            } catch {
                let apiError = (error as? APIError) ?? .network
                switch syncOutcome(for: apiError) {
                case .acknowledged:
                    context.delete(operation)
                    try? context.save()
                case .failed:
                    failed(operation, apiError)
                    if !operation.isDeleted { context.delete(operation) }
                    try? context.save()
                case .paused:
                    return .paused
                case .retry(let after):
                    // The schedule counts *previous* failures, so the first retry waits 1 s.
                    let wait = after ?? syncBackoff(attempts: operation.attempts)
                    operation.attempts += 1
                    try? context.save()
                    return .blocked(retryAfter: wait)
                }
            }
        }
        return .drained
    }
}

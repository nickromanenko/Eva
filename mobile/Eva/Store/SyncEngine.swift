import Foundation
import SwiftData

/// The sync engine (A3, #78): drains the outbound queue FIFO, one operation at a time, and
/// never reorders. `perform` is the seam that actually talks to the API — injectable so the
/// queue's semantics are unit-testable without a network, and in the app it is the
/// `AppSession` event methods.
///
/// The rules it enforces (§8.4): an acknowledged operation is removed; a 4xx marks the row
/// `failed` and moves on (one bad entry cannot block the rest); a 5xx / 429 / network failure
/// backs off and blocks, because order matters; a 401 pauses until there is a session again,
/// and nothing is discarded.
@MainActor
final class SyncEngine {

    private let context: ModelContext
    private let perform: @MainActor (PendingOperation) async throws -> Void

    init(
        context: ModelContext,
        perform: @escaping @MainActor (PendingOperation) async throws -> Void
    ) {
        self.context = context
        self.perform = perform
    }

    /// The head of the queue: the lowest `sequence` that is still pending.
    private func head() -> PendingOperation? {
        let descriptor = FetchDescriptor<PendingOperation>(
            sortBy: [SortDescriptor(\.sequence)]
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Drains until the queue is empty, an operation blocks on a retry, or the session
    /// pauses. Call again on reconnect / foreground / after a session returns.
    func drain() async {
        while let operation = head() {
            do {
                try await perform(operation)
                context.delete(operation)
                try? context.save()
            } catch {
                switch syncOutcome(for: (error as? APIError) ?? .network) {
                case .acknowledged:
                    context.delete(operation)
                    try? context.save()
                case .failed:
                    operation.attempts += 1
                    try? context.save()
                    // The operation itself is removed by the caller, which also marks its
                    // LocalEvent `failed` with `lastError`; the queue moves on regardless.
                    context.delete(operation)
                    try? context.save()
                case .paused:
                    return
                case .retry(let after):
                    operation.attempts += 1
                    try? context.save()
                    let wait = after ?? syncBackoff(attempts: operation.attempts)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    // Loop retries the same head.
                }
            }
        }
    }
}

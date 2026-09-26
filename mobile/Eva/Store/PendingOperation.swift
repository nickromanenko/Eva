import Foundation
import SwiftData

/// One queued write (§8.4): the outbound queue is FIFO, one operation at a time, never
/// reordered — an edit must follow its creation, and a delete must follow both.
///
/// The operation is stored as its wire payload (JSON-encoded) plus the routing the engine
/// needs, so the queue survives a relaunch and drains exactly as it was enqueued.
@Model
final class PendingOperation {
    /// FIFO order, assigned by the store's monotonically increasing counter.
    var sequence: Int
    /// `OperationKind`'s raw value.
    var kind: String
    /// The event's `clientId` — the `idempotencyKey` for a create.
    var clientId: String
    /// The event's `serverId`, for update / delete / restore.
    var serverId: String?
    /// The write payload (JSON-encoded) or the empty body for delete/restore.
    var payloadData: Data?
    /// The number of consecutive failed attempts, for the backoff.
    var attempts: Int

    init(
        sequence: Int,
        kind: OperationKind,
        clientId: String,
        serverId: String? = nil,
        payloadData: Data? = nil,
        attempts: Int = 0
    ) {
        self.sequence = sequence
        self.kind = kind.rawValue
        self.clientId = clientId
        self.serverId = serverId
        self.payloadData = payloadData
        self.attempts = attempts
    }
}

enum OperationKind: String {
    case create
    case update
    case bodySignals
    case delete
    case restore
}

import Foundation
import SwiftData

/// One calendar entry in the local store (A3, #78): a cache of `EvaEvent` (§4), field for
/// field, plus the device-only fields the sync engine needs.
///
/// **`clientId` is the `idempotencyKey`** (§8.2): a UUID created on the device when the
/// entry is logged, sent on `POST /me/events`, and what makes a retried create idempotent.
/// `serverId` is the API's id, `nil` until the create is acknowledged.
@Model
final class LocalEvent {
    /// The API's id (`EvaEvent.id`), `nil` until the create is acknowledged.
    var serverId: String?
    /// The device-generated UUID — **is** the `idempotencyKey` sent on create.
    var clientId: String
    var localDate: String
    var loggedAt: String
    /// `EvaEventType`'s raw value, so the store has no dependency on the wire enum's cases.
    var type: String
    /// The write payload, JSON-encoded. Stored as data so the store is agnostic to the
    /// payload enum's shape.
    var payloadData: Data
    var note: String?
    /// `EvaEventSource`'s raw value.
    var source: String
    /// Set when a delete is queued or acknowledged — the row leaves the screen immediately.
    var deletedAt: Date?
    var syncState: String
    /// The API error `code` for the "Couldn't sync your last entry" card.
    var lastError: String?

    init(
        serverId: String? = nil,
        clientId: String,
        localDate: String,
        loggedAt: String,
        type: String,
        payloadData: Data,
        note: String? = nil,
        source: String = EvaEventSource.user.rawValue,
        deletedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        lastError: String? = nil
    ) {
        self.serverId = serverId
        self.clientId = clientId
        self.localDate = localDate
        self.loggedAt = loggedAt
        self.type = type
        self.payloadData = payloadData
        self.note = note
        self.source = source
        self.deletedAt = deletedAt
        self.syncState = syncState.rawValue
        self.lastError = lastError
    }
}

/// `LocalEvent.syncState`, as the store's own vocabulary.
enum SyncState: String {
    case synced
    case pendingCreate
    case pendingUpdate
    case pendingDelete
    case failed
}

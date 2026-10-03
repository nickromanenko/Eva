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
    /// The event's `payload` object exactly as the wire carries it, JSON-encoded. Stored as
    /// data so the store is agnostic to the payload enum's shape, and so `EvaEvent`'s own
    /// decoder is the one reader of it (`evaEvent()`).
    var payloadData: Data
    var note: String?
    /// `EvaEventSource`'s raw value.
    var source: String
    /// Set when a delete is queued or acknowledged — the row leaves the screen immediately.
    var deletedAt: Date?
    var syncState: String
    /// The API error `code` for the "Couldn't sync your last entry" card.
    var lastError: String?
    /// Whether this device created the entry. Decides which id the screens use for it —
    /// see `displayId`.
    var isLocalOrigin: Bool = false

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
        lastError: String? = nil,
        isLocalOrigin: Bool = false
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
        self.isLocalOrigin = isLocalOrigin
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

extension LocalEvent {

    /// The id the screens use, **stable for as long as the row is on this device**.
    ///
    /// An entry logged here keeps its `clientId` even after the server acknowledges it: a
    /// row whose id changed under her finger a second after saving would re-identify in
    /// every list that draws it, mid-tap. An entry that arrived from the server uses the
    /// server's id, which is what `CalendarUITests` addresses the entries it POSTed by.
    var displayId: String {
        isLocalOrigin ? clientId : (serverId ?? clientId)
    }

    var state: SyncState { SyncState(rawValue: syncState) ?? .synced }

    var eventType: EvaEventType? { EvaEventType(rawValue: type) }

    /// The row as the screens read it — decoded by `EvaEvent`'s own decoder, from the same
    /// JSON shape `GET /me/events` serves, so a row and a fetched entry cannot disagree
    /// about what a payload means. `nil` for a row this build cannot read, which the range
    /// read skips exactly as `EvaEventsResponse` skips an unreadable server row.
    func evaEvent() -> EvaEvent? {
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) else { return nil }
        var object: [String: Any] = [
            "id": displayId,
            "type": type,
            "localDate": localDate,
            "loggedAt": loggedAt,
            "source": source,
            "payload": payload,
            "idempotencyKey": clientId
        ]
        if let note { object["note"] = note }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(EvaEvent.self, from: data)
    }

    /// The write that sends this row as it stands now — what a queued create, upsert or edit
    /// carries when it is finally sent. Built at send time rather than frozen at enqueue
    /// time, so an entry edited twice offline goes out once with its latest content.
    ///
    /// `nil` for the types the app cannot write (`sex`, `positiveTest`), which only ever
    /// arrive from the server.
    func write(timeZone: String?) -> EvaEventWrite? {
        guard let event = evaEvent(), let payload = event.detail.payload else { return nil }
        return EvaEventWrite(
            payload: payload,
            localDate: event.localDate,
            note: note,
            idempotencyKey: clientId,
            timeZone: timeZone ?? TimeZone.current.identifier
        )
    }

    /// Takes the server's copy of the entry: its id, and every field the server owns.
    /// `deletedAt` is left alone — a delete she made on this device is hers until its own
    /// operation is acknowledged.
    func absorb(_ event: EvaEvent) {
        serverId = event.id
        localDate = event.localDate.isoDate
        loggedAt = event.loggedAt
        type = event.type.rawValue
        payloadData = Self.payloadData(for: event.detail)
        note = event.note
        source = event.source.rawValue
    }

    /// A payload as the wire spells it. `{}` for the payload-less types.
    static func payloadData(for detail: EvaEventDetail) -> Data {
        guard let payload = detail.payload else { return Data("{}".utf8) }
        return payloadData(for: payload)
    }

    static func payloadData(for payload: EvaEventPayload) -> Data {
        (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
    }

    /// A row for an entry that arrived from the server.
    ///
    /// The `clientId` is the entry's own `idempotencyKey` when it has one — which is what
    /// lets a reconcile recognise an entry this device created but never heard back about —
    /// and a server-derived one otherwise, which nothing will ever send as a key.
    static func synced(from event: EvaEvent) -> LocalEvent {
        LocalEvent(
            serverId: event.id,
            clientId: event.idempotencyKey ?? "server:\(event.id)",
            localDate: event.localDate.isoDate,
            loggedAt: event.loggedAt,
            type: event.type.rawValue,
            payloadData: payloadData(for: event.detail),
            note: event.note,
            source: event.source.rawValue,
            syncState: .synced
        )
    }
}

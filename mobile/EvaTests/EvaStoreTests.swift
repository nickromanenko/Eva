import Foundation
import SwiftData
import Testing

@testable import Eva

/// The store's write-through and queue semantics (#78, §8.4): a logged entry is in the store
/// immediately, and its operation is queued FIFO. In-memory, so these run without touching
/// the simulator's Application Support.
@Suite("Issue #78 · the store writes through and queues", .serialized)
@MainActor
struct EvaStoreTests {

    private let store: EvaStore

    init() throws {
        store = try EvaStore(uid: "test-uid", inMemory: true)
    }

    @Test("a logged entry is visible in the store immediately, in pendingCreate")
    func writeThroughIsVisible() throws {
        let date = "2026-09-01"
        let event = store.upsertPendingCreate(
            clientId: UUID().uuidString,
            localDate: date,
            loggedAt: "2026-09-01T09:00:00",
            type: "sport",
            payloadData: Data("{}".utf8),
            note: nil,
            source: "user"
        )

        #expect(event.syncState == SyncState.pendingCreate.rawValue)

        let read = store.localEvents(from: EvaDay(isoDate: date)!, through: EvaDay(isoDate: date)!)
        #expect(read.count == 1)
        #expect(read.first?.clientId == event.clientId)
    }

    @Test("soft-deleted rows are not read back")
    func deletedRowsAreHidden() throws {
        let date = "2026-09-02"
        let event = store.upsertPendingCreate(
            clientId: UUID().uuidString,
            localDate: date,
            loggedAt: "2026-09-02T09:00:00",
            type: "sport",
            payloadData: Data("{}".utf8),
            note: nil,
            source: "user"
        )
        event.deletedAt = Date()
        try store.container.mainContext.save()

        let read = store.localEvents(from: EvaDay(isoDate: date)!, through: EvaDay(isoDate: date)!)
        #expect(read.isEmpty)
    }

    @Test("operations are queued FIFO")
    func queueIsFifo() {
        store.enqueue(.create, clientId: "a")
        store.enqueue(.create, clientId: "b")
        store.enqueue(.create, clientId: "c")

        let queued = (try? store.container.mainContext.fetch(
            FetchDescriptor<PendingOperation>(sortBy: [SortDescriptor(\.sequence)])
        )) ?? []

        #expect(queued.map(\.clientId) == ["a", "b", "c"])
        #expect(queued.map(\.sequence) == [1, 2, 3])
    }
}

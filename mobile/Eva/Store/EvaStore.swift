import Foundation
import SwiftData

/// The local store's container (A3, #78): SwiftData, one store file per account, kept out of
/// backups and protected like the rest of her health record.
///
/// **The server is the copy of record.** The store is a cache — wiped on log-out and account
/// deletion — and it must never become a second, backup-restorable copy of her health data
/// (§8.2, the same rule the Keychain token follows). The file sits in Application Support
/// with `NSFileProtectionCompleteUntilFirstUserAuthentication` (background sync must be able
/// to open it after a reboot-and-unlock) and is excluded from iCloud and iTunes backup.
@MainActor
final class EvaStore {

    let container: ModelContainer
    private let uid: String

    init(uid: String) throws {
        self.uid = uid
        let schema = Schema([LocalEvent.self, PendingOperation.self])
        let configuration = ModelConfiguration(schema: schema, url: Self.url(for: uid))
        container = try ModelContainer(for: schema, configurations: [configuration])
        Self.harden(Self.url(for: uid))
    }

    /// The one store file, keyed to the uid so a second account on the same device starts
    /// empty rather than reading the previous account's events.
    private static func url(for uid: String) -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return directory.appendingPathComponent("eva-\(uid).store")
    }

    /// File protection and backup exclusion, applied to the store file and its supporting
    /// files. Best-effort: a failure here is a device-level fault with no screen, and the
    /// Keychain's equivalent is handled the same way.
    private static func harden(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (
            try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        ) ?? []
        for file in files where file.lastPathComponent.hasPrefix(url.lastPathComponent) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = file
            try? mutable.setResourceValues(values)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path
            )
        }
    }

    /// Wipes the store — the log-out, account-deletion and `EVA_UITEST_RESET` path (§8.5).
    func reset() {
        let context = container.mainContext
        try? context.delete(model: LocalEvent.self)
        try? context.delete(model: PendingOperation.self)
        try? context.save()
    }

    /// A new account on the same device starts empty: the store is keyed to the uid, so a
    /// store file for a different uid is the caller's signal to wipe before switching.
    func belongsTo(_ other: String) -> Bool { uid == other }

    /// Wipes every store file, whatever account it belonged to — the `EVA_UITEST_RESET`
    /// path (§8.5), whose contract is "a fresh install", and a fresh install has no store.
    static func wipeAll() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let files = (
            try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        ) ?? []
        for file in files where file.lastPathComponent.hasPrefix("eva-") && file.pathExtension == "store" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

import Foundation
import Security

/// Persists the API JWT in the Keychain. Stateless (the Keychain itself holds
/// the data), hence trivially Sendable.
///
/// ## What a failure here means, and what the app does about it (#64)
///
/// Both writes used to discard their `OSStatus`, so `logOut()` set `state = .signedOut`
/// whether or not the token was gone — and the next launch would find it, validate it, and
/// land the user back on the dashboard they had just left. Since #61 made `logOut()` the
/// only exit from `.unreachable`, that stranded a user in a degraded app with no way out
/// and no signal that anything had happened.
///
/// So both calls now report. The decision the issue asked for, stated once here because
/// there is no good screen for "we could not forget your token" and inventing an alarming
/// one for a case nobody will hit is its own mistake:
///
/// - **A failed delete falls back to neutralising the item**, not to pretending. If
///   `SecItemDelete` returns anything but success or `errSecItemNotFound`, the value is
///   overwritten with nothing; `token` reads an empty item as absent, so the credential is
///   unusable even though the row survives. That covers every realistic failure — the item
///   is *there*, which is why the delete had something to fail on.
/// - **Only if the overwrite fails too does `clear()` return `false`.** That is a Keychain
///   that will neither delete nor update, which is a device-level fault with no move
///   available to an app; `AppSession.logOut()` signs the user out regardless, because
///   they asked to leave and refusing would be worse than the stale token.
/// - **A failed save does not fail the sign-in.** The user has just authenticated and the
///   server has granted a session; refusing it strands them, while proceeding costs them a
///   sign-in again on next launch. `AppSession.apply(_:)` says the same thing at the call
///   site.
///
/// ## Accessibility, and why saving deletes first
///
/// Neither call set `kSecAttrAccessible`, so items defaulted to
/// `kSecAttrAccessibleWhenUnlocked` — **synced into encrypted backups and restorable onto
/// another device.** For a 30-day bearer token over a health record that is the wrong
/// default, and #61 lengthened how long one lives on the device.
///
/// `…AfterFirstUnlockThisDeviceOnly` instead: never in a backup, and readable after the
/// first unlock following a reboot, which is what a launch needs.
///
/// Changing the attribute is not a no-op. `SecItemUpdate` does not migrate an item stored
/// under a different accessibility, so `save` deletes and adds rather than updating — which
/// is also the only thing that moves an existing install off the old attribute. The
/// attribute is deliberately **absent from `query`**: in a search, delete or update,
/// `kSecAttrAccessible` is a *filter*, so including it would stop every one of them
/// matching the very items this is meant to migrate.
final class KeychainTokenStore: Sendable {
    static let shared = KeychainTokenStore()

    /// Identifies one item by its account under the one service. No `kSecAttrAccessible`
    /// here — see the note above the class.
    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evaapp.ios",
            kSecAttrAccount as String: account,
        ]
    }

    private var query: [String: Any] { query(account: "api-jwt") }

    /// The stored JWT, or `nil` if there is none — which includes an item `clear()` could
    /// only neutralise. An empty value is not a credential, and treating it as one would
    /// send an `Authorization: Bearer ` header and turn a Keychain fault into a 401 loop.
    var token: String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Stores `token`, replacing whatever was there. `false` means nothing was stored and
    /// this device has no session across a relaunch.
    @discardableResult
    func save(_ token: String) -> Bool {
        // Delete-then-add, not update: an item written under the old accessibility is not
        // migrated in place, and this is the one path that moves an existing install.
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the token, or — if the Keychain refuses to remove it — makes it unusable.
    /// `false` means neither worked and a live token is still on this device.
    @discardableResult
    func clear() -> Bool {
        let deleted = SecItemDelete(query as CFDictionary)
        if deleted == errSecSuccess || deleted == errSecItemNotFound { return true }
        // The item exists (that is what the delete failed on) and cannot be removed. An
        // empty value is not a credential, so overwriting is as good as forgetting for
        // every purpose the caller has.
        let emptied = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: Data()] as CFDictionary
        )
        return emptied == errSecSuccess
    }

    // MARK: Device registry (#79)

    /// A stable id for this install, minted once and kept for the app's life — the `deviceId`
    /// the push-token route is keyed on, so a token rotation replaces a row rather than adds
    /// one (ARCHITECTURE §9.2). Not a secret; it identifies a device to our own API and
    /// nothing else. Written with the same device-only accessibility as the JWT.
    var deviceId: String {
        if let existing = read(account: "device-id") { return existing }
        let fresh = UUID().uuidString
        _ = write(fresh, account: "device-id")
        return fresh
    }

    /// The APNs device token this install last received, as a hex string — an identifier that
    /// reaches Apple, so it is handled like a credential: never logged, never echoed.
    var deviceToken: String? { read(account: "device-token") }

    @discardableResult
    func saveDeviceToken(_ token: String) -> Bool { write(token, account: "device-token") }

    /// The token last *sent* to `PUT /me/devices/{deviceId}`, so an unchanged token is not
    /// re-registered on every launch.
    var registeredDeviceToken: String? { read(account: "device-token-registered") }

    @discardableResult
    func markDeviceTokenRegistered(_ token: String) -> Bool {
        write(token, account: "device-token-registered")
    }

    private func read(account: String) -> String? {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    private func write(_ value: String, account: String) -> Bool {
        SecItemDelete(query(account: account) as CFDictionary)
        var item = query(account: account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

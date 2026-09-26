import Foundation
import Security
import Testing

@testable import Eva

/// What the token store actually writes (#64).
///
/// The accessibility attribute is the half that is assertable without simulating a
/// Keychain fault, and it is the half that matters most: before this, the item defaulted to
/// `kSecAttrAccessibleWhenUnlocked` and travelled in encrypted backups, restorable onto
/// different hardware with a live 30-day session over a health record inside it.
///
/// These run against the test host's real Keychain, which is why every case clears the item
/// on the way in and on the way out — and why the suite needs a signed host (GUARDRAILS 23:
/// an unsigned app has no Keychain entitlement, and every call here would fail with
/// `errSecMissingEntitlement` rather than prove anything).
///
/// `.serialized` because there is exactly one item, identified by a fixed service and
/// account, and these cases write to it. Run in parallel they would be writing over each
/// other's fixtures.
@Suite("Issue #64 · what the token store writes", .serialized)
struct KeychainTokenStoreTests {
    private let store = KeychainTokenStore.shared

    /// The same item `KeychainTokenStore` identifies, spelled out here rather than reached
    /// for through the type: a test that asked the store for its own query could not notice
    /// the store asking for the wrong one.
    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evaapp.ios",
            kSecAttrAccount as String: "api-jwt",
        ]
    }

    private func attributes() -> [String: Any]? {
        var query = itemQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? [String: Any]
    }

    private func accessibility() -> String? {
        attributes()?[kSecAttrAccessible as String] as? String
    }

    init() {
        SecItemDelete(itemQuery as CFDictionary)
    }

    @Test("a saved token is not restorable onto another device")
    func savedTokenIsThisDeviceOnly() {
        defer { SecItemDelete(itemQuery as CFDictionary) }

        #expect(store.save("header.payload.signature"))

        // Anything else — the old default `kSecAttrAccessibleWhenUnlocked` included — puts
        // a live session over a health record into an encrypted backup.
        #expect(accessibility() == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test("saving migrates an item written under the old accessibility")
    func saveMigratesLegacyItems() {
        defer { SecItemDelete(itemQuery as CFDictionary) }
        // Exactly what an install from before #64 carries. `SecItemUpdate` does not migrate
        // accessibility in place, which is why `save` deletes and adds — and why an upgrade
        // that only updated would leave every existing user backup-restorable forever.
        var legacy = itemQuery
        legacy[kSecValueData as String] = Data("old.token.value".utf8)
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        #expect(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess)
        #expect(accessibility() == kSecAttrAccessibleWhenUnlocked as String)

        #expect(store.save("new.token.value"))

        #expect(accessibility() == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(store.token == "new.token.value")
    }

    @Test("a token round-trips, and clear removes it")
    func roundTripAndClear() {
        defer { SecItemDelete(itemQuery as CFDictionary) }

        #expect(store.save("header.payload.signature"))
        #expect(store.token == "header.payload.signature")

        #expect(store.clear())

        #expect(store.token == nil)
        #expect(attributes() == nil, "clear() reported success, so the item should be gone")
    }

    @Test("an emptied item reads as no token at all")
    func emptiedItemIsNotACredential() {
        defer { SecItemDelete(itemQuery as CFDictionary) }
        // The state `clear()` falls back to when the Keychain refuses a delete: the row
        // survives, the credential does not. If `token` returned "" the app would send
        // `Authorization: Bearer ` and turn a Keychain fault into a 401 loop.
        #expect(store.save("header.payload.signature"))
        #expect(
            SecItemUpdate(
                itemQuery as CFDictionary,
                [kSecValueData as String: Data()] as CFDictionary
            ) == errSecSuccess
        )

        #expect(store.token == nil)
    }

    @Test("clearing nothing is still success")
    func clearingNothingSucceeds() {
        // `errSecItemNotFound` is the ordinary case on a fresh install and on a second
        // `logOut()`. Reporting it as a failure would make the honest signal meaningless
        // the first time anyone saw it.
        #expect(store.clear())
    }

    // MARK: Device registry (#79)

    @Test("the device id is minted once and stable across reads")
    func deviceIdIsStable() {
        defer { SecItemDelete(deviceIdQuery as CFDictionary) }

        let first = store.deviceId
        let second = store.deviceId

        #expect(first == second, "deviceId must not change between reads")
        #expect(first.contains("-"), "a UUID, not an accidental stable empty string")
    }

    @Test("the device token round-trips and the registered marker tracks it")
    func deviceTokenRoundTrip() {
        defer {
            SecItemDelete(deviceTokenQuery as CFDictionary)
            SecItemDelete(registeredDeviceTokenQuery as CFDictionary)
        }

        #expect(store.deviceToken == nil)
        #expect(store.saveDeviceToken("abc123"))
        #expect(store.deviceToken == "abc123")

        #expect(store.markDeviceTokenRegistered("abc123"))
        #expect(store.registeredDeviceToken == "abc123")
    }

    private var deviceIdQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evaapp.ios",
            kSecAttrAccount as String: "device-id",
        ]
    }

    private var deviceTokenQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evaapp.ios",
            kSecAttrAccount as String: "device-token",
        ]
    }

    private var registeredDeviceTokenQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evaapp.ios",
            kSecAttrAccount as String: "device-token-registered",
        ]
    }
}

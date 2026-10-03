import Foundation
import Security
import SharedCore
import XCTest

/// Runs in the iOS application test host against the real Keychain through
/// the store the shared core uses for gateway sessions. Every query names a
/// newly generated account or service; no test enumerates, reads, or deletes
/// existing sessions.
@MainActor
final class IOSCredentialNativeTests: XCTestCase {
    func testCoreStoreSavesUpdatesAndDeletesOnlyItsKey() throws {
        XCTAssertEqual(CoreKeychainSecureStore.defaultService, "com.dbpprt.dieter.ios.core")
        let store = CoreKeychainSecureStore()
        let origin = "https://keychain-\(UUID().uuidString.lowercased()).invalid:443"
        let other = "https://keychain-\(UUID().uuidString.lowercased()).invalid:8443"
        addTeardownBlock {
            store.delete(key: origin)
            store.delete(key: other)
        }
        XCTAssertNil(store.read(key: origin))
        store.write(key: origin, value: "first-test-token")
        store.write(key: other, value: "separate-test-token")
        store.write(key: origin, value: "updated-test-token")

        // A separate instance reads what this one wrote: the backend is the
        // Keychain, not memory.
        XCTAssertEqual(CoreKeychainSecureStore().read(key: origin), "updated-test-token")
        store.delete(key: origin)
        store.delete(key: origin)
        XCTAssertNil(store.read(key: origin))
        XCTAssertEqual(store.read(key: other), "separate-test-token")
    }

    func testStoredSessionIsDeviceLocalAndAvailableAfterFirstUnlock() throws {
        let service = "com.dbpprt.dieter.ios.native-tests.\(UUID().uuidString)"
        let account = "https://\(UUID().uuidString.lowercased()).invalid:443"
        let store = CoreKeychainSecureStore(service: service)
        addTeardownBlock { store.delete(key: account) }
        store.write(key: account, value: "isolated-test-token")
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        // An update keeps the item's protection.
        store.write(key: account, value: "updated-test-token")
        result = nil
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(
            (result as? [String: Any])?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testServicesKeepSeparateSessionsForTheSameGateway() throws {
        let account = "https://\(UUID().uuidString.lowercased()).invalid:443"
        let first = CoreKeychainSecureStore(service: "com.dbpprt.dieter.ios.native-tests.\(UUID().uuidString)")
        let second = CoreKeychainSecureStore(service: "com.dbpprt.dieter.ios.native-tests.\(UUID().uuidString)")
        addTeardownBlock {
            first.delete(key: account)
            second.delete(key: account)
        }
        first.write(key: account, value: "first-service-token")
        XCTAssertNil(second.read(key: account))
        second.write(key: account, value: "second-service-token")
        XCTAssertEqual(first.read(key: account), "first-service-token")
        first.delete(key: account)
        XCTAssertNil(first.read(key: account))
        XCTAssertEqual(second.read(key: account), "second-service-token")
    }
}

import DieterShared
import Foundation
import OSLog
import Security

/// Gateway session tokens as device-local Keychain generic passwords, one per
/// gateway origin (`https://host:port`) under one service. Items are readable
/// after the first unlock, never leave the device, and are not synchronizable.
/// The core calls it synchronously from its own thread.
package final class CoreKeychainSecureStore: NSObject, NativeSecureStore, Sendable {
    /// The iOS app's service. Earlier releases' items (another service) are
    /// not read, so every install signs in once.
    package static let defaultService = "com.dbpprt.dieter.ios.core"

    private static let logger = Logger(subsystem: "com.dbpprt.dieter", category: "SecureStore")
    package let service: String

    package init(service: String = CoreKeychainSecureStore.defaultService) {
        self.service = service
    }

    package func read(key: String) -> String? {
        var query = identity(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    package func write(key: String, value: String) {
        let query = identity(key)
        let changes: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = Data(value.utf8)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            }
        }
        if status != errSecSuccess {
            Self.logger.error("Keychain write failed: \(status, privacy: .public)")
        }
    }

    package func delete(key: String) {
        let status = SecItemDelete(identity(key) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.error("Keychain delete failed: \(status, privacy: .public)")
        }
    }

    private func identity(_ key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecAttrSynchronizable: false,
        ]
    }
}

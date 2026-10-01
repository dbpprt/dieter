#if os(iOS)
    import Foundation
    import DieterShared
    import OSLog
    import Security
    import SharedCore

    /// The only iOS-specific persistence edge required by the shared core.
    /// Routing, RPC, HTTP, signatures, settings, logging, and control channels
    /// use the canonical adapters from the SharedCore Swift target.
    final class IOSCoreSecureStore: NSObject, NativeSecureStore, Sendable {
        private static let logger = Logger(
            subsystem: "com.dbpprt.dieter.ios", category: "SharedCore")
        private let service = "com.dbpprt.dieter.ios.shared-core"

        func read(key: String) -> String? {
            var query = identity(key)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func write(key: String, value: String) {
            let query = identity(key)
            let changes: [CFString: Any] = [kSecValueData: Data(value.utf8)]
            var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData] = Data(value.utf8)
                item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            if status != errSecSuccess {
                Self.logger.error("Keychain write failed: \(status)")
            }
        }

        func delete(key: String) {
            let status = SecItemDelete(identity(key) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                Self.logger.error("Keychain delete failed: \(status)")
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
#endif

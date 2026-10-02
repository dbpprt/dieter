import DieterCore
import Foundation
import Security

#if os(iOS)
    package enum DieterCredentialStore {
        private static let storage = DieterCredentialKeychainStore()

        package static func token(for endpoint: DieterEndpoint) async -> String? {
            await storage.token(for: endpoint.credentialID)
        }

        package static func save(_ token: String, for endpoint: DieterEndpoint) async throws {
            try await storage.save(token, for: endpoint.credentialID)
        }

        package static func remove(for endpoint: DieterEndpoint) async throws {
            try await storage.remove(for: endpoint.credentialID)
        }
    }
#endif

/// Gateway sessions are device-local Keychain items on iOS. The service/account
/// pair separates gateway origins, and tokens never enter UserDefaults, a
/// projection checkpoint, or an iCloud-synchronizable Keychain item.
package actor DieterCredentialKeychainStore {
    private let service: String

    package init(service: String = "com.dbpprt.dieter.ios.gateway-sessions") {
        self.service = service
    }

    package func token(for credentialID: String) -> String? {
        var query = identityQuery(for: credentialID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    package func save(_ token: String, for credentialID: String) throws {
        try Task.checkCancellation()
        let query = identityQuery(for: credentialID)
        let changes: [CFString: Any] = [kSecValueData: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = Data(token.utf8)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw DieterCredentialKeychainError(status: status) }
    }

    package func remove(for credentialID: String) throws {
        let status = SecItemDelete(identityQuery(for: credentialID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DieterCredentialKeychainError(status: status)
        }
    }

    private func identityQuery(for credentialID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credentialID,
            kSecAttrSynchronizable: false,
        ]
    }
}

package struct DieterCredentialKeychainError: LocalizedError {
    package let status: OSStatus
    package var errorDescription: String? {
        "Dieter could not access its secure session storage (\(status))."
    }
}

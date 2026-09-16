import DieterCore
import Foundation
import Security

package enum DieterCredentialStore {
    #if os(iOS)
        private static let storage = DieterCredentialKeychainStore()
    #else
        private static let storage = DieterCredentialFileStore(fileURL: DieterCredentialFileStore.defaultFileURL())
    #endif

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

package actor DieterCredentialFileStore {
    private let fileURL: URL
    private let fileManager: FileManager

    package init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    package static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport =
            (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ))
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        #if os(iOS)
            let identifier = "com.dbpprt.dieter.ios"
        #else
            let identifier = "com.dbpprt.dieter.mac"
        #endif
        return
            applicationSupport
            .appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "gateway-sessions.json", directoryHint: .notDirectory)
    }

    package func token(for credentialID: String) -> String? {
        try? loadTokens()[credentialID]
    }

    package func save(_ token: String, for credentialID: String) throws {
        try Task.checkCancellation()
        var tokens = try loadTokens()
        tokens[credentialID] = token
        try persist(tokens)
    }

    package func remove(for credentialID: String) throws {
        var tokens = try loadTokens()
        guard tokens.removeValue(forKey: credentialID) != nil else { return }
        try persist(tokens)
    }

    private func loadTokens() throws -> [String: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ tokens: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(tokens).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

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

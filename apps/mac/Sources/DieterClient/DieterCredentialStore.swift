import DieterCore
import Foundation

package enum DieterCredentialStore {
    private static let storage = DieterCredentialFileStore(fileURL: DieterCredentialFileStore.defaultFileURL())

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
            ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        return
            applicationSupport
            .appending(path: "com.dbpprt.dieter.mac", directoryHint: .isDirectory)
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

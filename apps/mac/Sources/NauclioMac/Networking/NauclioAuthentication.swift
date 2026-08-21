import AppKit
import CryptoKit
import Foundation
import Security

enum NauclioAuthenticationError: LocalizedError {
    case secureEndpointRequired, invalidResponse, missingCode, sessionInProgress, couldNotOpenBrowser
    var errorDescription: String? {
        switch self {
        case .secureEndpointRequired: "Remote sign-in requires an HTTPS endpoint."
        case .invalidResponse: "Nauclio rejected the authentication exchange."
        case .missingCode: "The authentication callback did not contain a code."
        case .sessionInProgress: "A Nauclio sign-in is already in progress."
        case .couldNotOpenBrowser: "Nauclio could not open the system browser."
        }
    }
}

enum NauclioCredentialStore {
    private static let legacyStorage = NauclioCredentialFileStore(fileURL: NauclioCredentialFileStore.defaultFileURL())
    private static let service = "com.dbpprt.nauclio.mac.gateway-session"

    static func token(for endpoint: NauclioEndpoint) async -> String? {
        if let token = keychainToken(for: endpoint.credentialID) { return token }
        guard let legacy = await legacyStorage.token(for: endpoint.credentialID) else { return nil }
        if (try? saveToKeychain(legacy, for: endpoint.credentialID)) != nil {
            await legacyStorage.remove(for: endpoint.credentialID)
        }
        return legacy
    }

    static func save(_ token: String, for endpoint: NauclioEndpoint) async throws {
        try saveToKeychain(token, for: endpoint.credentialID)
        await legacyStorage.remove(for: endpoint.credentialID)
    }

    static func remove(for endpoint: NauclioEndpoint) async {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint.credentialID,
        ]
        SecItemDelete(query as CFDictionary)
        await legacyStorage.remove(for: endpoint.credentialID)
    }

    private static func keychainToken(for credentialID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToKeychain(_ token: String, for credentialID: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status: OSStatus
        if SecItemCopyMatching(key as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not store the gateway session in Keychain."])
        }
    }
}

actor NauclioCredentialFileStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        return applicationSupport
            .appending(path: "com.dbpprt.nauclio.mac", directoryHint: .isDirectory)
            .appending(path: "gateway-sessions.json", directoryHint: .notDirectory)
    }

    func token(for credentialID: String) -> String? {
        try? loadTokens()[credentialID]
    }

    func save(_ token: String, for credentialID: String) throws {
        var tokens = try loadTokens()
        tokens[credentialID] = token
        try persist(tokens)
    }

    func remove(for credentialID: String) {
        do {
            var tokens = try loadTokens()
            guard tokens.removeValue(forKey: credentialID) != nil else { return }
            try persist(tokens)
        } catch {
            // A missing or unreadable credential already behaves as signed out.
        }
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

@MainActor
final class NauclioAuthentication {
    private struct PendingAuthentication: Codable {
        let endpoint: NauclioEndpoint
        let verifier: String
    }

    private static let pendingKey = "NauclioPendingAuthentication"
    private var callbackContinuation: CheckedContinuation<URL, any Error>?

    func signIn(to endpoint: NauclioEndpoint) async throws -> String {
        guard endpoint.secure else { throw NauclioAuthenticationError.secureEndpointRequired }
        guard callbackContinuation == nil else { throw NauclioAuthenticationError.sessionInProgress }
        let verifier = Self.randomURLToken(bytes: 48)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        var components = URLComponents()
        components.scheme = "https"; components.host = endpoint.host
        if endpoint.port != 443 { components.port = endpoint.port }
        components.path = "/auth/github/start"
        components.queryItems = [URLQueryItem(name: "native_redirect_uri", value: "nauclio-mac://oauth/callback"), URLQueryItem(name: "native_code_challenge", value: challenge)]
        guard let authorizeURL = components.url else { throw NauclioAuthenticationError.invalidResponse }
        persistPending(.init(endpoint: endpoint.gatewayEndpoint, verifier: verifier))
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            guard NSWorkspace.shared.open(authorizeURL) else {
                callbackContinuation = nil
                clearPending()
                continuation.resume(throwing: NauclioAuthenticationError.couldNotOpenBrowser)
                return
            }
        }
        callbackContinuation = nil
        defer { clearPending() }
        return try await exchange(callbackURL: callbackURL, pending: .init(endpoint: endpoint.gatewayEndpoint, verifier: verifier))
    }

    @discardableResult
    func complete(url: URL) -> Bool {
        guard isCallback(url), let continuation = callbackContinuation else { return false }
        callbackContinuation = nil
        continuation.resume(returning: url)
        return true
    }

    /// Completes an OAuth callback delivered after the app was relaunched.
    func resumePending(url: URL) async throws -> NauclioEndpoint? {
        guard isCallback(url), callbackContinuation == nil,
              let data = UserDefaults.standard.data(forKey: Self.pendingKey),
              let pending = try? JSONDecoder().decode(PendingAuthentication.self, from: data) else { return nil }
        defer { clearPending() }
        _ = try await exchange(callbackURL: url, pending: pending)
        return pending.endpoint
    }

    private func exchange(callbackURL: URL, pending: PendingAuthentication) async throws -> String {
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { throw NauclioAuthenticationError.missingCode }
        var exchange = URLComponents()
        exchange.scheme = "https"
        exchange.host = pending.endpoint.host
        if pending.endpoint.port != 443 { exchange.port = pending.endpoint.port }
        exchange.path = "/auth/native/exchange"
        var request = URLRequest(url: exchange.url!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(code: code, verifier: pending.verifier))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NauclioAuthenticationError.invalidResponse }
        let token = try JSONDecoder().decode(ExchangeResponse.self, from: data).accessToken
        try await NauclioCredentialStore.save(token, for: pending.endpoint)
        return token
    }

    private func persistPending(_ pending: PendingAuthentication) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
    }

    private func clearPending() {
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
    }

    private func isCallback(_ url: URL) -> Bool {
        url.scheme == "nauclio-mac" && url.host == "oauth" && url.path == "/callback"
    }

    private struct ExchangeRequest: Encodable { let code: String; let verifier: String }
    private struct ExchangeResponse: Decodable { let accessToken: String }
    private static func randomURLToken(bytes: Int) -> String { Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString() }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

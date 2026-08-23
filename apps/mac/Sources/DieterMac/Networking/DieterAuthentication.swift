import AppKit
import CryptoKit
import Foundation

enum DieterAuthenticationError: LocalizedError {
    case secureEndpointRequired, invalidResponse, missingCode, sessionInProgress, couldNotOpenBrowser
    var errorDescription: String? {
        switch self {
        case .secureEndpointRequired: "Remote sign-in requires an HTTPS endpoint."
        case .invalidResponse: "Dieter rejected the authentication exchange."
        case .missingCode: "The authentication callback did not contain a code."
        case .sessionInProgress: "A Dieter sign-in is already in progress."
        case .couldNotOpenBrowser: "Dieter could not open the system browser."
        }
    }
}

enum DieterCredentialStore {
    private static let storage = DieterCredentialFileStore(fileURL: DieterCredentialFileStore.defaultFileURL())

    static func token(for endpoint: DieterEndpoint) async -> String? {
        await storage.token(for: endpoint.credentialID)
    }

    static func save(_ token: String, for endpoint: DieterEndpoint) async throws {
        try await storage.save(token, for: endpoint.credentialID)
    }

    static func remove(for endpoint: DieterEndpoint) async {
        await storage.remove(for: endpoint.credentialID)
    }
}

actor DieterCredentialFileStore {
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
            .appending(path: "com.dbpprt.dieter.mac", directoryHint: .isDirectory)
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
final class DieterAuthentication {
    private struct PendingAuthentication: Codable {
        let endpoint: DieterEndpoint
        let verifier: String
    }

    private static let pendingKey = "DieterPendingAuthentication"
    private var callbackContinuation: CheckedContinuation<URL, any Error>?

    func signIn(to endpoint: DieterEndpoint) async throws -> String {
        guard endpoint.secure else { throw DieterAuthenticationError.secureEndpointRequired }
        guard callbackContinuation == nil else { throw DieterAuthenticationError.sessionInProgress }
        let verifier = Self.randomURLToken(bytes: 48)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        var components = URLComponents()
        components.scheme = "https"; components.host = endpoint.host
        if endpoint.port != 443 { components.port = endpoint.port }
        components.path = "/auth/github/start"
        components.queryItems = [URLQueryItem(name: "native_redirect_uri", value: "dieter-mac://oauth/callback"), URLQueryItem(name: "native_code_challenge", value: challenge)]
        guard let authorizeURL = components.url else { throw DieterAuthenticationError.invalidResponse }
        persistPending(.init(endpoint: endpoint.gatewayEndpoint, verifier: verifier))
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            guard NSWorkspace.shared.open(authorizeURL) else {
                callbackContinuation = nil
                clearPending()
                continuation.resume(throwing: DieterAuthenticationError.couldNotOpenBrowser)
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
    func resumePending(url: URL) async throws -> DieterEndpoint? {
        guard isCallback(url), callbackContinuation == nil,
              let data = UserDefaults.standard.data(forKey: Self.pendingKey),
              let pending = try? JSONDecoder().decode(PendingAuthentication.self, from: data) else { return nil }
        defer { clearPending() }
        _ = try await exchange(callbackURL: url, pending: pending)
        return pending.endpoint
    }

    private func exchange(callbackURL: URL, pending: PendingAuthentication) async throws -> String {
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { throw DieterAuthenticationError.missingCode }
        var exchange = URLComponents()
        exchange.scheme = "https"
        exchange.host = pending.endpoint.host
        if pending.endpoint.port != 443 { exchange.port = pending.endpoint.port }
        exchange.path = "/auth/native/exchange"
        var request = URLRequest(url: exchange.url!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(code: code, verifier: pending.verifier))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DieterAuthenticationError.invalidResponse }
        let token = try JSONDecoder().decode(ExchangeResponse.self, from: data).accessToken
        try await DieterCredentialStore.save(token, for: pending.endpoint)
        return token
    }

    private func persistPending(_ pending: PendingAuthentication) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
    }

    private func clearPending() {
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
    }

    private func isCallback(_ url: URL) -> Bool {
        url.scheme == "dieter-mac" && url.host == "oauth" && url.path == "/callback"
    }

    private struct ExchangeRequest: Encodable { let code: String; let verifier: String }
    private struct ExchangeResponse: Decodable { let accessToken: String }
    private static func randomURLToken(bytes: Int) -> String { Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString() }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

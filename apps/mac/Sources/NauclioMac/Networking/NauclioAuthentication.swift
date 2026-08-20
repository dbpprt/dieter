import AppKit
import CryptoKit
import Foundation

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
    private static let storage = NauclioCredentialFileStore(fileURL: NauclioCredentialFileStore.defaultFileURL())

    static func token(for endpoint: NauclioEndpoint) async -> String? {
        await storage.token(for: endpoint.credentialID)
    }

    static func save(_ token: String, for endpoint: NauclioEndpoint) async throws {
        try await storage.save(token, for: endpoint.credentialID)
    }

    static func remove(for endpoint: NauclioEndpoint) async {
        await storage.remove(for: endpoint.credentialID)
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
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            guard NSWorkspace.shared.open(authorizeURL) else {
                callbackContinuation = nil
                continuation.resume(throwing: NauclioAuthenticationError.couldNotOpenBrowser)
                return
            }
        }
        callbackContinuation = nil
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { throw NauclioAuthenticationError.missingCode }
        var exchange = components
        exchange.path = "/auth/native/exchange"; exchange.queryItems = nil
        var request = URLRequest(url: exchange.url!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(code: code, verifier: verifier))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NauclioAuthenticationError.invalidResponse }
        let token = try JSONDecoder().decode(ExchangeResponse.self, from: data).accessToken
        try await NauclioCredentialStore.save(token, for: endpoint)
        return token
    }

    func complete(url: URL) {
        guard url.scheme == "nauclio-mac", url.host == "oauth", url.path == "/callback",
              let continuation = callbackContinuation else { return }
        callbackContinuation = nil
        continuation.resume(returning: url)
    }

    private struct ExchangeRequest: Encodable { let code: String; let verifier: String }
    private struct ExchangeResponse: Decodable { let accessToken: String }
    private static func randomURLToken(bytes: Int) -> String { Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString() }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

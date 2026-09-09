import DieterClient
import AppKit
import CryptoKit
import Foundation

enum DieterAuthenticationError: LocalizedError, Equatable {
    case secureEndpointRequired, invalidResponse, missingCode, sessionInProgress, couldNotOpenBrowser, timedOut
    var errorDescription: String? {
        switch self {
        case .secureEndpointRequired: "Remote sign-in requires an HTTPS endpoint."
        case .invalidResponse: "Dieter rejected the authentication exchange."
        case .missingCode: "The authentication callback did not contain a code."
        case .sessionInProgress: "A Dieter sign-in is already in progress."
        case .couldNotOpenBrowser: "Dieter could not open the system browser."
        case .timedOut: "Sign-in expired. Start sign-in again."
        }
    }
}

@MainActor
final class DieterAuthentication {
    private struct PendingAuthentication: Codable {
        let endpoint: DieterEndpoint
        let verifier: String
        var createdAt: Date? = nil
    }

    private static let pendingKey = "DieterPendingAuthentication"
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var attemptID: UUID?
    private var attemptTask: Task<String, Error>?
    private let defaults: UserDefaults
    private let credentials: DieterCredentialFileStore
    private let openBrowser: @MainActor (URL) -> Bool
    private let timeout: Duration
    private let clock: ClientClock

    init(
        defaults: UserDefaults = .standard,
        credentials: DieterCredentialFileStore = DieterCredentialFileStore(
            fileURL: DieterCredentialFileStore.defaultFileURL()),
        timeout: Duration = .seconds(300), clock: ClientClock = .live,
        openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults; self.credentials = credentials
        self.timeout = timeout; self.clock = clock; self.openBrowser = openBrowser
    }

    func signIn(to endpoint: DieterEndpoint) async throws -> String {
        try Task.checkCancellation()
        guard endpoint.secure else { throw DieterAuthenticationError.secureEndpointRequired }
        guard attemptID == nil else { throw DieterAuthenticationError.sessionInProgress }
        let verifier = Self.randomURLToken(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents()
        components.scheme = "https"; components.host = endpoint.host
        if endpoint.port != 443 { components.port = endpoint.port }
        components.path = "/auth/github/start"
        components.queryItems = [
            URLQueryItem(name: "native_redirect_uri", value: "dieter-mac://oauth/callback"),
            URLQueryItem(name: "native_code_challenge", value: challenge),
        ]
        guard let authorizeURL = components.url else { throw DieterAuthenticationError.invalidResponse }
        let id = UUID()
        let pending = PendingAuthentication(
            endpoint: endpoint.gatewayEndpoint, verifier: verifier, createdAt: clock.now())
        persistPending(pending)
        attemptID = id
        let task = Task {
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, self.attemptID == id else {
                    continuation.resume(throwing: CancellationError()); return
                }
                self.callbackContinuation = continuation
                if !self.openBrowser(authorizeURL) {
                    self.cancel(id: id, error: DieterAuthenticationError.couldNotOpenBrowser)
                }
            }
            try Task.checkCancellation()
            return try await self.exchange(callbackURL: callback, pending: pending)
        }
        attemptTask = task
        let timer = Task { [weak self, clock, timeout] in
            do { try await clock.sleep(timeout) } catch { return }
            self?.cancel(id: id, error: DieterAuthenticationError.timedOut)
        }
        defer {
            timer.cancel()
            if attemptID == id { attemptID = nil; attemptTask = nil; clearPending() }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.cancel(id: id, error: CancellationError()) }
        }
    }

    func cancel() {
        if let id = attemptID { cancel(id: id, error: CancellationError()) } else { clearPending() }
    }

    private func cancel(id: UUID, error: Error) {
        guard attemptID == id else { return }
        attemptTask?.cancel(); attemptTask = nil; attemptID = nil
        let continuation = callbackContinuation; callbackContinuation = nil
        clearPending()
        continuation?.resume(throwing: error)
    }

    @discardableResult
    func complete(url: URL) -> Bool {
        guard isCallback(url), let continuation = callbackContinuation else { return false }
        callbackContinuation = nil
        continuation.resume(returning: url)
        return true
    }

    /// Completes a recent OAuth callback delivered after the app was relaunched.
    func resumePending(url: URL) async throws -> DieterEndpoint? {
        guard isCallback(url), attemptID == nil,
            let data = defaults.data(forKey: Self.pendingKey),
            let pending = try? JSONDecoder().decode(PendingAuthentication.self, from: data)
        else { return nil }
        guard let created = pending.createdAt, clock.now().timeIntervalSince(created) < 300 else {
            clearPending(); throw DieterAuthenticationError.timedOut
        }
        let id = UUID(); attemptID = id
        let task = Task { try await self.exchange(callbackURL: url, pending: pending) }
        attemptTask = task
        defer { if attemptID == id { attemptID = nil; attemptTask = nil; clearPending() } }
        _ = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.cancel(id: id, error: CancellationError()) }
        }
        return pending.endpoint
    }

    private func exchange(callbackURL: URL, pending: PendingAuthentication) async throws -> String {
        guard
            let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
                $0.name == "code"
            })?.value
        else { throw DieterAuthenticationError.missingCode }
        var exchange = URLComponents()
        exchange.scheme = "https"
        exchange.host = pending.endpoint.host
        if pending.endpoint.port != 443 { exchange.port = pending.endpoint.port }
        exchange.path = "/auth/native/exchange"
        guard let url = exchange.url else { throw DieterAuthenticationError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(code: code, verifier: pending.verifier))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DieterAuthenticationError.invalidResponse
        }
        let token = try JSONDecoder().decode(ExchangeResponse.self, from: data).accessToken
        try Task.checkCancellation()
        try await credentials.save(token, for: pending.endpoint.credentialID)
        return token
    }

    private func persistPending(_ pending: PendingAuthentication) {
        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
    }

    private func clearPending() {
        defaults.removeObject(forKey: Self.pendingKey)
    }

    private func isCallback(_ url: URL) -> Bool {
        url.scheme == "dieter-mac" && url.host == "oauth" && url.path == "/callback"
    }

    private struct ExchangeRequest: Encodable { let code: String; let verifier: String }
    private struct ExchangeResponse: Decodable { let accessToken: String }
    private static func randomURLToken(bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

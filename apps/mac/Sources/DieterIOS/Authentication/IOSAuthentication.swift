import CryptoKit
import DieterCore
import Foundation

enum IOSAuthenticationError: LocalizedError {
    case secureEndpointRequired, invalidResponse, missingCode, sessionInProgress, missingWindow, timedOut

    var errorDescription: String? {
        switch self {
        case .secureEndpointRequired: "Enter an HTTPS gateway address."
        case .invalidResponse: "The gateway rejected sign-in. Please try again."
        case .missingCode: "The sign-in callback did not contain a valid code."
        case .sessionInProgress: "Sign-in is already in progress."
        case .missingWindow: "Open Dieter before starting sign-in."
        case .timedOut: "Sign-in expired. Please try again."
        }
    }
}

/// The existing gateway's registered native redirect works on iOS as well as macOS.
/// ASWebAuthenticationSession owns the callback and the one-time code is bound to PKCE.
enum IOSAuthenticationRequest {
    static let callback = "dieter-mac://oauth/callback"

    static func authorizationURL(endpoint: DieterEndpoint, verifier: String) throws -> URL {
        guard endpoint.secure else { throw IOSAuthenticationError.secureEndpointRequired }
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.port = endpoint.port == 443 ? nil : endpoint.port
        components.path = "/auth/github/start"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).urlSafeBase64
        components.queryItems = [
            .init(name: "native_redirect_uri", value: callback),
            .init(name: "native_code_challenge", value: challenge),
        ]
        guard let url = components.url else { throw IOSAuthenticationError.invalidResponse }
        return url
    }

    static func exchangeRequest(endpoint: DieterEndpoint, callback: URL, verifier: String) throws -> URLRequest {
        guard endpoint.secure else { throw IOSAuthenticationError.secureEndpointRequired }
        guard callback.scheme == "dieter-mac", callback.host == "oauth", callback.path == "/callback",
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
            !items.contains(where: { $0.name == "error" }),
            let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw IOSAuthenticationError.missingCode }
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.port = endpoint.port == 443 ? nil : endpoint.port
        components.path = "/auth/native/exchange"
        guard let url = components.url else { throw IOSAuthenticationError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(code: code, verifier: verifier))
        return request
    }

    private struct ExchangeRequest: Encodable { let code: String; let verifier: String }
}

private extension Data {
    var urlSafeBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
    import AuthenticationServices
    import UIKit

    @MainActor
    final class IOSAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
        private var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<URL, Error>?
        private var attemptID: UUID?
        private weak var anchor: UIWindow?

        func signIn(to endpoint: DieterEndpoint) async throws -> String {
            guard attemptID == nil else { throw IOSAuthenticationError.sessionInProgress }
            guard
                let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow)
            else { throw IOSAuthenticationError.missingWindow }
            anchor = window
            let verifier = Data((0..<48).map { _ in UInt8.random(in: .min ... .max) }).urlSafeBase64
            let url = try IOSAuthenticationRequest.authorizationURL(endpoint: endpoint, verifier: verifier)
            let id = UUID()
            attemptID = id
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.finish(id: id, result: .failure(IOSAuthenticationError.timedOut))
            }
            defer {
                timer.cancel()
                if attemptID == id { session = nil; attemptID = nil; continuation = nil }
            }
            let callback = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "dieter-mac") {
                        [weak self] callback, error in
                        Task { @MainActor in
                            if let callback {
                                self?.finish(id: id, result: .success(callback))
                            } else {
                                self?.finish(id: id, result: .failure(error ?? IOSAuthenticationError.missingCode))
                            }
                        }
                    }
                    session.presentationContextProvider = self
                    self.session = session
                    if !session.start() { finish(id: id, result: .failure(IOSAuthenticationError.missingWindow)) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
            }
            try Task.checkCancellation()
            let request = try IOSAuthenticationRequest.exchangeRequest(
                endpoint: endpoint, callback: callback, verifier: verifier)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw IOSAuthenticationError.invalidResponse
            }
            let token = try JSONDecoder().decode(ExchangeResponse.self, from: data).accessToken
            guard !token.isEmpty else { throw IOSAuthenticationError.invalidResponse }
            try Task.checkCancellation()
            return token
        }

        func cancel() {
            guard let id = attemptID else { return }
            finish(id: id, result: .failure(CancellationError()))
        }

        private func finish(id: UUID, result: Result<URL, Error>) {
            guard attemptID == id, let pending = continuation else { return }
            continuation = nil
            session?.cancel()
            session = nil
            pending.resume(with: result)
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }

        private struct ExchangeResponse: Decodable { let accessToken: String }
    }
#endif

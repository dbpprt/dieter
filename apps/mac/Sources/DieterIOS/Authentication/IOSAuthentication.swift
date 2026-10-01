import Foundation

enum IOSAuthenticationError: LocalizedError {
    case invalidResponse, sessionInProgress, missingWindow, timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The gateway rejected sign-in. Please try again."
        case .sessionInProgress: "Sign-in is already in progress."
        case .missingWindow: "Open Dieter before starting sign-in."
        case .timedOut: "Sign-in expired. Please try again."
        }
    }
}

#if os(iOS)
    import AuthenticationServices
    import UIKit

    /// Presents the system browser and returns its callback. PKCE creation,
    /// validation, code exchange, credentials, and account selection live in
    /// the shared core.
    @MainActor
    final class IOSAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
        private var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<URL, Error>?
        private var attemptID: UUID?
        private weak var anchor: UIWindow?

        func callback(for authorizationURL: URL) async throws -> URL {
            guard attemptID == nil else { throw IOSAuthenticationError.sessionInProgress }
            guard
                let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow)
            else { throw IOSAuthenticationError.missingWindow }
            anchor = window
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
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let session = ASWebAuthenticationSession(
                        url: authorizationURL, callbackURLScheme: "dieter-mac"
                    ) { [weak self] callback, error in
                        Task { @MainActor in
                            if let callback {
                                self?.finish(id: id, result: .success(callback))
                            } else {
                                self?.finish(id: id, result: .failure(error ?? IOSAuthenticationError.invalidResponse))
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
    }
#endif

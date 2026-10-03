#if os(iOS)
    import AuthenticationServices
    import Foundation
    import SharedCore
    import UIKit

    /// The native sign-in sheet. The shared core builds the gateway's authorize
    /// URL (with its PKCE challenge and state) and exchanges the callback; this
    /// only shows the page and hands back the callback URL.
    @MainActor
    final class IOSAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
        private var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<URL?, Error>?
        private weak var anchor: UIWindow?

        /// Shows `url` and returns the callback URL, or nil when the person
        /// closed the sheet.
        func authorize(_ url: URL) async throws -> URL? {
            cancel()
            anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                    self.continuation = continuation
                    let session = ASWebAuthenticationSession(
                        url: url, callbackURLScheme: CoreHostPlatform.nativeOAuthScheme
                    ) {
                        [weak self] callback, error in
                        Task { @MainActor in self?.finish(callback: callback, error: error) }
                    }
                    session.presentationContextProvider = self
                    self.session = session
                    if !session.start() { finish(callback: nil, error: nil) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel() }
            }
        }

        /// Closes an open sheet; its `authorize` returns nil.
        func cancel() {
            finish(callback: nil, error: nil)
        }

        private func finish(callback: URL?, error: Error?) {
            session?.cancel()
            session = nil
            guard let pending = continuation else { return }
            continuation = nil
            if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                pending.resume(throwing: error)
            } else {
                pending.resume(returning: callback)
            }
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }
    }
#endif

import DieterAPI
import DieterCore
import Foundation
import Synchronization

package struct DirectAccessCredentialSnapshot: Equatable, Sendable {
    package init(token: String, expiresAt: String, daemonGeneration: UInt64) {
        self.token = token
        self.expiresAt = expiresAt
        self.daemonGeneration = daemonGeneration
    }

    package let token: String
    package let expiresAt: String
    package let daemonGeneration: UInt64
}

/// A direct data-plane channel can outlive the short-lived bearer used when an
/// RPC begins. Keeping the credential behind a synchronized reference lets new
/// RPCs use a renewed bearer without interrupting already-authorized streams.
package final class DirectAccessCredential: Sendable {
    private let state: Mutex<DirectAccessCredentialSnapshot>

    package init(token: String, expiresAt: String, daemonGeneration: UInt64) {
        state = Mutex(
            DirectAccessCredentialSnapshot(
                token: token,
                expiresAt: expiresAt,
                daemonGeneration: daemonGeneration
            ))
    }

    package func snapshot() -> DirectAccessCredentialSnapshot {
        state.withLock { $0 }
    }

    package func update(token: String, expiresAt: String, daemonGeneration: UInt64) {
        state.withLock {
            $0 = DirectAccessCredentialSnapshot(
                token: token,
                expiresAt: expiresAt,
                daemonGeneration: daemonGeneration
            )
        }
    }
}

package enum DirectCredentialRefreshPolicy {
    package static let renewalMargin: TimeInterval = 30

    package static func renewalDelay(expiresAt: Date, now: Date) -> TimeInterval {
        max(1, expiresAt.timeIntervalSince(now) - renewalMargin)
    }

    /// Retry while the current bearer can still admit new calls. Once less than
    /// a second remains, connection recovery owns direct/relay route selection.
    package static func retryDelay(attempt: Int, expiresAt: Date, now: Date) -> TimeInterval? {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 1 else { return nil }
        let backoff = min(15, pow(1.8, Double(max(0, attempt))))
        return min(backoff, max(0.25, remaining - 1))
    }

    package static func requiresConnectionReplacement(
        currentGeneration: UInt64,
        renewedGeneration: UInt64
    ) -> Bool {
        currentGeneration != 0 && renewedGeneration != 0
            && currentGeneration != renewedGeneration
    }
}

/// Auxiliary routes have their own bearer and lifetime, independent of the
/// selected workspace connection. Renew in place for borrowed terminal watches
/// and screen lease/signaling calls.
package enum DirectCredentialRefreshLoop {
    package static func run(
        credential: DirectAccessCredential,
        clock: ClientClock = .live,
        exchange: @Sendable () async throws -> Dieter_Gateway_V1_DaemonAccessToken
    ) async {
        guard let expiry = DieterTimestamp.date(from: credential.snapshot().expiresAt) else { return }
        var delay = DirectCredentialRefreshPolicy.renewalDelay(expiresAt: expiry, now: clock.now())
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await clock.sleep(.seconds(delay))
                try Task.checkCancellation()
                let token = try await exchange()
                try Task.checkCancellation()
                guard token.tokenType == "Bearer", !token.accessToken.isEmpty,
                    let expires = DieterTimestamp.date(from: token.expiresAt), expires > clock.now(),
                    !DirectCredentialRefreshPolicy.requiresConnectionReplacement(
                        currentGeneration: credential.snapshot().daemonGeneration,
                        renewedGeneration: token.daemonGeneration)
                else { return }
                credential.update(
                    token: token.accessToken, expiresAt: token.expiresAt, daemonGeneration: token.daemonGeneration)
                attempt = 0
                delay = DirectCredentialRefreshPolicy.renewalDelay(expiresAt: expires, now: clock.now())
            } catch {
                guard !Task.isCancelled, DieterRPCFailure.isTransient(error),
                    let expires = DieterTimestamp.date(from: credential.snapshot().expiresAt),
                    let retry = DirectCredentialRefreshPolicy.retryDelay(
                        attempt: attempt, expiresAt: expires, now: clock.now())
                else { return }
                attempt += 1
                delay = retry
            }
        }
    }
}

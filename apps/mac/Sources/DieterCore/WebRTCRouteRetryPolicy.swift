import Foundation

/// Per-machine circuit breaker for the optional WebRTC control route. Relay is
/// still usable while this state delays another expensive ICE negotiation.
package struct WebRTCRouteRetryState: Equatable, Sendable {
    package private(set) var consecutiveFailures = 0
    package private(set) var retryAt: Date?

    package init() {}

    package func allowsAttempt(at now: Date) -> Bool {
        retryAt.map { now >= $0 } ?? true
    }

    @discardableResult
    package mutating func recordFailure(at now: Date) -> TimeInterval {
        consecutiveFailures += 1
        let delay = Self.cooldown(consecutiveFailures: consecutiveFailures)
        retryAt = now.addingTimeInterval(delay)
        return delay
    }

    package mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAt = nil
    }

    package static func cooldown(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        return min(15 * 60, 2 * 60 * pow(2, Double(consecutiveFailures - 1)))
    }
}

package enum TemporaryRouteCachePolicy {
    package static let healthyIdleLifetime: TimeInterval = 5 * 60

    package static func prefers(_ lhs: MachineConnectionRoute, over rhs: MachineConnectionRoute) -> Bool {
        rank(lhs) > rank(rhs)
    }

    package static func shouldProbeWebRTC(
        cachedRoute: MachineConnectionRoute,
        retry: WebRTCRouteRetryState?,
        now: Date
    ) -> Bool {
        cachedRoute == .gateway && (retry?.allowsAttempt(at: now) ?? true)
    }

    private static func rank(_ route: MachineConnectionRoute) -> Int {
        switch route {
        case .local: 5
        case .directTLS: 4
        case .webrtcDirect: 3
        case .webrtcTURN, .webrtc: 2
        case .gateway: 1
        }
    }
}

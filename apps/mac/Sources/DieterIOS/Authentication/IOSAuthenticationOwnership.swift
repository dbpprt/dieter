import Foundation

/// Authentication outlives a foreground data-plane connection, for example
/// while a person switches to an authenticator app. Only the owning gateway
/// and explicit authentication actions determine whether its result is valid.
struct IOSAuthenticationOwnership {
    struct Attempt: Equatable {
        let id: UUID
        let gatewayID: String
    }

    private(set) var active: Attempt?

    mutating func begin(gatewayID: String) -> Attempt {
        let attempt = Attempt(id: UUID(), gatewayID: gatewayID)
        active = attempt
        return attempt
    }

    func accepts(_ attempt: Attempt, gatewayID: String?) -> Bool {
        active == attempt && gatewayID == attempt.gatewayID
    }

    func shouldConnect(_ attempt: Attempt, gatewayID: String?, foreground: Bool) -> Bool {
        foreground && accepts(attempt, gatewayID: gatewayID)
    }

    mutating func invalidate() { active = nil }

    @discardableResult
    mutating func finish(_ attempt: Attempt) -> Bool {
        guard active == attempt else { return false }
        active = nil
        return true
    }
}

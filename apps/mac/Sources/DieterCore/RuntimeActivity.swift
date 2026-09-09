import DieterAPI

/// Runtime vocabulary stays separate from lanes, delivery and Git operations.
package enum RuntimeActivity: Equatable, Sendable {
    case idle, running, needsInput, completed, failed, review, unknown(String)

    package init(_ value: String) {
        switch value.lowercased() {
        case "idle", "queued": self = .idle
        case "running", "working", "starting": self = .running
        case "waiting", "waiting_for_user", "needs_input": self = .needsInput
        case "completed", "done": self = .completed
        case "failed", "error": self = .failed
        case "review": self = .review
        default: self = .unknown(value)
        }
    }

    package var shouldNotify: Bool {
        switch self {
        case .needsInput, .completed, .failed, .review: true
        default: false
        }
    }
}

package struct ActivityTransitions {
    private var states: [WorkspaceTarget: RuntimeActivity] = [:]
    package init() {}

    /// Initial snapshots establish a baseline. Equivalent aliases do not emit
    /// duplicate notifications when another projection reports the same state.
    package mutating func accept(_ cards: [Dieter_V1_Card], endpointID: String) -> [Dieter_V1_Card] {
        var changed: [Dieter_V1_Card] = []
        for card in cards {
            let key = WorkspaceTarget(endpointID: endpointID, projectID: card.projectID, conversationID: card.id)
            let next = RuntimeActivity(card.runtime)
            if let previous = states[key], previous != next, next.shouldNotify { changed.append(card) }
            states[key] = next
        }
        return changed
    }
}

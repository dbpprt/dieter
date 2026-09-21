import DieterCore

enum IOSConversationAvailability {
    static func canSend(
        phase: ConnectionPhase, busy: Bool, hasConversationTransport: Bool, hasSelection: Bool
    ) -> Bool {
        phase.isConnected && !busy && hasConversationTransport && hasSelection
    }
}

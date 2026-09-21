import DieterAPI
enum IOSWorkspaceContinuity {
    /// A global directory refresh may deliver the card (including a newer
    /// generated title or runtime state) before its creation RPC returns. Keep
    /// that authoritative version and only fill a directory that has not caught up.
    static func admittingCreatedCard(_ card: Dieter_V1_Card, into directory: [Dieter_V1_Card]) -> [Dieter_V1_Card] {
        guard !directory.contains(where: { $0.id == card.id }) else { return directory }
        return [card] + directory
    }
}

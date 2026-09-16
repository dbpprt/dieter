import DieterAPI
import DieterCore

/// Readable state may survive a reconnect only while it still belongs to the
/// same authenticated gateway and daemon. Presence and display-name changes do
/// not change that identity.
enum IOSWorkspaceContinuity {
    static func canRetainSnapshot(
        currentOrigin: DieterEndpoint?, currentDaemonID: String?,
        requestedOrigin: DieterEndpoint?, requestedDaemonID: String?
    ) -> Bool {
        guard let currentOrigin, let requestedOrigin,
            let currentDaemonID, !currentDaemonID.isEmpty,
            let requestedDaemonID, !requestedDaemonID.isEmpty
        else { return false }
        return currentOrigin.credentialID == requestedOrigin.credentialID && currentDaemonID == requestedDaemonID
    }

    /// Keep navigation anchored to an enrolled, compatible node while it is
    /// offline. A removed or incompatible node cannot retain a usable workspace.
    static func retainedOfflineSelection(in machines: [DieterEndpoint], previousDaemonID: String?) -> String? {
        guard let previousDaemonID else { return nil }
        return machines.first {
            $0.daemonID == previousDaemonID && !$0.online && IOSMachinePolicy.isCompatible($0)
        }?.daemonID
    }

    /// WatchState may deliver the card (including a newer generated title or
    /// runtime state) before its creation RPC returns. Keep that authoritative
    /// version and only fill the directory when the stream has not caught up.
    static func admittingCreatedCard(_ card: Dieter_V1_Card, into directory: [Dieter_V1_Card]) -> [Dieter_V1_Card] {
        guard !directory.contains(where: { $0.id == card.id }) else { return directory }
        return [card] + directory
    }
}

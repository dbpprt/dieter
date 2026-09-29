import DieterAPI

/// A harness reports provider connectivity while its provider stream retries.
/// The daemon clears it when the stream recovers or the turn ends.
package enum ProviderStatusPresentation {
    package static func label(_ status: Dieter_V1_ProviderStatus) -> String? {
        switch status.state.lowercased() {
        case "waiting-for-network":
            "Reconnecting to provider (waiting for network)…"
        case "reconnecting":
            status.attempt > 0 && status.maxAttempts > 0
                ? "Reconnecting to provider (\(status.attempt)/\(status.maxAttempts))…" : "Reconnecting to provider…"
        default:
            nil
        }
    }
}

extension Dieter_V1_Conversation {
    package var activeProviderStatus: Dieter_V1_ProviderStatus? {
        hasProviderStatus && !providerStatus.state.isEmpty ? providerStatus : nil
    }

    /// Updates always carry the current status, so an absent one is cleared.
    /// Assigning an unset message field would instead mark it present.
    package mutating func applyProviderStatus(from update: Dieter_V1_ConversationUpdate) {
        if update.hasProviderStatus {
            providerStatus = update.providerStatus
        } else {
            clearProviderStatus()
        }
    }
}

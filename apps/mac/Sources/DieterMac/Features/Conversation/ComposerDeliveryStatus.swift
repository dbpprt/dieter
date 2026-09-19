import DieterAPI
import DieterCore
import SwiftUI

struct ConversationDeliveryStatus: Equatable {
    let itemIDs: [String]
    let title: String
    let detail: String
    let phase: MachineDeliveryToastPhase

    static func resolve(
        entries: [DieterOutboxEntry], conversationID: String, endpointID: String,
        machineName: String, online: Bool
    ) -> Self? {
        let pending = entries.filter { entry in
            guard entry.endpointID == endpointID, entry.serverID == nil else { return false }
            if entry.kind == .sendMessage {
                return (try? Dieter_V1_SendMessageRequest(serializedBytes: entry.request))?.cardID == conversationID
            }
            return entry.optimisticID == conversationID
        }
        guard let summary = MachineOutboxSummary.summaries(for: pending)[endpointID] else { return nil }
        let phase = summary.toastPhase(machineOnline: online)
        let title: String =
            switch phase {
            case .sending: "Delivering to \(machineName)…"
            case .waiting: "Waiting for \(machineName) to reconnect"
            case .retrying: "Retrying delivery to \(machineName)…"
            case .failed: "Delivery to \(machineName) failed"
            }
        return Self(
            itemIDs: pending.map(\.optimisticID), title: title,
            detail: summary.failureMessage ?? summary.queuedLabel, phase: phase)
    }
}

struct ComposerDeliveryStatusView: View {
    @Environment(ConversationContext.self) private var context
    @State private var cancelIDs: [String] = []

    var body: some View {
        let status = context.deliveryStatus()
        HStack(spacing: 6) {
            if let status {
                Image(systemName: status.phase == .failed ? "exclamationmark.circle" : "arrow.up.circle")
                Text(status.title).lineLimit(1).help(status.detail)
                Spacer(minLength: 0)
                Menu {
                    if status.phase != .sending {
                        Button("Retry delivery") {
                            Task { for id in status.itemIDs { await context.retryOutboxItem(id) } }
                        }
                    }
                    Button("Cancel delivery…", role: .destructive) { cancelIDs = status.itemIDs }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Delivery actions")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(status?.phase == .failed ? DieterTheme.coral : DieterTheme.tertiary)
        // Reserve the status slot so delivery changes never move the transcript.
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 4)
        .accessibilityIdentifier("conversation.delivery-status")
        .smokeTarget("conversation.delivery-status")
        .accessibilityHidden(status == nil)
        .confirmationDialog(
            "Cancel pending delivery?",
            isPresented: Binding(get: { !cancelIDs.isEmpty }, set: { if !$0 { cancelIDs = [] } })
        ) {
            Button("Cancel delivery", role: .destructive) {
                let ids = cancelIDs
                cancelIDs = []
                Task { for id in ids { await context.discardOutboxItem(id) } }
            }
            Button("Keep waiting", role: .cancel) { cancelIDs = [] }
        } message: {
            Text("Removes these pending items from this Mac. Messages already accepted by the machine are unaffected.")
        }
    }
}

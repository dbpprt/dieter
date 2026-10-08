import DieterAPI
import SwiftUI

struct MachineDeliveryToastStack: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(store.machineOutboxes, id: \.daemonID) { outbox in
                MachineDeliveryToast(outbox: outbox)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)
                        ))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.machineOutboxes)
    }
}

/// One machine's queued work, worded by the shared core.
private struct MachineDeliveryToast: View {
    @Environment(DieterStore.self) private var store
    let outbox: ClientMachineOutbox
    @State private var discardConfirmationPresented = false

    private var tint: Color {
        switch outbox.phase {
        case .sending: DieterTheme.primary
        case .failed: DieterTheme.coral
        default: DieterTheme.amber
        }
    }

    private var symbol: String {
        switch outbox.phase {
        case .sending: "arrow.up"
        case .waiting: "wifi.exclamationmark"
        case .waitingForStorage: "externaldrive.badge.exclamationmark"
        case .retrying: "arrow.clockwise"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var identifier: String { "machine.\(outbox.daemonID)" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.13))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 5) {
                Text(outbox.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(outbox.phase == .waitingForStorage ? nil : 1)
                    .accessibilityIdentifier("\(identifier).queue-title")
                    .smokeTarget("\(identifier).queue-title")

                Text(outbox.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(outbox.phase == .waitingForStorage ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Cancel Delivery", role: .destructive) {
                        discardConfirmationPresented = true
                    }
                    .buttonStyle(DieterBarButtonStyle(destructive: true, size: 26))
                    .accessibilityIdentifier("\(identifier).cancel-queue")

                    if !outbox.retryTitle.isEmpty {
                        Button(outbox.retryTitle) { Task { await store.retryOutbox(daemonID: outbox.daemonID) } }
                            .buttonStyle(DieterBarButtonStyle(prominent: true, tint: tint, size: 26))
                            .accessibilityIdentifier("\(identifier).retry")
                            .smokeTarget("\(identifier).retry")
                    }
                }
                .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: 356, alignment: .leading)
        .dieterToastChrome()
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(outbox.phase == .failed ? 0.38 : 0.24))
        }
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).queue")
        .smokeTarget("\(identifier).queue")
        .confirmationDialog(
            "Cancel delivery to \(outbox.machineName)?",
            isPresented: $discardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                "Cancel \(outbox.messageCount + outbox.changeCount == 1 ? "Queued Item" : "Queued Items")",
                role: .destructive
            ) {
                Task { await store.discardOutbox(daemonID: outbox.daemonID) }
            }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes the queued work from this Mac. Work already accepted by \(outbox.machineName) is not affected."
            )
        }
    }
}

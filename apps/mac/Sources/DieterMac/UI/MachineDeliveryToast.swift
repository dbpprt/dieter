import SwiftUI

struct MachineDeliveryToastStack: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(store.machines, id: \.id) { machine in
                if let summary = store.outboxSummary(for: machine) {
                    MachineDeliveryToast(machine: machine, summary: summary)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)
                            ))
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.machineOutboxSummaries)
    }
}

private struct MachineDeliveryToast: View {
    @Environment(DieterStore.self) private var store
    let machine: DieterEndpoint
    let summary: MachineOutboxSummary
    @State private var discardConfirmationPresented = false

    private var phase: MachineDeliveryToastPhase { summary.toastPhase(machineOnline: machine.online) }

    private var tint: Color {
        switch phase {
        case .sending: DieterTheme.primary
        case .waiting, .retrying: DieterTheme.amber
        case .failed: DieterTheme.coral
        }
    }

    private var title: String {
        switch phase {
        case .sending: "Delivering to \(machine.name)"
        case .waiting: "Waiting for \(machine.name)"
        case .retrying: "Retrying delivery to \(machine.name)"
        case .failed: "Delivery to \(machine.name) failed"
        }
    }

    private var detail: String {
        switch phase {
        case .sending: "\(summary.queuedLabel) · Sending now"
        case .waiting: "\(summary.queuedLabel) · Sends when it reconnects"
        case .retrying: "\(summary.queuedLabel) · Trying again automatically"
        case .failed:
            summary.failureMessage ?? "\(summary.queuedLabel) · Try again when the machine is available"
        }
    }

    private var symbol: String {
        switch phase {
        case .sending: "arrow.up"
        case .waiting: "wifi.exclamationmark"
        case .retrying: "arrow.clockwise"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var retryTitle: String {
        switch phase {
        case .failed, .retrying: "Try Again"
        case .waiting: "Retry Now"
        case .sending: ""
        }
    }

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
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Cancel Delivery", role: .destructive) {
                        discardConfirmationPresented = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DieterTheme.tertiary)
                    .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id).cancel-queue")

                    if phase != .sending {
                        Button(retryTitle) { Task { await store.retryOutbox(for: machine) } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(tint)
                            .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id).retry")
                    }
                }
                .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: 356, alignment: .leading)
        .background(DieterTheme.elevated.opacity(0.97), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(phase == .failed ? 0.38 : 0.24))
        }
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 12)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id).queue")
        .smokeTarget("machine.\(machine.daemonID ?? machine.id).queue")
        .confirmationDialog(
            "Cancel delivery to \(machine.name)?",
            isPresented: $discardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel \(summary.itemCount == 1 ? "Queued Item" : "Queued Items")", role: .destructive) {
                Task { await store.discardOutbox(for: machine) }
            }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes the queued work from this Mac. Work already accepted by \(machine.name) is not affected."
            )
        }
    }
}

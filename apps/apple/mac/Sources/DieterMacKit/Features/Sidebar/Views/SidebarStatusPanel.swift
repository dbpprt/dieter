import DieterClientAPI
import DieterCore
import SwiftUI

/// The machines and provider quotas, in one recessed panel at the foot of the
/// sidebar card.
struct SidebarStatusPanel: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Machines").font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
                Spacer(minLength: 4)
                SidebarConnectionStatus()
            }
            .padding(.horizontal, 8).frame(height: 24)
            ForEach(store.machines) { machine in
                SidebarMachineRow(machine: machine)
            }
            Rectangle().fill(DieterTheme.hairline).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
            ProviderQuotaSidebarBlock()
        }
        .padding(.vertical, 6)
        .dieterInset(radius: 12)
    }
}

/// Compact workspace connection state, docked beside the machines so it never
/// floats over a pane header. The full freshness lives in the tooltip and
/// accessibility label.
private struct SidebarConnectionStatus: View {
    @Environment(DieterStore.self) private var store

    /// Live, still working toward live, or offline until something changes.
    private var dotColor: Color {
        if store.workspaceIsLive { return DieterTheme.running }
        return store.workspaceNotice?.offline == true ? DieterTheme.coral : DieterTheme.amber
    }

    private var working: Bool { !store.workspaceIsLive && store.workspaceNotice?.offline != true }

    private var label: String { store.session.phaseLabel }

    var body: some View {
        let now = Date()
        HStack(spacing: 5) {
            if working {
                DieterActivityIndicator(color: dotColor, size: 8).accessibilityHidden(true)
            } else {
                Circle().fill(dotColor).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(store.workspaceIsLive ? DieterTheme.tertiary : dotColor)
                .lineLimit(1)
        }
        .fixedSize()
        .help(accessibilityLabel(now: now))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(now: now))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func accessibilityLabel(now: Date) -> String {
        let freshness = SharedRules.shared.lastConnected(
            atMillis: store.lastSyncedAt?.epochMillis ?? 0, nowMillis: now.epochMillis)
        return "Dieter is \(label.lowercased()), \(freshness)"
    }

    private var accessibilityIdentifier: String {
        "connection.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }
}

private struct SidebarMachineRow: View {
    @Environment(DieterStore.self) private var store
    let machine: MachineEndpoint

    var body: some View {
        let online = store.machineIsAvailable(machine)
        let detail = store.machineStatusLine(machine)
        let entry = store.machineEntry(machine)
        Button {
            Task { await store.fleet.openMachine(machine.id) }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    DieterStatusDot(color: online ? DieterTheme.running : DieterTheme.tertiary.opacity(0.6), size: 6)
                    name(online: online).fixedSize()
                    privacy(entry)
                    Spacer(minLength: 6)
                    detailText(detail).fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        DieterStatusDot(
                            color: online ? DieterTheme.running : DieterTheme.tertiary.opacity(0.6), size: 6)
                        name(online: online)
                        privacy(entry)
                        Spacer(minLength: 0)
                    }
                    detailText(detail).padding(.leading, 13)
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 8).frame(minHeight: 26)
            .background(
                store.fleet.selectedMachineID == machine.id ? DieterTheme.tileSelected : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(detail: detail, entry: entry))
        .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")
        .e2eTarget("machine.\(machine.daemonID ?? machine.id)", text: machine.name)
    }

    private func name(online: Bool) -> some View {
        Text(machine.name)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(online ? DieterTheme.text : DieterTheme.subtle)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private func privacy(_ entry: ClientMachineEntry?) -> some View {
        if let entry, entry.privacyActive || entry.privacyWarning {
            Image(systemName: entry.privacyWarning ? "exclamationmark.shield" : "lock.shield")
                .font(.system(size: 10.5))
                .foregroundStyle(entry.privacyWarning ? DieterTheme.amber : DieterTheme.subtle)
                .opacity(entry.privacyStale ? 0.45 : 1)
                .help(entry.privacyLabel)
                .accessibilityLabel(entry.privacyLabel)
                .accessibilityIdentifier("machine.privacy.\(machine.id)")
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(DieterFont.monoSmall)
            .foregroundStyle(DieterTheme.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(detail)
    }

    private func accessibilityLabel(detail: String, entry: ClientMachineEntry?) -> String {
        let privacy = entry.flatMap { $0.privacyActive || $0.privacyWarning ? $0.privacyLabel : nil }
        return [machine.name, detail, privacy].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

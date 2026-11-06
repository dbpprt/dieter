import DieterCore
import SwiftUI

struct ConnectionSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var name = ""
    @State private var address = ""
    @State private var pendingRevoke: MachineEndpoint?
    @State private var pendingRename: MachineEndpoint?
    @State private var pendingCleanSync = false

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                connectionExplanation
                activeConnection
                gatewayList
                machineList
                addGateway
            }
        }
        .sheet(item: $pendingRename) { machine in RenameMachineSheet(machine: machine).environment(store) }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.name ?? "machine")?",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } })
        ) {
            Button("Revoke machine", role: .destructive) {
                if let endpoint = pendingRevoke { Task { await store.revokeDaemon(endpoint) } }
                pendingRevoke = nil
            }
        } message: {
            Text("This machine will lose gateway and direct access until it is enrolled again.")
        }
        .confirmationDialog("Start a clean sync?", isPresented: $pendingCleanSync) {
            Button("Clean sync", role: .destructive) {
                Task { await store.cleanSync() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Dieter will replay every machine's changes from the beginning and replace each machine's cached view once it has caught up. Your sign-in and pending changes are kept."
            )
        }
    }

    private var connectionExplanation: some View {
        SettingsPanel(title: "How connections work") {
            HStack(spacing: 13) {
                ConnectionConcept(symbol: "laptopcomputer", title: "This Mac", detail: "Dieter app")
                Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                ConnectionConcept(
                    symbol: "point.3.connected.trianglepath.dotted", title: "Gateway", detail: "Sign-in + discovery")
                Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                ConnectionConcept(symbol: "desktopcomputer", title: "All machines", detail: "Projects + agents")
            }
            Text(
                "A gateway does not store projects or conversations. Dieter combines every machine enrolled through the active gateway and automatically routes each project action to its owner."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activeConnection: some View {
        SettingsPanel(title: "Automatic routing", subtitle: store.session.phaseLabel) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(DieterTheme.shell).frame(
                    width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeGateway.name).font(.system(size: 12, weight: .semibold))
                    Text("Gateway · \(store.activeGateway.address)").font(.caption2).foregroundStyle(
                        DieterTheme.tertiary)
                }
                Spacer()
                if store.phase == .authenticationRequired {
                    Button("Sign in with GitHub") { Task { await store.signIn() } }
                        .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                }
            }
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Circle().fill(store.phase.isConnected ? DieterTheme.eyes : DieterTheme.amber).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.projects.count) projects across \(store.machines.count) machines").font(
                        .system(size: 12, weight: .semibold))
                    Text("Project actions are routed to their host automatically.").font(.caption2).foregroundStyle(
                        DieterTheme.tertiary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Reconnect") { Task { await store.connect() } }
                    Button("Clean sync…") { pendingCleanSync = true }
                        .accessibilityIdentifier("settings.connection.clean-sync")
                }
                .buttonStyle(DieterBarButtonStyle(size: 28))
            }
            Text(
                "Clean sync replays every machine's changes from the beginning, rebuilding this Mac's cached workspace while it stays shown. Sign-in and pending changes are kept."
            )
            .font(.caption2).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gatewayList: some View {
        SettingsPanel(title: "Gateways", subtitle: "Choose one to sign in and discover its enrolled machines.") {
            ForEach(store.gateways) { gateway in
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(DieterTheme.shell).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(gateway.name).font(.system(size: 12, weight: .semibold))
                            if gateway.isPrimaryGateway {
                                Text("PRIMARY").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                                    .padding(.horizontal, 5).frame(height: 16).background(
                                        DieterTheme.eyes.opacity(0.1), in: Capsule())
                            }
                        }
                        Text(gateway.address).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer()
                    if gateway.credentialID == store.activeGateway.credentialID {
                        Text("Active gateway").font(.caption2).foregroundStyle(DieterTheme.eyes)
                    }
                    Button("Use gateway") { Task { await store.chooseGateway(gateway) } }
                        .buttonStyle(DieterBarButtonStyle(size: 28))
                    if store.gateways.count > 1 {
                        Button(role: .destructive) {
                            store.deleteEndpoint(gateway)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(DieterBarButtonStyle(shape: .circle, destructive: true, size: 26))
                        .disabled(gateway.credentialID == store.activeGateway.credentialID)
                        .help("Remove gateway")
                    }
                }
                if gateway.id != store.gateways.last?.id { Divider().overlay(DieterTheme.border) }
            }
        }
    }

    private var machineList: some View {
        SettingsPanel(
            title: "Machines discovered through \(store.activeGateway.name)",
            subtitle: store.machines.isEmpty
                ? "Sign in to this gateway to load its machines."
                : "Projects and conversations stay on these machines, never on the gateway."
        ) {
            if store.machines.isEmpty {
                Text("No machines discovered yet.").font(.caption).foregroundStyle(DieterTheme.tertiary).padding(
                    .vertical, 5)
            }
            ForEach(store.machines) { machine in
                HStack(spacing: 10) {
                    Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(machine.name).font(.system(size: 12, weight: .semibold))
                        Text(machineSummary(machine)).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer()
                    Button {
                        pendingRename = machine
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 26)).help("Rename machine")
                    Button(role: .destructive) {
                        pendingRevoke = machine
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle, destructive: true, size: 26))
                    .help("Revoke machine")
                }
                if machine.id != store.machines.last?.id { Divider().overlay(DieterTheme.border) }
            }
        }
    }

    private var addGateway: some View {
        SettingsPanel(
            title: "Add another gateway",
            subtitle: "Use this only for a separate Dieter deployment. It has a separate sign-in and machine directory."
        ) {
            HStack(spacing: 9) {
                TextField("Display name", text: $name)
                TextField("https://dieter.example.com", text: $address)
                Button("Save and discover") {
                    if let gateway = MachineEndpoint(address: address, name: name.isEmpty ? "Custom gateway" : name) {
                        Task { await store.saveEndpoint(gateway) }
                        name = ""; address = ""
                    }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                .disabled(MachineEndpoint(address: address, name: "") == nil)
            }
            Text(
                "Gateway sessions are stored in Dieter's private app data directory. Dieter prefers verified direct TLS to a discovered machine and otherwise uses the gateway's encrypted relay."
            )
            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
        }
    }

    private func machineSummary(_ machine: MachineEndpoint) -> String {
        store.machineStatusLine(machine)
    }
}

private struct ConnectionConcept: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
    }
}

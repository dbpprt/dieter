import DieterAPI
import DieterShared
import Foundation
import SwiftUI

/// Byte counts of machine readings, in the shared core's binary units.
private func machineBytes(_ value: UInt64) -> String {
    SharedRules.shared.bytes(count: Int64(min(value, UInt64(Int64.max))))
}

/// The SF Symbol of a machine operation's menu item.
private func operationSymbol(_ action: Dieter_V1_MachineOperationAction) -> String {
    switch action {
    case .updateDaemon: "arrow.down.circle"
    case .restart: "arrow.clockwise.circle"
    case .shutdown: "power"
    default: "gearshape"
    }
}

/// A machine operation's wording, as the shared core gives it.
private func operationCopy(_ action: Dieter_V1_MachineOperationAction) -> ClientMachineOperationCopy {
    ClientMachineOperationCopy(rules: SharedRules.shared.machineOperationCopy(action: Int32(action.rawValue)))
}

struct MachinePopover: View {
    @Environment(DieterStore.self) private var store
    @State private var pendingAction: Dieter_V1_MachineOperationAction?

    private var machine: DieterEndpoint? {
        guard let id = store.fleet.selectedMachineID else { return store.machines.first }
        return store.machines.first { $0.id == id }
    }

    private var information: Dieter_V1_MachineInformation? {
        machine.flatMap { store.fleet.machineInformation[$0.id] }
    }

    var body: some View {
        Group {
            if let machine {
                machineBody(machine)
            } else {
                ContentUnavailableView(
                    "Machine unavailable",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("This machine is no longer enrolled.")
                )
            }
        }
        .foregroundStyle(DieterTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dieterOverlayChrome()
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("machine.popover")
        .onExitCommand { store.fleet.dismissMachinePopover() }
        .confirmationDialog(
            pendingAction.map { operationCopy($0).title } ?? "Machine operation",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                let copy = operationCopy(action)
                Button(copy.button, role: copy.destructive ? .destructive : nil) {
                    pendingAction = nil
                    Task { await store.fleet.performMachineOperation(action) }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction.map { operationCopy($0).explanation } ?? "")
        }
        .alert(
            "Machine operation accepted",
            isPresented: Binding(
                get: { store.fleet.machineOperationMessage != nil },
                set: { if !$0 { store.fleet.machineOperationMessage = nil } }
            )
        ) {
            Button("OK") { store.fleet.machineOperationMessage = nil }
        } message: {
            Text(store.fleet.machineOperationMessage ?? "")
        }
    }

    private func machineBody(_ machine: DieterEndpoint) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                machineIdentity(machine)
                if let information {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            cpuPanel(information, machineID: machine.id)
                            memoryPanel(information)
                        }
                        VStack(spacing: 14) {
                            cpuPanel(information, machineID: machine.id)
                            memoryPanel(information)
                        }
                    }
                    gpuSection(information, machineID: machine.id)
                    softwarePanel(information, machine: machine)
                    processPanel(information)
                    machineFooter(information, machine: machine)
                } else if store.fleet.machineInformationLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading machine information…")
                            .font(DieterFont.body).foregroundStyle(DieterTheme.subtle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 210)
                } else {
                    machineUnavailable(machine)
                }
            }
            .padding(22)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("machine.detail")
    }

    private func machineIdentity(_ machine: DieterEndpoint) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(DieterTheme.shell)
                .frame(width: 54, height: 54)
                .background(DieterTheme.selection, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(machine.name).font(.system(size: 22, weight: .bold))
                    HStack(spacing: 5) {
                        Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(
                            width: 6, height: 6)
                        Text(machine.online ? "Online" : "Offline")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(machine.online ? DieterTheme.eyes : DieterTheme.tertiary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((machine.online ? DieterTheme.eyes : DieterTheme.tertiary).opacity(0.10), in: Capsule())
                }
                Text(machineSubtitle(machine))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(2)
                if let entry = store.machineEntry(machine), !entry.route.isEmpty {
                    let status = store.machineStatusLine(machine)
                    Label(status, systemImage: "network")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DieterTheme.subtle)
                        .accessibilityLabel("Connection: \(status)")
                        .accessibilityIdentifier("machine.connection-mode")
                }
            }
            Spacer()
            Button {
                Task { await store.fleet.refreshSelectedMachineInformation() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(!machine.online || store.fleet.machineInformationLoading)
            .help("Refresh machine information")
            .accessibilityIdentifier("machine.refresh")

            Menu {
                ForEach(store.fleet.machineOperations[machine.id] ?? [], id: \.action) { operation in
                    Button(operationCopy(operation.action).menuTitle, systemImage: operationSymbol(operation.action)) {
                        pendingAction = operation.action
                    }
                    .disabled(!operation.available || !store.machineIsAvailable(machine))
                    .help(operation.unavailableReason)
                    .accessibilityIdentifier(operationIdentifier(operation.action))
                    if operation.action == .updateDaemon { Divider() }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.fleet.machineOperationInFlight)
            .help("Machine operations")

            Button {
                store.fleet.dismissMachinePopover()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close machine information")
            .accessibilityIdentifier("machine.close")
        }
    }

    private func operationIdentifier(_ action: Dieter_V1_MachineOperationAction) -> String {
        switch action {
        case .updateDaemon: "machine.update-daemon"
        case .restart: "machine.restart"
        case .shutdown: "machine.shutdown"
        default: "machine.operation"
        }
    }

    private func machineSubtitle(_ machine: DieterEndpoint) -> String {
        guard let information else {
            if store.fleet.machineInformationError != nil { return "Machine information unavailable" }
            return machine.online ? "Loading machine information…" : store.machineStatusLine(machine)
        }
        return SharedRules.shared.machineSubtitle(
            hardwareModel: information.hardwareModel, processor: information.processor, osName: information.osName,
            osVersion: information.osVersion, uptimeSeconds: Int64(information.uptimeSeconds))
    }

    private func cpuPanel(_ information: Dieter_V1_MachineInformation, machineID: String) -> some View {
        MachineMetricPanel {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.subtle)
                Spacer()
                Text(SharedRules.shared.machinePercentage(value: information.cpuUsagePercent))
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundStyle(DieterTheme.shell)
            }
            MachineCPUHistory(
                values: information.cpuCoreUsagePercent.isEmpty
                    ? store.fleet.machineCPUHistory[machineID, default: [information.cpuUsagePercent]]
                    : information.cpuCoreUsagePercent
            )
            .frame(height: 48)
            Text(
                SharedRules.shared.machineLoad(
                    cores: Int32(information.logicalCpuCount), load1: information.load1, load5: information.load5,
                    load15: information.load15)
            )
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(DieterTheme.tertiary)
        }
    }

    private func memoryPanel(_ information: Dieter_V1_MachineInformation) -> some View {
        MachineMetricPanel {
            HStack(alignment: .firstTextBaseline) {
                Text("MEMORY").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.subtle)
                Spacer()
                Text(machineBytes(information.memoryUsedBytes))
                    .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(DieterTheme.eyes)
                Text("/ \(machineBytes(information.memoryTotalBytes))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(
                        DieterTheme.tertiary)
            }
            MachineMemoryBar(information: information).frame(height: 16)
            HStack(spacing: 18) {
                memoryLegend("used", value: information.memoryUsedBytes, color: DieterTheme.eyes)
                memoryLegend("cache", value: information.memoryCachedBytes, color: DieterTheme.shell)
                memoryLegend("swap", value: information.swapUsedBytes, color: DieterTheme.amber)
            }
        }
    }

    private func memoryLegend(_ title: String, value: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
            }
            Text(machineBytes(value))
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(DieterTheme.tertiary)
    }

    @ViewBuilder
    private func gpuSection(_ information: Dieter_V1_MachineInformation, machineID: String) -> some View {
        if information.hasGpu {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("GPU").font(DieterFont.sectionLabel).tracking(1).foregroundStyle(DieterTheme.tertiary)
                    Spacer()
                    if !information.gpu.devices.isEmpty {
                        Text(
                            SharedRules.shared.machineCount(
                                count: Int32(information.gpu.devices.count), noun: "device", plural: "devices")
                        )
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DieterTheme.tertiary)
                    }
                }
                if information.gpu.devices.isEmpty {
                    Text(
                        information.gpu.unavailableReason.isEmpty
                            ? "No supported GPU telemetry is available." : information.gpu.unavailableReason
                    )
                    .font(DieterFont.body).foregroundStyle(DieterTheme.subtle)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        DieterTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ForEach(information.gpu.devices, id: \.id) { device in
                        gpuPanel(device, history: store.fleet.machineGPUHistory[machineID]?[device.id] ?? [])
                    }
                }
            }
        }
    }

    private func gpuPanel(_ device: Dieter_V1_GPUDevice, history: [Double]) -> some View {
        MachineMetricPanel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name.isEmpty ? "GPU" : device.name)
                        .font(.system(size: 14, weight: .bold))
                    Text(
                        [
                            SharedRules.shared.gpuVendor(vendor: Int32(device.vendor.rawValue)), device.id,
                            device.driverVersion.isEmpty ? "" : "driver \(device.driverVersion)",
                        ]
                        .filter { !$0.isEmpty }.joined(separator: "  ·  ")
                    )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                Spacer()
                Text(
                    device.hasUtilizationPercent
                        ? SharedRules.shared.machinePercentage(value: device.utilizationPercent) : "—"
                )
                .font(.system(size: 23, weight: .bold, design: .monospaced))
                .foregroundStyle(device.hasUtilizationPercent ? DieterTheme.shell : DieterTheme.tertiary)
            }
            if device.hasUtilizationPercent {
                MachineCPUHistory(values: history.isEmpty ? [device.utilizationPercent] : history).frame(height: 38)
            }
            HStack(spacing: 18) {
                gpuMemory(device)
                if device.hasTemperatureCelsius {
                    Label(
                        SharedRules.shared.machineTemperature(celsius: device.temperatureCelsius),
                        systemImage: "thermometer.medium")
                }
                if device.hasPowerWatts {
                    Label(SharedRules.shared.machinePower(watts: device.powerWatts), systemImage: "bolt")
                }
                if device.hasProcessCount {
                    Label(
                        SharedRules.shared.machineCount(
                            count: Int32(device.processCount), noun: "process", plural: "processes"),
                        systemImage: "gearshape.2")
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(DieterTheme.tertiary)
        }
    }

    @ViewBuilder
    private func gpuMemory(_ device: Dieter_V1_GPUDevice) -> some View {
        if device.hasMemoryUsedBytes || device.hasMemoryTotalBytes {
            Label(
                SharedRules.shared.gpuMemory(
                    unified: device.memoryKind == .unified,
                    usedBytes: device.hasMemoryUsedBytes ? Int64(clamping: device.memoryUsedBytes) : -1,
                    totalBytes: device.hasMemoryTotalBytes ? Int64(clamping: device.memoryTotalBytes) : -1),
                systemImage: "memorychip")
        }
    }

    private func softwarePanel(_ information: Dieter_V1_MachineInformation, machine: DieterEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOFTWARE").font(DieterFont.sectionLabel).tracking(1).foregroundStyle(DieterTheme.tertiary)
            VStack(spacing: 0) {
                softwareRow(
                    name: "Dieter daemon",
                    version: SharedRules.shared.daemonVersion(
                        buildVersion: information.daemonBuild.releaseVersion, releaseVersion: machine.releaseVersion,
                        revision: information.daemonBuild.sourceRevision),
                    systemImage: "server.rack"
                )
                Divider().overlay(DieterTheme.border).padding(.leading, 38)
                if let gateway = store.gatewayInformation[machine.credentialID] {
                    softwareRow(
                        name: "Dieter gateway",
                        version: SharedRules.shared.softwareVersion(
                            version: gateway.releaseVersion, revision: gateway.sourceRevision),
                        systemImage: "network")
                } else {
                    softwareRow(
                        name: "Dieter gateway", version: machine.daemonID == nil ? "Local connection" : "Unavailable",
                        systemImage: "network")
                }
            }
            .background(DieterTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DieterTheme.border))
        }
    }

    private func softwareRow(name: String, version: String, systemImage: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage).foregroundStyle(DieterTheme.tertiary).frame(width: 22)
            Text(name).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(version)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DieterTheme.subtle)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }

    private func processPanel(_ information: Dieter_V1_MachineInformation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DIETER PROCESSES").font(DieterFont.sectionLabel).tracking(1).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Circle().fill(information.activeAgentCount > 0 ? DieterTheme.shell : DieterTheme.tertiary).frame(
                    width: 6, height: 6)
                Text(SharedRules.shared.machineActiveAgents(agents: Int32(information.activeAgentCount)))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.shell)
            }
            VStack(spacing: 0) {
                ForEach(Array(information.processes.enumerated()), id: \.element.pid) { index, process in
                    MachineProcessRow(process: process)
                    if index < information.processes.count - 1 {
                        Divider().overlay(DieterTheme.border).padding(.leading, 38)
                    }
                }
            }
            .background(DieterTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DieterTheme.border))
        }
    }

    private func machineFooter(_ information: Dieter_V1_MachineInformation, machine: DieterEndpoint) -> some View {
        HStack(spacing: 18) {
            Label(
                SharedRules.shared.machineDisk(freeBytes: Int64(clamping: information.diskFreeBytes)),
                systemImage: "internaldrive")
            Label(
                SharedRules.shared.machineNetwork(
                    receiveBytesPerSecond: information.networkReceiveBytesPerSecond,
                    sendBytesPerSecond: information.networkSendBytesPerSecond),
                systemImage: "network"
            )
            if information.temperatureCelsius > 0 {
                Label(
                    SharedRules.shared.machineTemperature(celsius: information.temperatureCelsius),
                    systemImage: "thermometer.medium")
            }
            Spacer()
            Button("Open terminals", systemImage: "terminal") {
                Task { await store.openTerminals(on: machine) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DieterTheme.text)
            .disabled(!store.machineIsAvailable(machine))
            .accessibilityIdentifier("machine.open-terminals")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(DieterTheme.tertiary)
        .padding(.top, 2)
    }

    private func machineUnavailable(_ machine: DieterEndpoint) -> some View {
        VStack(spacing: 10) {
            Image(
                systemName: machine.online
                    ? "exclamationmark.triangle" : "desktopcomputer.trianglebadge.exclamationmark"
            )
            .font(.system(size: 24)).foregroundStyle(machine.online ? DieterTheme.amber : DieterTheme.tertiary)
            Text(store.fleet.machineInformationError ?? "Machine information is unavailable.")
                .font(DieterFont.body).foregroundStyle(DieterTheme.subtle)
                .multilineTextAlignment(.center)
            if machine.online {
                Button("Try again") { Task { await store.fleet.refreshSelectedMachineInformation() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct MachineMetricPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(DieterTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DieterTheme.border))
    }
}

private struct MachineCPUHistory: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let count = max(values.count, 1)
            let spacing: CGFloat = 4
            let width = max(3, (geometry.size.width - (CGFloat(count - 1) * spacing)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            DieterTheme.shell.opacity(
                                index == values.count - 1 ? 0.95 : 0.42 + (Double(index) / Double(count) * 0.25))
                        )
                        .frame(width: width, height: max(5, geometry.size.height * min(max(value, 0), 100) / 100))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct MachineMemoryBar: View {
    let information: Dieter_V1_MachineInformation

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(information.memoryTotalBytes), 1)
            let usedWidth = geometry.size.width * min(Double(information.memoryUsedBytes) / total, 1)
            let cacheWidth = min(
                geometry.size.width - usedWidth, geometry.size.width * Double(information.memoryCachedBytes) / total)
            HStack(spacing: 0) {
                Rectangle().fill(DieterTheme.eyes).frame(width: usedWidth)
                Rectangle().fill(DieterTheme.shell.opacity(0.66)).frame(width: max(0, cacheWidth))
                Spacer(minLength: 0)
            }
            .background(DieterTheme.raised)
            .clipShape(Capsule())
        }
    }
}

private struct MachineProcessRow: View {
    let process: Dieter_V1_MachineProcess

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: process.kind == "agent" ? "arrow.triangle.2.circlepath" : "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(process.kind == "agent" ? DieterTheme.shell : DieterTheme.tertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(SharedRules.shared.machineProcessDetail(pid: Int32(clamping: process.pid), detail: process.detail))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            }
            Spacer()
            Text(SharedRules.shared.machinePercentage(value: process.cpuUsagePercent))
                .foregroundStyle(process.kind == "agent" ? DieterTheme.shell : DieterTheme.subtle)
            Text(machineBytes(process.memoryBytes))
                .foregroundStyle(process.kind == "agent" ? DieterTheme.eyes : DieterTheme.subtle)
                .frame(minWidth: 58, alignment: .trailing)
            if process.gpuUsage.contains(where: \.hasMemoryBytes) {
                Text(
                    machineBytes(
                        process.gpuUsage.filter(\.hasMemoryBytes).reduce(UInt64(0)) { $0 + $1.memoryBytes })
                )
                .foregroundStyle(DieterTheme.shell)
                .frame(minWidth: 58, alignment: .trailing)
                .help("GPU memory")
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

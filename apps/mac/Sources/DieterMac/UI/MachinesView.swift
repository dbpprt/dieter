import DieterAPI
import Foundation
import SwiftUI

enum MachineInformationPresentation {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .memory
        )
    }

    static func rate(_ value: Double) -> String {
        guard value > 0 else { return "0 B/s" }
        return bytes(UInt64(value.rounded())) + "/s"
    }

    static func uptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}

private enum MachinePowerAction: String, Identifiable {
    case restart
    case shutdown

    var id: String { rawValue }
    var title: String { self == .restart ? "Restart machine" : "Shut down machine" }
    var buttonTitle: String { self == .restart ? "Restart" : "Shut Down" }
    var confirmation: String { self == .restart ? "RESTART" : "SHUT DOWN" }
    var wireAction: Dieter_V1_MachineOperationAction { self == .restart ? .restart : .shutdown }
    var explanation: String {
        self == .restart
            ? "Active Dieter turns will be suspended while macOS restarts. The machine will reconnect after Dieter starts again."
            : "Active Dieter turns will be suspended and the machine will remain offline until somebody turns it on again."
    }
}

struct MachinesView: View {
    @Environment(DieterStore.self) private var store
    @State private var pendingPowerAction: MachinePowerAction?

    private var machine: DieterEndpoint? {
        guard let id = store.selectedMachineID else { return store.machines.first }
        return store.machines.first { $0.id == id }
    }

    private var information: Dieter_V1_MachineInformation? {
        machine.flatMap { store.machineInformation[$0.id] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DieterTheme.border)
            Group {
                if let machine {
                    machineBody(machine)
                } else {
                    ContentUnavailableView(
                        "No machines enrolled",
                        systemImage: "desktopcomputer",
                        description: Text("Enroll a Dieter daemon to see machine information here.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DieterTheme.background)
        .confirmationDialog(
            pendingPowerAction?.title ?? "Machine operation",
            isPresented: Binding(
                get: { pendingPowerAction != nil },
                set: { if !$0 { pendingPowerAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingPowerAction {
                Button(action.buttonTitle, role: .destructive) {
                    pendingPowerAction = nil
                    Task {
                        await store.performMachineOperation(action.wireAction, confirmation: action.confirmation)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingPowerAction = nil }
        } message: {
            Text(pendingPowerAction?.explanation ?? "")
        }
        .alert(
            "Machine operation accepted",
            isPresented: Binding(
                get: { store.machineOperationMessage != nil },
                set: { if !$0 { store.machineOperationMessage = nil } }
            )
        ) {
            Button("OK") { store.machineOperationMessage = nil }
        } message: {
            Text(store.machineOperationMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Machines").font(DieterFont.paneTitle)
                Text("Live host telemetry and controls")
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Button {
                Task { await store.refreshSelectedMachineInformation() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(machine?.online != true || store.machineInformationLoading)
            .help("Refresh machine information")
            .accessibilityIdentifier("machine.refresh")

            Menu {
                Button("Restart…", systemImage: "arrow.clockwise.circle") { pendingPowerAction = .restart }
                    .disabled(information?.supportsRestart != true || machine?.online != true)
                    .accessibilityIdentifier("machine.restart")
                Button("Shut Down…", systemImage: "power") { pendingPowerAction = .shutdown }
                    .disabled(information?.supportsShutdown != true || machine?.online != true)
                    .accessibilityIdentifier("machine.shutdown")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Machine operations")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
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
                    processPanel(information)
                    machineFooter(information, machine: machine)
                } else if store.machineInformationLoading {
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
                        Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 6, height: 6)
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
            }
            Spacer()
        }
    }

    private func machineSubtitle(_ machine: DieterEndpoint) -> String {
        guard let information else {
            return machine.online ? "Connecting…" : MachinePresenceText.lastSeen(machine.lastSeenAt)
        }
        var parts: [String] = []
        let hardware = [information.hardwareModel, information.processor]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if !hardware.isEmpty { parts.append(hardware) }
        let operatingSystem = [information.osName, information.osVersion]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !operatingSystem.isEmpty { parts.append(operatingSystem) }
        parts.append("up \(MachineInformationPresentation.uptime(information.uptimeSeconds))")
        if let status = store.connectionStatus(for: machine) {
            parts.append("\(status.route.rawValue) \(status.latencyMilliseconds) ms")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func cpuPanel(_ information: Dieter_V1_MachineInformation, machineID: String) -> some View {
        MachineMetricPanel {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.subtle)
                Spacer()
                Text(MachineInformationPresentation.percentage(information.cpuUsagePercent))
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundStyle(DieterTheme.shell)
            }
            MachineCPUHistory(values: information.cpuCoreUsagePercent.isEmpty
                ? store.machineCPUHistory[machineID, default: [information.cpuUsagePercent]]
                : information.cpuCoreUsagePercent)
                .frame(height: 48)
            Text("\(information.logicalCpuCount) cores  ·  load \(information.load1, specifier: "%.1f") / \(information.load5, specifier: "%.1f") / \(information.load15, specifier: "%.1f")")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DieterTheme.tertiary)
        }
    }

    private func memoryPanel(_ information: Dieter_V1_MachineInformation) -> some View {
        MachineMetricPanel {
            HStack(alignment: .firstTextBaseline) {
                Text("MEMORY").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.subtle)
                Spacer()
                Text(MachineInformationPresentation.bytes(information.memoryUsedBytes))
                    .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(DieterTheme.eyes)
                Text("/ \(MachineInformationPresentation.bytes(information.memoryTotalBytes))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
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
            Text(MachineInformationPresentation.bytes(value))
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(DieterTheme.tertiary)
    }

    private func processPanel(_ information: Dieter_V1_MachineInformation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DIETER PROCESSES").font(DieterFont.sectionLabel).tracking(1).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Circle().fill(information.activeAgentCount > 0 ? DieterTheme.shell : DieterTheme.tertiary).frame(width: 6, height: 6)
                Text("\(information.activeAgentCount) \(information.activeAgentCount == 1 ? "agent" : "agents") active")
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
            Label("disk \(MachineInformationPresentation.bytes(information.diskFreeBytes)) free", systemImage: "internaldrive")
            Label(
                "↓ \(MachineInformationPresentation.rate(information.networkReceiveBytesPerSecond))  ↑ \(MachineInformationPresentation.rate(information.networkSendBytesPerSecond))",
                systemImage: "network"
            )
            if information.temperatureCelsius > 0 {
                Label("\(information.temperatureCelsius, specifier: "%.0f")°", systemImage: "thermometer.medium")
            }
            Spacer()
            Button("Open terminals", systemImage: "terminal") {
                Task { await store.openTerminals(on: machine) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DieterTheme.text)
            .disabled(!machine.online)
            .accessibilityIdentifier("machine.open-terminals")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(DieterTheme.tertiary)
        .padding(.top, 2)
    }

    private func machineUnavailable(_ machine: DieterEndpoint) -> some View {
        VStack(spacing: 10) {
            Image(systemName: machine.online ? "exclamationmark.triangle" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 24)).foregroundStyle(machine.online ? DieterTheme.amber : DieterTheme.tertiary)
            Text(store.machineInformationError ?? "Machine information is unavailable.")
                .font(DieterFont.body).foregroundStyle(DieterTheme.subtle)
                .multilineTextAlignment(.center)
            if machine.online {
                Button("Try again") { Task { await store.refreshSelectedMachineInformation() } }
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
                        .fill(DieterTheme.shell.opacity(index == values.count - 1 ? 0.95 : 0.42 + (Double(index) / Double(count) * 0.25)))
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
            let cacheWidth = min(geometry.size.width - usedWidth, geometry.size.width * Double(information.memoryCachedBytes) / total)
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
                Text("pid \(process.pid)  ·  \(process.detail)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            }
            Spacer()
            Text(MachineInformationPresentation.percentage(process.cpuUsagePercent))
                .foregroundStyle(process.kind == "agent" ? DieterTheme.shell : DieterTheme.subtle)
            Text(MachineInformationPresentation.bytes(process.memoryBytes))
                .foregroundStyle(process.kind == "agent" ? DieterTheme.eyes : DieterTheme.subtle)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

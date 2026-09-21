#if os(iOS)
    import DieterAPI
    import DieterCore
    import Foundation
    import SwiftUI

    @MainActor
    struct IOSMachineStateView: View {
        @Bindable var store: IOSStore

        private var machine: DieterEndpoint? { store.utilityMachine }
        private var routeDescription: String {
            guard let id = machine?.daemonID else { return "" }
            return store.machineRouteDescriptions[id] ?? ""
        }

        var body: some View {
            Group {
                if let machine {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            identity(machine)
                            if let information = store.machineInformation {
                                if let error = store.machineInformationError {
                                    IOSConnectionBanner(title: "State may be out of date", detail: error) {
                                        Task { await store.refreshMachineInformation() }
                                    }
                                }
                                metrics(information)
                                system(information)
                                gpu(information)
                                software(information, machine: machine)
                                processes(information)
                                Text("Live state refreshes every five seconds while this view is open.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if store.machineInformationLoading {
                                ProgressView("Reading machine state…")
                                    .frame(maxWidth: .infinity, minHeight: 220)
                            } else {
                                unavailable(machine)
                            }
                        }
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .background { IOSWorkspaceBackdrop() }
                } else {
                    ContentUnavailableView(
                        "Choose a machine",
                        systemImage: "desktopcomputer",
                        description: Text("Select an enrolled machine before opening its state."))
                }
            }
            .navigationTitle("Machine state")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("ios.machine-state")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu(machine?.name ?? "Machine", systemImage: "desktopcomputer") {
                        ForEach(store.supportedMachines) { candidate in
                            Button {
                                store.selectUtilityMachine(id: candidate.daemonID ?? candidate.id)
                            } label: {
                                Label(
                                    candidate.name + (candidate.online ? "" : " · Offline"),
                                    systemImage: candidate.daemonID == store.utilityMachineID
                                        ? "checkmark" : "desktopcomputer")
                            }
                            .accessibilityIdentifier("ios.machine-state.machine.\(candidate.daemonID ?? candidate.id)")
                        }
                    }
                    .accessibilityIdentifier("ios.machine-state.machine-picker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.machineInformationLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh machine state", systemImage: "arrow.clockwise") {
                            Task { await store.refreshMachineInformation() }
                        }
                        .disabled(machine?.online != true || !store.phase.isConnected)
                        .accessibilityIdentifier("ios.machine-state.refresh")
                    }
                }
            }
            .refreshable { await store.refreshMachineInformation() }
            .task(id: machine?.daemonID) {
                while !Task.isCancelled {
                    await store.refreshMachineInformation()
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                }
            }
        }

        private func identity(_ machine: DieterEndpoint) -> some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(machine.name).font(.title2.bold())
                    HStack(spacing: 6) {
                        Circle().fill(machine.online ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(machine.online ? "Online" : MachinePresenceText.lastSeen(machine.lastSeenAt))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    if !routeDescription.isEmpty {
                        Label(routeDescription, systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ios.machine-state.route")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .modifier(
                IOSGlassCardModifier(
                    shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ios.machine-state.identity")
        }

        @ViewBuilder
        private func metrics(_ information: Dieter_V1_MachineInformation) -> some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                cpuCard(information)
                memoryCard(information)
            }
        }

        private func cpuCard(_ information: Dieter_V1_MachineInformation) -> some View {
            metricCard(title: "CPU", value: IOSMachineInformationPresentation.percentage(information.cpuUsagePercent)) {
                ProgressView(value: min(max(information.cpuUsagePercent / 100, 0), 1))
                    .tint(.blue)
                Text(
                    "\(information.logicalCpuCount) cores · load \(information.load1, specifier: "%.1f") / \(information.load5, specifier: "%.1f") / \(information.load15, specifier: "%.1f")"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("ios.machine-state.cpu")
        }

        private func memoryCard(_ information: Dieter_V1_MachineInformation) -> some View {
            metricCard(
                title: "Memory",
                value: IOSMachineInformationPresentation.bytes(information.memoryUsedBytes)
            ) {
                ProgressView(
                    value: IOSMachineInformationPresentation.fraction(
                        information.memoryUsedBytes, of: information.memoryTotalBytes)
                )
                .tint(.purple)
                Text(
                    "\(IOSMachineInformationPresentation.bytes(information.memoryTotalBytes)) total · \(IOSMachineInformationPresentation.bytes(information.memoryCachedBytes)) cached"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("ios.machine-state.memory")
        }

        private func system(_ information: Dieter_V1_MachineInformation) -> some View {
            stateCard("System", systemImage: "cpu") {
                detailRow("Host", value: information.hostname)
                Divider()
                detailRow(
                    "Operating system",
                    value: [information.osName, information.osVersion].filter { !$0.isEmpty }.joined(separator: " "))
                Divider()
                detailRow("Hardware", value: information.hardwareModel)
                Divider()
                detailRow("Processor", value: information.processor)
                Divider()
                detailRow("Architecture", value: information.architecture)
                Divider()
                detailRow("Uptime", value: IOSMachineInformationPresentation.uptime(information.uptimeSeconds))
                Divider()
                detailRow(
                    "Disk free",
                    value:
                        "\(IOSMachineInformationPresentation.bytes(information.diskFreeBytes)) of \(IOSMachineInformationPresentation.bytes(information.diskTotalBytes))"
                )
                Divider()
                detailRow(
                    "Network",
                    value:
                        "↓ \(IOSMachineInformationPresentation.rate(information.networkReceiveBytesPerSecond))  ↑ \(IOSMachineInformationPresentation.rate(information.networkSendBytesPerSecond))"
                )
                if information.temperatureCelsius > 0 {
                    Divider()
                    detailRow(
                        "Temperature",
                        value: "\(information.temperatureCelsius.formatted(.number.precision(.fractionLength(0))))°C")
                }
            }
            .accessibilityIdentifier("ios.machine-state.system")
        }

        @ViewBuilder
        private func gpu(_ information: Dieter_V1_MachineInformation) -> some View {
            if information.hasGpu, !information.gpu.devices.isEmpty {
                stateCard("GPU", systemImage: "memorychip") {
                    ForEach(Array(information.gpu.devices.enumerated()), id: \.offset) { index, device in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(device.name.isEmpty ? "GPU" : device.name).font(.headline)
                                Spacer()
                                if device.hasUtilizationPercent {
                                    Text(IOSMachineInformationPresentation.percentage(device.utilizationPercent))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(.blue)
                                }
                            }
                            if device.hasUtilizationPercent {
                                ProgressView(value: min(max(device.utilizationPercent / 100, 0), 1))
                                    .tint(.blue)
                            }
                            Text(gpuDetails(device))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("ios.machine-state.gpu")
            } else if information.hasGpu, information.gpu.state == .unavailable,
                !information.gpu.unavailableReason.isEmpty
            {
                stateCard("GPU", systemImage: "memorychip") {
                    Text(information.gpu.unavailableReason).foregroundStyle(.secondary)
                }
            }
        }

        private func software(_ information: Dieter_V1_MachineInformation, machine: DieterEndpoint) -> some View {
            let build = information.daemonBuild
            let version = build.releaseVersion.isEmpty ? machine.version : build.releaseVersion
            let api = build.apiVersion.isEmpty ? machine.apiVersion : build.apiVersion
            let revision = IOSMachineInformationPresentation.shortRevision(build.sourceRevision)
            return stateCard("Software", systemImage: "server.rack") {
                detailRow("Dieter daemon", value: version.isEmpty ? "Unknown" : version)
                Divider()
                detailRow("API", value: api.isEmpty ? "Unknown" : api)
                if let revision {
                    Divider()
                    detailRow("Revision", value: revision)
                }
            }
            .accessibilityIdentifier("ios.machine-state.software")
        }

        private func processes(_ information: Dieter_V1_MachineInformation) -> some View {
            stateCard(
                "Dieter processes",
                systemImage: "gearshape.2",
                detail:
                    "\(information.activeAgentCount) \(information.activeAgentCount == 1 ? "agent" : "agents") active"
            ) {
                if information.processes.isEmpty {
                    Text("No Dieter processes reported.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(information.processes.enumerated()), id: \.offset) { index, process in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: process.kind == "agent" ? "sparkles" : "terminal")
                                .foregroundStyle(process.kind == "agent" ? .blue : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("pid \(process.pid) · \(process.detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(IOSMachineInformationPresentation.percentage(process.cpuUsagePercent))
                                Text(IOSMachineInformationPresentation.bytes(process.memoryBytes))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("ios.machine-state.processes")
        }

        private func unavailable(_ machine: DieterEndpoint) -> some View {
            ContentUnavailableView {
                Label(
                    machine.online ? "Machine state unavailable" : "Machine offline",
                    systemImage: machine.online ? "exclamationmark.triangle" : "wifi.slash")
            } description: {
                Text(store.machineInformationError ?? "Dieter could not read this machine’s current state.")
            } actions: {
                if machine.online {
                    Button("Try again") { Task { await store.refreshMachineInformation() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }

        private func metricCard<Content: View>(
            title: String,
            value: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(value).font(.title2.bold().monospacedDigit())
                }
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .modifier(
                IOSGlassCardModifier(
                    shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        }

        private func stateCard<Content: View>(
            _ title: String,
            systemImage: String,
            detail: String? = nil,
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(title, systemImage: systemImage).font(.headline)
                    Spacer()
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(
                IOSGlassCardModifier(
                    shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        }

        private func detailRow(_ title: String, value: String) -> some View {
            LabeledContent(title) {
                Text(value.isEmpty ? "Unknown" : value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.subheadline)
        }

        private func gpuDetails(_ device: Dieter_V1_GPUDevice) -> String {
            var values: [String] = []
            if device.hasMemoryUsedBytes, device.hasMemoryTotalBytes {
                values.append(
                    "\(IOSMachineInformationPresentation.bytes(device.memoryUsedBytes)) / \(IOSMachineInformationPresentation.bytes(device.memoryTotalBytes)) memory"
                )
            } else if device.hasMemoryTotalBytes {
                values.append("\(IOSMachineInformationPresentation.bytes(device.memoryTotalBytes)) memory")
            }
            if device.hasTemperatureCelsius {
                values.append("\(device.temperatureCelsius.formatted(.number.precision(.fractionLength(0))))°C")
            }
            if device.hasPowerWatts {
                values.append("\(device.powerWatts.formatted(.number.precision(.fractionLength(0)))) W")
            }
            if device.hasProcessCount { values.append("\(device.processCount) processes") }
            return values.isEmpty ? "No additional telemetry" : values.joined(separator: " · ")
        }
    }

#endif

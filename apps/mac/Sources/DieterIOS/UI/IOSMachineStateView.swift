#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import SharedCore
    import SwiftUI

    /// A machine's live state: the shared core reads it every two seconds
    /// while this view shows it, with its power and update operations.
    struct IOSMachineStateView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @State private var fleet: FleetModel?
        @State private var chosenMachineID: String?
        @State private var pendingAction: Dieter_V1_MachineOperationAction?

        /// Shows `machineID` first when given, e.g. opened from its row.
        init(machineID: String? = nil) {
            _chosenMachineID = State(initialValue: machineID)
        }

        /// The machines that can report their state, in the core's order.
        private var machines: [ClientMachineEntry] { app.session.machines.filter(\.compatible) }

        /// The chosen machine, else the one whose terminals are open, or the
        /// first that can report.
        private var machineID: String? {
            let candidates = [chosenMachineID, navigation.terminalMachineID]
            if let id = candidates.compactMap({ $0 }).first(where: { id in machines.contains { $0.id == id } }) {
                return id
            }
            return (machines.first(where: \.available) ?? machines.first)?.id
        }

        private var machine: ClientMachineEntry? { machineID.flatMap(app.machine) }

        private var information: Dieter_V1_MachineInformation? {
            machineID.flatMap { fleet?.machineInformation[$0] }
        }

        var body: some View {
            Group {
                if let machine {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            identity(machine)
                            if let information {
                                if let error = fleet?.machineInformationError {
                                    IOSConnectionBanner(title: "State may be out of date", detail: error) {
                                        Task { await fleet?.refreshSelectedMachineInformation() }
                                    }
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                    cpuCard(information, machineID: machine.id)
                                    memoryCard(information)
                                }
                                system(information)
                                gpu(information, machineID: machine.id)
                                software(information, machine: machine)
                                processes(information)
                                Text("Live state refreshes while this view is open.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if fleet?.machineInformationLoading != false, fleet?.machineInformationError == nil {
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
                    .refreshable { await fleet?.refreshSelectedMachineInformation() }
                } else {
                    ContentUnavailableView(
                        "No machines", systemImage: "desktopcomputer",
                        description: Text("Enroll a machine with the Dieter daemon to see its state here."))
                }
            }
            .navigationTitle("Machine state")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("ios.machine-state")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu(machine?.name ?? "Machine", systemImage: "desktopcomputer") {
                        ForEach(machines, id: \.id) { candidate in
                            Button {
                                chosenMachineID = candidate.id
                            } label: {
                                Label(
                                    candidate.displayName,
                                    systemImage: candidate.id == machineID ? "checkmark" : "desktopcomputer")
                                Text(candidate.detail)
                            }
                            .accessibilityIdentifier("ios.machine-state.machine.\(candidate.id)")
                        }
                    }
                    .accessibilityIdentifier("ios.machine-state.machine-picker")
                }
            }
            .task(id: machineID) {
                guard let machineID else { return }
                let fleet = self.fleet ?? makeFleet()
                self.fleet = fleet
                if fleet.selectedMachineID != machineID { fleet.selectedMachineID = machineID }
                await fleet.refreshMachineInformation(machineID: machineID)
            }
            .onChange(of: machine?.available) { _, available in
                if available == true { Task { await fleet?.refreshSelectedMachineInformation() } }
            }
            .onDisappear { fleet?.dismissMachinePopover() }
            .confirmationDialog(
                pendingAction.map { operationCopy($0).title } ?? "Machine operation",
                isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                titleVisibility: .visible
            ) {
                if let action = pendingAction {
                    let copy = operationCopy(action)
                    Button(copy.button, role: copy.destructive ? .destructive : nil) {
                        pendingAction = nil
                        Task { await fleet?.performMachineOperation(action) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            } message: {
                Text(pendingAction.map { operationCopy($0).explanation } ?? "")
            }
            .alert(
                "Machine operation accepted",
                isPresented: Binding(
                    get: { fleet?.machineOperationMessage != nil },
                    set: { if !$0 { fleet?.machineOperationMessage = nil } })
            ) {
                Button("OK") { fleet?.machineOperationMessage = nil }
            } message: {
                Text(fleet?.machineOperationMessage ?? "")
            }
        }

        private func makeFleet() -> FleetModel {
            FleetModel(
                machines: { [weak app] in
                    app?.session.machines.map {
                        FleetMachine(id: $0.id, daemonID: $0.id, name: $0.name, entry: $0)
                    } ?? []
                },
                core: app.core, reportError: { [weak app] in app?.show($0) })
        }

        private func operationCopy(_ action: Dieter_V1_MachineOperationAction) -> ClientMachineOperationCopy {
            ClientMachineOperationCopy(rules: SharedRules.shared.machineOperationCopy(action: Int32(action.rawValue)))
        }

        private func bytes(_ value: UInt64) -> String {
            SharedRules.shared.bytes(count: Int64(clamping: value))
        }

        // MARK: - Identity

        private func identity(_ machine: ClientMachineEntry) -> some View {
            TimelineView(.periodic(from: .now, by: 30)) { clock in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "desktopcomputer")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(machine.displayName).font(.title2.bold())
                        HStack(spacing: 6) {
                            Circle().fill(machine.tone.color).frame(width: 7, height: 7)
                            Text(app.machineStatus(machine, now: clock.date))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        if let information {
                            Text(
                                SharedRules.shared.machineSubtitle(
                                    hardwareModel: information.hardwareModel, processor: information.processor,
                                    osName: information.osName, osVersion: information.osVersion,
                                    uptimeSeconds: Int64(clamping: information.uptimeSeconds))
                            )
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                        if !machine.route.isEmpty {
                            Label(machine.route, systemImage: "network")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("ios.machine-state.route")
                        }
                    }
                    Spacer(minLength: 0)
                    operations(machine)
                }
            }
            .padding()
            .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.machine-state.identity")
        }

        @ViewBuilder
        private func operations(_ machine: ClientMachineEntry) -> some View {
            let operations = fleet?.machineOperations[machine.id] ?? []
            if !operations.isEmpty {
                Menu {
                    ForEach(operations, id: \.action) { operation in
                        Button(
                            operationCopy(operation.action).menuTitle, systemImage: operationSymbol(operation.action)
                        ) {
                            pendingAction = operation.action
                        }
                        .disabled(!operation.available || !machine.available)
                        .accessibilityHint(operation.unavailableReason)
                        .accessibilityIdentifier("ios.machine-state.operation.\(operation.action.rawValue)")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .disabled(fleet?.machineOperationInFlight == true)
                .accessibilityLabel("Machine actions")
                .accessibilityIdentifier("ios.machine-state.actions")
            }
        }

        private func operationSymbol(_ action: Dieter_V1_MachineOperationAction) -> String {
            switch action {
            case .updateDaemon: "arrow.down.circle"
            case .restart: "arrow.clockwise.circle"
            case .shutdown: "power"
            default: "gearshape"
            }
        }

        // MARK: - Readings

        private func cpuCard(_ information: Dieter_V1_MachineInformation, machineID: String) -> some View {
            metricCard(title: "CPU", value: SharedRules.shared.machinePercentage(value: information.cpuUsagePercent)) {
                IOSMachineSparkline(
                    values: fleet?.machineCPUHistory[machineID] ?? [information.cpuUsagePercent], tint: .blue
                )
                .frame(height: 34)
                Text(
                    SharedRules.shared.machineLoad(
                        cores: Int32(clamping: information.logicalCpuCount), load1: information.load1,
                        load5: information.load5, load15: information.load15)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("ios.machine-state.cpu")
        }

        private func memoryCard(_ information: Dieter_V1_MachineInformation) -> some View {
            metricCard(title: "Memory", value: bytes(information.memoryUsedBytes)) {
                ProgressView(
                    value: Double(information.memoryUsedBytes),
                    total: Double(max(information.memoryTotalBytes, information.memoryUsedBytes, 1))
                )
                .tint(.purple)
                Text(
                    SharedRules.shared.machineMemory(
                        totalBytes: Int64(information.memoryTotalBytes),
                        cachedBytes: Int64(information.memoryCachedBytes),
                        swapBytes: Int64(information.swapUsedBytes))
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
                    value: SharedRules.shared.operatingSystem(
                        osName: information.osName, osVersion: information.osVersion))
                Divider()
                detailRow("Hardware", value: information.hardwareModel)
                Divider()
                detailRow("Processor", value: information.processor)
                Divider()
                detailRow("Architecture", value: information.architecture)
                Divider()
                detailRow(
                    "Disk", value: SharedRules.shared.machineDisk(freeBytes: Int64(clamping: information.diskFreeBytes))
                )
                Divider()
                detailRow(
                    "Network",
                    value: SharedRules.shared.machineNetwork(
                        receiveBytesPerSecond: information.networkReceiveBytesPerSecond,
                        sendBytesPerSecond: information.networkSendBytesPerSecond))
                if information.temperatureCelsius > 0 {
                    Divider()
                    detailRow(
                        "Temperature",
                        value: SharedRules.shared.machineTemperature(celsius: information.temperatureCelsius))
                }
            }
            .accessibilityIdentifier("ios.machine-state.system")
        }

        @ViewBuilder
        private func gpu(_ information: Dieter_V1_MachineInformation, machineID: String) -> some View {
            if information.hasGpu {
                stateCard(
                    "GPU", systemImage: "memorychip",
                    detail: information.gpu.devices.isEmpty
                        ? nil
                        : SharedRules.shared.count(
                            count: Int32(clamping: information.gpu.devices.count), noun: "device", plural: "devices")
                ) {
                    if information.gpu.devices.isEmpty {
                        Text(SharedRules.shared.gpuUnavailable(reason: information.gpu.unavailableReason))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(information.gpu.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        gpuDevice(device, history: fleet?.machineGPUHistory[machineID]?[device.id] ?? [])
                    }
                }
                .accessibilityIdentifier("ios.machine-state.gpu")
            }
        }

        private func gpuDevice(_ device: Dieter_V1_GPUDevice, history: [Double]) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SharedRules.shared.gpuName(name: device.name)).font(.headline)
                        Text(SharedRules.shared.gpuVendor(vendor: Int32(device.vendor.rawValue)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(
                        SharedRules.shared.gpuUtilization(
                            percent: device.utilizationPercent, reported: device.hasUtilizationPercent)
                    )
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(device.hasUtilizationPercent ? Color.blue : Color.secondary)
                }
                if device.hasUtilizationPercent {
                    IOSMachineSparkline(values: history.isEmpty ? [device.utilizationPercent] : history, tint: .blue)
                        .frame(height: 28)
                }
                let details = gpuDetails(device)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func gpuDetails(_ device: Dieter_V1_GPUDevice) -> [String] {
            var values: [String] = []
            if device.hasMemoryUsedBytes || device.hasMemoryTotalBytes {
                values.append(
                    SharedRules.shared.gpuMemory(
                        unified: device.memoryKind == .unified,
                        usedBytes: device.hasMemoryUsedBytes ? Int64(clamping: device.memoryUsedBytes) : -1,
                        totalBytes: device.hasMemoryTotalBytes ? Int64(clamping: device.memoryTotalBytes) : -1))
            }
            if device.hasTemperatureCelsius {
                values.append(SharedRules.shared.machineTemperature(celsius: device.temperatureCelsius))
            }
            if device.hasPowerWatts { values.append(SharedRules.shared.machinePower(watts: device.powerWatts)) }
            if device.hasProcessCount {
                values.append(
                    SharedRules.shared.count(
                        count: Int32(clamping: device.processCount), noun: "process", plural: "processes"))
            }
            return values
        }

        private func software(_ information: Dieter_V1_MachineInformation, machine: ClientMachineEntry) -> some View {
            stateCard("Software", systemImage: "server.rack") {
                detailRow(
                    "Dieter daemon",
                    value: SharedRules.shared.daemonVersion(
                        buildVersion: information.daemonBuild.releaseVersion, releaseVersion: machine.releaseVersion,
                        revision: information.daemonBuild.sourceRevision))
            }
            .accessibilityIdentifier("ios.machine-state.software")
        }

        private func processes(_ information: Dieter_V1_MachineInformation) -> some View {
            stateCard(
                "Dieter processes", systemImage: "gearshape.2",
                detail: SharedRules.shared.machineActiveAgents(agents: Int32(clamping: information.activeAgentCount))
            ) {
                if information.processes.isEmpty {
                    Text("No Dieter processes reported.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(information.processes.enumerated()), id: \.offset) { index, process in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            let agent = SharedRules.shared.isAgentProcess(kind: process.kind)
                            Image(systemName: agent ? "sparkles" : "terminal")
                                .foregroundStyle(agent ? .blue : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(
                                    SharedRules.shared.machineProcessDetail(
                                        pid: Int32(clamping: process.pid), detail: process.detail)
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(SharedRules.shared.machinePercentage(value: process.cpuUsagePercent))
                                Text(bytes(process.memoryBytes))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .accessibilityIdentifier("ios.machine-state.processes")
        }

        private func unavailable(_ machine: ClientMachineEntry) -> some View {
            ContentUnavailableView {
                Label(
                    machine.available ? "Machine state unavailable" : "Machine unavailable",
                    systemImage: machine.available ? "exclamationmark.triangle" : "wifi.slash")
            } description: {
                Text(
                    SharedRules.shared.machineInformationUnavailable(
                        online: machine.available,
                        detail: machine.unavailableMessage.isEmpty ? machine.detail : machine.unavailableMessage,
                        error: fleet?.machineInformationError ?? ""))
            } actions: {
                if machine.available {
                    Button("Try again") { Task { await fleet?.refreshSelectedMachineInformation() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ios.machine-state.retry")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }

        // MARK: - Cards

        private func metricCard<Content: View>(
            title: String, value: String, @ViewBuilder content: () -> Content
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
            .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
            .accessibilityElement(children: .combine)
        }

        private func stateCard<Content: View>(
            _ title: String, systemImage: String, detail: String? = nil, @ViewBuilder content: () -> Content
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
            .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
            .accessibilityElement(children: .contain)
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
    }

    /// Recent samples (0–100) as a filled line, oldest first.
    private struct IOSMachineSparkline: View {
        let values: [Double]
        let tint: Color

        var body: some View {
            GeometryReader { geometry in
                let points = points(in: geometry.size)
                ZStack {
                    if let first = points.first, let last = points.last {
                        Path { path in
                            path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                            points.forEach { path.addLine(to: $0) }
                            path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                            path.closeSubpath()
                        }
                        .fill(tint.opacity(0.16))
                        Path { path in
                            path.move(to: first)
                            points.dropFirst().forEach { path.addLine(to: $0) }
                        }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
            }
            .accessibilityHidden(true)
        }

        private func points(in size: CGSize) -> [CGPoint] {
            let samples = values.count == 1 ? values + values : values
            guard samples.count > 1 else { return [] }
            let step = size.width / CGFloat(samples.count - 1)
            return samples.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step, y: size.height * (1 - CGFloat(min(max(value, 0), 100)) / 100))
            }
        }
    }
#endif

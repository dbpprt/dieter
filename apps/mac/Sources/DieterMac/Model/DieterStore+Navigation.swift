import AppKit
import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

private struct TerminalOverviewMachineResult: Sendable {
    let machineID: String
    let entries: [TerminalOverviewEntry]
    let error: String?
}

extension DieterStore {
    func selectProject(_ id: String) async {
        guard await ensureProjectConnection(id) else { return }
        selectedProjectID = id
        selectedBoardID = boards(for: id).first?.id ?? ""
        resetFileSurface()
        await refreshState()
        if section == .files { await loadFiles() }
        if section == .schedules { await loadSchedules() }
    }

    func selectBoard(_ id: String) async {
        selectedBoardID = id
        if !hasLiveBoardProjection(projectID: selectedProjectID) { await refreshState() }
    }

    func openBoard(_ boardID: String, projectID: String) async {
        boardSelectionGeneration &+= 1
        let generation = boardSelectionGeneration
        stopTerminalWatch()
        closeConversation()
        section = .board
        selectCachedBoard(boardID, projectID: projectID)
        resetFileSurface()
        query = ""
        runtimeFilter = ""
        labelFilter = ""
        guard await ensureProjectConnection(projectID, reportOffline: false) else { return }
        guard generation == boardSelectionGeneration, section == .board else { return }
        selectCachedBoard(boardID, projectID: projectID)
        // WatchSync already owns this live project's state. A board click must
        // not fetch and republish the same project (including every card/chat).
        if !hasLiveBoardProjection(projectID: projectID) { await refreshState() }
    }

    func hasLiveBoardProjection(projectID: String) -> Bool {
        workspaceIsLive && (projectEndpointIDs[projectID] ?? endpoint.id) == endpoint.id
            && syncSnapshot?.state.projects.contains(where: { $0.id == projectID }) == true
    }

    /// Board navigation is backed by the synchronized projection. Selecting it
    /// must never wait for the host RPC: a refresh can follow when connectivity
    /// is available, while the cached workspace remains immediately usable.
    func selectCachedBoard(_ boardID: String, projectID: String) {
        selectedProjectID = projectID
        selectedBoardID = boardID
        updateSelectedState()
    }

    func openProject(_ projectID: String, section destination: AppSection) async {
        boardSelectionGeneration &+= 1
        let generation = boardSelectionGeneration
        stopTerminalWatch()
        closeConversation()
        section = destination
        selectedProjectID = projectID
        fileScopeCardID = nil
        terminalScopeCardID = nil
        if selectedBoardID.isEmpty
            || boards(for: projectID).contains(where: { $0.id == selectedBoardID }) == false
        {
            selectedBoardID = boards(for: projectID).first?.id ?? ""
        }
        resetFileSurface()
        updateSelectedState()
        // Schedules owns connection preparation and its paginated reads.
        if destination == .schedules { return }
        guard await ensureProjectConnection(projectID, reportOffline: false),
            generation == boardSelectionGeneration,
            selectedProjectID == projectID, section == destination
        else {
            if generation == boardSelectionGeneration, destination == .files {
                filesError = "This machine is unavailable. Reconnect and retry."
            }
            return
        }
        if destination == .changes { return }
        if destination == .files { await loadFiles() } else { await refreshState() }
    }

    func openProjectChanges(_ projectID: String) async {
        await openProject(projectID, section: .changes)
    }

    func openChats() async {
        stopTerminalWatch()
        closeConversation()
        section = .chats
        await refreshChats()
        if let lastUsedChatID,
            chats.contains(where: { $0.id == lastUsedChatID && !$0.archived })
        {
            await openConversation(cardID: lastUsedChatID, chat: true)
        }
    }

    func openTerminals() async {
        terminalScopeCardID = nil
        terminalOverviewPreferredMachineID = nil
        closeConversation()
        section = .terminals
    }

    func openWorkspaceFiles(card: Dieter_V1_Card, opening path: String? = nil) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        selectedProjectID = card.projectID
        fileScopeCardID = card.id
        resetFileSurface()
        closeConversation()
        section = .files
        await loadFiles()
        if let path, !path.isEmpty, selectedProjectID == card.projectID, fileScopeCardID == card.id,
            section == .files
        {
            await openFile(path: path)
        }
    }

    func openWorkspaceTerminal(card: Dieter_V1_Card) async {
        guard await ensureProjectConnection(card.projectID), let rpc else { return }
        selectedProjectID = card.projectID
        terminalScopeCardID = card.id
        var request = Dieter_V1_CreateTerminalRequest()
        request.projectID = card.projectID
        request.cardID = card.id
        request.name = card.title.isEmpty ? "Workspace" : card.title
        request.shell = ""
        request.workingDirectory = "."
        request.columns = 120
        request.rows = 36
        do {
            let terminal = try await rpc.createTerminal(request)
            closeConversation()
            section = .terminals
            terminals = try await rpc.terminals(projectID: card.projectID, cardID: card.id).terminals
            upsertTerminal(terminal)
            selectedTerminalID = terminal.id
            terminalSequences[terminal.id] = 0
            terminalScreens[terminal.id] = TerminalScreenState()
            startTerminalWatch()
        } catch { show(error) }
    }

    func showAllTerminals() async {
        terminalScopeCardID = nil
        terminalOverviewPreferredMachineID = nil
        await loadTerminalOverview()
    }

    func openScreens() {
        stopTerminalWatch()
        closeConversation()
        section = .screens
    }

    func openMachine(_ machine: DieterEndpoint) async {
        if selectedMachineID == machine.id {
            dismissMachinePopover()
            return
        }
        stopMachineTelemetry()
        selectedMachineID = machine.id
        machineInformationError = nil
        await refreshMachineInformation(machineID: machine.id)
        guard selectedMachineID == machine.id else { return }
        startMachineTelemetry(machineID: machine.id)
    }

    func dismissMachinePopover() {
        stopMachineTelemetry()
        selectedMachineID = nil
        machineInformationError = nil
    }

    func refreshSelectedMachineInformation() async {
        guard let selectedMachineID else { return }
        await refreshMachineInformation(machineID: selectedMachineID)
    }

    func startMachineTelemetry(machineID: String) {
        machineTelemetryTask?.cancel()
        machineTelemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(2)
                guard let self, !Task.isCancelled, self.selectedMachineID == machineID else { return }
                await self.refreshMachineInformation(machineID: machineID)
            }
        }
    }

    func stopMachineTelemetry() {
        machineTelemetryTask?.cancel()
        machineTelemetryTask = nil
        machineInformationLoading = false
    }

    func refreshMachineInformation(machineID: String) async {
        guard selectedMachineID == machineID else { return }
        machineInformationGeneration &+= 1
        let generation = machineInformationGeneration
        guard
            let machine = machines.first(where: { $0.id == machineID })
                ?? (endpoint.id == machineID ? endpoint : nil)
        else {
            machineInformationError = "This machine is no longer enrolled."
            return
        }
        guard machine.online else {
            machineInformationError = "\(machine.name) is offline."
            return
        }
        guard machine.apiCompatibility != .incompatible else {
            machineInformationError = machine.incompatibilityDescription
            return
        }
        machineInformationLoading = machineInformation[machineID] == nil
        defer { if generation == machineInformationGeneration { machineInformationLoading = false } }

        var borrowedPlane: DataPlaneLease?
        do {
            let client: DieterRPC
            if machine.id == endpoint.id, let rpc {
                client = rpc
            } else {
                let plane = try await selectDirectoryDataPlane(for: machine)
                borrowedPlane = plane
                client = plane.rpc
                machineConnectionStatuses[machine.id] = plane.connection
            }
            defer {
                borrowedPlane?.release()
            }
            let information = try await client.machineInformation()
            guard selectedMachineID == machineID, generation == machineInformationGeneration else {
                return
            }
            machineInformation[machineID] = information
            var history = machineCPUHistory[machineID, default: []]
            history.append(information.cpuUsagePercent)
            if history.count > 12 { history.removeFirst(history.count - 12) }
            machineCPUHistory[machineID] = history
            var gpuHistory = machineGPUHistory[machineID, default: [:]]
            let liveGPUIds = Set(information.gpu.devices.map(\.id))
            gpuHistory = gpuHistory.filter { liveGPUIds.contains($0.key) }
            for gpu in information.gpu.devices where gpu.hasUtilizationPercent {
                var values = gpuHistory[gpu.id, default: []]
                values.append(gpu.utilizationPercent)
                if values.count > 12 { values.removeFirst(values.count - 12) }
                gpuHistory[gpu.id] = values
            }
            machineGPUHistory[machineID] = gpuHistory
            machineInformationError = nil
        } catch is CancellationError {
        } catch {
            guard selectedMachineID == machineID, generation == machineInformationGeneration else {
                return
            }
            machineInformationError = DieterRPCFailure.message(for: error)
        }
    }

    func performMachineOperation(
        _ action: Dieter_V1_MachineOperationAction,
        confirmation: String
    ) async {
        guard let machineID = selectedMachineID,
            let machine = machines.first(where: { $0.id == machineID })
                ?? (endpoint.id == machineID ? endpoint : nil)
        else { return }
        guard machine.online else {
            show(
                NSError(
                    domain: "DieterMachine", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
        guard !machineOperationInFlight else { return }
        machineOperationInFlight = true
        defer { machineOperationInFlight = false }
        guard machine.apiCompatibility != .incompatible else {
            machineOperationMessage = machine.incompatibilityDescription
            return
        }
        var borrowedPlane: DataPlaneLease?
        do {
            let client: DieterRPC
            if machine.id == endpoint.id, let rpc {
                client = rpc
            } else {
                let plane = try await selectDirectoryDataPlane(for: machine)
                borrowedPlane = plane
                client = plane.rpc
            }
            defer {
                borrowedPlane?.release()
            }
            let response = try await client.performMachineOperation(action, confirmation: confirmation)
            machineOperationMessage = response.message
        } catch {
            show(error)
        }
    }

    func openTerminals(on machine: DieterEndpoint) async {
        guard machine.online else {
            show(
                NSError(
                    domain: "DieterMachine", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
        guard machine.apiCompatibility != .incompatible else {
            machineConnectionErrors[machine.id] = machine.incompatibilityDescription
            return
        }
        await openTerminals()
        terminalOverviewPreferredMachineID = machine.id
        await loadTerminalOverview(preferredMachineID: machine.id)
    }

    func bindTerminals() {
        terminalsModel.active = section == .terminals
        terminalsModel.onCreated = { [weak self] in self?.section = .terminals }
        terminalsModel.onTerminalChanged = { [weak self] machineID, terminalID, terminal in
            self?.updateTerminalOverviewEntry(machineID: machineID, terminalID: terminalID, terminal: terminal)
        }
        guard terminalScopeCardID != nil else {
            terminalsModel.isLive = terminalOverviewMachines.contains(where: machineIsAvailable)
            return
        }
        terminalsModel.bind(
            target: WorkspaceTarget(
                endpointID: endpoint.id,
                projectID: terminalScopeCardID == nil ? "" : selectedProjectID,
                conversationID: terminalScopeCardID ?? ""), client: rpc)
        terminalsModel.machineName = endpoint.name
        terminalsModel.isLive = workspaceIsLive
    }
    func loadTerminals() async {
        if terminalScopeCardID == nil {
            await loadTerminalOverview(preferredMachineID: terminalOverviewPreferredMachineID)
            return
        }
        bindTerminals()
        await terminalsModel.loadTerminals()
    }
    func selectTerminal(_ id: String) {
        if terminalScopeCardID == nil,
            let entry = terminalOverviewEntries.first(where: { $0.terminal.id == id })
        {
            Task { await selectTerminalOverviewEntry(entry.id) }
            return
        }
        bindTerminals()
        terminalsModel.selectTerminal(id)
    }
    func createTerminal(
        projectID: String, machineID: String? = nil, machineHome: Bool = false,
        name: String, shell: String, workingDirectory: String
    ) async {
        if terminalScopeCardID == nil {
            await createOverviewTerminal(
                projectID: projectID, machineID: machineID, machineHome: machineHome,
                name: name, shell: shell, workingDirectory: workingDirectory)
            return
        }
        if machineHome {
            guard
                let machine = endpoints.first(where: { $0.id == machineID })
                    ?? (endpoint.id == machineID ? endpoint : nil)
            else {
                show(
                    NSError(
                        domain: "DieterTerminal", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected machine is unavailable."]))
                return
            }
            guard machineIsAvailable(machine) else {
                show(
                    NSError(
                        domain: "DieterTerminal", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
                return
            }
            if machine.id != endpoint.id {
                await connect(to: machine)
                guard phase.isConnected, endpoint.id == machine.id else { return }
            }
        } else {
            guard await ensureProjectConnection(projectID) else { return }
        }
        bindTerminals()
        await terminalsModel.createTerminal(
            projectID: projectID, machineHome: machineHome, name: name, shell: shell,
            workingDirectory: workingDirectory)
    }
    func sendTerminalInput(id: String, data: Data) {
        terminalsModel.sendTerminalInput(id: id, data: data)
    }
    func resizeTerminal(id: String, columns: Int, rows: Int) async {
        await terminalsModel.resizeTerminal(id: id, columns: columns, rows: rows)
    }
    func renameTerminal(id: String, name: String) async {
        await terminalsModel.renameTerminal(id: id, name: name)
    }
    func closeTerminal(id: String) async { await terminalsModel.closeTerminal(id: id) }
    func closeTerminalOverviewEntry(_ id: String) async {
        guard let entry = terminalOverviewEntries.first(where: { $0.id == id }) else { return }
        if selectedTerminalOverviewID != id || terminalsModel.target.endpointID != entry.machineID {
            await selectTerminalOverviewEntry(id)
        }
        guard selectedTerminalOverviewID == id, terminalsModel.selectedTerminalID == entry.terminal.id else { return }
        await terminalsModel.closeTerminal(id: entry.terminal.id)
    }
    func startTerminalWatch() {
        bindTerminals()
        terminalsModel.startTerminalWatch()
    }
    func stopTerminalWatch() {
        terminalsModel.stopTerminalWatch()
        terminalOverviewGeneration &+= 1
        terminalOverviewLoading = false
        terminalOverviewLease?.release()
        terminalOverviewLease = nil
    }
    func acceptTerminalFrame(_ frame: Dieter_V1_TerminalFrame, terminalID: String) async {
        await terminalsModel.acceptTerminalFrame(frame, terminalID: terminalID)
    }
    func upsertTerminal(_ value: Dieter_V1_Terminal) { terminalsModel.upsertTerminal(value) }

    var terminalOverviewMachines: [DieterEndpoint] {
        var values = endpoints.filter { $0.daemonID != nil || $0.id == endpoint.id }
        if !values.contains(where: { $0.id == endpoint.id }), endpoint.daemonID != nil {
            values.append(endpoint)
        }
        return Array(Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values)
            .sorted {
                if $0.online != $1.online { return $0.online && !$1.online }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func loadTerminalOverview(preferredMachineID: String? = nil) async {
        terminalOverviewGeneration &+= 1
        let generation = terminalOverviewGeneration
        terminalOverviewLoading = terminalOverviewEntries.isEmpty
        terminalOverviewError = nil
        defer {
            if generation == terminalOverviewGeneration { terminalOverviewLoading = false }
        }

        let candidates = terminalOverviewMachines.filter(machineIsAvailable)
        guard !candidates.isEmpty else {
            terminalOverviewEntries = []
            selectedTerminalOverviewID = nil
            terminalOverviewError = "No compatible Dieter machines are online."
            terminalsModel.stopTerminalWatch()
            terminalsModel.installTerminals([], selectedID: nil)
            return
        }

        var results: [TerminalOverviewMachineResult] = []
        for machine in candidates {
            let result = await fetchTerminalOverview(on: machine)
            guard generation == terminalOverviewGeneration else { return }
            results.append(result)
            // Publish successful routes progressively so one slow machine does
            // not hold the complete overview in its empty loading state.
            terminalOverviewEntries = TerminalOverviewCatalog.sorted(results.flatMap(\.entries))
        }
        guard generation == terminalOverviewGeneration else { return }

        terminalOverviewEntries = TerminalOverviewCatalog.sorted(results.flatMap(\.entries))
        let failures = results.compactMap { result in result.error.map { "\(result.machineID): \($0)" } }
        terminalOverviewError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        guard
            let selected = TerminalOverviewCatalog.selection(
                in: terminalOverviewEntries, currentID: selectedTerminalOverviewID,
                preferredMachineID: preferredMachineID)
        else {
            selectedTerminalOverviewID = nil
            terminalOverviewLease?.release()
            terminalOverviewLease = nil
            terminalsModel.stopTerminalWatch()
            terminalsModel.installTerminals([], selectedID: nil)
            return
        }
        await activateTerminalOverviewEntry(selected, generation: generation)
    }

    func selectTerminalOverviewEntry(_ id: String) async {
        guard terminalScopeCardID == nil,
            let entry = terminalOverviewEntries.first(where: { $0.id == id })
        else { return }
        terminalOverviewGeneration &+= 1
        await activateTerminalOverviewEntry(entry, generation: terminalOverviewGeneration)
    }

    private func fetchTerminalOverview(on machine: DieterEndpoint) async -> TerminalOverviewMachineResult {
        var lease: DataPlaneLease?
        do {
            let client: DieterRPC
            if machine.id == endpoint.id, let rpc {
                client = rpc
            } else {
                let borrowed = try await selectDirectoryDataPlane(for: machine)
                lease = borrowed
                client = borrowed.rpc
            }
            defer { lease?.release() }
            let values = try await client.terminals(projectID: "", cardID: "").terminals
            return TerminalOverviewMachineResult(
                machineID: machine.id,
                entries: values.map {
                    TerminalOverviewEntry(machineID: machine.id, machineName: machine.name, terminal: $0)
                }, error: nil)
        } catch is CancellationError {
            return TerminalOverviewMachineResult(machineID: machine.id, entries: [], error: nil)
        } catch {
            return TerminalOverviewMachineResult(
                machineID: machine.id, entries: [], error: DieterRPCFailure.message(for: error))
        }
    }

    private func activateTerminalOverviewEntry(_ entry: TerminalOverviewEntry, generation: UInt64) async {
        guard terminalScopeCardID == nil,
            let machine = terminalOverviewMachines.first(where: { $0.id == entry.machineID })
        else { return }
        terminalsModel.stopTerminalWatch()
        terminalOverviewLease?.release()
        terminalOverviewLease = nil
        do {
            let client: DieterRPC
            var lease: DataPlaneLease?
            if machine.id == endpoint.id, let rpc {
                client = rpc
            } else {
                let borrowed = try await selectDirectoryDataPlane(for: machine)
                lease = borrowed
                client = borrowed.rpc
            }
            guard generation == terminalOverviewGeneration, section == .terminals, terminalScopeCardID == nil else {
                lease?.release()
                return
            }
            terminalOverviewLease = lease
            selectedTerminalOverviewID = entry.id
            terminalsModel.bind(
                target: WorkspaceTarget(endpointID: machine.id, projectID: ""), client: client)
            terminalsModel.machineName = machine.name
            terminalsModel.isLive = true
            terminalsModel.active = true
            terminalsModel.installTerminals(
                terminalOverviewEntries.filter { $0.machineID == machine.id }.map(\.terminal),
                selectedID: entry.terminal.id)
        } catch {
            guard generation == terminalOverviewGeneration else { return }
            terminalOverviewError = DieterRPCFailure.message(for: error)
            terminalsModel.isLive = false
        }
    }

    private func createOverviewTerminal(
        projectID: String, machineID: String?, machineHome: Bool,
        name: String, shell: String, workingDirectory: String
    ) async {
        let destination = machineID.flatMap { id in terminalOverviewMachines.first(where: { $0.id == id }) }
        guard let machine = destination, machineIsAvailable(machine) else {
            show(
                NSError(
                    domain: "DieterTerminal", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected machine is unavailable."]))
            return
        }
        var lease: DataPlaneLease?
        do {
            let client: DieterRPC
            if machine.id == endpoint.id, let rpc {
                client = rpc
            } else {
                let borrowed = try await selectDirectoryDataPlane(for: machine)
                lease = borrowed
                client = borrowed.rpc
            }
            defer { lease?.release() }
            var request = Dieter_V1_CreateTerminalRequest()
            request.projectID = projectID
            request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            request.shell = shell
            request.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            request.columns = 120
            request.rows = 36
            request.machineHome = machineHome
            let terminal = try await client.createTerminal(request)
            let entry = TerminalOverviewEntry(machineID: machine.id, machineName: machine.name, terminal: terminal)
            terminalOverviewEntries.removeAll { $0.id == entry.id }
            terminalOverviewEntries.append(entry)
            terminalOverviewEntries = TerminalOverviewCatalog.sorted(terminalOverviewEntries)
            selectedTerminalOverviewID = entry.id
            terminalsModel.createTerminalPresented = false
            terminalOverviewGeneration &+= 1
            await activateTerminalOverviewEntry(entry, generation: terminalOverviewGeneration)
        } catch {
            show(error)
        }
    }

    private func updateTerminalOverviewEntry(
        machineID: String, terminalID: String, terminal: Dieter_V1_Terminal?
    ) {
        guard terminalScopeCardID == nil else { return }
        let id = TerminalOverviewEntry.id(machineID: machineID, terminalID: terminalID)
        if let terminal,
            let machine = terminalOverviewMachines.first(where: { $0.id == machineID })
        {
            let entry = TerminalOverviewEntry(machineID: machineID, machineName: machine.name, terminal: terminal)
            if let index = terminalOverviewEntries.firstIndex(where: { $0.id == id }) {
                terminalOverviewEntries[index] = entry
            } else {
                terminalOverviewEntries.append(entry)
            }
            terminalOverviewEntries = TerminalOverviewCatalog.sorted(terminalOverviewEntries)
        } else {
            terminalOverviewEntries.removeAll { $0.id == id }
            if selectedTerminalOverviewID == id {
                selectedTerminalOverviewID = nil
                if let next = terminalOverviewEntries.first {
                    Task { await selectTerminalOverviewEntry(next.id) }
                }
            }
        }
    }

    func beginStandaloneChat(projectID: String? = nil) {
        stopTerminalWatch()
        closeConversation()
        section = .chats
        newChatProjectID = projectID ?? selectedProjectID
    }

    func openSettings(section: DieterSettingsSection = .general) {
        stopTerminalWatch()
        closeConversation()
        settingsSection = section
        self.section = .settings
    }

    func presentNewBoard(projectID: String) {
        Task {
            guard await ensureProjectConnection(projectID) else { return }
            selectedProjectID = projectID
            selectedBoardID = boards(for: projectID).first?.id ?? ""
            createBoardPresented = true
        }
    }

    func presentRenameProject(projectID: String) {
        Task {
            guard await ensureProjectConnection(projectID) else { return }
            selectedProjectID = projectID
            renameProjectTargetID = projectID
            renameProjectPresented = true
        }
    }

    func presentProjectEditor(projectID: String) {
        Task {
            guard await ensureProjectConnection(projectID) else { return }
            selectedProjectID = projectID
            projectContextPresented = true
        }
    }

    func presentRenameBoard(boardID: String) {
        guard let target = board(id: boardID) else { return }
        Task {
            guard await ensureProjectConnection(target.projectID) else { return }
            renameBoardTargetID = boardID
            renameBoardPresented = true
        }
    }
}

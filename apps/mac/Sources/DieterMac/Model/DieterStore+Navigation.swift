import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func selectProject(_ id: String) async {
        guard await ensureProjectConnection(id) else { return }
        selectedProjectID = id
        selectedBoardID = boards(for: id).first?.id ?? ""
        filePath = ""; fileNavigation.reset(); fileDocument = nil
        await refreshState()
        if section == .files { await loadFiles() }
        if section == .schedules { await loadSchedules() }
    }

    func selectBoard(_ id: String) async {
        selectedBoardID = id
        await refreshState()
    }

    func openBoard(_ boardID: String, projectID: String) async {
        boardSelectionGeneration &+= 1
        let generation = boardSelectionGeneration
        stopTerminalWatch()
        closeConversation()
        section = .board
        selectCachedBoard(boardID, projectID: projectID)
        filePath = ""; fileNavigation.reset(); fileDocument = nil
        query = ""; runtimeFilter = ""; labelFilter = ""
        guard await ensureProjectConnection(projectID, reportOffline: false) else { return }
        guard generation == boardSelectionGeneration, section == .board else { return }
        selectCachedBoard(boardID, projectID: projectID)
        await refreshState()
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
        guard await ensureProjectConnection(projectID) else { return }
        stopTerminalWatch()
        closeConversation()
        section = destination
        selectedProjectID = projectID
        fileScopeCardID = nil
        terminalScopeCardID = nil
        if selectedBoardID.isEmpty || boards(for: projectID).contains(where: { $0.id == selectedBoardID }) == false {
            selectedBoardID = boards(for: projectID).first?.id ?? ""
        }
        filePath = ""; fileNavigation.reset(); fileDocument = nil
        await refreshState()
        if destination == .files { await loadFiles() }
        if destination == .schedules { await loadSchedules() }
    }

    func openChats() async {
        stopTerminalWatch()
        closeConversation()
        section = .chats
        await refreshChats()
    }

    func openTerminals() async {
        terminalScopeCardID = nil
        closeConversation()
        section = .terminals
        await loadTerminals()
    }

    func openWorkspaceFiles(card: Dieter_V1_Card, opening path: String? = nil) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        selectedProjectID = card.projectID
        fileScopeCardID = card.id
        filePath = ""
        fileNavigation.reset()
        fileDocument = nil
        closeConversation()
        section = .files
        await loadFiles()
        if let path, !path.isEmpty { await openFile(path: path) }
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
        await loadTerminals()
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
        selectedMachineID = machine.id
        machineInformationError = nil
        await refreshMachineInformation(machineID: machine.id)
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
        guard let machine = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil) else {
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
        defer { machineInformationLoading = false }

        var borrowedPlane: DataPlaneConnection?
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
                borrowedPlane?.task.cancel()
                borrowedPlane?.rpc.shutdown()
            }
            let information = try await client.machineInformation()
            guard selectedMachineID == machineID else { return }
            machineInformation[machineID] = information
            var history = machineCPUHistory[machineID, default: []]
            history.append(information.cpuUsagePercent)
            if history.count > 12 { history.removeFirst(history.count - 12) }
            machineCPUHistory[machineID] = history
            machineInformationError = nil
        } catch is CancellationError {
        } catch {
            guard selectedMachineID == machineID else { return }
            machineInformationError = error.localizedDescription
        }
    }

    func performMachineOperation(
        _ action: Dieter_V1_MachineOperationAction,
        confirmation: String
    ) async {
        guard let machineID = selectedMachineID,
              let machine = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil) else { return }
        guard machine.online else {
            show(NSError(domain: "DieterMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
		guard machine.apiCompatibility != .incompatible else {
			machineOperationMessage = machine.incompatibilityDescription
			return
		}
        var borrowedPlane: DataPlaneConnection?
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
                borrowedPlane?.task.cancel()
                borrowedPlane?.rpc.shutdown()
            }
            let response = try await client.performMachineOperation(action, confirmation: confirmation)
            machineOperationMessage = response.message
        } catch {
            show(error)
        }
    }

    func openTerminals(on machine: DieterEndpoint) async {
        guard machine.online else {
            show(NSError(domain: "DieterMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
		guard machine.apiCompatibility != .incompatible else {
			machineConnectionErrors[machine.id] = machine.incompatibilityDescription
			return
		}
        if machine.id != endpoint.id {
            await connect(to: machine)
            guard phase.isConnected, endpoint.id == machine.id else { return }
        }
        await openTerminals()
    }

    func loadTerminals() async {
        guard let rpc else { return }
        terminalLoading = true
        defer { terminalLoading = false }
        do {
            let values: [Dieter_V1_Terminal]
            if let terminalScopeCardID {
                values = try await rpc.terminals(projectID: selectedProjectID, cardID: terminalScopeCardID).terminals
            } else {
                values = try await rpc.terminals().terminals
            }
            terminals = values
            let liveIDs = Set(values.map(\.id))
            terminalScreens = terminalScreens.filter { liveIDs.contains($0.key) }
            terminalSequences = terminalSequences.filter { liveIDs.contains($0.key) }
            await terminalOutputAccumulator.retain(terminalIDs: liveIDs)
            if selectedTerminalID.flatMap({ id in values.first(where: { $0.id == id }) }) == nil {
                selectedTerminalID = values.first?.id
            }
            startTerminalWatch()
        } catch {
            show(error)
        }
    }

    func selectTerminal(_ id: String) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
        startTerminalWatch()
    }

    func createTerminal(projectID: String, name: String, shell: String, workingDirectory: String) async {
        guard await ensureProjectConnection(projectID) else { return }
        guard let rpc else { return }
        var request = Dieter_V1_CreateTerminalRequest()
        request.projectID = projectID
        request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        request.shell = shell
        request.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        request.columns = 120
        request.rows = 36
        request.cardID = terminalScopeCardID ?? ""
        do {
            let value = try await rpc.createTerminal(request)
            upsertTerminal(value)
            selectedTerminalID = value.id
            terminalSequences[value.id] = 0
            terminalScreens[value.id] = TerminalScreenState()
            await terminalOutputAccumulator.seed(terminalID: value.id)
            createTerminalPresented = false
            section = .terminals
            startTerminalWatch()
        } catch {
            show(error)
        }
    }

    func sendTerminalInput(id: String, data: Data) {
        guard let rpc,
              !data.isEmpty,
              terminals.first(where: { $0.id == id })?.status == "running" else { return }
        Task { [weak self] in
            guard let self else { return }
            if let message = await terminalInputForwarder.enqueue(id: id, data: data, rpc: rpc),
               self.rpc === rpc,
               self.terminals.contains(where: { $0.id == id }) {
                self.terminalStreamConnected = false
                self.errorMessage = "Terminal input could not be forwarded: \(message)"
            }
        }
    }

    func resizeTerminal(id: String, columns: Int, rows: Int) async {
        guard let rpc,
              columns >= 2, rows >= 2,
              terminals.first(where: { $0.id == id })?.status == "running" else { return }
        do {
            upsertTerminal(try await rpc.resizeTerminal(id: id, columns: columns, rows: rows))
        } catch where Self.isExpectedCancellation(error) { }
        catch {
            guard terminals.contains(where: { $0.id == id }) else { return }
            show(error)
        }
    }

    func renameTerminal(id: String, name: String) async {
        guard let rpc else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { upsertTerminal(try await rpc.renameTerminal(id: id, name: value)) }
        catch { show(error) }
    }

    func closeTerminal(id: String) async {
        guard let rpc else { return }
        do {
            try await rpc.closeTerminal(id: id)
            terminals.removeAll { $0.id == id }
            terminalScreens.removeValue(forKey: id)
            terminalSequences.removeValue(forKey: id)
            await terminalOutputAccumulator.remove(terminalID: id)
            if selectedTerminalID == id {
                selectedTerminalID = terminals.first?.id
                startTerminalWatch()
            }
        } catch { show(error) }
    }

    func startTerminalWatch() {
        terminalWatchTask?.cancel()
        terminalWatchTask = nil
        terminalStreamConnected = false
        guard section == .terminals,
              let id = selectedTerminalID,
              terminals.contains(where: { $0.id == id }),
              let rpc else { return }
        let after = terminalSequences[id] ?? 0
        terminalWatchTask = Task { [weak self] in
            guard let self else { return }
            var delay = 0.5
            while !Task.isCancelled, self.rpc === rpc, self.selectedTerminalID == id {
                do {
                    self.terminalStreamConnected = true
                    try await rpc.watchTerminal(id: id, after: self.terminalSequences[id] ?? after) { [weak self] frame in
                        await self?.acceptTerminalFrame(frame, terminalID: id)
                    }
                    guard !Task.isCancelled else { return }
                    self.terminalStreamConnected = false
                } catch where Self.isExpectedCancellation(error) {
                    return
                } catch {
                    self.terminalStreamConnected = false
                    if let rpcError = error as? RPCError, rpcError.code == .notFound {
                        self.terminals.removeAll { $0.id == id }
                        self.selectedTerminalID = self.terminals.first?.id
                        return
                    }
                }
                try? await DieterTaskSleep.seconds(delay)
                delay = min(5, delay * 1.8)
            }
        }
    }

    func acceptTerminalFrame(_ frame: Dieter_V1_TerminalFrame, terminalID: String) async {
        guard frame.hasTerminal, frame.terminal.id == terminalID else { return }
        upsertTerminal(frame.terminal)
        if !terminalStreamConnected { terminalStreamConnected = true }
        terminalSequences[terminalID] = max(terminalSequences[terminalID] ?? 0, frame.sequence)
        guard frame.screenReset || !frame.data.isEmpty else { return }
        await terminalOutputAccumulator.enqueue(
            terminalID: terminalID,
            data: frame.data,
            screenReset: frame.screenReset,
            current: terminalScreens[terminalID] ?? TerminalScreenState()
        ) { [weak self] id, screen in
            guard let self, self.terminals.contains(where: { $0.id == id }) else { return }
            self.terminalScreens[id] = screen
        }
    }

    func upsertTerminal(_ value: Dieter_V1_Terminal) {
        if let index = terminals.firstIndex(where: { $0.id == value.id }) {
            guard terminals[index] != value else { return }
            terminals[index] = value
        } else {
            terminals.append(value)
        }
        terminals.sort {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    func stopTerminalWatch() {
        terminalWatchTask?.cancel()
        terminalWatchTask = nil
        terminalStreamConnected = false
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

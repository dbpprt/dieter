import AppKit
import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func selectProject(_ id: String) async {
        guard await ensureReplicaConnection(id) else { return }
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
        guard await ensureReplicaConnection(projectID, reportOffline: false) else { return }
        guard generation == boardSelectionGeneration, section == .board else { return }
        selectCachedBoard(boardID, projectID: projectID)
        // WatchSync already owns this live project's state. A board click must
        // not fetch and republish the same project (including every card/chat).
        if !hasLiveBoardProjection(projectID: projectID) { await refreshState() }
    }

    func hasLiveBoardProjection(projectID: String) -> Bool {
        workspaceIsLive
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
        let ready: Bool
        if destination == .files || destination == .changes {
            ready = await ensureCheckoutConnection(projectID)
        } else {
            ready = await ensureReplicaConnection(projectID, reportOffline: false)
        }
        guard ready,
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

    func openInbox() async {
        guard section != .inbox else { return }
        boardSelectionGeneration &+= 1
        stopTerminalWatch()
        closeConversation()
        section = .inbox
        if !hasLiveChatDirectory { await refreshChats(includeArchived: false) }
    }

    func openChats() async {
        // Reselecting the current destination must not tear down its transcript.
        guard section != .chats else { return }
        stopTerminalWatch()
        closeConversation()
        section = .chats
        if !hasLiveChatDirectory { await refreshChats(includeArchived: false) }
        guard section == .chats else { return }
        if let lastUsedChatID,
            chats.contains(where: { $0.id == lastUsedChatID && !$0.archived })
        {
            await openConversation(cardID: lastUsedChatID, chat: true)
        }
    }

    var hasLiveChatDirectory: Bool { workspaceIsLive && syncSnapshot != nil }

    func ensureChatDirectory(includeArchived: Bool) async {
        if includeArchived || !hasLiveChatDirectory { await refreshChats(includeArchived: includeArchived) }
    }

    func openTerminals() async {
        terminalScopeCardID = nil
        terminalOverview.terminalOverviewPreferredMachineID = nil
        closeConversation()
        section = .terminals
    }

    func openWorkspaceFiles(card: Dieter_V1_Card, opening path: String? = nil) async {
        guard await ensureConversationConnection(card) else { return }
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
        guard await ensureConversationConnection(card), let rpc else { return }
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
            terminalsModel.terminals = try await rpc.terminals(projectID: card.projectID, cardID: card.id).terminals
            upsertTerminal(terminal)
            terminalsModel.selectedTerminalID = terminal.id
            terminalsModel.terminalSequences[terminal.id] = 0
            terminalsModel.terminalScreens[terminal.id] = TerminalScreenState()
            startTerminalWatch()
        } catch { show(error) }
    }

    func showAllTerminals() async {
        terminalScopeCardID = nil
        terminalOverview.terminalOverviewPreferredMachineID = nil
        await terminalOverview.loadTerminalOverview()
    }

    func openScreens() {
        stopTerminalWatch()
        closeConversation()
        section = .screens
    }

    func openTerminals(on machine: DieterEndpoint) async {
        guard machine.online else {
            show(
                NSError(
                    domain: "DieterMachine", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
        guard machine.compatibilityState != .incompatible else {
            machineConnectionErrors[machine.id] = machine.incompatibilityDescription
            return
        }
        await openTerminals()
        terminalOverview.terminalOverviewPreferredMachineID = machine.id
        await terminalOverview.loadTerminalOverview(preferredMachineID: machine.id)
    }

    func bindTerminals() {
        terminalsModel.active = section == .terminals
        terminalsModel.onCreated = { [weak self] in self?.section = .terminals }
        terminalsModel.onTerminalChanged = { [weak self] machineID, terminalID, terminal in
            self?.terminalOverview.updateTerminalOverviewEntry(
                machineID: machineID, terminalID: terminalID, terminal: terminal)
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
            await terminalOverview.loadTerminalOverview(
                preferredMachineID: terminalOverview.terminalOverviewPreferredMachineID)
            return
        }
        bindTerminals()
        await terminalsModel.loadTerminals()
    }
    func selectTerminal(_ id: String) {
        if terminalScopeCardID == nil,
            let entry = terminalOverview.terminalOverviewEntries.first(where: { $0.terminal.id == id })
        {
            Task { await terminalOverview.selectTerminalOverviewEntry(entry.id) }
            return
        }
        bindTerminals()
        terminalsModel.selectTerminal(id)
    }
    func createTerminal(
        projectID: String, checkoutID: String = "", machineID: String? = nil, machineHome: Bool = false,
        name: String, shell: String, workingDirectory: String
    ) async {
        if terminalScopeCardID == nil {
            await terminalOverview.createOverviewTerminal(
                projectID: projectID, checkoutID: checkoutID, machineID: machineID, machineHome: machineHome,
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
        } else if let cardID = terminalScopeCardID,
            let card = synchronizedCardValues().first(where: { $0.id == cardID })
        {
            guard await ensureConversationConnection(card) else { return }
        } else {
            if !checkoutID.isEmpty { creationCheckoutIDs[projectID] = checkoutID }
            guard await ensureCheckoutConnection(projectID) else { return }
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
        guard let entry = terminalOverview.terminalOverviewEntries.first(where: { $0.id == id }) else { return }
        if terminalOverview.selectedTerminalOverviewID != id || terminalsModel.target.endpointID != entry.machineID {
            await terminalOverview.selectTerminalOverviewEntry(id)
        }
        guard terminalOverview.selectedTerminalOverviewID == id, terminalsModel.selectedTerminalID == entry.terminal.id
        else { return }
        await terminalsModel.closeTerminal(id: entry.terminal.id)
    }
    func startTerminalWatch() {
        bindTerminals()
        terminalsModel.startTerminalWatch()
    }
    func stopTerminalWatch() {
        terminalsModel.stopTerminalWatch()
        terminalOverview.stop()
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
            guard await ensureReplicaConnection(projectID) else { return }
            selectedProjectID = projectID
            selectedBoardID = boards(for: projectID).first?.id ?? ""
            createBoardPresented = true
        }
    }

    func presentRenameProject(projectID: String) {
        Task {
            guard await ensureReplicaConnection(projectID) else { return }
            selectedProjectID = projectID
            renameProjectTargetID = projectID
            renameProjectPresented = true
        }
    }

    func presentProjectEditor(projectID: String) {
        Task {
            guard await ensureReplicaConnection(projectID) else { return }
            selectedProjectID = projectID
            projectContextPresented = true
        }
    }

    func presentRenameBoard(boardID: String) {
        guard let target = board(id: boardID) else { return }
        Task {
            guard await ensureReplicaConnection(target.projectID) else { return }
            renameBoardTargetID = boardID
            renameBoardPresented = true
        }
    }
}

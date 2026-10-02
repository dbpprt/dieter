import AppKit
import DieterAPI
import DieterCore
import Foundation
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func selectProject(_ id: String) async {
        guard await ensureConnected() else { return }
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
        stateFilter = .all
        labelFilter = ""
        guard await ensureConnected(reportOffline: false) else { return }
        guard generation == boardSelectionGeneration, section == .board else { return }
        selectCachedBoard(boardID, projectID: projectID)
        // The core's feed already keeps a live project current; a board click
        // only asks for a refresh when the workspace is not live.
        if !hasLiveBoardProjection(projectID: projectID) { await refreshState() }
    }

    func hasLiveBoardProjection(projectID: String) -> Bool {
        workspaceIsLive && projectDirectory[projectID] != nil
    }

    /// Board navigation shows the core's cached workspace at once; a refresh
    /// can follow when the machine is reachable.
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
            ready = await ensureConnected(reportOffline: false)
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
    }

    func openChats() async {
        // Reselecting the current destination must not tear down its transcript.
        guard section != .chats else { return }
        stopTerminalWatch()
        closeConversation()
        section = .chats
        if let lastUsedChatID,
            chats.contains(where: { $0.id == lastUsedChatID && !$0.archived })
        {
            await openConversation(cardID: lastUsedChatID, chat: true)
        }
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

    /// Opens a new shell in a conversation's workspace, on the machine that holds it.
    func openWorkspaceTerminal(card: Dieter_V1_Card) async {
        selectedProjectID = card.projectID
        terminalScopeCardID = card.id
        closeConversation()
        section = .terminals
        await terminalsModel.loadTerminals()
        await terminalsModel.createTerminal(
            name: card.title.isEmpty ? "Workspace" : card.title, shell: "", workingDirectory: ".")
        if let message = terminalsModel.errorMessage { errorMessage = message }
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
        if let reason = unavailableReason(machine) {
            show(NSError(domain: "DieterMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: reason]))
            return
        }
        await openTerminals()
        terminalOverview.terminalOverviewPreferredMachineID = machine.id
        await terminalOverview.loadTerminalOverview(preferredMachineID: machine.id)
    }

    /// Points the terminals at the overview, or at a conversation's
    /// workspace on the machine that holds it.
    func bindTerminals() {
        terminalsModel.onCreated = { [weak self] in self?.section = .terminals }
        guard let cardID = terminalScopeCardID else {
            terminalsModel.isLive = terminalOverviewMachines.contains(where: machineIsAvailable)
            terminalsModel.active = section == .terminals
            return
        }
        terminalOverview.stop()
        let card = synchronizedCardValues().first { $0.id == cardID } ?? chats.first { $0.id == cardID }
        let machine = card.map { endpointID(for: $0) } ?? endpoint.id
        terminalsModel.bind(
            target: WorkspaceTarget(endpointID: machine, projectID: selectedProjectID, conversationID: cardID),
            core: core)
        terminalsModel.machineName = endpoints.first { $0.id == machine }?.name ?? endpoint.name
        terminalsModel.isLive = workspaceIsLive
        terminalsModel.active = section == .terminals
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
        // A conversation's terminals start in its workspace.
        bindTerminals()
        await terminalsModel.createTerminal(name: name, shell: shell, workingDirectory: workingDirectory)
    }
    func closeTerminalOverviewEntry(_ id: String) async {
        guard let entry = terminalOverview.terminalOverviewEntries.first(where: { $0.id == id }) else { return }
        if terminalOverview.selectedTerminalOverviewID != id || terminalsModel.target.endpointID != entry.machineID {
            await terminalOverview.selectTerminalOverviewEntry(id)
        }
        guard terminalOverview.selectedTerminalOverviewID == id, terminalsModel.selectedTerminalID == entry.terminal.id
        else { return }
        await terminalsModel.closeTerminal(id: entry.terminal.id)
    }
    /// Stops streaming when the terminals are hidden; the shells keep running.
    func stopTerminalWatch() {
        terminalsModel.active = false
        terminalOverview.stop()
    }

    /// The machines the terminal overview lists, in the core's order.
    var terminalOverviewMachines: [DieterEndpoint] {
        var values = endpoints.filter { $0.daemonID != nil || $0.id == endpoint.id }
        if !values.contains(where: { $0.id == endpoint.id }), endpoint.daemonID != nil {
            values.append(endpoint)
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
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
            guard await ensureConnected() else { return }
            selectedProjectID = projectID
            selectedBoardID = boards(for: projectID).first?.id ?? ""
            createBoardPresented = true
        }
    }

    func presentRenameProject(projectID: String) {
        Task {
            guard await ensureConnected() else { return }
            selectedProjectID = projectID
            renameProjectTargetID = projectID
            renameProjectPresented = true
        }
    }

    func presentProjectEditor(projectID: String) {
        Task {
            guard await ensureConnected() else { return }
            selectedProjectID = projectID
            projectContextPresented = true
        }
    }

    func presentRenameBoard(boardID: String) {
        guard board(id: boardID) != nil else { return }
        Task {
            guard await ensureConnected() else { return }
            renameBoardTargetID = boardID
            renameBoardPresented = true
        }
    }
}

import AppKit
import DieterAPI
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
        if section == .files { await loadFiles() }
        if section == .schedules { await loadSchedules() }
    }

    /// Every machine's stream keeps the workspace live, so navigating reads nothing.
    func selectBoard(_ id: String) {
        selectedBoardID = id
    }

    func openBoard(_ boardID: String, projectID: String) {
        boardSelectionGeneration &+= 1
        stopTerminalWatch()
        closeConversation()
        section = .board
        selectCachedBoard(boardID, projectID: projectID)
        resetFileSurface()
        query = ""
        stateFilter = .all
        labelFilter = ""
    }

    /// Board navigation shows the core's workspace at once, live or cached.
    func selectCachedBoard(_ boardID: String, projectID: String) {
        selectedProjectID = projectID
        selectedBoardID = boardID
        updateSelectedState()
    }

    func openProject(_ projectID: String, section destination: AppSection) async {
        boardSelectionGeneration &+= 1
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
        // Schedules and changes load themselves; files and changes need the
        // chosen checkout's machine.
        guard destination == .files || destination == .changes else { return }
        guard checkoutIsAvailable(projectID) else {
            if destination == .files { filesError = "This machine is unavailable. Reconnect and retry." }
            return
        }
        if destination == .files { await loadFiles() }
    }

    func openProjectChanges(_ projectID: String) async {
        await openProject(projectID, section: .changes)
    }

    /// Shows a checkout path in Files: a folder's listing, or a file opened beside its folder.
    func openProjectPath(_ projectID: String, path: String, directory: Bool) async {
        await openProject(projectID, section: .files)
        guard section == .files, selectedProjectID == projectID, filesError == nil else { return }
        let folder = directory ? path : (path as NSString).deletingLastPathComponent
        if !folder.isEmpty { await filesModel.navigateFiles(to: folder) }
        if !directory, section == .files, selectedProjectID == projectID { await openFile(path: path) }
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
        guard conversationMachineIsAvailable(card) else { return }
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

    func openTerminals(on machine: MachineEndpoint) async {
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
            terminalsModel.isLive = terminalsAreLive
            terminalsModel.active = section == .terminals
            return
        }
        terminalOverview.stop()
        let card = synchronizedCardValues().first { $0.id == cardID } ?? chats.first { $0.id == cardID }
        let owner = card.flatMap { machine(for: $0) }
        terminalsModel.bind(
            target: WorkspaceTarget(endpointID: owner?.id ?? "", projectID: selectedProjectID, conversationID: cardID),
            core: core)
        terminalsModel.machineName = owner?.name ?? ""
        terminalsModel.isLive = terminalsAreLive
        terminalsModel.active = section == .terminals
    }

    /// The overview opens shells while any machine is available; a
    /// conversation's terminals while the machine that runs it is.
    var terminalsAreLive: Bool {
        guard phase.isConnected else { return false }
        guard terminalScopeCardID != nil else { return machines.contains(where: machineIsAvailable) }
        let machineID = terminalsModel.target.endpointID
        return endpoints.contains { $0.id == machineID && machineIsAvailable($0) }
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

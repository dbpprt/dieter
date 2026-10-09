import AppKit
import DieterAPI
import Foundation
import Observation
import SharedCore
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    /// Points the files at the project's chosen checkout, or a conversation's
    /// workspace, on the machine that holds it. Without a chosen checkout,
    /// the project's machine shows its own checkout.
    func resetFileSurface() {
        let checkout = fileScopeCardID == nil ? checkout(forProjectID: selectedProjectID) : nil
        let machine: String
        if let checkout {
            machine = endpointID(forDaemon: checkout.daemonID)
        } else if let cardID = fileScopeCardID {
            // A conversation's files are on the machine that runs it.
            machine =
                filesModel.target.conversationID == cardID && !filesModel.target.endpointID.isEmpty
                ? filesModel.target.endpointID
                : synchronizedCardValues().first { $0.id == cardID }.map { endpointID(for: $0) } ?? ""
        } else {
            machine = projectMachine(forProjectID: selectedProjectID)?.id ?? ""
        }
        filesModel.bind(
            target: WorkspaceTarget(
                endpointID: machine, projectID: selectedProjectID, conversationID: fileScopeCardID ?? "",
                checkoutID: checkout?.id ?? ""),
            core: core
        )
        filesModel.projectName = selectedProject?.name ?? "Project"
        filesModel.projectPath = selectedProject?.path ?? ""
        filesModel.isLive = filesAreLive
    }

    /// Files can change while their machine is available.
    var filesAreLive: Bool {
        let machine = filesModel.target.endpointID
        return phase.isConnected && endpoints.contains { $0.id == machine && machineIsAvailable($0) }
    }

    @discardableResult func loadFiles(path: String? = nil) async -> Bool {
        resetFileSurface()
        return await filesModel.loadFiles(path: path)
    }
    func openFile(path: String) async { resetFileSurface(); await filesModel.openFile(path: path) }
    @discardableResult func saveFile(content: String) async -> Dieter_V1_FileDocument? {
        resetFileSurface(); return await filesModel.saveFile(content: content)
    }
    func createFile(name: String, directory: Bool) async {
        resetFileSurface(); await filesModel.createFile(name: name, directory: directory)
    }

    /// Schedules change on their project's machines while one is available.
    var schedulesAreLive: Bool { phase.isConnected && projectIsAvailable(selectedProjectID) }

    /// Shows the selected project's schedules; the core reaches each
    /// schedule's machine.
    func bindSchedules() {
        let machine = projectMachine(forProjectID: selectedProjectID)?.id ?? ""
        schedulesModel.bind(target: WorkspaceTarget(endpointID: machine, projectID: selectedProjectID), core: core)
        schedulesModel.isLive = schedulesAreLive
        schedulesModel.catalog = { [weak self] daemonID in
            guard let self else { return nil }
            if self.machineMetadata[daemonID]?.loaded != true {
                _ = await self.perform { $0.ensureMetadata = .with { $0.daemonID = daemonID } }
                _ = await self.awaitCore(timeout: .seconds(5)) { self.machineMetadata[daemonID]?.loaded == true }
            }
            return self.machineMetadata[daemonID].flatMap { $0.loaded ? $0.harnesses : nil }
        }
    }

    var scheduleEditorContext: ScheduleEditorContext {
        let checkout = checkout(forProjectID: selectedProjectID)
        let machine = checkout?.daemonID ?? projectMachine(forProjectID: selectedProjectID)?.daemonID ?? ""
        return ScheduleEditorContext(
            target: WorkspaceTarget(
                endpointID: schedulesModel.target.endpointID, projectID: schedulesModel.target.projectID,
                checkoutID: checkout?.id ?? ""),
            projectName: selectedProject?.name ?? "Project",
            boards: state.boards.filter { $0.projectID == selectedProjectID },
            selectedBoardID: selectedBoardID, harnessCatalog: harnessCatalog(forDaemon: machine),
            checkoutMachines: Dictionary(
                (selectedProject?.checkouts ?? []).map { ($0.id, $0.daemonID) }, uniquingKeysWith: { first, _ in first }
            ))
    }

    func loadSchedules() async { bindSchedules(); await schedulesModel.loadSchedules() }
    @discardableResult func saveSchedule(id: String?, draft: Dieter_V1_ScheduleDraft) async -> Bool {
        bindSchedules(); return await schedulesModel.saveSchedule(id: id, draft: draft)
    }

    /// `daemonID`'s global prompt templates, which its agents use.
    func loadPromptSettings(daemonID: String) async throws -> Dieter_V1_PromptSettings {
        try await administer { $0.promptSettings = .with { $0.daemonID = daemonID } }.promptSettings
    }

    func updatePromptSettings(_ value: Dieter_V1_PromptSettings, daemonID: String) async throws
        -> Dieter_V1_PromptSettings
    {
        try await administer {
            $0.updatePromptSettings = .with {
                $0.daemonID = daemonID
                $0.context = value.promptTemplate
                $0.boardSkill = value.boardSkillTemplate
                $0.chatSkill = value.chatSkillTemplate
            }
        }.promptSettings
    }

    @discardableResult
    func setSelectedProjectPromptTemplate(inherit: Bool, template: String) async throws -> Bool {
        guard let project = selectedProject else { return false }
        _ = try await administer {
            $0.setProjectPrompt = .with {
                $0.scopeID = project.id
                if !inherit { $0.template = template }
            }
        }
        return true
    }

    @discardableResult
    func setSelectedBoardPromptTemplate(inherit: Bool, template: String) async throws -> Bool {
        guard let board = selectedBoard else { return false }
        _ = try await administer {
            $0.setBoardPrompt = .with {
                $0.scopeID = board.id
                if !inherit { $0.template = template }
            }
        }
        return true
    }

    @discardableResult
    func updatePromptInstructions(for label: Dieter_V1_Label, instructions: String) async throws -> Bool {
        guard let board = selectedBoard else { return false }
        _ = try await administer {
            $0.updateLabel = .with {
                $0.boardID = board.id
                $0.labelID = label.id
                $0.name = label.name
                $0.color = label.color
                $0.instructions = instructions
            }
        }
        return true
    }

    func previewPrompt(labelIDs: Set<String>) async throws -> Dieter_V1_PromptPreview? {
        guard let project = selectedProject else { return nil }
        let boardID = selectedBoard?.id ?? ""
        return try await administer {
            $0.previewPrompt = .with {
                $0.projectID = project.id
                $0.boardID = boardID
                $0.labelIds = Array(labelIDs)
            }
        }.promptPreview
    }

    /// The core posts notifications and reads this setting on every change.
    var notificationsEnabled: Bool {
        get { (environment.defaults.string(forKey: "notifications.enabled") ?? "true") == "true" }
        set {
            environment.defaults.set(newValue ? "true" : "false", forKey: "notifications.enabled")
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func show(_ error: Error) {
        guard !Self.isExpectedCancellation(error) else { return }
        // While the machine is unreachable the window already shows that, and
        // the core retries its own work; a transient failure adds nothing.
        if (error as? CoreFailure)?.kind == .transient, !phase.isConnected { return }
        errorMessage = error.localizedDescription
    }
}

import AppKit
import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func resetFileSurface() {
        filesModel.bind(
            target: WorkspaceTarget(
                endpointID: projectEndpointIDs[selectedProjectID] ?? endpoint.id,
                projectID: selectedProjectID, conversationID: fileScopeCardID ?? ""),
            client: rpc
        )
        filesModel.projectName = selectedProject?.name ?? "Project"
        filesModel.projectPath = selectedProject?.path ?? ""
        filesModel.isLive = selectedProjectIsLive
    }

    @discardableResult func loadFiles(path: String? = nil) async -> Bool {
        resetFileSurface()
        return await filesModel.loadFiles(path: path)
    }
    func navigateFiles(to path: String) async { resetFileSurface(); await filesModel.navigateFiles(to: path) }
    func navigateFilesBack() async { resetFileSurface(); await filesModel.navigateFilesBack() }
    func navigateFilesForward() async { resetFileSurface(); await filesModel.navigateFilesForward() }
    func openFile(path: String) async { resetFileSurface(); await filesModel.openFile(path: path) }
    @discardableResult func saveFile(content: String) async -> Dieter_V1_FileDocument? {
        resetFileSurface(); return await filesModel.saveFile(content: content)
    }
    func createFile(path: String, directory: Bool) async {
        resetFileSurface(); await filesModel.createFile(path: path, directory: directory)
    }
    func deleteFile(path: String, recursive: Bool) async {
        resetFileSurface(); await filesModel.deleteFile(path: path, recursive: recursive)
    }
    func moveFile(source: String, destination: String) async {
        resetFileSurface(); await filesModel.moveFile(source: source, destination: destination)
    }

    func bindSchedules() {
        schedulesModel.bind(
            target: WorkspaceTarget(endpointID: endpoint.id, projectID: selectedProjectID),
            reader: scheduleRPCOverride ?? rpc, writer: rpc
        )
        schedulesModel.isLive = selectedProjectIsLive
    }

    var scheduleEditorContext: ScheduleEditorContext {
        ScheduleEditorContext(
            target: schedulesModel.target, projectName: selectedProject?.name ?? "Project",
            boards: state.boards.filter { $0.projectID == selectedProjectID },
            selectedBoardID: selectedBoardID, harnessCatalog: harnessCatalog)
    }

    func loadSchedules() async { bindSchedules(); await schedulesModel.loadSchedules() }
    func loadMoreSchedules() async { bindSchedules(); await schedulesModel.loadMoreSchedules() }
    func selectSchedule(_ id: String) async { bindSchedules(); await schedulesModel.selectSchedule(id) }
    func loadScheduleRuns(for id: String, appending: Bool = false) async {
        bindSchedules(); await schedulesModel.loadScheduleRuns(for: id, appending: appending)
    }
    func loadMoreScheduleRuns() async { bindSchedules(); await schedulesModel.loadMoreScheduleRuns() }
    func upsertLoadedSchedule(_ schedule: Dieter_V1_Schedule) { schedulesModel.upsertLoadedSchedule(schedule) }
    @discardableResult func saveSchedule(id: String?, draft: Dieter_V1_ScheduleDraft) async -> Bool {
        bindSchedules(); return await schedulesModel.saveSchedule(id: id, draft: draft)
    }
    func toggleSchedule(_ schedule: Dieter_V1_Schedule) async {
        bindSchedules(); await schedulesModel.toggleSchedule(schedule)
    }
    func runSchedule(_ schedule: Dieter_V1_Schedule) async {
        bindSchedules(); await schedulesModel.runSchedule(schedule)
    }
    func deleteSchedule(_ schedule: Dieter_V1_Schedule) async {
        bindSchedules(); await schedulesModel.deleteSchedule(schedule)
    }
    func previewSchedule(cron: String, timezone: String, count: Int32 = 5) async throws -> [String]? {
        bindSchedules(); return try await schedulesModel.previewSchedule(cron: cron, timezone: timezone, count: count)
    }

    func loadPromptSettings() async throws -> Dieter_V1_PromptSettings? {
        guard let rpc else { return nil }
        return try await rpc.promptSettings()
    }

    func updatePromptSettings(_ value: Dieter_V1_PromptSettings) async throws -> Dieter_V1_PromptSettings? {
        guard let rpc else { return nil }
        var request = Dieter_V1_UpdatePromptSettingsRequest()
        request.promptTemplate = value.promptTemplate
        request.boardSkillTemplate = value.boardSkillTemplate
        request.chatSkillTemplate = value.chatSkillTemplate
        return try await rpc.updatePromptSettings(request)
    }

    @discardableResult
    func setSelectedProjectPromptTemplate(inherit: Bool, template: String) async throws -> Bool {
        guard let rpc, let project = selectedProject else { return false }
        var request = Dieter_V1_SetScopedPromptTemplateRequest()
        request.scopeID = project.id
        request.inherit = inherit
        request.promptTemplate = template
        acceptProject(try await rpc.setProjectPromptTemplate(request))
        return true
    }

    @discardableResult
    func setSelectedBoardPromptTemplate(inherit: Bool, template: String) async throws -> Bool {
        guard let rpc, let board = selectedBoard else { return false }
        var request = Dieter_V1_SetScopedPromptTemplateRequest()
        request.scopeID = board.id
        request.inherit = inherit
        request.promptTemplate = template
        acceptBoard(try await rpc.setBoardPromptTemplate(request))
        return true
    }

    @discardableResult
    func updatePromptInstructions(for label: Dieter_V1_Label, instructions: String) async throws -> Bool {
        guard let rpc, let board = selectedBoard else { return false }
        var request = Dieter_V1_UpdateBoardLabelRequest()
        request.boardID = board.id
        request.labelID = label.id
        request.name = label.name
        request.color = label.color
        request.instructions = instructions
        acceptBoard(try await rpc.updateBoardLabel(request))
        return true
    }

    func previewPrompt(labelIDs: Set<String>) async throws -> Dieter_V1_PromptPreview? {
        guard let rpc, let project = selectedProject else { return nil }
        var request = Dieter_V1_PreviewPromptRequest()
        request.projectID = project.id
        request.boardID = selectedBoard?.id ?? ""
        request.scope = request.boardID.isEmpty ? "chat" : "board"
        request.labelIds = Array(labelIDs)
        return try await rpc.previewPrompt(request)
    }

    func updateLimits(global: Int, agents: [String: Int], boards: [String: Int]) async {
        guard let rpc else { return }
        var settings = boardSettings; settings.globalParallelLimit = Int32(global);
        settings.agentParallelLimits = agents.mapValues(Int32.init);
        settings.boardParallelLimits = boards.mapValues(Int32.init)
        var request = Dieter_V1_UpdateSettingsRequest(); request.settings = settings
        do { boardSettings = try await rpc.updateSettings(request) } catch { show(error) }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyTransitions(_ cards: [Dieter_V1_Card], endpointID: String) {
        for card in activityTransitions.accept(cards, endpointID: endpointID) {
            notify(title: card.title, body: "Status changed to \(card.runtime)")
        }
    }

    func notify(title: String, body: String) {
        guard environment.defaults.bool(forKey: "DieterNotifications") else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body;
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func show(_ error: Error) {
        guard !Self.isExpectedCancellation(error) else { return }
        if DieterRPCFailure.isTransient(error) {
            // One stream usually notices a dropped connection first and starts
            // reconnecting. Other in-flight calls may then fail after `rpc` has
            // already been released; those failures are the same connectivity
            // event and must not fall through to the global alert.
            if let rpc { connectionStopped(error, client: rpc) }
            return
        }
        errorMessage = DieterRPCFailure.message(for: error)
    }
}

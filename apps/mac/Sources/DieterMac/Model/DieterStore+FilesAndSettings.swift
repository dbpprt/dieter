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
                endpointID: endpoint.id,
                projectID: selectedProjectID, conversationID: fileScopeCardID ?? "", checkoutID: fileScopeCardID == nil ? (checkout(forProjectID: selectedProjectID)?.id ?? "") : ""),
            client: rpc
        )
        filesModel.projectName = selectedProject?.name ?? "Project"
        filesModel.projectPath = selectedProject?.path ?? ""
        filesModel.isLive = selectedProjectIsLive
    }

    @discardableResult func loadFiles(path: String? = nil) async -> Bool {
        if fileScopeCardID == nil { guard await ensureCheckoutConnection(selectedProjectID) else { return false } }
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
        if scheduleRPCOverride != nil { schedulesModel.ownerConnection = nil; return }
        schedulesModel.ownerConnection = { [weak self] ownerID, checkoutID in
            guard let self else { throw CancellationError() }
            let checkout = self.projectDirectory[self.selectedProjectID]?.checkouts.first { $0.id == checkoutID }
                ?? self.checkout(forProjectID: self.selectedProjectID)
            let daemonID = ownerID.isEmpty ? checkout?.daemonID : ownerID
            guard let daemonID, let machine = self.endpoints.first(where: { $0.daemonID == daemonID }), machine.online else {
                throw NSError(domain: "Schedule", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an online machine and checkout for this schedule."])
            }
            if machine.id == self.endpoint.id, let rpc = self.rpc {
                return ScheduleOwnerConnection(reader: rpc, writer: rpc, detail: { try await rpc.schedule(id: $0) }, release: {}, catalog: { try await rpc.harnesses() })
            }
            let lease = try await self.selectDirectoryDataPlane(for: machine)
            return ScheduleOwnerConnection(reader: lease.rpc, writer: lease.rpc, detail: { try await lease.rpc.schedule(id: $0) }, release: { lease.release() }, catalog: { try await lease.rpc.harnesses() })
        }
    }

    var scheduleEditorContext: ScheduleEditorContext {
        ScheduleEditorContext(
            target: WorkspaceTarget(endpointID: schedulesModel.target.endpointID, projectID: schedulesModel.target.projectID, checkoutID: checkout(forProjectID: selectedProjectID)?.id ?? ""), projectName: selectedProject?.name ?? "Project",
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
            guard phase.isConnected, rpc != nil else { return }
            // A single failed operation is not proof that the shared data plane
            // is dead. Stream supervisors and the transport runner own recovery;
            // this caller only reports its own unsuccessful operation. Ignore a
            // stale result after that data plane has already been released.
            connectionLogger.info(
                "Operation failed transiently without replacing the data plane: \(DieterRPCFailure.message(for: error), privacy: .public)"
            )
            errorMessage = DieterRPCFailure.message(for: error)
            return
        }
        errorMessage = DieterRPCFailure.message(for: error)
    }
}

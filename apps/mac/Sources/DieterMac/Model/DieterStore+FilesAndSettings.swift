import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    @discardableResult
    func loadFiles(path: String? = nil) async -> Bool {
        guard let rpc, !selectedProjectID.isEmpty else { return false }
        let destination = path ?? filePath
        var request = Dieter_V1_ListFilesRequest(); request.projectID = selectedProjectID; request.path = destination; request.showHidden = showHiddenFiles
        request.cardID = fileScopeCardID ?? ""
        do {
            let listing = try await rpc.listFiles(request)
            files = listing.entries
            filePath = listing.path
            return true
        } catch {
            show(error)
            return false
        }
    }

    func navigateFiles(to destination: String) async {
        guard destination != filePath, !fileNavigationLoading else { return }
        fileNavigationLoading = true
        defer { fileNavigationLoading = false }
        let previousNavigation = fileNavigation
        fileNavigation.recordNavigation(from: filePath, to: destination)
        if !(await loadFiles(path: destination)) { fileNavigation = previousNavigation }
    }

    func navigateFilesBack() async {
        guard !fileNavigationLoading else { return }
        fileNavigationLoading = true
        defer { fileNavigationLoading = false }
        let previousNavigation = fileNavigation
        guard let destination = fileNavigation.goBack(from: filePath) else { return }
        if !(await loadFiles(path: destination)) { fileNavigation = previousNavigation }
    }

    func navigateFilesForward() async {
        guard !fileNavigationLoading else { return }
        fileNavigationLoading = true
        defer { fileNavigationLoading = false }
        let previousNavigation = fileNavigation
        guard let destination = fileNavigation.goForward(from: filePath) else { return }
        if !(await loadFiles(path: destination)) { fileNavigation = previousNavigation }
    }

    func openFile(path: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_ReadFileRequest(); request.projectID = selectedProjectID; request.path = path; request.cardID = fileScopeCardID ?? ""
        do { fileDocument = try await rpc.readFile(request) } catch { show(error) }
    }

    @discardableResult
    func saveFile(content: String) async -> Dieter_V1_FileDocument? {
        guard let rpc, let doc = fileDocument else { return nil }
        var request = Dieter_V1_SaveFileRequest(); request.projectID = selectedProjectID; request.path = doc.path; request.cardID = fileScopeCardID ?? ""
        request.content = content; request.revision = doc.revision
        do {
            var saved = try await rpc.saveFile(request)
            if saved.mimeType.isEmpty { saved.mimeType = doc.mimeType }
            fileDocument = saved
            return saved
        } catch {
            show(error)
            return nil
        }
    }

    func createFile(path: String, directory: Bool) async {
        guard let rpc else { return }
        var request = Dieter_V1_CreateFileRequest(); request.projectID = selectedProjectID; request.path = path; request.kind = directory ? "directory" : "file"; request.cardID = fileScopeCardID ?? ""
        do { _ = try await rpc.createFile(request); await loadFiles() } catch { show(error) }
    }

    func deleteFile(path: String, recursive: Bool) async {
        guard let rpc else { return }
        var request = Dieter_V1_DeleteFileRequest(); request.projectID = selectedProjectID; request.path = path; request.recursive = recursive; request.cardID = fileScopeCardID ?? ""
        do { try await rpc.deleteFile(request); fileDocument = nil; await loadFiles() } catch { show(error) }
    }

    func moveFile(source: String, destination: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_MoveFileRequest(); request.projectID = selectedProjectID; request.source = source; request.destination = destination; request.cardID = fileScopeCardID ?? ""
        do { _ = try await rpc.moveFile(request); fileDocument = nil; await loadFiles() } catch { show(error) }
    }

    func loadSchedules() async {
        guard !selectedProjectID.isEmpty else { return }
        let projectID = selectedProjectID
        let endpointID = endpoint.id
        guard let client = scheduleRPCOverride ?? rpc else { return }

        schedulesRequestGeneration &+= 1
        let generation = schedulesRequestGeneration
        schedulesLoading = true
        schedulesLoadingMore = false
        schedulesNextPageToken = ""
        if !schedulesAreLoaded {
            schedules = []
            scheduleRuns = []
            selectedScheduleID = nil
        }

        do {
            let response = try await client.schedules(projectID: projectID, pageSize: schedulePageSize, pageToken: "")
            guard generation == schedulesRequestGeneration,
                  selectedProjectID == projectID, endpoint.id == endpointID else { return }
            schedules = response.schedules
            schedulesTotalCount = Int(response.totalCount)
            schedulesNextPageToken = response.nextPageToken
            schedulesLoadedProjectID = projectID
            schedulesLoadedEndpointID = endpointID
            schedulesLoading = false
            if selectedScheduleID == nil || !schedules.contains(where: { $0.id == selectedScheduleID }) {
                selectedScheduleID = schedules.first?.id
            }
            guard let selectedScheduleID else {
                scheduleRunsRequestGeneration &+= 1
                scheduleRuns = []
                scheduleRunsLoading = false
                return
            }
            await loadScheduleRuns(for: selectedScheduleID)
        } catch {
            guard generation == schedulesRequestGeneration,
                  selectedProjectID == projectID, endpoint.id == endpointID else { return }
            schedulesLoading = false
            show(error)
        }
    }

    func loadMoreSchedules() async {
        guard schedulesAreLoaded, !schedulesLoading, !schedulesLoadingMore,
              !schedulesNextPageToken.isEmpty,
              let client = scheduleRPCOverride ?? rpc else { return }
        let projectID = selectedProjectID
        let endpointID = endpoint.id
        let pageToken = schedulesNextPageToken
        let generation = schedulesRequestGeneration
        schedulesLoadingMore = true
        do {
            let response = try await client.schedules(projectID: projectID, pageSize: schedulePageSize, pageToken: pageToken)
            guard generation == schedulesRequestGeneration,
                  selectedProjectID == projectID, endpoint.id == endpointID else { return }
            let existing = Set(schedules.map(\.id))
            schedules.append(contentsOf: response.schedules.filter { !existing.contains($0.id) })
            schedulesTotalCount = Int(response.totalCount)
            schedulesNextPageToken = response.nextPageToken
            schedulesLoadingMore = false
        } catch {
            guard generation == schedulesRequestGeneration,
                  selectedProjectID == projectID, endpoint.id == endpointID else { return }
            schedulesLoadingMore = false
            show(error)
        }
    }

    func selectSchedule(_ id: String) async {
        guard schedulesAreLoaded, schedules.contains(where: { $0.id == id }) else { return }
        selectedScheduleID = id
        await loadScheduleRuns(for: id)
    }

    func loadScheduleRuns(for scheduleID: String, appending: Bool = false) async {
        guard let client = scheduleRPCOverride ?? rpc else { return }
        let projectID = selectedProjectID
        let endpointID = endpoint.id
        if !appending { scheduleRunsRequestGeneration &+= 1 }
        let generation = scheduleRunsRequestGeneration
        let pageToken = appending ? scheduleRunsNextPageToken : ""
        if appending {
            guard !scheduleRunsLoading, !scheduleRunsLoadingMore, !pageToken.isEmpty else { return }
            scheduleRunsLoadingMore = true
        } else {
            scheduleRuns.removeAll()
            scheduleRunsNextPageToken = ""
            scheduleRunsLoading = true
            scheduleRunsLoadingMore = false
        }
        do {
            let response = try await client.scheduleRuns(id: scheduleID, pageSize: schedulePageSize, pageToken: pageToken)
            guard generation == scheduleRunsRequestGeneration,
                  selectedProjectID == projectID, endpoint.id == endpointID,
                  selectedScheduleID == scheduleID else { return }
            if appending {
                let existing = Set(scheduleRuns.map(\.id))
                scheduleRuns.append(contentsOf: response.runs.filter { !existing.contains($0.id) })
            } else {
                scheduleRuns = response.runs
            }
            scheduleRunsNextPageToken = response.nextPageToken
            scheduleRunsLoading = false
            scheduleRunsLoadingMore = false
        } catch {
            guard generation == scheduleRunsRequestGeneration,
                  selectedProjectID == projectID, endpoint.id == endpointID,
                  selectedScheduleID == scheduleID else { return }
            scheduleRunsLoading = false
            scheduleRunsLoadingMore = false
            show(error)
        }
    }

    func loadMoreScheduleRuns() async {
        guard let selectedScheduleID else { return }
        await loadScheduleRuns(for: selectedScheduleID, appending: true)
    }

    func upsertLoadedSchedule(_ schedule: Dieter_V1_Schedule) {
        let existingIndex = schedules.firstIndex(where: { $0.id == schedule.id })
        if let existingIndex {
            schedules[existingIndex] = schedule
        } else {
            schedules.append(schedule)
            schedulesTotalCount += 1
        }
        schedules.sort {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    @discardableResult
    func saveSchedule(id: String?, draft: Dieter_V1_ScheduleDraft) async -> Bool {
        guard let rpc else { return false }
        var request = Dieter_V1_SaveScheduleRequest(); request.scheduleID = id ?? ""; request.schedule = draft
        do {
            let saved = try await (id == nil ? rpc.createSchedule(request) : rpc.updateSchedule(request))
            upsertLoadedSchedule(saved)
            selectedScheduleID = saved.id
            await loadScheduleRuns(for: saved.id)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func toggleSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard let rpc else { return }
        do { upsertLoadedSchedule(try await rpc.setScheduleEnabled(id: schedule.id, enabled: !schedule.enabled)) } catch { show(error) }
    }

    func runSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.runSchedule(id: schedule.id)
            selectedScheduleID = schedule.id
            await loadScheduleRuns(for: schedule.id)
        } catch { show(error) }
    }

    func deleteSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard let rpc else { return }
        do {
            try await rpc.deleteSchedule(id: schedule.id)
            let removed = schedules.contains { $0.id == schedule.id }
            schedules.removeAll { $0.id == schedule.id }
            if removed { schedulesTotalCount = max(0, schedulesTotalCount - 1) }
            if selectedScheduleID == schedule.id {
                selectedScheduleID = schedules.first?.id
                scheduleRuns = []
                scheduleRunsNextPageToken = ""
            }
            if schedules.isEmpty && !schedulesNextPageToken.isEmpty {
                await loadMoreSchedules()
                selectedScheduleID = schedules.first?.id
            }
            if let selectedScheduleID, scheduleRuns.isEmpty {
                await loadScheduleRuns(for: selectedScheduleID)
            }
        } catch { show(error) }
    }

    func previewSchedule(cron: String, timezone: String, count: Int32 = 5) async throws -> [String]? {
        guard let rpc, !cron.isEmpty, !timezone.isEmpty else { return nil }
        var request = Dieter_V1_PreviewScheduleRequest()
        request.cron = cron
        request.timezone = timezone
        request.count = count
        return try await rpc.previewSchedule(request).times
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
        var settings = boardSettings; settings.globalParallelLimit = Int32(global); settings.agentParallelLimits = agents.mapValues(Int32.init); settings.boardParallelLimits = boards.mapValues(Int32.init)
        var request = Dieter_V1_UpdateSettingsRequest(); request.settings = settings
        do { boardSettings = try await rpc.updateSettings(request) } catch { show(error) }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: "DieterNotifications") else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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

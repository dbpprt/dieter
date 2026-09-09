import DieterAPI
import DieterCore
import Foundation
import Observation

struct ScheduleEditorContext {
    let target: WorkspaceTarget
    let projectName: String
    let boards: [Dieter_V1_Board]
    let selectedBoardID: String
    let harnessCatalog: Dieter_V1_HarnessCatalog
}

@MainActor @Observable
final class SchedulesModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var isLive = false
    var schedules: [Dieter_V1_Schedule] = []
    var scheduleRuns: [Dieter_V1_ScheduleRun] = []
    var selectedScheduleID: String?
    var schedulesLoading = false
    var schedulesLoadingMore = false
    var scheduleRunsLoading = false
    var scheduleRunsLoadingMore = false
    var schedulesTotalCount = 0
    var schedulesNextPageToken = ""
    var scheduleRunsNextPageToken = ""
    var schedulesLoadedProjectID = ""
    var schedulesLoadedEndpointID = ""
    var schedulesError: String?
    var errorMessage: String?
    @ObservationIgnored private var reader: (any DieterScheduleRPC)?
    @ObservationIgnored private var writer: (any ScheduleCommandsRPC)?
    private(set) var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var schedulesRequestGeneration: UInt64 = 0
    @ObservationIgnored private var scheduleRunsRequestGeneration: UInt64 = 0
    @ObservationIgnored private let schedulesRead = OwnedRead<Dieter_V1_SchedulesResponse>()

    var schedulesAreLoaded: Bool {
        !target.projectID.isEmpty && schedulesLoadedProjectID == target.projectID
            && schedulesLoadedEndpointID == target.endpointID
    }
    var selectedSchedule: Dieter_V1_Schedule? {
        guard schedulesAreLoaded else { return nil }
        return schedules.first { $0.id == selectedScheduleID }
    }

    func bind(target: WorkspaceTarget, reader: (any DieterScheduleRPC)?, writer: (any ScheduleCommandsRPC)?) {
        guard self.target != target || self.reader !== reader || self.writer !== writer else { return }
        let sameTarget = self.target == target
        self.target = target; self.reader = reader; self.writer = writer
        connectionGeneration &+= 1; schedulesRequestGeneration &+= 1; scheduleRunsRequestGeneration &+= 1
        schedulesRead.cancel()
        schedulesLoading = false; schedulesLoadingMore = false; scheduleRunsLoading = false;
        scheduleRunsLoadingMore = false
        schedulesError = nil; errorMessage = nil
        if !sameTarget {
            schedules = []; scheduleRuns = []; selectedScheduleID = nil
            schedulesTotalCount = 0; schedulesNextPageToken = ""; scheduleRunsNextPageToken = ""
            schedulesLoadedProjectID = ""; schedulesLoadedEndpointID = ""
        }
    }

    private func report(_ error: Error) {
        guard !DieterRPCFailure.isCancellation(error) else { return }
        errorMessage = DieterRPCFailure.message(for: error)
    }

    func loadSchedules() async {
        guard !target.projectID.isEmpty else { return }
        let projectID = target.projectID
        let endpointID = target.endpointID
        let binding = connectionGeneration
        guard let client = reader else { return }

        schedulesRequestGeneration &+= 1
        let generation = schedulesRequestGeneration
        schedulesLoading = true
        schedulesError = nil
        schedulesLoadingMore = false
        schedulesNextPageToken = ""
        if !schedulesAreLoaded {
            schedules = []
            scheduleRuns = []
            selectedScheduleID = nil
        }

        do {
            let response = try await schedulesRead.value(key: "\(connectionGeneration):\(endpointID):\(projectID)") {
                try await client.schedules(projectID: projectID, pageSize: schedulePageSize, pageToken: "")
            }
            guard binding == connectionGeneration, generation == schedulesRequestGeneration,
                target.projectID == projectID, target.endpointID == endpointID
            else { return }
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
            guard binding == connectionGeneration, generation == schedulesRequestGeneration,
                target.projectID == projectID, target.endpointID == endpointID
            else { return }
            schedulesLoading = false
            if !DieterRPCFailure.isCancellation(error) { schedulesError = DieterRPCFailure.message(for: error) }
        }
    }

    func loadMoreSchedules() async {
        guard schedulesAreLoaded, !schedulesLoading, !schedulesLoadingMore,
            !schedulesNextPageToken.isEmpty,
            let client = reader
        else { return }
        let projectID = target.projectID
        let endpointID = target.endpointID
        let binding = connectionGeneration
        let pageToken = schedulesNextPageToken
        let generation = schedulesRequestGeneration
        schedulesLoadingMore = true
        do {
            let response = try await client.schedules(
                projectID: projectID, pageSize: schedulePageSize, pageToken: pageToken)
            guard binding == connectionGeneration, generation == schedulesRequestGeneration,
                target.projectID == projectID, target.endpointID == endpointID
            else { return }
            let existing = Set(schedules.map(\.id))
            schedules.append(contentsOf: response.schedules.filter { !existing.contains($0.id) })
            schedulesTotalCount = Int(response.totalCount)
            schedulesNextPageToken = response.nextPageToken
            schedulesLoadingMore = false
        } catch {
            guard binding == connectionGeneration, generation == schedulesRequestGeneration,
                target.projectID == projectID, target.endpointID == endpointID
            else { return }
            schedulesLoadingMore = false
            report(error)
        }
    }

    func selectSchedule(_ id: String) async {
        guard schedulesAreLoaded, schedules.contains(where: { $0.id == id }) else { return }
        selectedScheduleID = id
        await loadScheduleRuns(for: id)
    }

    func loadScheduleRuns(for scheduleID: String, appending: Bool = false) async {
        guard let client = reader else { return }
        let projectID = target.projectID
        let endpointID = target.endpointID
        let binding = connectionGeneration
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
            let response = try await client.scheduleRuns(
                id: scheduleID, pageSize: schedulePageSize, pageToken: pageToken)
            guard binding == connectionGeneration, generation == scheduleRunsRequestGeneration,
                target.projectID == projectID, target.endpointID == endpointID,
                selectedScheduleID == scheduleID
            else { return }
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
            guard binding == connectionGeneration, generation == scheduleRunsRequestGeneration,
                target.projectID == projectID, target.endpointID == endpointID,
                selectedScheduleID == scheduleID
            else { return }
            scheduleRunsLoading = false
            scheduleRunsLoadingMore = false
            report(error)
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
    func saveSchedule(id: String?, draft: Dieter_V1_ScheduleDraft, expectedTarget: WorkspaceTarget? = nil) async -> Bool
    {
        guard expectedTarget == nil || expectedTarget == target, draft.projectID == target.projectID,
            let rpc = writer
        else { return false }
        let binding = connectionGeneration
        var request = Dieter_V1_SaveScheduleRequest(); request.scheduleID = id ?? ""; request.schedule = draft
        do {
            let saved = try await (id == nil ? rpc.createSchedule(request) : rpc.updateSchedule(request))
            guard binding == connectionGeneration else { return false }
            upsertLoadedSchedule(saved)
            selectedScheduleID = saved.id
            await loadScheduleRuns(for: saved.id)
            return true
        } catch {
            if binding == connectionGeneration { report(error) }
            return false
        }
    }

    func toggleSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard schedule.projectID == target.projectID, let rpc = writer else { return }
        let binding = connectionGeneration
        do {
            let saved = try await rpc.setScheduleEnabled(id: schedule.id, enabled: !schedule.enabled)
            guard binding == connectionGeneration else { return }
            upsertLoadedSchedule(saved)
        } catch { if binding == connectionGeneration { report(error) } }
    }

    func runSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard schedule.projectID == target.projectID, let rpc = writer else { return }
        let binding = connectionGeneration
        do {
            _ = try await rpc.runSchedule(id: schedule.id)
            guard binding == connectionGeneration else { return }
            selectedScheduleID = schedule.id
            await loadScheduleRuns(for: schedule.id)
        } catch { if binding == connectionGeneration { report(error) } }
    }

    func deleteSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard schedule.projectID == target.projectID, let rpc = writer else { return }
        let binding = connectionGeneration
        do {
            try await rpc.deleteSchedule(id: schedule.id)
            guard binding == connectionGeneration else { return }
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
                guard binding == connectionGeneration else { return }
                selectedScheduleID = schedules.first?.id
            }
            if let selectedScheduleID, scheduleRuns.isEmpty {
                await loadScheduleRuns(for: selectedScheduleID)
            }
        } catch { if binding == connectionGeneration { report(error) } }
    }

    func previewSchedule(cron: String, timezone: String, count: Int32 = 5) async throws -> [String]? {
        guard let rpc = writer, !cron.isEmpty, !timezone.isEmpty else { return nil }
        var request = Dieter_V1_PreviewScheduleRequest()
        request.cron = cron
        request.timezone = timezone
        request.count = count
        return try await rpc.previewSchedule(request).times
    }

}

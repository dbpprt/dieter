import DieterAPI
import Foundation
import GRPCCore
import SharedCore

/// The shared core's schedules (`Schedules.kt`) over RPC fakes, so tests
/// drive SchedulesModel through the slice contract: a bound project's pages,
/// the selection's run history, mutations through the writer, and results
/// for a project that is no longer shown dropped.
@MainActor final class SchedulesCoreDouble {
    private weak var core: ScriptedCoreClient?
    private let reader: any DieterScheduleRPC
    private let writer: (any ScheduleCommandsRPC)?
    private var view = ClientSchedulesSlice()
    /// The scope of the view the last command came from.
    private var scope = ""
    private var binding: UInt64 = 0
    private var listRequest: UInt64 = 0

    /// A scripted core whose schedules read through `reader` and change
    /// through `writer`; it owns the double.
    static func core(reader: any DieterScheduleRPC, writer: (any ScheduleCommandsRPC)? = nil) -> ScriptedCoreClient {
        let core = ScriptedCoreClient()
        let double = SchedulesCoreDouble(reader: reader, writer: writer, core: core)
        core.asyncHandler = { command in try await double.handle(command) }
        return core
    }

    private init(reader: any DieterScheduleRPC, writer: (any ScheduleCommandsRPC)?, core: ScriptedCoreClient) {
        self.reader = reader
        self.writer = writer
        self.core = core
    }

    private func handle(_ command: ClientCommand) async throws -> ClientResult {
        guard case .schedules(let schedules)? = command.command else { return .with { $0.done = ClientDone() } }
        scope = schedules.scope
        switch schedules.action {
        case .bind(let project)?:
            if project.projectID != view.projectID {
                binding += 1
                view = .with { $0.projectID = project.projectID }
            }
        case .load?:
            try await page(more: false)
        case .loadMore?:
            try await page(more: true)
        case .select(let schedule)?:
            try await select(schedule.scheduleID)
        case .loadMoreRuns?:
            try await runs(more: true)
        case .save(let save)?:
            let writer = try requireWriter()
            let bound = binding, project = view.projectID
            var request = Dieter_V1_SaveScheduleRequest()
            request.scheduleID = save.scheduleID
            request.schedule = save.draft
            request.schedule.projectID = project
            let saved =
                try await save.scheduleID.isEmpty ? writer.createSchedule(request) : writer.updateSchedule(request)
            if bound == binding, saved.projectID == project {
                upsert(saved)
                try await select(saved.id)
            }
            return .with { $0.schedule = saved }
        case .setEnabled(let enabled)?:
            let saved = try await requireWriter().setScheduleEnabled(id: enabled.scheduleID, enabled: enabled.enabled)
            upsert(saved)
            publish()
            return .with { $0.schedule = saved }
        case .runNow(let schedule)?:
            _ = try await requireWriter().runSchedule(id: schedule.scheduleID)
            try await select(schedule.scheduleID)
        case .delete(let schedule)?:
            try await requireWriter().deleteSchedule(id: schedule.scheduleID)
            let present = view.schedules.contains { $0.id == schedule.scheduleID }
            view.schedules.removeAll { $0.id == schedule.scheduleID }
            if present { view.totalCount = max(0, view.totalCount - 1) }
            if view.selectedID == schedule.scheduleID {
                if let next = view.schedules.first {
                    try await select(next.id)
                } else {
                    view.selectedID = ""
                    view.runs = []
                    view.runsNextPageToken = ""
                }
            }
        case .preview(let preview)?:
            guard let writer else { break }
            var request = Dieter_V1_PreviewScheduleRequest()
            request.cron = preview.cron
            request.timezone = preview.timezone
            request.count = 5
            view.preview = try await writer.previewSchedule(request).times
        case .closeEditor?:
            view.preview = []
            view.previewError = ""
        default:
            break
        }
        publish()
        return .with { $0.schedules = view }
    }

    private func requireWriter() throws -> any ScheduleCommandsRPC {
        guard let writer else { throw CoreFailure(kind: .permanent, message: "Schedules cannot change here.") }
        return writer
    }

    /// Like the core, a newer load supersedes an older one, and a list
    /// failure shows on the list.
    private func page(more: Bool) async throws {
        let project = view.projectID
        guard !project.isEmpty else { return }
        listRequest += 1
        let bound = binding, request = listRequest
        if more { view.loadingMore = true } else { view.loading = true }
        publish()
        let response: Dieter_V1_SchedulesResponse
        do {
            response = try await reader.schedules(
                projectID: project, pageSize: 50, pageToken: more ? view.nextPageToken : "")
        } catch {
            guard bound == binding, request == listRequest else { return }
            view.loading = false
            view.loadingMore = false
            view.error = (error as? CoreFailure)?.message ?? (error as? RPCError)?.message ?? error.localizedDescription
            return
        }
        guard bound == binding, request == listRequest else { return }
        view.loading = false
        view.loadingMore = false
        view.error = ""
        let existing = Set(view.schedules.map(\.id))
        view.schedules =
            more ? view.schedules + response.schedules.filter { !existing.contains($0.id) } : response.schedules
        view.totalCount = response.totalCount
        view.nextPageToken = response.nextPageToken
        view.loaded = true
        if !view.schedules.contains(where: { $0.id == view.selectedID }), let first = view.schedules.first {
            try await select(first.id)
        }
    }

    private func select(_ id: String) async throws {
        view.selectedID = id
        view.runs = []
        view.runsNextPageToken = ""
        try await runs(more: false)
    }

    private func runs(more: Bool) async throws {
        let bound = binding, id = view.selectedID
        guard !id.isEmpty else { return }
        let response = try await reader.scheduleRuns(
            id: id, pageSize: 50, pageToken: more ? view.runsNextPageToken : "")
        guard bound == binding, view.selectedID == id else { return }
        let existing = Set(view.runs.map(\.id))
        view.runs = more ? view.runs + response.runs.filter { !existing.contains($0.id) } : response.runs
        view.runsNextPageToken = response.nextPageToken
    }

    private func upsert(_ schedule: Dieter_V1_Schedule) {
        if let index = view.schedules.firstIndex(where: { $0.id == schedule.id }) {
            view.schedules[index] = schedule
        } else {
            view.schedules.append(schedule)
            view.totalCount += 1
        }
        view.schedules.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    /// Publishes the view with the list state the core derives: failed only
    /// with nothing to show, loading until the first page arrived.
    private func publish() {
        if !view.error.isEmpty, view.schedules.isEmpty, !view.loading {
            view.state = .failed
        } else if !view.loaded || (view.loading && view.schedules.isEmpty) {
            view.state = .loading
        } else {
            view.state = view.schedules.isEmpty ? .empty : .loaded
        }
        let current = view
        core?.emit(.schedules, scope: scope) { $0.schedules = current }
    }
}

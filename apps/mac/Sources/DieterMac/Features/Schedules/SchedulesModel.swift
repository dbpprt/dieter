import DieterAPI
import DieterCore
import Foundation
import Observation
import SharedCore

struct ScheduleEditorContext {
    let target: WorkspaceTarget
    let projectName: String
    let boards: [Dieter_V1_Board]
    let selectedBoardID: String
    let harnessCatalog: Dieter_V1_HarnessCatalog
}

/// The shown project's schedules, kept by the shared core: lists come from
/// any replica, and definitions, run history, and every change go to the
/// machine that owns the schedule.
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
    var schedulesError: String?
    var errorMessage: String?
    /// Next occurrences (RFC 3339) of the editor's timing, and why there are none.
    private(set) var schedulePreview: [String] = []
    private(set) var schedulePreviewError: String?
    /// The agents of a machine, by daemon, once the core has read them.
    @ObservationIgnored var catalog: (String) async -> Dieter_V1_HarnessCatalog? = { _ in nil }
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The project the core was last told to show; slices for another are stale.
    @ObservationIgnored private var bound = ""
    @ObservationIgnored private var queued: Task<Void, Never>?

    var schedulesAreLoaded: Bool { !target.projectID.isEmpty && schedulesLoadedProjectID == target.projectID }
    var selectedSchedule: Dieter_V1_Schedule? {
        guard schedulesAreLoaded else { return nil }
        return schedules.first { $0.id == selectedScheduleID }
    }

    /// Shows `target`'s project; the core reaches each schedule's machine.
    func bind(target: WorkspaceTarget, core: CoreClient?) {
        if subscription == nil, let core {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .schedules, scope: "") { [weak self] update in
                guard let self, case .schedules(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        let sameProject = self.target.projectID == target.projectID
        self.target = target
        guard !sameProject || bound != target.projectID else { return }
        bound = target.projectID
        schedules = []; scheduleRuns = []; selectedScheduleID = nil
        schedulesTotalCount = 0; schedulesNextPageToken = ""; scheduleRunsNextPageToken = ""
        schedulesLoadedProjectID = ""; schedulesError = nil; errorMessage = nil
        let project = bound
        send { $0.bind = .with { $0.projectID = project } }
    }

    private func fold(_ slice: ClientSchedulesSlice) {
        guard slice.projectID == bound else { return }
        if schedules != slice.schedules { schedules = slice.schedules }
        if scheduleRuns != slice.runs { scheduleRuns = slice.runs }
        let selected = slice.selectedID.isEmpty ? nil : slice.selectedID
        if selectedScheduleID != selected { selectedScheduleID = selected }
        if schedulesLoading != slice.loading { schedulesLoading = slice.loading }
        if schedulesLoadingMore != slice.loadingMore { schedulesLoadingMore = slice.loadingMore }
        if scheduleRunsLoading != slice.runsLoading { scheduleRunsLoading = slice.runsLoading }
        if scheduleRunsLoadingMore != slice.runsLoadingMore { scheduleRunsLoadingMore = slice.runsLoadingMore }
        if schedulesTotalCount != Int(slice.totalCount) { schedulesTotalCount = Int(slice.totalCount) }
        if schedulesNextPageToken != slice.nextPageToken { schedulesNextPageToken = slice.nextPageToken }
        if scheduleRunsNextPageToken != slice.runsNextPageToken { scheduleRunsNextPageToken = slice.runsNextPageToken }
        let loaded = slice.loaded ? slice.projectID : ""
        if schedulesLoadedProjectID != loaded { schedulesLoadedProjectID = loaded }
        let error = slice.error.isEmpty ? nil : slice.error
        if schedulesError != error { schedulesError = error }
        let actionError = slice.actionError.isEmpty ? nil : slice.actionError
        if errorMessage != actionError { errorMessage = actionError }
        if schedulePreview != slice.preview { schedulePreview = slice.preview }
        let previewError = slice.previewError.isEmpty ? nil : slice.previewError
        if schedulePreviewError != previewError { schedulePreviewError = previewError }
    }

    /// Sends a command without waiting for it, after those sent before.
    private func send(_ build: @escaping (inout ClientSchedulesCommand) -> Void) {
        guard core != nil else { return }
        let previous = queued
        queued = Task { [weak self] in
            await previous?.value
            await self?.run(afterQueued: false, build)
        }
    }

    /// Runs a command and folds the schedules it returns; a failure shows as
    /// the error message.
    @discardableResult
    private func run(
        afterQueued: Bool = true, _ build: (inout ClientSchedulesCommand) -> Void
    ) async -> ClientResult? {
        guard let core else { return nil }
        if afterQueued, let queued { await queued.value }
        var command = ClientSchedulesCommand()
        build(&command)
        let sent = command, project = bound
        do {
            let result = try await core.dispatch(.with { $0.schedules = sent })
            if case .schedules(let slice)? = result.result { fold(slice) }
            return result
        } catch let failure as CoreFailure {
            if project == bound { errorMessage = failure.message }
            return nil
        } catch {
            return nil
        }
    }

    func loadSchedules() async {
        guard !target.projectID.isEmpty else { return }
        await run { $0.load = ClientScheduleStep() }
    }

    func loadMoreSchedules() async {
        guard schedulesAreLoaded, !schedulesLoading, !schedulesLoadingMore, !schedulesNextPageToken.isEmpty else {
            return
        }
        await run { $0.loadMore = ClientScheduleStep() }
    }

    /// The owner's full definition for the editor; replicas only list a summary.
    func editorSchedule(_ schedule: Dieter_V1_Schedule) async -> Dieter_V1_Schedule? {
        let result = await run { command in command.details = .with { $0.scheduleID = schedule.id } }
        guard case .schedule(let full)? = result?.result else { return nil }
        return full
    }

    func selectSchedule(_ id: String) async {
        guard schedulesAreLoaded, schedules.contains(where: { $0.id == id }) else { return }
        selectedScheduleID = id
        await run { command in command.select = .with { $0.scheduleID = id } }
    }

    func loadScheduleRuns(for scheduleID: String, appending: Bool = false) async {
        if appending, scheduleID == selectedScheduleID {
            await loadMoreScheduleRuns()
        } else {
            await run { command in command.select = .with { $0.scheduleID = scheduleID } }
        }
    }

    func loadMoreScheduleRuns() async {
        guard selectedScheduleID != nil, !scheduleRunsLoading, !scheduleRunsLoadingMore,
            !scheduleRunsNextPageToken.isEmpty
        else { return }
        await run { $0.loadMoreRuns = ClientScheduleStep() }
    }

    /// The editor for `schedule` (or a new one) on its checkout's machine,
    /// with that machine's agents.
    func editorContext(schedule: Dieter_V1_Schedule?, base: ScheduleEditorContext) async -> ScheduleEditorContext? {
        let checkoutID = schedule?.checkoutID ?? base.target.checkoutID
        let owner = schedule?.ownerDaemonID ?? ""
        return ScheduleEditorContext(
            target: WorkspaceTarget(
                endpointID: base.target.endpointID, projectID: base.target.projectID, checkoutID: checkoutID),
            projectName: base.projectName, boards: base.boards,
            selectedBoardID: schedule?.boardID ?? base.selectedBoardID,
            harnessCatalog: (owner.isEmpty ? nil : await catalog(owner)) ?? base.harnessCatalog)
    }

    /// Creates on the chosen checkout's machine, or updates on the owner.
    /// False when it failed or the project changed meanwhile.
    @discardableResult
    func saveSchedule(id: String?, draft: Dieter_V1_ScheduleDraft, expectedTarget: WorkspaceTarget? = nil) async -> Bool
    {
        guard expectedTarget == nil || expectedTarget?.projectID == target.projectID,
            draft.projectID == target.projectID
        else { return false }
        let project = bound
        let result = await run { command in
            command.save = .with {
                $0.draft = draft
                $0.scheduleID = id ?? ""
                $0.checkoutID = draft.checkoutID
            }
        }
        guard case .schedule(let saved)? = result?.result, project == bound, saved.projectID == project else {
            return false
        }
        selectedScheduleID = saved.id
        return true
    }

    func toggleSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard schedule.projectID == target.projectID else { return }
        await run { command in
            command.setEnabled = .with {
                $0.scheduleID = schedule.id
                $0.enabled = !schedule.enabled
            }
        }
    }

    func runSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard schedule.projectID == target.projectID else { return }
        await run { command in command.runNow = .with { $0.scheduleID = schedule.id } }
    }

    func deleteSchedule(_ schedule: Dieter_V1_Schedule) async {
        guard schedule.projectID == target.projectID else { return }
        await run { command in command.delete = .with { $0.scheduleID = schedule.id } }
    }

    /// Previews the editor's timing; the core debounces and publishes the
    /// occurrences in `schedulePreview`.
    func previewSchedule(cron: String, timezone: String) {
        send { command in
            command.preview = .with {
                $0.cron = cron
                $0.timezone = timezone
            }
        }
    }

    /// Drops the editor's preview.
    func closeEditor() {
        send { $0.closeEditor = ClientScheduleStep() }
    }
}

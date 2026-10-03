import DieterAPI
import Foundation
import Observation
import SharedCore

struct ScheduleEditorContext {
    let target: WorkspaceTarget
    let projectName: String
    let boards: [Dieter_V1_Board]
    let selectedBoardID: String
    let harnessCatalog: Dieter_V1_HarnessCatalog
    /// The machine of each of the project's checkouts, by checkout ID.
    var checkoutMachines: [String: String] = [:]
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
    private(set) var schedulePreviewLoading = false
    /// What the list area shows, its header line, and each schedule's and
    /// run's wording, as the core presents them.
    private(set) var state = ClientSchedulesSlice.State.loading
    private(set) var subtitle = ""
    private(set) var rows: [String: ClientScheduleRow] = [:]
    private(set) var runRows: [ClientScheduleRunRow] = []
    /// The agents of a machine, by daemon, once the core has read them.
    @ObservationIgnored var catalog: (String) async -> Dieter_V1_HarnessCatalog? = { _ in nil }
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private let scope = "schedules-\(UUID().uuidString)"
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
            subscription = SliceSubscription(client: core, slice: .schedules, scope: scope) { [weak self] update in
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
        state = .loading; subtitle = ""; rows = [:]; runRows = []
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
        if schedulePreviewLoading != slice.previewLoading { schedulePreviewLoading = slice.previewLoading }
        if state != slice.state { state = slice.state }
        if subtitle != slice.subtitle { subtitle = slice.subtitle }
        let rows = Dictionary(slice.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.rows != rows { self.rows = rows }
        if runRows != slice.runRows { runRows = slice.runRows }
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
        command.scope = scope
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
        await run { $0.load = ClientStep() }
    }

    func loadMoreSchedules() async {
        guard schedulesAreLoaded, !schedulesLoading, !schedulesLoadingMore, !schedulesNextPageToken.isEmpty else {
            return
        }
        await run { $0.loadMore = ClientStep() }
    }

    func selectSchedule(_ id: String) async {
        guard schedulesAreLoaded, schedules.contains(where: { $0.id == id }) else { return }
        selectedScheduleID = id
        await run { command in command.select = .with { $0.scheduleID = id } }
    }

    func loadMoreScheduleRuns() async {
        guard selectedScheduleID != nil, !scheduleRunsLoading, !scheduleRunsLoadingMore,
            !scheduleRunsNextPageToken.isEmpty
        else { return }
        await run { $0.loadMoreRuns = ClientStep() }
    }

    /// The draft the editor opens on, as the core prepares it: an existing
    /// schedule's full definition from its owner, or a new schedule's
    /// defaults in this device's time zone.
    func editorDraft(scheduleID: String?, context: ScheduleEditorContext) async -> Dieter_V1_ScheduleDraft? {
        let result = await run { command in
            command.draft = .with {
                $0.scheduleID = scheduleID ?? ""
                $0.checkoutID = context.target.checkoutID
                $0.selectedBoardID = context.selectedBoardID
                $0.timezone = TimeZone.current.identifier
            }
        }
        guard case .scheduleDraft(let draft)? = result?.result else { return nil }
        return draft
    }

    /// The editor's context with the agents of the machine that runs the
    /// draft: the owner of an existing schedule, else the draft's checkout's.
    func editorContext(owner: String, draft: Dieter_V1_ScheduleDraft, base: ScheduleEditorContext) async
        -> ScheduleEditorContext
    {
        let machine = owner.isEmpty ? base.checkoutMachines[draft.checkoutID] ?? "" : owner
        return ScheduleEditorContext(
            target: WorkspaceTarget(
                endpointID: base.target.endpointID, projectID: base.target.projectID, checkoutID: draft.checkoutID),
            projectName: base.projectName, boards: base.boards, selectedBoardID: draft.boardID,
            harnessCatalog: (machine.isEmpty ? nil : await catalog(machine)) ?? base.harnessCatalog,
            checkoutMachines: base.checkoutMachines)
    }

    /// Creates on the chosen checkout's machine, or updates on the owner.
    /// False when it failed or the project changed meanwhile.
    @discardableResult
    func saveSchedule(id: String?, draft: Dieter_V1_ScheduleDraft, expectedTarget: WorkspaceTarget? = nil) async -> Bool
    {
        guard expectedTarget == nil || expectedTarget?.projectID == target.projectID else { return false }
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
        send { $0.closeEditor = ClientStep() }
    }
}

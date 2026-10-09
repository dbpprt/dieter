package com.dbpprt.dieter.core.schedules

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.ListScheduleRunsRequest
import com.dbpprt.dieter.api.v1.ListSchedulesRequest
import com.dbpprt.dieter.api.v1.PreviewScheduleRequest
import com.dbpprt.dieter.api.v1.SaveScheduleRequest
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.api.v1.ScheduleRef
import com.dbpprt.dieter.api.v1.ScheduleRun
import com.dbpprt.dieter.api.v1.SetScheduleEnabledRequest
import com.dbpprt.dieter.client.v1.ScheduleRow
import com.dbpprt.dieter.client.v1.ScheduleRunRow
import com.dbpprt.dieter.core.composition.Creation
import com.dbpprt.dieter.core.metadata.MachineMetadataStore
import com.dbpprt.dieter.core.machines.MachineChoice
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.WorkspaceStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

data class SchedulesView(
    val projectId: String? = null,
    val schedules: List<Schedule> = emptyList(),
    val totalCount: Int = 0,
    val nextPageToken: String = "",
    val loaded: Boolean = false,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    /** The list could not be read. */
    val error: String? = null,
    /** A mutation or run history read failed. */
    val actionError: String? = null,
    val selectedId: String? = null,
    val runs: List<ScheduleRun> = emptyList(),
    val runsNextPageToken: String = "",
    val runsLoading: Boolean = false,
    val runsLoadingMore: Boolean = false,
    /** Next occurrences (RFC 3339, UTC) for the editor's cron and timezone. */
    val preview: List<String> = emptyList(),
    val previewError: String? = null,
    /** A preview of the editor's timing is pending. */
    val previewLoading: Boolean = false,
) {
    val presentation: SchedulesPresentation get() = SchedulePresentations.resolve(loaded, loading, schedules.isNotEmpty(), error)
    val selected: Schedule? get() = schedules.firstOrNull { it.id == selectedId }

    /** "3 automations", "Loading automations…", or "Automations unavailable". */
    val subtitle: String get() = SchedulePresentations.subtitle(loaded, totalCount, error)

    /** [schedules] as rows, in the same order; [harnesses] name each owner machine's agents. */
    fun rows(harnesses: (daemonId: String) -> List<Harness> = { emptyList() }): List<ScheduleRow> =
        schedules.map { SchedulePresentations.row(it, harnesses(it.owner_daemon_id)) }

    /** [runs] as rows, in the same order. */
    val runRows: List<ScheduleRunRow> get() = runs.map(SchedulePresentations::runRow)
}

/**
 * Schedules of one project. Lists come from any machine with the project; full definitions,
 * run history, and every mutation go to the machine that owns the schedule.
 * Results for a project that is no longer shown are dropped. [metadata]
 * supplies the agents a new draft starts with; without it, drafts start
 * without one. Confined to the core dispatcher.
 */
class Schedules(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
    private val scope: CoroutineScope,
    private val metadata: MachineMetadataStore? = null,
) {
    private val mutableView = MutableStateFlow(SchedulesView())
    val view: StateFlow<SchedulesView> = mutableView.asStateFlow()
    private var binding = 0L
    private var listRequest = 0L
    private var runsRequest = 0L
    private var previewJob: Job? = null
    private var previewKey = ""

    /** Shows nothing; results still in flight are dropped. */
    fun stop() {
        binding++
        previewJob?.cancel()
        previewKey = ""
        mutableView.value = SchedulesView()
    }

    /** Shows [projectId]'s schedules, or nothing. */
    fun bind(projectId: String?) {
        if (projectId == view.value.projectId) return
        binding++
        previewJob?.cancel()
        mutableView.value = SchedulesView(projectId = projectId)
    }

    private fun projectMachine(projectId: String): String = choice.project(projectId)
        ?: throw CoreException(FailureKind.TRANSIENT, "No machine with this project is reachable.")

    /** The machine that owns [schedule]: its recorded owner, else its checkout's machine. */
    private fun owner(schedule: Schedule): String = schedule.owner_daemon_id.ifEmpty { null }?.let(store.directoryProjection::machine)
        ?: store.directoryProjection.checkoutMachine(schedule.project_id, schedule.checkout_id)
        ?: throw CoreException(FailureKind.TRANSIENT, "This schedule’s machine is unavailable")

    suspend fun load() = page(more = false)

    suspend fun loadMore() {
        val current = view.value
        if (current.nextPageToken.isBlank() || current.loading || current.loadingMore) return
        page(more = true)
    }

    private suspend fun page(more: Boolean) {
        val projectId = view.value.projectId ?: return
        val bound = binding
        val request = ++listRequest
        mutableView.update { if (more) it.copy(loadingMore = true) else it.copy(loading = true) }
        try {
            val token = if (more) view.value.nextPageToken else ""
            val response = sessions.call(projectMachine(projectId), Deadlines.CALL) { it.ListSchedules().execute(ListSchedulesRequest(project_id = projectId, page_size = PAGE_SIZE, page_token = token)) }
            if (bound != binding || request != listRequest) return
            mutableView.update { state ->
                val schedules = if (more) state.schedules + response.schedules.filter { incoming -> state.schedules.none { it.id == incoming.id } } else response.schedules
                state.copy(
                    schedules = schedules, totalCount = response.total_count, nextPageToken = response.next_page_token,
                    loading = false, loadingMore = false, loaded = true, error = null,
                )
            }
            // Keep a live selection; otherwise select the first schedule and read its runs.
            val state = view.value
            if (state.selected == null) state.schedules.firstOrNull()?.let { select(it.id) }
        } catch (error: Throwable) {
            if (bound == binding && request == listRequest) {
                mutableView.update { it.copy(loading = false, loadingMore = false, error = if (error is CancellationException) it.error else Failures.message(error)) }
            }
            if (error is CancellationException) throw error
        }
    }

    suspend fun select(scheduleId: String) {
        mutableView.update { it.copy(selectedId = scheduleId, runs = emptyList(), runsNextPageToken = "") }
        runs(more = false)
    }

    suspend fun loadMoreRuns() {
        val current = view.value
        if (current.runsNextPageToken.isBlank() || current.runsLoading || current.runsLoadingMore) return
        runs(more = true)
    }

    private suspend fun runs(more: Boolean) {
        val schedule = view.value.selected ?: return
        val bound = binding
        val request = ++runsRequest
        mutableView.update { if (more) it.copy(runsLoadingMore = true) else it.copy(runsLoading = true) }
        try {
            val token = if (more) view.value.runsNextPageToken else ""
            val response = sessions.call(owner(schedule), Deadlines.CALL) { it.ListScheduleRuns().execute(ListScheduleRunsRequest(schedule_id = schedule.id, page_size = PAGE_SIZE, page_token = token)) }
            if (bound != binding || request != runsRequest || view.value.selectedId != schedule.id) return
            mutableView.update { state ->
                val runs = if (more) state.runs + response.runs.filter { incoming -> state.runs.none { it.id == incoming.id } } else response.runs
                state.copy(runs = runs, runsNextPageToken = response.next_page_token, runsLoading = false, runsLoadingMore = false)
            }
        } catch (error: Throwable) {
            if (bound == binding && request == runsRequest) {
                mutableView.update { it.copy(runsLoading = false, runsLoadingMore = false, actionError = if (error is CancellationException) it.actionError else Failures.message(error)) }
            }
            if (error is CancellationException) throw error
        }
    }

    /** The owner's full definition; other machines only know a summary. */
    suspend fun details(scheduleId: String): Schedule {
        val summary = view.value.schedules.firstOrNull { it.id == scheduleId } ?: throw CoreException(FailureKind.PERMANENT, "The schedule is no longer available.")
        val bound = binding
        val full = sessions.call(owner(summary), Deadlines.CALL) { it.GetSchedule().execute(ScheduleRef(schedule_id = scheduleId)) }
        if (bound == binding) upsert(full)
        return full
    }

    /**
     * The draft the editor starts with ([ScheduleDrafts.make]): [scheduleId]'s
     * full definition from its owner, or a new schedule in [timezone] (UTC
     * when blank) on [checkoutId] (else the project's only checkout), with
     * the project's boards and the agents of the machine that runs it. The
     * agents are those the machine reported within 5 s; otherwise the draft
     * starts without one.
     */
    suspend fun draft(scheduleId: String?, checkoutId: String?, selectedBoardId: String?, timezone: String): ScheduleDraft {
        val projectId = view.value.projectId ?: throw CoreException(FailureKind.PERMANENT, "This project is no longer connected. Close the editor and reconnect.")
        val existing = scheduleId?.let { details(it) }
        val checkout = if (existing != null) null else store.directoryProjection.projects[projectId]?.let { Creation.checkout(it, checkoutId) }
        val machine = if (existing != null) owner(existing) else checkout?.daemon_id?.ifEmpty { null }?.let(store.directoryProjection::machine) ?: choice.project(projectId)
        val agents = machine?.let { harnesses(it) }.orEmpty()
        val boards = store.state.value.boards[projectId].orEmpty()
        val draft = ScheduleDrafts.make(existing, projectId, timezone.trim().ifEmpty { "UTC" }, boards, selectedBoardId, agents)
        return if (existing != null) draft else draft.copy(checkout_id = checkout?.id ?: checkoutId.orEmpty())
    }

    /** [daemonId]'s agents once its metadata has loaded, waiting up to [CATALOG_WAIT]. */
    private suspend fun harnesses(daemonId: String): List<Harness> {
        val catalogs = metadata ?: return emptyList()
        catalogs.ensure(daemonId)
        val machines = withTimeoutOrNull(CATALOG_WAIT) { catalogs.machines.first { it[daemonId]?.loaded == true } }
        return machines?.get(daemonId)?.harnesses?.harnesses.orEmpty()
    }

    /**
     * Previews the next occurrences of [cron] in [timezone] after 300 ms;
     * only the latest request may publish.
     */
    fun preview(cron: String, timezone: String) {
        val key = "$cron|$timezone"
        if (key == previewKey && previewJob?.isActive == true) return
        previewKey = key
        previewJob?.cancel()
        val projectId = view.value.projectId ?: return
        if (cron.isBlank() || timezone.isBlank()) {
            mutableView.update { it.copy(preview = emptyList(), previewError = null, previewLoading = false) }
            return
        }
        val bound = binding
        mutableView.update { it.copy(previewLoading = true) }
        previewJob = scope.launch {
            delay(PREVIEW_DEBOUNCE)
            try {
                val times = sessions.call(projectMachine(projectId), Deadlines.CALL) { it.PreviewSchedule().execute(PreviewScheduleRequest(cron = cron.trim(), timezone = timezone.trim(), count = PREVIEW_COUNT)) }.times
                if (bound == binding && previewKey == key) mutableView.update { it.copy(preview = times, previewError = null, previewLoading = false) }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                if (bound == binding && previewKey == key) mutableView.update { it.copy(preview = emptyList(), previewError = Failures.message(error), previewLoading = false) }
            }
        }
    }

    /** Closing the editor drops its preview; a late result cannot bring it back. */
    fun closeEditor() {
        previewJob?.cancel()
        previewKey = ""
        mutableView.update { it.copy(preview = emptyList(), previewError = null, previewLoading = false) }
    }

    /**
     * Creates a schedule on the chosen checkout's machine, or updates one on
     * its owner. The checkout of an existing schedule cannot change.
     */
    suspend fun save(draft: ScheduleDraft, scheduleId: String? = null, checkoutId: String? = null): Schedule {
        val projectId = view.value.projectId ?: throw CoreException(FailureKind.PERMANENT, "This project is no longer connected. Close the editor and reconnect.")
        if (draft.project_id.isNotEmpty() && draft.project_id != projectId) throw CoreException(FailureKind.PERMANENT, "A schedule cannot be moved to another project.")
        if (!ScheduleDrafts.canSave(draft)) throw CoreException(FailureKind.PERMANENT, "Name, timing, board, and templates are required.")
        val bound = binding
        val saved = if (scheduleId.isNullOrEmpty()) {
            val project = store.directoryProjection.projects[projectId] ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
            val checkout = Creation.checkout(project, checkoutId ?: draft.checkout_id.ifEmpty { null })
                ?: throw CoreException(FailureKind.PERMANENT, "Choose a machine and checkout for this project")
            val request = SaveScheduleRequest(schedule = ScheduleDrafts.normalized(draft, projectId, checkout.id))
            sessions.call(checkout.daemon_id.ifEmpty { throw CoreException(FailureKind.TRANSIENT, "The checkout’s machine is unavailable") }, Deadlines.CALL) { it.CreateSchedule().execute(request) }
        } else {
            val existing = view.value.schedules.firstOrNull { it.id == scheduleId } ?: throw CoreException(FailureKind.PERMANENT, "The schedule is no longer available.")
            val request = SaveScheduleRequest(schedule_id = scheduleId, schedule = ScheduleDrafts.normalized(draft, projectId, existing.checkout_id))
            sessions.call(owner(existing), Deadlines.CALL) { it.UpdateSchedule().execute(request) }
        }
        if (bound != binding || saved.project_id != projectId) return saved
        listRequest++
        upsert(saved)
        select(saved.id)
        return saved
    }

    suspend fun setEnabled(scheduleId: String, enabled: Boolean): Schedule = mutate(scheduleId) { schedule ->
        sessions.call(owner(schedule), Deadlines.CALL) { it.SetScheduleEnabled().execute(SetScheduleEnabledRequest(schedule_id = scheduleId, enabled = enabled)) }.also {
            listRequest++
            upsert(it)
        }
    }

    suspend fun runNow(scheduleId: String): ScheduleRun = mutate(scheduleId) { schedule ->
        sessions.call(owner(schedule), Deadlines.CALL) { it.RunSchedule().execute(ScheduleRef(schedule_id = scheduleId)) }.also { select(scheduleId) }
    }

    suspend fun delete(scheduleId: String) = mutate(scheduleId) { schedule ->
        sessions.call(owner(schedule), Deadlines.CALL) { it.DeleteSchedule().execute(ScheduleRef(schedule_id = scheduleId)) }
        mutableView.update { state ->
            val present = state.schedules.any { it.id == scheduleId }
            state.copy(schedules = state.schedules.filterNot { it.id == scheduleId }, totalCount = if (present) maxOf(0, state.totalCount - 1) else state.totalCount)
        }
        val state = view.value
        if (state.selectedId == scheduleId) {
            val next = state.schedules.firstOrNull()
            if (next != null) select(next.id) else mutableView.update { it.copy(selectedId = null, runs = emptyList(), runsNextPageToken = "") }
        }
        if (state.schedules.isEmpty() && state.nextPageToken.isNotBlank()) loadMore()
    }

    /** Runs a change of [scheduleId]; its failure, including a schedule that is gone, is the view's [SchedulesView.actionError]. */
    private suspend fun <T> mutate(scheduleId: String, block: suspend (Schedule) -> T): T {
        try {
            val schedule = view.value.schedules.firstOrNull { it.id == scheduleId } ?: throw CoreException(FailureKind.PERMANENT, "The schedule is no longer available.")
            return block(schedule)
        } catch (error: Throwable) {
            if (error !is CancellationException) mutableView.update { it.copy(actionError = Failures.message(error)) }
            throw error
        }
    }

    private fun upsert(schedule: Schedule) = mutableView.update { state ->
        val present = state.schedules.any { it.id == schedule.id }
        val list = if (present) state.schedules.map { if (it.id == schedule.id) schedule else it } else state.schedules + schedule
        state.copy(
            schedules = list.sortedWith(compareBy<Schedule>({ it.name.lowercase() }, { it.id })),
            totalCount = if (present) state.totalCount else state.totalCount + 1,
        )
    }

    fun clearActionError() = mutableView.update { it.copy(actionError = null) }

    companion object {
        const val PAGE_SIZE = 50
        const val PREVIEW_COUNT = 5
        val PREVIEW_DEBOUNCE = 300.milliseconds
        val CATALOG_WAIT = 5.seconds
    }
}

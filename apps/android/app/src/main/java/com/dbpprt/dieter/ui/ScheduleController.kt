package com.dbpprt.dieter.ui

import com.dbpprt.dieter.data.ScheduleClient
import com.dbpprt.dieter.v1.*
import kotlinx.coroutines.CoroutineScope

data class ScheduleWorkspaceState(
    val schedules: List<Schedule> = emptyList(),
    val schedulesTotalCount: Int = 0,
    val schedulesNextPageToken: String = "",
    val schedulesLoading: Boolean = false,
    val schedulesLoadingMore: Boolean = false,
    val selectedScheduleId: String? = null,
    val scheduleRuns: List<ScheduleRun> = emptyList(),
    val scheduleRunsNextPageToken: String = "",
    val scheduleRunsLoading: Boolean = false,
    val scheduleRunsLoadingMore: Boolean = false,
    val schedulePreview: List<String> = emptyList(),
)

/** Owns schedule reads, pagination, editing and mutation completions for one project binding. */
internal class ScheduleController(
    scope: CoroutineScope,
    binding: () -> Any?,
    private val replica: suspend (String) -> ScheduleClient,
    private val owner: suspend (String) -> ScheduleClient,
    private val checkout: suspend (ScheduleDraft) -> Pair<ScheduleClient, String>,
    private val publish: (ScheduleWorkspaceState) -> Unit,
    reportError: (Throwable) -> Unit,
) {
    var state = ScheduleWorkspaceState()
        private set
    private val requests = FeatureRequests(scope, binding) { key, error ->
        update { when (key) {
            "list" -> it.copy(schedulesLoading = false, schedulesLoadingMore = false)
            "runs" -> it.copy(scheduleRunsLoading = false, scheduleRunsLoadingMore = false)
            "preview" -> it.copy(schedulePreview = emptyList())
            else -> it
        } }
        reportError(error)
    }
    private fun update(change: (ScheduleWorkspaceState) -> ScheduleWorkspaceState) { state = change(state); publish(state) }
    fun reset() { requests.cancelAll(); update { ScheduleWorkspaceState() } }
    fun cancel() {
        requests.cancelAll()
        update { it.copy(schedulesLoading = false, schedulesLoadingMore = false, scheduleRunsLoading = false, scheduleRunsLoadingMore = false) }
    }
    fun clearPreview() { requests.cancel("preview"); requests.cancel("details"); update { it.copy(schedulePreview = emptyList()) } }

    fun load(project: String, more: Boolean = false) = if (project.isBlank() || (more &&
        (state.schedulesNextPageToken.isBlank() || state.schedulesLoading || state.schedulesLoadingMore))) null else {
        val token = if (more) state.schedulesNextPageToken else ""
        update { it.copy(schedulesLoading = !more, schedulesLoadingMore = more, schedulesNextPageToken = token) }
        requests.launch("list") {
            val client = replica(project)
            check()
            val page = client.list(project, token)
            check()
            val previousSelection = state.selectedScheduleId
            update { it.applyingSchedulePage(page, more) }
            if (previousSelection != state.selectedScheduleId) requests.cancel("runs")
        }
    }

    fun preview(project: String, cron: String, timezone: String) = requests.launch("preview") {
        val client = replica(project)
        check()
        val result = client.preview(cron, timezone)
        check()
        update { it.copy(schedulePreview = result.timesList) }
    }

    fun details(schedule: Schedule, onDetail: (Schedule) -> Unit) = requests.launch("details") {
        val client = owner(schedule.ownerDaemonId)
        check()
        val detail = client.details(schedule.id)
        check()
        upsert(detail)
        onDetail(detail)
    }

    fun select(schedule: Schedule?) {
        requests.cancel("runs")
        update { it.copy(selectedScheduleId = schedule?.id, scheduleRuns = emptyList(), scheduleRunsNextPageToken = "",
            scheduleRunsLoading = schedule != null, scheduleRunsLoadingMore = false) }
        if (schedule != null) loadRuns(schedule, false)
    }
    fun moreRuns() {
        val schedule = state.schedules.firstOrNull { it.id == state.selectedScheduleId } ?: return
        if (state.scheduleRunsNextPageToken.isBlank() || state.scheduleRunsLoading || state.scheduleRunsLoadingMore) return
        loadRuns(schedule, true)
    }
    private fun loadRuns(schedule: Schedule, more: Boolean) {
        val token = if (more) state.scheduleRunsNextPageToken else ""
        update { it.copy(scheduleRunsLoading = !more, scheduleRunsLoadingMore = more) }
        requests.launch("runs") {
            val client = owner(schedule.ownerDaemonId)
            check()
            val page = client.runs(schedule.id, token)
            check()
            update { it.applyingScheduleRunPage(page, more) }
        }
    }

    fun save(id: String, draft: ScheduleDraft, onSaved: () -> Unit) = requests.launch("mutation:$id") {
        val existing = state.schedules.firstOrNull { it.id == id }
        val (client, checkoutId) = if (existing == null) checkout(draft) else owner(existing.ownerDaemonId) to existing.checkoutId
        check()
        val saved = client.save(id, SaveScheduleRequest.newBuilder().setScheduleId(id)
            .setSchedule(draft.toBuilder().setCheckoutId(checkoutId)).build())
        check()
        requests.cancel("list")
        requests.cancel("runs")
        upsert(saved, true)
        onSaved()
    }
    fun toggle(schedule: Schedule) = requests.launch("mutation:${schedule.id}") {
        val client = owner(schedule.ownerDaemonId)
        check()
        val updated = client.enabled(schedule.id, !schedule.enabled)
        check()
        requests.cancel("list")
        upsert(updated)
    }
    fun run(schedule: Schedule) = requests.launch("mutation:${schedule.id}") {
        val client = owner(schedule.ownerDaemonId)
        check()
        client.run(schedule.id)
        check()
        select(schedule)
    }
    fun delete(schedule: Schedule, project: String) = requests.launch("mutation:${schedule.id}") {
        val client = owner(schedule.ownerDaemonId)
        check()
        client.delete(schedule.id)
        check()
        requests.cancel("list")
        if (state.selectedScheduleId == schedule.id) select(null)
        update { it.copy(schedules = it.schedules.filterNot { item -> item.id == schedule.id },
            schedulesTotalCount = maxOf(0, it.schedulesTotalCount - if (it.schedules.any { item -> item.id == schedule.id }) 1 else 0),
            schedulesLoading = false, schedulesLoadingMore = false) }
        if (state.schedules.isEmpty() && state.schedulesNextPageToken.isNotBlank()) load(project, true)
    }

    private fun upsert(schedule: Schedule, select: Boolean = false) = update {
        val existed = it.schedules.any { item -> item.id == schedule.id }
        val selectionChanged = select && it.selectedScheduleId != schedule.id
        it.copy(schedules = (it.schedules.filterNot { item -> item.id == schedule.id } + schedule)
            .sortedWith(compareBy<Schedule> { item -> item.name.lowercase() }.thenBy { item -> item.id }),
            schedulesTotalCount = it.schedulesTotalCount + if (existed) 0 else 1,
            schedulesLoading = false, schedulesLoadingMore = false,
            selectedScheduleId = if (select) schedule.id else it.selectedScheduleId,
            scheduleRuns = if (selectionChanged) emptyList() else it.scheduleRuns,
            scheduleRunsNextPageToken = if (selectionChanged) "" else it.scheduleRunsNextPageToken,
            scheduleRunsLoading = false, scheduleRunsLoadingMore = false)
    }
}

internal fun ScheduleWorkspaceState.applyingSchedulePage(response: SchedulesResponse, appending: Boolean): ScheduleWorkspaceState {
    val nextSchedules = if (appending) {
        val existing = schedules.mapTo(hashSetOf()) { it.id }
        schedules + response.schedulesList.filter { it.id !in existing }
    } else {
        response.schedulesList
    }
    val nextSelection = if (appending) selectedScheduleId
    else selectedScheduleId?.takeIf { id -> nextSchedules.any { it.id == id } }
    return copy(
        schedules = nextSchedules,
        schedulesTotalCount = response.totalCount,
        schedulesNextPageToken = response.nextPageToken,
        schedulesLoading = false,
        schedulesLoadingMore = false,
        selectedScheduleId = nextSelection,
        scheduleRuns = if (nextSelection == null) emptyList() else scheduleRuns,
        scheduleRunsNextPageToken = if (nextSelection == null) "" else scheduleRunsNextPageToken,
    )
}

internal fun ScheduleWorkspaceState.applyingScheduleRunPage(response: ScheduleRunsResponse, appending: Boolean): ScheduleWorkspaceState {
    val nextRuns = if (appending) {
        val existing = scheduleRuns.mapTo(hashSetOf()) { it.id }
        scheduleRuns + response.runsList.filter { it.id !in existing }
    } else {
        response.runsList
    }
    return copy(
        scheduleRuns = nextRuns,
        scheduleRunsNextPageToken = response.nextPageToken,
        scheduleRunsLoading = false,
        scheduleRunsLoadingMore = false,
    )
}

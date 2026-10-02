package com.dbpprt.dieter.core.schedules

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleRun
import com.dbpprt.dieter.client.v1.ScheduleRow
import com.dbpprt.dieter.client.v1.ScheduleRunRow
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.selection.AgentControls

enum class SchedulesPresentation { LOADING, FAILED, EMPTY, LOADED }

/** Schedules and their runs as every view shows them. */
object SchedulePresentations {
    const val EMPTY_TITLE = "No schedules"
    const val EMPTY_DETAIL = "Automate cards and chats with cron schedules."
    const val NO_NEXT_RUN = "No next run"
    const val LOAD_MORE = "Load more schedules"
    const val LOADING_MORE = "Loading…"
    const val RUNS_LOADING = "Loading occurrences…"
    const val RUNS_EMPTY = "No occurrences yet."
    const val LOAD_OLDER_RUNS = "Load older runs"
    const val LOADING_OLDER_RUNS = "Loading older runs…"

    /**
     * Failed only while nothing is shown; loading until the first list
     * arrives and while a reload has nothing to show yet.
     */
    fun resolve(loaded: Boolean, loading: Boolean, hasSchedules: Boolean, error: String?): SchedulesPresentation = when {
        error != null && !hasSchedules && !loading -> SchedulesPresentation.FAILED
        !loaded || (loading && !hasSchedules) -> SchedulesPresentation.LOADING
        hasSchedules -> SchedulesPresentation.LOADED
        else -> SchedulesPresentation.EMPTY
    }

    /** "1 automation", "3 automations"; before the first list, "Loading automations…" or, after a failure, "Automations unavailable". */
    fun subtitle(loaded: Boolean, totalCount: Int, error: String?): String = when {
        loaded -> Counts.of(totalCount, "automation")
        error == null -> "Loading automations…"
        else -> "Automations unavailable"
    }

    /** [schedule] as lists show it; [harnesses] (its owner machine's catalog) name its agent, else its IDs do. */
    fun row(schedule: Schedule, harnesses: List<Harness> = emptyList()): ScheduleRow {
        val agent = AgentControls(HarnessSelection(schedule.provider, schedule.model, schedule.effort, schedule.provider_options), harnesses)
        return ScheduleRow(
            id = schedule.id,
            timing = Cadence.timing(schedule.cron, schedule.timezone),
            placement = ScheduleDrafts.placementTitle(schedule.action),
            status = if (schedule.enabled) "Enabled" else "Paused",
            subtitle = schedule.description.trim().ifEmpty { ScheduleDrafts.placementDetail(schedule.action) },
            next_run_fallback = if (schedule.next_run_at.isBlank()) NO_NEXT_RUN else "",
            provider_label = agent.providerLabel, model_label = agent.modelLabel, effort_label = agent.effortLabel,
        )
    }

    fun runRow(run: ScheduleRun): ScheduleRunRow = ScheduleRunRow(
        id = run.id,
        status = runStatus(run.status),
        tone = runTone(run.status),
        trigger = if (run.manual) "Manual" else "Scheduled",
        at = run.scheduled_for.ifBlank { run.created_at },
        message = run.message,
        card_id = run.card_id,
    )

    /** "Pending", "Starting", "Running", "Completed", "Interrupted", "Failed", "Skipped", "Cancelled"; "Unknown" when blank. */
    fun runStatus(status: String): String {
        val value = status.trim().lowercase()
        if (value.isEmpty()) return "Unknown"
        return value.replace('_', ' ').replaceFirstChar { it.uppercaseChar() }
    }

    /** Starting and running are active, completed succeeded, failed and cancelled failed; the rest are neutral. */
    fun runTone(status: String): ScheduleRunRow.Tone = when (status.trim().lowercase()) {
        "starting", "running" -> ScheduleRunRow.Tone.TONE_ACTIVE
        "completed" -> ScheduleRunRow.Tone.TONE_SUCCESS
        "failed", "cancelled" -> ScheduleRunRow.Tone.TONE_FAILURE
        else -> ScheduleRunRow.Tone.TONE_NEUTRAL
    }
}

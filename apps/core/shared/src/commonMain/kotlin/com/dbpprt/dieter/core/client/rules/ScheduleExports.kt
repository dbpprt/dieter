package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ScheduleCadence
import com.dbpprt.dieter.client.v1.ScheduleEditorOptions
import com.dbpprt.dieter.core.schedules.Cadence
import com.dbpprt.dieter.core.schedules.CadenceKind
import com.dbpprt.dieter.core.schedules.ScheduleDrafts
import com.dbpprt.dieter.core.schedules.SchedulePresentations
import com.dbpprt.dieter.core.schedules.ScheduleTemplates

/**
 * The schedule editor's timing, templates, and choices, as the editor calls
 * them while the user edits. A cadence travels as its parts: a
 * `ScheduleCadence.Kind` number, hour, minute, cron weekday (0 = Sunday), and
 * the custom expression.
 */
object ScheduleExports {
    private val options = ScheduleEditorOptions(
        cadences = CadenceKind.entries.map { ScheduleEditorOptions.Option(key = kindValue(it).value.toString(), title = it.title) },
        weekdays = Cadence.WEEKDAY_ORDER.map { ScheduleEditorOptions.Option(key = it.toString(), title = Cadence.weekdayShortName(it), detail = Cadence.weekdayName(it)) },
        variables = ScheduleTemplates.VARIABLES.map { ScheduleEditorOptions.Option(key = it, title = "{{$it}}", detail = ScheduleTemplates.help(it)) },
        placements = listOf(ScheduleDrafts.DRAFT, ScheduleDrafts.RUN).map {
            ScheduleEditorOptions.Option(key = it, title = ScheduleDrafts.placementTitle(it), detail = ScheduleDrafts.placementDetail(it))
        },
        open_policies = ScheduleDrafts.OPEN_POLICIES.map { (policy, title) -> ScheduleEditorOptions.Option(key = policy, title = title) },
        misfire_note = ScheduleDrafts.MISFIRE_NOTE,
        title_placeholder = ScheduleTemplates.TITLE_PLACEHOLDER,
        prompt_placeholder = ScheduleTemplates.PROMPT_PLACEHOLDER,
        cron_help = ScheduleDrafts.CRON_HELP,
        new_title = ScheduleDrafts.NEW_TITLE,
        edit_title = ScheduleDrafts.EDIT_TITLE,
        empty_title = SchedulePresentations.EMPTY_TITLE,
        empty_detail = SchedulePresentations.EMPTY_DETAIL,
        load_more = SchedulePresentations.LOAD_MORE,
        loading_more = SchedulePresentations.LOADING_MORE,
        runs_loading = SchedulePresentations.RUNS_LOADING,
        runs_empty = SchedulePresentations.RUNS_EMPTY,
        load_older_runs = SchedulePresentations.LOAD_OLDER_RUNS,
        loading_older_runs = SchedulePresentations.LOADING_OLDER_RUNS,
    )

    /** [cron] in the friendly editor: weekdays, daily, or weekly at a time, else custom. */
    fun cadence(cron: String): ScheduleCadence = message(Cadence.parse(cron))

    /**
     * The cadence for the editor's choices, with its cron and summary. Hours
     * and minutes clamp to 0-23 and 0-59, a weekday outside 0-6 reads
     * Monday, and an unknown kind is custom.
     */
    fun cadenceOf(kind: Int, hour: Int, minute: Int, weekday: Int, custom: String): ScheduleCadence =
        message(cadence(kind, hour, minute, weekday, custom))

    /**
     * [cadenceOf] repeating as [toKind] instead: switching to custom starts
     * from the current cron unless [custom] already holds an expression.
     */
    fun cadenceSwitched(kind: Int, hour: Int, minute: Int, weekday: Int, custom: String, toKind: Int): ScheduleCadence =
        message(cadence(kind, hour, minute, weekday, custom).withKind(cadenceKind(toKind)))

    /** A schedule's timing line: "Weekdays at 09:00 · Europe/Berlin", "Custom schedule · UTC"; without " · zone" when [timezone] is empty. */
    fun timing(cron: String, timezone: String): String = Cadence.timing(cron, timezone)

    /** The time zone choices: [selected], [device], and UTC first, then [all] sorted, without blanks or duplicates. */
    fun timezones(selected: String, device: String, all: List<String>): List<String> = ScheduleDrafts.timezoneOptions(selected, device, all)

    /** The editor's and list's fixed choices and wording. */
    fun editorOptions(): ScheduleEditorOptions = options

    /** [field] with `{{variable}}` appended, after a space unless the field is empty or ends with whitespace. */
    fun insertVariable(field: String, variable: String): String = ScheduleTemplates.insert(field, variable)

    /**
     * [template] as an occurrence would render it, or [empty] when nothing
     * is left: [date] ("yyyy-MM-dd" in the schedule's zone) and [scheduledAt]
     * come from the platform; blank names read "Project", "Board", and
     * "Schedule".
     */
    fun templateExample(template: String, empty: String, date: String, scheduledAt: String, project: String, board: String, schedule: String): String =
        ScheduleTemplates.example(template, ScheduleTemplates.exampleValues(project, board, schedule, scheduledAt, date), empty)

    /** Whether a draft can be saved: every one of these is filled in. */
    fun canSave(name: String, titleTemplate: String, promptTemplate: String, cron: String, timezone: String, boardId: String, workspaceMode: String): Boolean =
        ScheduleDrafts.canSave(name, titleTemplate, promptTemplate, cron, timezone, boardId, workspaceMode)

    private fun cadence(kind: Int, hour: Int, minute: Int, weekday: Int, custom: String): Cadence =
        Cadence(cadenceKind(kind), hour.coerceIn(0, 23), minute.coerceIn(0, 59), weekday.takeIf { it in 0..6 } ?: 1, custom)

    private fun message(cadence: Cadence): ScheduleCadence = ScheduleCadence(
        kind = kindValue(cadence.kind),
        hour = cadence.hour,
        minute = cadence.minute,
        weekday = cadence.weekday,
        custom = cadence.custom,
        cron = cadence.cron(),
        time = cadence.time,
        summary = cadence.summary(),
    )

    private fun kindValue(kind: CadenceKind): ScheduleCadence.Kind = when (kind) {
        CadenceKind.WEEKDAYS -> ScheduleCadence.Kind.KIND_WEEKDAYS
        CadenceKind.DAILY -> ScheduleCadence.Kind.KIND_DAILY
        CadenceKind.WEEKLY -> ScheduleCadence.Kind.KIND_WEEKLY
        CadenceKind.CUSTOM -> ScheduleCadence.Kind.KIND_CUSTOM
    }

    private fun cadenceKind(value: Int): CadenceKind = when (ScheduleCadence.Kind.fromValue(value)) {
        ScheduleCadence.Kind.KIND_WEEKDAYS -> CadenceKind.WEEKDAYS
        ScheduleCadence.Kind.KIND_DAILY -> CadenceKind.DAILY
        ScheduleCadence.Kind.KIND_WEEKLY -> CadenceKind.WEEKLY
        ScheduleCadence.Kind.KIND_CUSTOM, null -> CadenceKind.CUSTOM
    }
}

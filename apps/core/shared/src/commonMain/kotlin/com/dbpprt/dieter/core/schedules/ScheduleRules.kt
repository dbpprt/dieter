package com.dbpprt.dieter.core.schedules

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.core.selection.Selections

enum class CadenceKind(val title: String) { WEEKDAYS("Weekdays"), DAILY("Daily"), WEEKLY("Weekly"), CUSTOM("Custom") }

/** The friendly editor over a five-field cron expression; the daemon stays authoritative. */
data class Cadence(val kind: CadenceKind, val hour: Int = 9, val minute: Int = 0, val weekday: Int = 1, val custom: String = "") {
    /** The cron the daemon receives; hours and minutes are clamped, never zero-padded. */
    fun cron(): String {
        if (kind == CadenceKind.CUSTOM) return custom.trim()
        val day = when (kind) {
            CadenceKind.WEEKDAYS -> "1-5"
            CadenceKind.DAILY -> "*"
            else -> weekday.takeIf { it in 0..6 }?.toString() ?: "1"
        }
        return "${minute.coerceIn(0, 59)} ${hour.coerceIn(0, 23)} * * $day"
    }

    /** The time of day, "09:30". */
    val time: String get() = "${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}"

    /** The same cadence at [time] ("HH:mm"); out-of-range parts are clamped. */
    fun at(time: String): Cadence {
        val parts = time.split(':')
        return copy(hour = parts.getOrNull(0)?.toIntOrNull()?.coerceIn(0, 23) ?: 9, minute = parts.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 59) ?: 0)
    }

    /** "Weekdays · 09:00", "Monday · 09:00", "Custom cron". */
    fun summary(): String = when (kind) {
        CadenceKind.WEEKLY -> "${weekdayName(weekday)} · $time"
        CadenceKind.CUSTOM -> "Custom cron"
        else -> "${kind.title} · $time"
    }

    companion object {
        /** Monday first, Sunday (0) last. */
        val WEEKDAY_ORDER = listOf(1, 2, 3, 4, 5, 6, 0)

        private val WEEKDAY_NAMES = listOf("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")

        /** Cron day numbers (0 is Sunday) with names, Monday first. */
        val WEEKDAYS: List<Pair<Int, String>> = WEEKDAY_ORDER.map { it to WEEKDAY_NAMES[it] }

        fun weekdayName(day: Int): String = WEEKDAY_NAMES.getOrNull(day) ?: "Monday"

        /** Only plain "minute hour * * day" expressions are friendly; everything else stays custom. */
        fun parse(cron: String): Cadence {
            val fields = cron.trim().split(Regex("\\s+"))
            val minute = fields.getOrNull(0)?.toIntOrNull()
            val hour = fields.getOrNull(1)?.toIntOrNull()
            val plain = fields.size == 5 && fields[2] == "*" && fields[3] == "*"
            val time = (hour ?: 9) to (minute ?: 0)
            if (minute != null && hour != null && plain) {
                val day = fields[4]
                when {
                    day == "1-5" -> return Cadence(CadenceKind.WEEKDAYS, hour, minute)
                    day == "*" -> return Cadence(CadenceKind.DAILY, hour, minute)
                    day.toIntOrNull() in 0..6 -> return Cadence(CadenceKind.WEEKLY, hour, minute, day.toInt())
                }
            }
            return Cadence(CadenceKind.CUSTOM, time.first, time.second, 1, cron.trim())
        }
    }
}

/** Placeholders the daemon renders for each occurrence. */
object ScheduleTemplates {
    val VARIABLES = listOf("date", "scheduled_at", "project", "board", "schedule")

    fun render(template: String, values: Map<String, String>): String =
        values.entries.fold(template) { text, (name, value) -> text.replace("{{$name}}", value) }

    /**
     * What the editor's example renders with: the next occurrence (else now)
     * and the names chosen so far. The platform formats [date] in the
     * schedule's time zone.
     */
    fun exampleValues(project: String?, board: String?, schedule: String, scheduledAt: String, date: String): Map<String, String> = mapOf(
        "date" to date,
        "scheduled_at" to scheduledAt,
        "project" to (project?.ifBlank { null } ?: "Project"),
        "board" to (board?.ifBlank { null } ?: "Board"),
        "schedule" to schedule.ifBlank { "Schedule" },
    )

    /** Appends `{{variable}}` to a field, separated by a space unless the field already ends with whitespace. */
    fun insert(field: String, variable: String): String {
        val token = "{{$variable}}"
        return when {
            field.isEmpty() -> token
            field.last().isWhitespace() -> field + token
            else -> "$field $token"
        }
    }
}

/** The editable definition, with the defaults every client applies. */
object ScheduleDrafts {
    const val DEFAULT_CRON = "0 9 * * 1-5"
    const val DEFAULT_TITLE = "Scheduled work · {{date}}"

    fun make(existing: Schedule?, projectId: String, timezone: String, boards: List<Board>, selectedBoardId: String?, harnesses: List<Harness>): ScheduleDraft {
        val board = existing?.board_id?.takeIf { id -> boards.any { it.id == id } }
            ?: selectedBoardId?.takeIf { id -> boards.any { it.id == id } }
            ?: boards.firstOrNull()?.id.orEmpty()
        val base = existing?.let {
            ScheduleDraft(
                checkout_id = it.checkout_id, project_id = it.project_id, board_id = board, name = it.name, description = it.description,
                cron = it.cron, timezone = it.timezone, enabled = it.enabled, action = it.action, title_template = it.title_template,
                prompt_template = it.prompt_template, provider = it.provider, model = it.model, effort = it.effort, label_ids = it.label_ids,
                open_card_policy = it.open_card_policy, misfire_policy = it.misfire_policy, provider_options = it.provider_options,
                workspace_mode = it.workspace_mode,
            )
        } ?: run {
            val selection = harnesses.firstOrNull()?.let { harness ->
                val model = harness.models.firstOrNull { it.id == harness.default_model } ?: harness.models.firstOrNull()
                HarnessSelection(harness.id, model?.id.orEmpty(), model?.default_effort.orEmpty(), Selections.defaultOptions(harness, model?.id))
            }
            ScheduleDraft(
                project_id = projectId, board_id = board, cron = DEFAULT_CRON, timezone = timezone, enabled = true, title_template = DEFAULT_TITLE,
                provider = selection?.provider.orEmpty(), model = selection?.model.orEmpty(), effort = selection?.effort.orEmpty(),
                provider_options = selection?.provider_options.orEmpty(), workspace_mode = "worktree",
            )
        }
        return base.copy(
            action = if (base.action == "run") "run" else "draft",
            open_card_policy = if (base.open_card_policy == "always") "always" else "skip_if_open",
            misfire_policy = "latest",
            workspace_mode = if (existing == null || base.workspace_mode.equals("worktree", ignoreCase = true)) "worktree" else "project",
        )
    }

    /** Switching boards keeps only labels the new board has. */
    fun onBoard(draft: ScheduleDraft, board: Board): ScheduleDraft {
        val labels = board.labels.mapTo(HashSet()) { it.id }
        return draft.copy(board_id = board.id, label_ids = draft.label_ids.filter { it in labels })
    }

    fun toggleLabel(draft: ScheduleDraft, id: String): ScheduleDraft =
        draft.copy(label_ids = if (id in draft.label_ids) draft.label_ids - id else draft.label_ids + id)

    fun selection(draft: ScheduleDraft): HarnessSelection = HarnessSelection(draft.provider, draft.model, draft.effort, draft.provider_options)

    fun choose(draft: ScheduleDraft, selection: HarnessSelection): ScheduleDraft =
        draft.copy(provider = selection.provider, model = selection.model, effort = selection.effort, provider_options = selection.provider_options)

    const val DRAFT = "draft"
    const val RUN = "run"

    /** What each occurrence does with its card. */
    fun placementDetail(action: String): String =
        if (action == RUN) "The daemon creates the card and starts its agent turn when admission allows."
        else "The daemon creates a draft in Todo and waits for you to start it."

    /** What an occurrence does while the previous card is still open. */
    val OPEN_POLICIES = listOf("skip_if_open" to "Skip if open", "always" to "Always create")

    fun canSave(draft: ScheduleDraft): Boolean = listOf(draft.name, draft.title_template, draft.prompt_template, draft.cron, draft.timezone, draft.board_id, draft.workspace_mode)
        .all { it.isNotBlank() }

    /** The draft as sent: trimmed text, the latest misfire policy, and sorted labels. */
    fun normalized(draft: ScheduleDraft, projectId: String, checkoutId: String): ScheduleDraft = draft.copy(
        project_id = projectId, checkout_id = checkoutId, name = draft.name.trim(), description = draft.description.trim(), cron = draft.cron.trim(),
        timezone = draft.timezone.trim(), title_template = draft.title_template.trim(), prompt_template = draft.prompt_template.trim(),
        misfire_policy = "latest", label_ids = draft.label_ids.sorted(),
    )

    /** Timezone choices: the selection and device zone first, then the rest, without duplicates. */
    fun timezoneOptions(selected: String?, device: String, all: List<String>): List<String> =
        (listOfNotNull(selected, device, "UTC") + all.sortedBy { it.lowercase() }).filter { it.isNotBlank() }.distinct()
}

enum class SchedulesPresentation { LOADING, FAILED, EMPTY, LOADED }

object SchedulePresentations {
    fun resolve(loaded: Boolean, loading: Boolean, hasSchedules: Boolean, error: String?): SchedulesPresentation = when {
        error != null && !hasSchedules && !loading -> SchedulesPresentation.FAILED
        !loaded || (loading && !hasSchedules) -> SchedulesPresentation.LOADING
        hasSchedules -> SchedulesPresentation.LOADED
        else -> SchedulesPresentation.EMPTY
    }
}

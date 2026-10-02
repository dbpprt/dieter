package com.dbpprt.dieter.core.schedules

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.core.selection.Selections

enum class CadenceKind(val title: String) { WEEKDAYS("Weekdays"), DAILY("Daily"), WEEKLY("Weekly"), CUSTOM("Custom") }

/**
 * The friendly editor over a five-field cron expression (minute, hour, day
 * of month, month, day of week; no seconds), as the daemon parses it; the
 * daemon stays authoritative.
 */
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

    /** "Weekdays at 09:00", "Every day at 09:00", "Every Monday at 09:00", "Custom schedule". */
    fun summary(): String = when (kind) {
        CadenceKind.WEEKDAYS -> "Weekdays at $time"
        CadenceKind.DAILY -> "Every day at $time"
        CadenceKind.WEEKLY -> "Every ${weekdayName(weekday)} at $time"
        CadenceKind.CUSTOM -> "Custom schedule"
    }

    /** [summary] followed by " · [timezone]" unless the zone is blank: "Weekdays at 09:00 · Europe/Berlin". */
    fun summary(timezone: String): String = if (timezone.isBlank()) summary() else "${summary()} · $timezone"

    /**
     * The same timing repeating as [kind]. Switching to custom starts from
     * this cadence's cron unless a custom expression was already entered.
     */
    fun withKind(kind: CadenceKind): Cadence = copy(kind = kind, custom = custom.ifBlank { cron() })

    companion object {
        /** Monday first, Sunday (0) last. */
        val WEEKDAY_ORDER = listOf(1, 2, 3, 4, 5, 6, 0)

        private val WEEKDAY_NAMES = listOf("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
        private val WEEKDAY_SHORT_NAMES = listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
        private val WHITESPACE = Regex("\\s+")

        /** Cron day numbers (0 is Sunday) with names, Monday first. */
        val WEEKDAYS: List<Pair<Int, String>> = WEEKDAY_ORDER.map { it to WEEKDAY_NAMES[it] }

        fun weekdayName(day: Int): String = WEEKDAY_NAMES.getOrNull(day) ?: "Monday"

        /** "Mon" for cron day 1; out-of-range days read "Mon". */
        fun weekdayShortName(day: Int): String = WEEKDAY_SHORT_NAMES.getOrNull(day) ?: "Mon"

        /**
         * Only plain "minute hour * * day" expressions with exactly five
         * fields, a minute of 0-59, an hour of 0-23, and a day of "1-5", "*",
         * or 0-6 are friendly; everything else stays custom, keeping a valid
         * time (else 09:00).
         */
        fun parse(cron: String): Cadence {
            val fields = cron.trim().split(WHITESPACE)
            val minute = fields.getOrNull(0)?.toIntOrNull()?.takeIf { it in 0..59 }
            val hour = fields.getOrNull(1)?.toIntOrNull()?.takeIf { it in 0..23 }
            val plain = fields.size == 5 && fields[2] == "*" && fields[3] == "*"
            if (minute != null && hour != null && plain) {
                val day = fields[4]
                when {
                    day == "1-5" -> return Cadence(CadenceKind.WEEKDAYS, hour, minute)
                    day == "*" -> return Cadence(CadenceKind.DAILY, hour, minute)
                    day.toIntOrNull() in 0..6 -> return Cadence(CadenceKind.WEEKLY, hour, minute, day.toInt())
                }
            }
            return Cadence(CadenceKind.CUSTOM, hour ?: 9, minute ?: 0, 1, cron.trim())
        }

        /** A schedule's timing line: "Every Thursday at 16:45 · UTC", "Custom schedule · UTC". */
        fun timing(cron: String, timezone: String): String = parse(cron).summary(timezone)
    }
}

/** Placeholders the daemon renders for each occurrence. */
object ScheduleTemplates {
    val VARIABLES = listOf("date", "scheduled_at", "project", "board", "schedule")

    private val HELP = mapOf(
        "date" to "Occurrence date in the schedule timezone",
        "scheduled_at" to "Exact scheduled timestamp",
        "project" to "Project name",
        "board" to "Board name",
        "schedule" to "Schedule name",
    )

    /** The example output of an empty title template. */
    const val TITLE_PLACEHOLDER = "Card title preview"

    /** The example output of an empty prompt template. */
    const val PROMPT_PLACEHOLDER = "Agent task preview"

    /** What a placeholder stands for, e.g. "Occurrence date in the schedule timezone"; an unknown one reads as its name. */
    fun help(variable: String): String = HELP[variable] ?: variable

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

    /** [template] rendered with [values], or [empty] when that leaves nothing to show. */
    fun example(template: String, values: Map<String, String>, empty: String): String = render(template, values).ifBlank { empty }

    /** How [variable] is written in a template: `{{date}}`. */
    fun token(variable: String): String = "{{$variable}}"

    /** Appends `{{variable}}` to a field, separated by a space unless the field already ends with whitespace. */
    fun insert(field: String, variable: String): String {
        val written = token(variable)
        return when {
            field.isEmpty() -> written
            field.last().isWhitespace() -> field + written
            else -> "$field $written"
        }
    }
}

/** The editable definition, with the defaults every client applies. */
object ScheduleDrafts {
    const val DEFAULT_CRON = "0 9 * * 1-5"
    const val DEFAULT_TITLE = "Scheduled work · {{date}}"

    const val NEW_TITLE = "New schedule"
    const val EDIT_TITLE = "Edit schedule"
    const val CRON_HELP = "Five fields: minute, hour, day of month, month, day of week."
    const val MISFIRE_NOTE = "Missed occurrences are collapsed to the latest one after the daemon returns."

    /**
     * [existing] as an editable draft, or a new one in [timezone] at 09:00 on
     * weekdays. The board is the schedule's when it still exists, else
     * [selectedBoardId], else the first. A draft without an agent gets the
     * first of [harnesses] with its default model (else its first model),
     * that model's default effort, and its default options.
     */
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
        } ?: ScheduleDraft(
            project_id = projectId, board_id = board, cron = DEFAULT_CRON, timezone = timezone, enabled = true, title_template = DEFAULT_TITLE,
            workspace_mode = "worktree",
        )
        val agent = if (base.provider.isBlank()) defaultAgent(harnesses) else null
        return base.copy(
            provider = agent?.provider ?: base.provider,
            model = agent?.model ?: base.model,
            effort = agent?.effort ?: base.effort,
            provider_options = agent?.provider_options ?: base.provider_options,
            action = if (base.action == "run") "run" else "draft",
            open_card_policy = if (base.open_card_policy == "always") "always" else "skip_if_open",
            misfire_policy = "latest",
            workspace_mode = if (existing == null || base.workspace_mode.equals("worktree", ignoreCase = true)) "worktree" else "project",
        )
    }

    private fun defaultAgent(harnesses: List<Harness>): HarnessSelection? = harnesses.firstOrNull()?.let { harness ->
        val model = harness.models.firstOrNull { it.id == harness.default_model } ?: harness.models.firstOrNull()
        HarnessSelection(harness.id, model?.id.orEmpty(), model?.default_effort.orEmpty(), Selections.defaultOptions(harness, model?.id))
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

    /** Where each occurrence's card goes: "Running" for [RUN], else "Todo". */
    fun placementTitle(action: String): String = if (action == RUN) "Running" else "Todo"

    /** What each occurrence does with its card. */
    fun placementDetail(action: String): String =
        if (action == RUN) "The daemon creates the card and starts its agent turn when admission allows."
        else "The daemon creates a draft in Todo and waits for you to start it."

    /** What an occurrence does while the previous card is still open. */
    val OPEN_POLICIES = listOf("skip_if_open" to "Skip if open", "always" to "Always create")

    fun canSave(draft: ScheduleDraft): Boolean =
        canSave(draft.name, draft.title_template, draft.prompt_template, draft.cron, draft.timezone, draft.board_id, draft.workspace_mode)

    /** A draft can be saved once its name, templates, timing, board, and workspace are filled in. */
    fun canSave(name: String, titleTemplate: String, promptTemplate: String, cron: String, timezone: String, boardId: String, workspaceMode: String): Boolean =
        listOf(name, titleTemplate, promptTemplate, cron, timezone, boardId, workspaceMode).all { it.isNotBlank() }

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

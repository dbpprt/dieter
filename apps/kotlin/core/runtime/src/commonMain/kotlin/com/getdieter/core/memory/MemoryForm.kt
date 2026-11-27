package com.getdieter.core.memory

import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.MemoryProjectStatus
import com.getdieter.api.v1.MemorySettings
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentControlsState
import com.getdieter.client.v1.MachineEntry
import com.getdieter.client.v1.MachineMetadata
import com.getdieter.core.client.agentControlsState
import com.getdieter.core.client.choosing
import com.getdieter.core.presentation.Ages
import com.getdieter.core.presentation.Counts
import com.getdieter.core.providers.AgentAccounts
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.selection.AgentControls
import kotlin.time.Instant

/**
 * The agent memory setting's form, worded and checked once for every client: which machine it
 * edits, its agent pickers over that machine's catalog, dreaming's schedule and limits, and what
 * keeps it from saving. The bounds are the daemon's (`schema.ValidateMemorySettings`).
 */
object MemoryForm {
    const val AUTO = "auto"
    const val REVIEW = "review"
    val APPLY_MODES = listOf(AUTO, REVIEW)

    /** A dream starts at most this often per project, in hours. */
    val MIN_HOURS = 1..168

    /** A dream waits for this many memory conversations to finish. */
    val MIN_NEW_TASKS = 1..100

    /** A dream changes at most this many memories. */
    val MAX_OPERATIONS = 1..100

    /** A dream retires or supersedes at most this percentage of the active memories. */
    val MAX_RETIRE_PERCENT = 1..100

    const val MAX_INSTRUCTIONS_BYTES = 4 * 1024

    /** The daemon's defaults (`schema.DefaultMemorySettings`). */
    const val DEFAULT_HARNESS = "claude-code"
    const val DEFAULT_MODEL = "opus"
    const val DEFAULT_MIN_HOURS = 24
    const val DEFAULT_MIN_NEW_TASKS = 5
    const val DEFAULT_WINDOW = "02:00-06:00"
    const val DEFAULT_MAX_OPERATIONS = 40
    const val DEFAULT_MAX_RETIRE_PERCENT = 25

    /** Strix runs security scans, not memory dreams; the daemon refuses it. */
    const val STRIX = "strix"

    /** The title of a settings screen that shows the defaults nobody saved yet. */
    const val DEFAULTS = "Defaults"

    /** The run-on picker's choice that lets each project dream where most of it runs. */
    const val AUTOMATIC = "Automatic"

    private const val MAX_NAME_BYTES = 128
    private val WINDOW = Regex("^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$")

    /**
     * The machine the form reads and saves on, whose catalog its pickers show: this device's
     * machine, else the first available one; null while none is.
     */
    fun machine(machines: List<MachineEntry>): String? =
        machines.firstOrNull { it.available && it.local }?.id
            ?: machines.firstOrNull { it.available }?.id

    /** [daemonId]'s agents that can dream, from [metadata]; empty until its catalog has arrived. */
    fun harnesses(metadata: Map<String, MachineMetadata>, daemonId: String?): List<Harness> =
        daemonId?.let { metadata[it]?.harnesses?.harnesses }.orEmpty().filter { it.id != STRIX }

    /**
     * [settings] as the daemon stores a save: an empty agent takes the default agent and model,
     * unset numbers and apply mode their defaults. An empty window stays empty: any time.
     */
    fun withDefaults(settings: MemorySettings): MemorySettings {
        val harness = settings.harness.trim()
        return settings.copy(
            harness = harness.ifEmpty { DEFAULT_HARNESS },
            model = if (harness.isEmpty()) DEFAULT_MODEL else settings.model,
            min_hours = settings.min_hours.takeIf { it != 0 } ?: DEFAULT_MIN_HOURS,
            min_new_tasks = settings.min_new_tasks.takeIf { it != 0 } ?: DEFAULT_MIN_NEW_TASKS,
            apply = settings.apply.trim().ifEmpty { AUTO },
            max_operations = settings.max_operations.takeIf { it != 0 } ?: DEFAULT_MAX_OPERATIONS,
            max_retire_percent =
                settings.max_retire_percent.takeIf { it != 0 } ?: DEFAULT_MAX_RETIRE_PERCENT,
        )
    }

    /** The setting's agent as a picker selection. */
    fun selection(settings: MemorySettings): HarnessSelection =
        HarnessSelection(
            provider = settings.harness,
            model = settings.model,
            effort = settings.effort,
            account_id = settings.account_id,
        )

    /**
     * The agent pickers for [settings] over [harnesses]: agent, model, effort and the provider
     * accounts in [accounts] (judged on the machine that dreams); provider options are not offered.
     */
    fun agent(
        settings: MemorySettings,
        harnesses: List<Harness>,
        accounts: AgentAccounts = AgentAccounts(),
    ): AgentControlsState =
        agentControlsState(AgentControls(selection(settings), harnesses, accounts = accounts))
            .copy(
                options = emptyList(),
                option_values = emptyMap(),
                option_enabled = emptyMap(),
                option_kinds = emptyMap(),
                option_on = emptyMap(),
                fast_mode = false,
                fast_option_id = "",
                account_blocked = false,
            )

    /**
     * [settings] after a picker's [choice]: another agent takes its default model and effort and
     * the provider default account, another model its default effort. Options do not apply.
     */
    fun choosing(
        settings: MemorySettings,
        harnesses: List<Harness>,
        choice: AgentChoice,
        accounts: AgentAccounts = AgentAccounts(),
    ): MemorySettings {
        if (choice.option != null) return settings
        val next =
            runCatching {
                AgentControls(selection(settings), harnesses, accounts = accounts).choosing(choice)
            }
                .getOrNull() ?: return settings
        return settings.copy(
            harness = next.provider,
            model = next.model,
            effort = next.effort,
            // A provider account belongs to the agent it was chosen for.
            account_id =
                when {
                    choice.account != null -> next.account_id
                    next.provider == settings.harness -> settings.account_id
                    else -> ""
                },
        )
    }

    /** "Dreaming off", else "Claude Code · opus · Review first". */
    fun status(settings: MemorySettings, harnesses: List<Harness>): String {
        if (!settings.dreaming) return "Dreaming off"
        val harness = harnesses.firstOrNull { it.id == settings.harness }
        val model = harness?.models?.firstOrNull { it.id == settings.model }
        return listOf(
                harness?.name?.ifEmpty { null } ?: settings.harness,
                model?.name?.ifEmpty { null } ?: settings.model,
                applyTitle(settings.apply),
            )
            .filter { it.isNotBlank() }
            .joinToString(" · ")
    }

    /** "Apply at once", "Review first"; an empty mode is the daemon's default, auto. */
    fun applyTitle(apply: String): String =
        when (apply.ifEmpty { AUTO }) {
            AUTO -> "Apply at once"
            REVIEW -> "Review first"
            else -> apply.replaceFirstChar { it.uppercaseChar() }
        }

    /** What an apply mode does, in one line. */
    fun applyDetail(apply: String): String =
        when (apply.ifEmpty { AUTO }) {
            AUTO -> "A checked dream changes the memories at once; Undo restores them."
            REVIEW -> "A dream waits in its conversation until you apply or discard it."
            else -> ""
        }

    /** The run-on picker's choices: [AUTOMATIC] first, then [machines], then an unknown [runOn]. */
    fun runOnChoices(machines: List<MachineEntry>, runOn: String): List<Pair<String, String>> {
        val known = machines.map { it.id to it.display_name.ifEmpty { it.name.ifEmpty { it.id } } }
        val unknown =
            runOn.takeIf { it.isNotEmpty() && known.none { (id, _) -> id == it } }?.let { it to it }
        return listOf("" to AUTOMATIC) + known + listOfNotNull(unknown)
    }

    /** The run-on picker's value: [AUTOMATIC], or the machine's name. */
    fun runOnTitle(machines: List<MachineEntry>, runOn: String): String =
        runOnChoices(machines, runOn).firstOrNull { it.first == runOn }?.second ?: runOn

    /** What the run-on choice means. */
    fun runOnDetail(runOn: String): String =
        if (runOn.isEmpty()) "Each project dreams on the machine with most of its conversations."
        else "Every project dreams on this machine."

    /** Why [window] is not a start window; null for "HH:MM-HH:MM" or empty (any time). */
    fun windowProblem(window: String): String? =
        window
            .trim()
            .takeIf { it.isNotEmpty() && !WINDOW.matches(it) }
            ?.let {
                "Write the window as HH:MM-HH:MM, e.g. $DEFAULT_WINDOW, or leave it empty."
            }

    /** Why [settings] cannot be saved, as the daemon would refuse them; null when they can. */
    fun problem(settings: MemorySettings): String? {
        val names =
            listOf(
                settings.harness,
                settings.model,
                settings.effort,
                settings.account_id,
                settings.run_on,
            )
        val instructions = settings.instructions.trim()
        return when {
            settings.harness.trim() == STRIX -> "Strix cannot dream; choose another agent."
            names.any { !validName(it.trim()) } -> "Choose the dreaming agent again."
            settings.min_hours != 0 && settings.min_hours !in MIN_HOURS ->
                "Dreams start at most every ${MIN_HOURS.first} to ${MIN_HOURS.last} hours."
            settings.min_new_tasks != 0 && settings.min_new_tasks !in MIN_NEW_TASKS ->
                "A dream waits for ${MIN_NEW_TASKS.first} to ${MIN_NEW_TASKS.last} finished " +
                    "conversations."
            settings.apply.isNotBlank() && settings.apply.trim() !in APPLY_MODES ->
                "Choose to apply dreams at once or to review them first."
            settings.max_operations != 0 && settings.max_operations !in MAX_OPERATIONS ->
                "A dream changes ${MAX_OPERATIONS.first} to ${MAX_OPERATIONS.last} memories."
            settings.max_retire_percent != 0 &&
                settings.max_retire_percent !in MAX_RETIRE_PERCENT ->
                "A dream retires ${MAX_RETIRE_PERCENT.first} to ${MAX_RETIRE_PERCENT.last} " +
                    "percent of the memories."
            windowProblem(settings.window) != null -> windowProblem(settings.window)
            instructions.encodeToByteArray().size > MAX_INSTRUCTIONS_BYTES ->
                "Extra instructions are limited to 4 KiB."
            '\u0000' in instructions -> "Extra instructions cannot contain NUL characters."
            else -> null
        }
    }

    /** What a save sends: the fields the daemon stores, trimmed. */
    fun saved(settings: MemorySettings): MemorySettings =
        MemorySettings(
            dreaming = settings.dreaming,
            harness = settings.harness.trim(),
            model = settings.model.trim(),
            effort = settings.effort.trim(),
            account_id = settings.account_id.trim(),
            run_on = settings.run_on.trim(),
            min_hours = settings.min_hours,
            min_new_tasks = settings.min_new_tasks,
            window = settings.window.trim(),
            apply = settings.apply.trim(),
            max_operations = settings.max_operations,
            max_retire_percent = settings.max_retire_percent,
            instructions = settings.instructions.trim(),
        )

    /**
     * [draft] differs from the [saved] setting it was read from, or nobody saved one yet (saving
     * the defaults keeps them); false while nothing was read.
     */
    fun changed(draft: MemorySettings, saved: MemorySettings?): Boolean =
        saved != null && (!saved.configured || saved(draft) != saved(saved))

    /**
     * A project's memory on the machine that answered, in one line: "12 conversations indexed on
     * Studio · 5 saved memories", with the conversations still waiting to be indexed.
     */
    fun projectSummary(status: MemoryProjectStatus, machine: String): String =
        listOfNotNull(
                Counts.of(status.cards, "conversation") +
                    " indexed" +
                    machine.takeIf { it.isNotBlank() }?.let { " on $it" }.orEmpty(),
                Counts.of(status.saved, "saved memory", "saved memories"),
                status.backlog.takeIf { it > 0 }?.let { "$it waiting to be indexed" },
            )
            .joinToString(" · ")

    /**
     * A project's dreams in one line: "Last dream 2d ago · Next dream in 5h", "No dream yet ·
     * Waiting for 3 more finished conversations". [machineName] names a daemon ID.
     */
    fun projectDreams(
        status: MemoryProjectStatus,
        nowMillis: Long,
        machineName: (String) -> String = { it },
    ): String {
        val now = Instant.fromEpochMilliseconds(nowMillis)
        val last =
            Timestamps.parse(status.last_dream_at)?.let { "Last dream ${Ages.ago(it, now)}" }
                ?: "No dream yet"
        val next = nextDream(status.next_dream, now, machineName)
        return listOfNotNull(last, next).joinToString(" · ")
    }

    /** The daemon's reason the next dream waits, as a sentence; null without one. */
    private fun nextDream(reason: String, now: Instant, machineName: (String) -> String): String? {
        val text =
            reason.trim().ifEmpty {
                return null
            }
        text.removePrefixOrNull("next dream after ")?.let { value ->
            val at = Timestamps.parse(value) ?: return "Next dream after $value"
            val until = if (at > now) Ages.span(at - now) else null
            return when {
                at <= now -> "Next dream when the window opens"
                until == null -> "Next dream in under a minute"
                else -> "Next dream in ${until.compact}"
            }
        }
        text.removePrefixOrNull("dreams run on ")?.let {
            return "Dreams run on ${machineName(it)}"
        }
        return text.replaceFirstChar { it.uppercaseChar() }
    }

    private fun String.removePrefixOrNull(prefix: String): String? =
        if (startsWith(prefix)) removePrefix(prefix) else null

    private fun validName(value: String): Boolean =
        value.encodeToByteArray().size <= MAX_NAME_BYTES &&
            value.none { it < ' ' || it == '\u007f' }
}

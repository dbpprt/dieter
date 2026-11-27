package com.getdieter.core.reviews

import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.ReviewerSettings
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentControlsState
import com.getdieter.client.v1.MachineEntry
import com.getdieter.client.v1.MachineMetadata
import com.getdieter.core.client.agentControlsState
import com.getdieter.core.client.choosing
import com.getdieter.core.selection.AgentControls

/**
 * The code reviewer's settings form, worded and checked once for every client: which machine it
 * edits, its agent pickers over that machine's catalog, depth and limits, and what keeps it from
 * saving.
 */
object ReviewerForm {
    const val QUICK = "quick"
    const val THOROUGH = "thorough"
    val DEPTHS = listOf(QUICK, THOROUGH)

    /** At most this many findings per review. */
    val MAX_FINDINGS = 1..20

    /** Agents ask for at most this many reviews per task. */
    val MAX_ROUNDS = 1..10

    /** Findings rated below this confidence are dropped. */
    val MIN_CONFIDENCE = 0..10

    const val MAX_INSTRUCTIONS_BYTES = 4 * 1024

    /** The title of a settings screen that shows the defaults nobody saved yet. */
    const val DEFAULTS = "Defaults"

    fun depthTitle(depth: String): String =
        when (depth) {
            QUICK -> "Quick"
            THOROUGH -> "Thorough"
            else -> depth.replaceFirstChar { it.uppercaseChar() }
        }

    /** What a depth does, in one line. */
    fun depthDetail(depth: String): String =
        when (depth) {
            QUICK -> "One pass over the diff; the checkout only to settle doubts."
            THOROUGH -> "Every finding is confirmed in the code first. Slower."
            else -> ""
        }

    /**
     * The machine the form reads and saves on, whose catalog its pickers show: this device's
     * machine, else the first available one; null while none is.
     */
    fun machine(machines: List<MachineEntry>): String? =
        machines.firstOrNull { it.available && it.local }?.id
            ?: machines.firstOrNull { it.available }?.id

    /** [daemonId]'s agents from [metadata]; empty until its catalog has arrived. */
    fun harnesses(metadata: Map<String, MachineMetadata>, daemonId: String?): List<Harness> =
        daemonId?.let { metadata[it]?.harnesses?.harnesses }.orEmpty()

    /** The setting's agent as a picker selection. */
    fun selection(settings: ReviewerSettings): HarnessSelection =
        HarnessSelection(
            provider = settings.harness,
            model = settings.model,
            effort = settings.effort,
            account_id = settings.account_id,
        )

    /**
     * The agent pickers for [settings] over [harnesses]: agent, model and effort; provider options
     * and accounts are not offered.
     */
    fun agent(settings: ReviewerSettings, harnesses: List<Harness>): AgentControlsState =
        agentControlsState(AgentControls(selection(settings), harnesses))
            .copy(
                options = emptyList(),
                option_values = emptyMap(),
                option_enabled = emptyMap(),
                option_kinds = emptyMap(),
                option_on = emptyMap(),
                fast_mode = false,
                fast_option_id = "",
                accounts = emptyList(),
                account_enabled = false,
            )

    /**
     * [settings] after a picker's [choice]: another agent takes its default model and effort,
     * another model its default effort. Options and accounts do not apply to the reviewer.
     */
    fun choosing(
        settings: ReviewerSettings,
        harnesses: List<Harness>,
        choice: AgentChoice,
    ): ReviewerSettings {
        if (choice.option != null || choice.account != null) return settings
        val next =
            runCatching { AgentControls(selection(settings), harnesses).choosing(choice) }
                .getOrNull() ?: return settings
        return settings.copy(
            harness = next.provider,
            model = next.model,
            effort = next.effort,
            // A provider account belongs to the agent it was chosen for.
            account_id = if (next.provider == settings.harness) settings.account_id else "",
        )
    }

    /** "Defaults" until someone saved the setting, else "Claude Code · opus". */
    fun status(settings: ReviewerSettings, harnesses: List<Harness>): String {
        if (!settings.configured) return DEFAULTS
        val harness = harnesses.firstOrNull { it.id == settings.harness }
        val model = harness?.models?.firstOrNull { it.id == settings.model }
        return listOf(
                harness?.name?.ifEmpty { null } ?: settings.harness,
                model?.name?.ifEmpty { null } ?: settings.model,
            )
            .filter { it.isNotBlank() }
            .joinToString(" · ")
    }

    /** Why [settings] cannot be saved, as the daemon would refuse them; null when they can. */
    fun problem(settings: ReviewerSettings): String? =
        when {
            settings.harness.isBlank() -> "Choose the reviewer's agent."
            settings.depth.isNotEmpty() && settings.depth !in DEPTHS ->
                "Choose a quick or a thorough review."
            settings.max_findings != 0 && settings.max_findings !in MAX_FINDINGS ->
                "A review reports ${MAX_FINDINGS.first} to ${MAX_FINDINGS.last} findings."
            settings.max_rounds != 0 && settings.max_rounds !in MAX_ROUNDS ->
                "Agents may ask for ${MAX_ROUNDS.first} to ${MAX_ROUNDS.last} reviews per task."
            settings.min_confidence !in MIN_CONFIDENCE ->
                "The minimum confidence is ${MIN_CONFIDENCE.first} to ${MIN_CONFIDENCE.last}."
            settings.instructions.trim().encodeToByteArray().size > MAX_INSTRUCTIONS_BYTES ->
                "Extra instructions are limited to 4 KiB."
            else -> null
        }

    /** What a save sends: the fields the daemon stores, trimmed. */
    fun saved(settings: ReviewerSettings): ReviewerSettings =
        ReviewerSettings(
            harness = settings.harness.trim(),
            model = settings.model.trim(),
            effort = settings.effort.trim(),
            account_id = settings.account_id.trim(),
            depth = settings.depth.trim(),
            max_findings = settings.max_findings,
            min_confidence = settings.min_confidence,
            instructions = settings.instructions.trim(),
            ignore_globs = settings.ignore_globs.map { it.trim() }.filter { it.isNotEmpty() },
            max_rounds = settings.max_rounds,
        )
}

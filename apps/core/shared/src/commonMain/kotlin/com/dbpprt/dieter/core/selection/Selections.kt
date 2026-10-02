package com.dbpprt.dieter.core.selection

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.api.v1.ProviderOptionChoice
import com.dbpprt.dieter.core.board.Runtimes

/** How a provider option is edited: switched on or off, picked from its choices, or typed. */
enum class ProviderOptionKind { TOGGLE, CHOICE, TEXT }

/**
 * Provider, model, effort, and option resolution against a machine's harness
 * catalog, with the daemon's own rules for what a model accepts.
 */
object Selections {
    /** The explicit effort that stops the daemon from inheriting one the new model may not support. */
    const val DEFAULT_EFFORT = "default"

    fun harness(harnesses: List<Harness>, provider: String): Harness? = harnesses.firstOrNull { it.id == provider }

    fun model(harness: Harness, id: String): HarnessModel? = harness.models.firstOrNull { it.id == id }

    /** The model a choice of [harness] starts with: its default model, else its first. */
    fun defaultModel(harness: Harness): HarnessModel? = model(harness, harness.default_model) ?: harness.models.firstOrNull()

    /** Efforts [model] accepts, as the daemon checks them: the model's own list, else every effort the harness offers. */
    fun efforts(harness: Harness, model: HarnessModel?): List<String> =
        model?.efforts?.takeIf { it.isNotEmpty() } ?: harness.effort?.options.orEmpty().map { it.id }

    /** [model]'s default effort when it accepts it, else the provider's own default ([DEFAULT_EFFORT]). */
    fun defaultEffort(harness: Harness, model: HarnessModel?): String {
        val effort = model?.default_effort.orEmpty()
        val allowed = efforts(harness, model)
        return if (effort.isNotEmpty() && (allowed.isEmpty() || effort in allowed)) effort else DEFAULT_EFFORT
    }

    /**
     * A valid selection for [saved]: the harness (else the first), the model
     * (else its default, else the first), and an effort that model accepts.
     * With [allowServerDefault], an empty provider means "let the daemon choose".
     */
    fun resolve(saved: HarnessSelection, harnesses: List<Harness>, allowServerDefault: Boolean = false): HarnessSelection? {
        if (allowServerDefault && saved.provider.isEmpty()) return HarnessSelection()
        val harness = harness(harnesses, saved.provider) ?: harnesses.firstOrNull() ?: return null
        val model = model(harness, saved.model) ?: defaultModel(harness)
        val allowed = efforts(harness, model)
        val effort = when {
            model == null -> ""
            harness.id == saved.provider && model.id == saved.model && (saved.effort.isEmpty() || saved.effort in allowed) -> saved.effort
            model.default_effort.isNotEmpty() && (allowed.isEmpty() || model.default_effort in allowed) -> model.default_effort
            else -> allowed.firstOrNull().orEmpty()
        }
        return HarnessSelection(
            provider = harness.id,
            model = model?.id.orEmpty(),
            effort = effort,
            provider_options = normalizedOptions(harness, model?.id.orEmpty(), if (harness.id == saved.provider) saved.provider_options else emptyMap()),
        )
    }

    /**
     * [selection] checked against its harness in [harnesses]: a blank model
     * takes the harness's default, an effort the model does not accept
     * becomes [DEFAULT_EFFORT], and the options are validated. An unknown
     * provider or model stays as it is ([supports] reports it).
     */
    fun validated(selection: HarnessSelection, harnesses: List<Harness>): HarnessSelection {
        val harness = harness(harnesses, selection.provider) ?: return selection
        val modelId = selection.model.ifEmpty { defaultModel(harness)?.id ?: harness.default_model }
        val model = model(harness, modelId)
        val allowed = efforts(harness, model)
        val effort = selection.effort.takeIf { it.isEmpty() || it == DEFAULT_EFFORT || model == null || allowed.isEmpty() || it in allowed } ?: DEFAULT_EFFORT
        return selection.copy(model = modelId, effort = effort, provider_options = normalizedOptions(harness, modelId, selection.provider_options))
    }

    /** Options that apply to [model] (the default model when blank). */
    fun options(harness: Harness?, model: String): List<ProviderOption> {
        harness ?: return emptyList()
        val selected = model.ifEmpty { harness.default_model }
        return harness.options.filter { it.models.isEmpty() || selected in it.models }
    }

    /** Every advertised option with a valid value: saved when valid, else the default. */
    fun resolvedOptions(harness: Harness?, existing: Map<String, String>): Map<String, String> {
        val values = LinkedHashMap<String, String>()
        for (option in harness?.options.orEmpty()) {
            if (option.id in values) continue
            var value = existing[option.id] ?: option.default_value
            when (optionKind(option)) {
                ProviderOptionKind.TOGGLE -> value = value.lowercase().takeIf { it == "true" || it == "false" } ?: option.default_value
                ProviderOptionKind.CHOICE -> if (option.choices.none { it.value_ == value }) value = option.default_value
                ProviderOptionKind.TEXT -> Unit
            }
            values[option.id] = value
        }
        return values
    }

    /** "bool"/"boolean" options toggle, "enum"/"select" options offer their choices, any other type is typed. */
    fun optionKind(option: ProviderOption): ProviderOptionKind = when (option.type.lowercase()) {
        "bool", "boolean" -> ProviderOptionKind.TOGGLE
        "enum", "select" -> ProviderOptionKind.CHOICE
        else -> ProviderOptionKind.TEXT
    }

    /** A toggle option's [value] is on. */
    fun isOn(value: String): Boolean = value.equals("true", ignoreCase = true)

    /** A choice's name, else its value. */
    fun choiceName(choice: ProviderOptionChoice): String = choice.name.ifBlank { choice.value_ }

    /** A choice option's label: the name of the choice [value] selects, else the option's name. */
    fun optionLabel(option: ProviderOption, value: String): String =
        option.choices.firstOrNull { it.value_ == value }?.let { choiceName(it) } ?: option.name

    /** Valid values for the options that apply to [model]; options the harness does not advertise are dropped. */
    fun normalizedOptions(harness: Harness?, model: String, saved: Map<String, String>): Map<String, String> {
        val applicable = options(harness, model).mapTo(HashSet()) { it.id }
        return resolvedOptions(harness, saved).filterKeys { it in applicable }
    }

    fun defaultOptions(harness: Harness?, model: String? = null): Map<String, String> =
        normalizedOptions(harness, model ?: harness?.default_model.orEmpty(), emptyMap())

    /**
     * Choosing another model: its default effort ([defaultEffort]), or the
     * current effort when [keepEffort] (the effort may not change now); the
     * options are re-validated for it.
     */
    fun selectingModel(current: HarnessSelection, harness: Harness?, id: String, keepEffort: Boolean = false): HarnessSelection {
        val effort = when {
            keepEffort -> current.effort
            harness != null -> defaultEffort(harness, model(harness, id))
            else -> DEFAULT_EFFORT
        }
        return current.copy(model = id, effort = effort, provider_options = normalizedOptions(harness, id, current.provider_options))
    }

    /** Choosing another provider starts from its defaults: its default model (else its first), that model's default effort, and its default options. */
    fun selectingProvider(harness: Harness): HarnessSelection {
        val model = defaultModel(harness)
        val id = model?.id ?: harness.default_model
        return HarnessSelection(provider = harness.id, model = id, effort = defaultEffort(harness, model), provider_options = defaultOptions(harness, id))
    }

    /**
     * Once a conversation has started, its provider is fixed, and model and
     * effort only change where the harness allows it between turns.
     */
    fun locked(card: Card, hasMessages: Boolean = false): Boolean =
        card.initial_prompt_sent_at.isNotEmpty() || Runtimes.isActive(card.runtime) || hasMessages

    fun canChange(harness: Harness?, capability: String, locked: Boolean): Boolean =
        !locked || harness?.capabilities.orEmpty().any { it.id == capability && it.level == "between-turns" }

    fun optionEnabled(option: ProviderOption, locked: Boolean): Boolean = !locked || option.mutable

    const val MODEL_SELECTION = "model-selection"
    const val EFFORT_SELECTION = "effort-selection"

    /**
     * The request selection for a send: [draft], else the card's agent. A
     * gap is filled from the card (an empty effort is [DEFAULT_EFFORT]).
     * A [locked] (started) conversation keeps its provider; a draft for
     * another provider sends the card's agent. With the conversation
     * machine's [harnesses] known, a locked conversation also keeps the
     * model, effort, and immutable options its harness does not let change
     * between turns, and the result is [validated]. An empty catalog counts
     * as unknown.
     */
    fun forSend(draft: HarnessSelection?, card: Card, harnesses: List<Harness>? = null, locked: Boolean = locked(card)): HarnessSelection {
        val agent = HarnessSelection(card.provider, card.model, card.effort, card.provider_options)
        if (draft == null || draft.provider.isEmpty()) return agent
        if (locked && card.provider.isNotEmpty() && draft.provider != card.provider) return agent
        val catalog = harnesses?.takeIf { it.isNotEmpty() }
        val harness = catalog?.let { harness(it, draft.provider) }
        if (locked && catalog != null && harness == null) return agent
        var model = draft.model.ifEmpty { if (draft.provider == card.provider) card.model else "" }
        var effort = draft.effort.ifEmpty { DEFAULT_EFFORT }
        var options = draft.provider_options
        if (locked && harness != null) {
            if (!canChange(harness, MODEL_SELECTION, locked = true)) model = card.model
            if (!canChange(harness, EFFORT_SELECTION, locked = true)) effort = card.effort
            for (option in harness.options) {
                if (option.mutable) continue
                options = card.provider_options[option.id]?.let { options + (option.id to it) } ?: (options - option.id)
            }
        }
        val chosen = HarnessSelection(draft.provider, model, effort, options)
        if (catalog == null) return chosen
        val checked = validated(chosen, catalog)
        // An effort the harness keeps for the conversation stays as the card has it.
        return if (locked && !canChange(harness, EFFORT_SELECTION, locked = true)) checked.copy(effort = card.effort) else checked
    }

    /** A conversation's composer starts from the card's agent, with options validated against the catalog. */
    fun initial(card: Card?, harnesses: List<Harness>): HarnessSelection {
        val provider = card?.provider?.ifEmpty { null } ?: harnesses.firstOrNull()?.id.orEmpty()
        val harness = harness(harnesses, provider)
        val model = card?.model?.ifEmpty { null } ?: harness?.default_model.orEmpty()
        val saved = card?.provider_options.orEmpty()
        return HarnessSelection(provider, model, card?.effort.orEmpty(), if (harness == null) saved else normalizedOptions(harness, model, saved))
    }

    /** [selection] with its gaps filled: no provider or model means the card's agent; options are re-validated. */
    fun filled(selection: HarnessSelection?, card: Card?, harnesses: List<Harness>): HarnessSelection {
        if (selection == null || selection.provider.isEmpty() || selection.model.isEmpty()) return initial(card, harnesses)
        val harness = harness(harnesses, selection.provider) ?: return selection
        return selection.copy(provider_options = normalizedOptions(harness, selection.model, selection.provider_options))
    }

    /**
     * The composer's [draft] choice while it still differs from [card]'s
     * agent; null once the conversation runs with it, or once a started
     * conversation is on another provider than the draft names. The
     * composer then follows the card again, including changes made elsewhere.
     * [DEFAULT_EFFORT] and an empty effort count as the same.
     */
    fun pending(draft: HarnessSelection?, card: Card, harnesses: List<Harness>): HarnessSelection? {
        draft ?: return null
        if (locked(card) && card.provider.isNotEmpty() && draft.provider.isNotEmpty() && draft.provider != card.provider) return null
        val chosen = filled(draft, card, harnesses)
        val current = initial(card, harnesses)
        val same = chosen.provider == current.provider && chosen.model == current.model &&
            plainEffort(chosen.effort) == plainEffort(current.effort) && chosen.provider_options == current.provider_options
        return draft.takeIf { !same }
    }

    private fun plainEffort(effort: String): String = if (effort == DEFAULT_EFFORT) "" else effort

    fun supports(harnesses: List<Harness>, selection: HarnessSelection): Boolean =
        harness(harnesses, selection.provider)?.let { model(it, selection.model) != null } == true
}

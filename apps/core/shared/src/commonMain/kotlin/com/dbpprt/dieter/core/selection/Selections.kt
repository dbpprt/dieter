package com.dbpprt.dieter.core.selection

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.core.board.Runtimes

/**
 * Provider, model, effort, and option resolution against a machine's harness
 * catalog. Ported from the Apple `HarnessSelection`/`ProviderOptionValues`,
 * which validate more strictly than Android's `ProviderOptions`.
 */
object Selections {
    /** The explicit effort that stops the daemon from inheriting one the new model may not support. */
    const val DEFAULT_EFFORT = "default"

    fun harness(harnesses: List<Harness>, provider: String): Harness? = harnesses.firstOrNull { it.id == provider }

    fun model(harness: Harness, id: String): HarnessModel? = harness.models.firstOrNull { it.id == id }

    /** Efforts [model] accepts: the harness options, narrowed to the model's list when it has one. */
    fun efforts(harness: Harness, model: HarnessModel?): List<String> =
        harness.effort?.options.orEmpty().map { it.id }.filter { model == null || model.efforts.isEmpty() || it in model.efforts }

    /**
     * A valid selection for [saved]: the harness (else the first), the model
     * (else its default, else the first), and an effort that model accepts.
     * With [allowServerDefault], an empty provider means "let the daemon choose".
     */
    fun resolve(saved: HarnessSelection, harnesses: List<Harness>, allowServerDefault: Boolean = false): HarnessSelection? {
        if (allowServerDefault && saved.provider.isEmpty()) return HarnessSelection()
        val harness = harness(harnesses, saved.provider) ?: harnesses.firstOrNull() ?: return null
        val model = model(harness, saved.model) ?: model(harness, harness.default_model) ?: harness.models.firstOrNull()
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
            when (option.type.lowercase()) {
                "bool", "boolean" -> value = value.lowercase().takeIf { it == "true" || it == "false" } ?: option.default_value
                "enum", "select" -> if (option.choices.none { it.value_ == value }) value = option.default_value
            }
            values[option.id] = value
        }
        return values
    }

    /** Valid values for the options that apply to [model]; options the harness does not advertise are dropped. */
    fun normalizedOptions(harness: Harness?, model: String, saved: Map<String, String>): Map<String, String> {
        val applicable = options(harness, model).mapTo(HashSet()) { it.id }
        return resolvedOptions(harness, saved).filterKeys { it in applicable }
    }

    fun defaultOptions(harness: Harness?, model: String? = null): Map<String, String> =
        normalizedOptions(harness, model ?: harness?.default_model.orEmpty(), emptyMap())

    /** Choosing another model resets effort to the explicit default and re-validates options. */
    fun selectingModel(current: HarnessSelection, harness: Harness?, model: String): HarnessSelection =
        current.copy(model = model, effort = DEFAULT_EFFORT, provider_options = normalizedOptions(harness, model, current.provider_options))

    /** Choosing another provider starts from its defaults. */
    fun selectingProvider(harness: Harness): HarnessSelection =
        HarnessSelection(provider = harness.id, model = harness.default_model, effort = DEFAULT_EFFORT, provider_options = defaultOptions(harness))

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

    /** The request selection for a send: the composer's choice, falling back to the card's. */
    fun forSend(draft: HarnessSelection?, card: Card): HarnessSelection {
        if (draft == null || draft.provider.isEmpty()) {
            return HarnessSelection(card.provider, card.model, card.effort, card.provider_options)
        }
        return HarnessSelection(
            provider = draft.provider,
            model = draft.model.ifEmpty { card.model },
            effort = draft.effort.ifEmpty { DEFAULT_EFFORT },
            provider_options = draft.provider_options,
        )
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

    fun supports(harnesses: List<Harness>, selection: HarnessSelection): Boolean =
        harness(harnesses, selection.provider)?.let { model(it, selection.model) != null } == true
}

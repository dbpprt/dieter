package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Harness

internal fun conversationSelectionLocked(card: Card?): Boolean =
    card?.initialPromptSentAt?.isNotBlank() == true ||
        card?.runtime?.lowercase() in setOf("starting", "running", "working", "streaming", "cancelling")

internal fun conversationSettingEnabled(harness: Harness?, locked: Boolean, capability: String): Boolean =
    !locked || harness?.capabilitiesList.orEmpty().any {
        it.id == capability && it.level == "between-turns"
    }

/** The next message owns its selection; live card updates describe an already running turn. */
internal data class ConversationComposerSelection(
    val provider: String,
    val model: String,
    val effort: String,
    val providerOptions: Map<String, String>,
) {
    fun selectingModel(id: String, harness: Harness?): ConversationComposerSelection = copy(
        model = id,
        // Empty means inherit on the wire. Selecting Default must instead clear
        // a prior explicit effort even when switching back to the current model.
        effort = "default",
        providerOptions = providerOptionValues(harness, providerOptions, id),
    )

    fun fillingMissingSelection(card: Card?, harnesses: List<Harness>): ConversationComposerSelection {
        if (provider.isBlank() || model.isBlank()) return initial(card, harnesses)
        val harness = harnesses.firstOrNull { it.id == provider } ?: return this
        return copy(providerOptions = providerOptionValues(harness, providerOptions, model))
    }

    companion object {
        fun initial(card: Card?, harnesses: List<Harness>): ConversationComposerSelection {
            val provider = card?.provider?.takeIf(String::isNotBlank) ?: harnesses.firstOrNull()?.id.orEmpty()
            val harness = harnesses.firstOrNull { it.id == provider }
            val model = card?.model?.takeIf(String::isNotBlank) ?: harness?.defaultModel.orEmpty()
            return ConversationComposerSelection(
                provider = provider,
                model = model,
                effort = card?.effort.orEmpty(),
                providerOptions = if (harness == null) card?.providerOptionsMap.orEmpty()
                    else providerOptionValues(harness, card?.providerOptionsMap.orEmpty(), model),
            )
        }

        fun forProvider(harness: Harness): ConversationComposerSelection = ConversationComposerSelection(
            provider = harness.id,
            model = harness.defaultModel,
            effort = "default",
            providerOptions = providerOptionValues(harness),
        )
    }
}

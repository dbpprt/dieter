package com.dbpprt.dieter.ui

import com.dbpprt.dieter.settings.ConversationCreationPreferences
import com.dbpprt.dieter.v1.Harness

internal data class ResolvedConversationCreationPreferences(
    val provider: String,
    val model: String,
    val effort: String,
    val workspaceMode: ConversationWorkspaceMode,
)

internal fun resolveConversationCreationPreferences(
    saved: ConversationCreationPreferences,
    harnesses: List<Harness>,
): ResolvedConversationCreationPreferences {
    val harness = harnesses.firstOrNull { it.id == saved.provider } ?: harnesses.firstOrNull()
        ?: return ResolvedConversationCreationPreferences(
            provider = "",
            model = "",
            effort = "",
            workspaceMode = ConversationWorkspaceMode.resolve(saved.workspaceMode),
        )
    val model = harness.modelsList.firstOrNull { it.id == saved.model }
        ?: harness.modelsList.firstOrNull { it.id == harness.defaultModel }
        ?: harness.modelsList.firstOrNull()
    val effortOptions = model?.let { harness.effortOptionsFor(it.id) }.orEmpty()
    val hasSavedAgentSelection = saved.provider.isNotBlank() || saved.model.isNotBlank() || saved.effort.isNotBlank()
    val effort = when {
        !hasSavedAgentSelection -> ""
        harness.id == saved.provider && model?.id == saved.model &&
            (saved.effort.isBlank() || effortOptions.any { it.id == saved.effort }) -> saved.effort
        model != null && model.defaultEffort.isNotBlank() &&
            (effortOptions.isEmpty() || effortOptions.any { it.id == model.defaultEffort }) -> model.defaultEffort
        else -> effortOptions.firstOrNull()?.id.orEmpty()
    }
    return ResolvedConversationCreationPreferences(
        provider = harness.id,
        model = model?.id.orEmpty(),
        effort = effort,
        workspaceMode = ConversationWorkspaceMode.resolve(saved.workspaceMode),
    )
}

internal fun optimisticQuickTaskTitle(story: String): String {
    val firstLine = story.lineSequence().firstOrNull().orEmpty().trim()
    if (firstLine.length <= 80) return firstLine
    val prefix = firstLine.take(80)
    val boundary = prefix.lastIndexOf(' ')
    return if (boundary >= 40) prefix.take(boundary) else prefix
}

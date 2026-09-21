package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.settings.ConversationCreationPreferences
import com.dbpprt.dieter.v1.Checkout
import com.dbpprt.dieter.v1.Harness

internal data class ResolvedConversationCreationPreferences(
    val provider: String,
    val model: String,
    val effort: String,
    val workspaceMode: ConversationWorkspaceMode,
)

internal fun harnessCatalogMatchesProject(
    projectId: String,
    catalogEndpointId: String?,
    projectReplicas: Map<String, ProjectReplica>,
): Boolean {
    if (projectId.isBlank() || catalogEndpointId.isNullOrBlank()) return false
    return projectReplicas[projectId]?.endpointId?.let(catalogEndpointId::equals) ?: true
}

internal fun harnessCatalogSupportsSelection(
    harnesses: List<Harness>,
    provider: String,
    model: String,
): Boolean = harnesses.firstOrNull { it.id == provider }
    ?.modelsList
    ?.any { it.id == model }
    ?: false

internal fun preferredCreationCheckout(
    checkouts: List<Checkout>,
    selectedCheckoutId: String,
    catalogEndpointId: String?,
    endpointIdsByDaemon: Map<String, String>,
    projectReplicaEndpointId: String?,
): Checkout? {
    val available = checkouts.filterNot { it.detached }
    available.firstOrNull { it.id == selectedCheckoutId }?.let { return it }
    catalogEndpointId?.let { endpointId ->
        available.firstOrNull { endpointIdsByDaemon[it.daemonId] == endpointId }?.let { return it }
    }
    if (available.size == 1) return available.first()
    projectReplicaEndpointId?.let { endpointId ->
        available.firstOrNull { endpointIdsByDaemon[it.daemonId] == endpointId }?.let { return it }
    }
    return null
}

internal fun creationCheckoutNeedsPreparation(
    checkoutId: String?,
    selectedCheckoutId: String,
    checkoutEndpointId: String?,
    catalogEndpointId: String?,
): Boolean = checkoutId != null &&
    (selectedCheckoutId != checkoutId || checkoutEndpointId != catalogEndpointId)

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

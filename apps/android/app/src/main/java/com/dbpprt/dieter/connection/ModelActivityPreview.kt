package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.Subagent

internal data class ModelActivity(
    val cardTitle: String,
    val modelLabel: String,
    val detail: String,
)

internal data class ModelActivityPreview(
    val rows: List<ModelActivity>,
    val totalCount: Int,
) {
    val overflowCount: Int = (totalCount - rows.size).coerceAtLeast(0)
}

/**
 * Produces a deliberately small, notification-safe view of live work. The
 * model projection already contains human-readable plan and subagent activity,
 * so raw tool arguments never need to be exposed on the lock screen.
 */
internal fun modelActivityPreview(
    activeCardsById: Map<String, Card>,
    conversations: Map<String, ConversationSnapshot>,
    maxRows: Int = 3,
): ModelActivityPreview {
    require(maxRows > 0) { "maxRows must be positive" }
    val activities = activeCardsById.values.flatMap { card ->
        currentModelActivities(card, conversations[card.id])
    }
    return ModelActivityPreview(
        rows = activities.take(maxRows),
        totalCount = activities.size,
    )
}

internal fun currentModelActivities(card: Card, snapshot: ConversationSnapshot?): List<ModelActivity> {
    val cardTitle = notificationText(card.title.ifBlank { "Dieter conversation" }, 42)
    val conversation = snapshot?.conversation
    val activeTask = conversation?.taskPlansList.orEmpty()
        .asReversed()
        .flatMap { plan -> plan.phasesList.asReversed() }
        .flatMap { phase -> phase.tasksList.asReversed() }
        .firstOrNull { task -> task.status.equals("in_progress", ignoreCase = true) }
        ?.let { task -> task.activeForm.ifBlank { task.content } }
        .orEmpty()
    val currentTool = conversation?.pendingToolsList?.lastOrNull()?.toolName.orEmpty()
    val mainDetail = listOfNotNull(
        activeTask.takeIf(String::isNotBlank),
        currentTool.takeIf(String::isNotBlank)?.let(::toolActivity),
    ).joinToString(" · ").ifBlank {
        card.summary.ifBlank { "Working on your request" }
    }

    return buildList {
        add(
            ModelActivity(
                cardTitle = cardTitle,
                modelLabel = "Main model",
                detail = notificationText(mainDetail, 96),
            ),
        )
        conversation?.subagentsList.orEmpty()
            .filter(::isActiveSubagent)
            .forEach { subagent ->
                add(
                    ModelActivity(
                        cardTitle = cardTitle,
                        modelLabel = notificationText(subagentLabel(subagent), 34),
                        detail = notificationText(subagentActivity(subagent), 96),
                    ),
                )
            }
    }
}

private fun isActiveSubagent(subagent: Subagent): Boolean =
    subagent.status.equals("running", ignoreCase = true) || subagent.status.equals("pending", ignoreCase = true)

private fun subagentLabel(subagent: Subagent): String = subagent.name.ifBlank {
    subagent.agentType.ifBlank {
        subagent.assignment.ifBlank { subagent.task.ifBlank { "Subagent" } }
    }
}

private fun subagentActivity(subagent: Subagent): String = subagent.activity.ifBlank {
    subagent.currentTool.takeIf(String::isNotBlank)?.let(::toolActivity).orEmpty()
}.ifBlank {
    subagent.description.ifBlank {
        subagent.assignment.ifBlank { subagent.task.ifBlank { "Getting started" } }
    }
}

private fun toolActivity(toolName: String): String {
    val normalized = toolName.lowercase()
    return when {
        Regex("shell|bash|terminal|exec|command").containsMatchIn(normalized) -> "Running a command"
        Regex("apply.?patch|edit|replace|write").containsMatchIn(normalized) -> "Editing files"
        Regex("read|view.?file").containsMatchIn(normalized) -> "Reading files"
        Regex("grep|glob|search|find").containsMatchIn(normalized) -> "Searching the workspace"
        Regex("browser|navigate|click|screenshot").containsMatchIn(normalized) -> "Using the browser"
        else -> "Using ${humanizeToolName(toolName)}"
    }
}

private fun humanizeToolName(value: String): String = value
    .substringAfterLast('.')
    .removePrefix("tool-")
    .replace('_', ' ')
    .replace('-', ' ')
    .trim()
    .ifBlank { "a tool" }

private fun notificationText(value: String, maxLength: Int): String {
    val compact = value.replace(Regex("\\s+"), " ").trim()
    return if (compact.length <= maxLength) compact else compact.take(maxLength - 1).trimEnd() + "…"
}

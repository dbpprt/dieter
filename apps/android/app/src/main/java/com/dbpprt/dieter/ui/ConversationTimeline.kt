package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent

internal sealed interface ConversationTimelineItem {
    data class Part(val part: MessagePart) : ConversationTimelineItem
    data class Tools(val parts: List<MessagePart>) : ConversationTimelineItem
    data object Subagents : ConversationTimelineItem
}

private val taskPlanToolNames = setOf(
    "todowrite",
    "taskcreate",
    "taskupdate",
    "tasklist",
    "taskget",
    "todo",
    "board_task_plan",
    "update_plan",
)

/**
 * Preserves provider chronology while collapsing adjacent tool calls. Visible
 * model output closes the current group, so later calls cannot jump into an
 * earlier group at the start of the message.
 */
internal fun buildConversationTimeline(
    parts: List<MessagePart>,
    subagents: List<Subagent> = emptyList(),
    hasTaskPlan: Boolean = false,
    showReasoning: Boolean = false,
): List<ConversationTimelineItem> {
    val delegatedToolIds = subagents.mapNotNullTo(mutableSetOf()) {
        it.parentToolCallId.takeIf(String::isNotBlank)
    }
    val timeline = mutableListOf<ConversationTimelineItem>()
    val tools = mutableListOf<MessagePart>()
    var renderedSubagents = false

    fun flushTools() {
        if (tools.isEmpty()) return
        timeline += ConversationTimelineItem.Tools(tools.toList())
        tools.clear()
    }

    parts.forEach { part ->
        when (part.conversationPartPresentation(showReasoning)) {
            ConversationPartPresentation.TOOL -> {
                if (hasTaskPlan && part.normalizedToolName() in taskPlanToolNames) return@forEach
                if (part.toolCallId in delegatedToolIds) {
                    flushTools()
                    if (!renderedSubagents && subagents.isNotEmpty()) {
                        timeline += ConversationTimelineItem.Subagents
                        renderedSubagents = true
                    }
                } else {
                    tools += part
                }
            }
            ConversationPartPresentation.HIDDEN -> Unit
            else -> {
                flushTools()
                timeline += ConversationTimelineItem.Part(part)
            }
        }
    }
    flushTools()
    if (!renderedSubagents && subagents.isNotEmpty()) timeline += ConversationTimelineItem.Subagents
    return timeline
}

private fun MessagePart.normalizedToolName(): String = toolName
    .ifBlank { type.removePrefix("tool-") }
    .trim()
    .lowercase()
    .replace('-', '_')
    .replace(' ', '_')

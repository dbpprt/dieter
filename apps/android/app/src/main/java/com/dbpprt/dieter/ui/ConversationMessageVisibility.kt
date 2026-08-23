package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage

internal enum class ConversationPartPresentation {
    TOOL,
    TEXT,
    REASONING,
    FILE,
    FALLBACK_TEXT,
    HIDDEN,
}

/**
 * Transport streams create an assistant message at turn start, before it has
 * any user-visible parts. Keep that envelope in state so later deltas can
 * update it, but do not give it a row in the conversation yet.
 */
internal fun UiMessage.hasRenderableConversationContent(
    taskPlan: TaskPlan? = null,
    subagents: List<Subagent> = emptyList(),
    includeReasoning: Boolean = true,
): Boolean = taskPlan != null || subagents.isNotEmpty() || partsList.any {
    it.conversationPartPresentation(includeReasoning) != ConversationPartPresentation.HIDDEN
}

/**
 * One presentation policy is shared by message filtering and rendering. This
 * keeps explicitly hidden parts, especially reasoning, from falling through
 * to the generic text renderer.
 */
internal fun MessagePart.conversationPartPresentation(
    includeReasoning: Boolean,
): ConversationPartPresentation = when {
    type == "dynamic-tool" || type.startsWith("tool-") -> ConversationPartPresentation.TOOL
    type == "file" && (url.isNotBlank() || filename.isNotBlank()) -> ConversationPartPresentation.FILE
    type == "text" && text.isNotBlank() -> ConversationPartPresentation.TEXT
    type == "reasoning" && includeReasoning && text.isNotBlank() -> ConversationPartPresentation.REASONING
    type == "file" || type == "text" || type == "reasoning" || type == "step-start" ->
        ConversationPartPresentation.HIDDEN
    text.isNotBlank() -> ConversationPartPresentation.FALLBACK_TEXT
    else -> ConversationPartPresentation.HIDDEN
}

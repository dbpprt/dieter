package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.conversation.TurnFailure

/** Classification of message parts shared by every presentation. */
object Parts {
    fun isUser(message: UiMessage): Boolean = TurnFailure.isUser(message)

    fun isToolCall(part: MessagePart): Boolean = TurnFailure.isToolCall(part)

    /** The tool's name: explicit, else the part type after `tool-`. */
    fun toolName(part: MessagePart): String = part.tool_name.ifEmpty { part.type.takeIf { it.startsWith("tool-") }?.removePrefix("tool-").orEmpty() }

    fun isReasoning(part: MessagePart): Boolean = part.type.lowercase().let { it == "reasoning" || it == "thinking" }

    private val attentionStates = setOf("error", "failed", "failure", "denied", "rejected", "cancelled", "canceled")
    private val attentionWords = listOf("approval", "permission", "confirmation")

    /** An error, a denial, or a request for the user's decision. */
    fun needsAttention(part: MessagePart): Boolean {
        val state = part.state.lowercase()
        val type = part.type.lowercase()
        return part.error_text.isNotBlank() || state in attentionStates || "error" in state || "error" in type ||
            attentionWords.any { it in state || it in type }
    }

    /** A tool call waiting for approval or denied; it interrupts routine activity. */
    fun isApprovalTool(part: MessagePart): Boolean {
        val text = (part.state + " " + part.type).lowercase()
        return attentionWords.any { it in text } || "denied" in text || "rejected" in text
    }

    /** Tool calls (even failed ones) and quiet reasoning are routine activity; approvals are not. */
    fun isRoutineActivity(part: MessagePart): Boolean = when {
        isToolCall(part) -> !isApprovalTool(part)
        isReasoning(part) -> !needsAttention(part)
        else -> false
    }

    fun isFailure(part: MessagePart): Boolean = TurnFailure.isFailurePart(part)

    /**
     * Whether [part] is shown in the transcript. Failure diagnostics are
     * hidden because the turn-failure banner carries them; approvals stay.
     */
    fun isVisible(part: MessagePart, showReasoning: Boolean): Boolean = when {
        isToolCall(part) -> true
        isFailure(part) -> false
        needsAttention(part) -> true
        isReasoning(part) -> showReasoning && part.text.isNotBlank()
        part.type == "step-start" -> false
        part.type == "image" -> part.url.isNotEmpty() || part.data_.size > 0
        part.type == "file" || part.type == "attachment" -> true
        else -> part.text.isNotBlank()
    }

    fun isBlank(part: MessagePart): Boolean = part.text.isBlank() && part.data_.size == 0 && part.url.isEmpty() && part.filename.isEmpty()

    /** The text a "copy message" action copies: prose only, never tools, reasoning, or attachments. */
    fun copyText(message: UiMessage): String = message.parts.filter { part ->
        !isToolCall(part) && part.type.lowercase() !in setOf("reasoning", "thinking", "step-start", "file", "attachment", "image") && part.text.isNotEmpty()
    }.joinToString("\n\n") { it.text }
}

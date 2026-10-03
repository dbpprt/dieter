package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.conversation.TurnFailure
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Classification of message parts shared by every presentation. */
object Parts {
    fun isUser(message: UiMessage): Boolean = TurnFailure.isUser(message)

    fun isToolCall(part: MessagePart): Boolean = TurnFailure.isToolCall(part)

    /** The tool's name: explicit, else the part type after `tool-`. */
    fun toolName(part: MessagePart): String = part.tool_name.ifEmpty { part.type.takeIf { it.startsWith("tool-") }?.removePrefix("tool-").orEmpty() }

    fun isText(part: MessagePart): Boolean = part.type == "text"

    /** A file, attachment, or image the user or agent attached. */
    fun isAttachment(part: MessagePart): Boolean = part.type == "file" || part.type == "attachment" || part.type == "image"

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

    fun isFailure(part: MessagePart): Boolean = TurnFailure.isFailurePart(part)

    /**
     * Whether [part] is shown in the transcript. With [hideFailures] (the
     * message whose failure the turn-failure banner shows), failure
     * diagnostics are hidden because the banner carries them; elsewhere they
     * show as attention. Approvals and other attention parts always show,
     * even with reasoning hidden.
     */
    fun isVisible(part: MessagePart, showReasoning: Boolean, hideFailures: Boolean = true): Boolean = when {
        isToolCall(part) -> true
        hideFailures && isFailure(part) -> false
        needsAttention(part) -> true
        isReasoning(part) -> showReasoning && part.text.isNotBlank()
        part.type == "step-start" -> false
        part.type == "image" -> part.url.isNotEmpty() || part.data_.size > 0
        part.type == "file" || part.type == "attachment" -> true
        else -> part.text.isNotBlank()
    }

    fun isBlank(part: MessagePart): Boolean = part.text.isBlank() && part.data_.size == 0 && part.url.isEmpty() && part.filename.isEmpty()

    private val uncopied = setOf("reasoning", "thinking", "step-start", "file", "attachment", "image")

    /** Prose a "copy message" action copies: never tools, reasoning, steps, or attachments, and never empty. */
    fun isCopyable(part: MessagePart): Boolean = !isToolCall(part) && part.type.lowercase() !in uncopied && part.text.isNotEmpty()

    /** The message has prose to copy. */
    fun isCopyable(message: UiMessage): Boolean = message.parts.any { isCopyable(it) }

    /** The text a "copy message" action copies: prose only, never tools, reasoning, or attachments. */
    fun copyText(message: UiMessage): String = copyText(listOf(message))

    /** One row's copy text: every prose part of [messages], as written, separated by a blank line. */
    fun copyText(messages: List<UiMessage>): String = messages.flatMap { it.parts }.filter { isCopyable(it) }.joinToString("\n\n") { it.text }
}

/** A message's `metadata_json`, parsed one way for every reader. */
object MessageMetadata {
    /** The metadata object; null when absent, malformed, or not a JSON object. */
    fun of(message: UiMessage): JsonObject? {
        if (message.metadata_json.size == 0) return null
        return runCatching { Json.parseToJsonElement(message.metadata_json.utf8()) as? JsonObject }.getOrNull()
    }

    /** A string member of [metadata]; null when it is missing or not a string. */
    fun string(metadata: JsonObject?, key: String): String? = (metadata?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** When the message was written, from its `createdAt`. */
    fun createdAt(message: UiMessage): Instant? = Timestamps.parse(string(of(message), "createdAt"))
}

package com.dbpprt.dieter.core.conversation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.UiMessage

/** A failed turn: what to show, the full log, and the request to retry. */
data class TurnFailure(
    val summary: String,
    val log: String,
    val failedMessageId: String?,
    /** The last user request before the failure; empty when there is nothing to retry. */
    val retryParts: List<MessagePart>,
) {
    companion object {
        const val FALLBACK_LOG = "The harness turn failed without producing diagnostic output."
        const val FALLBACK_SUMMARY = "The harness exited unexpectedly."
        private val prefix = Regex("^turn failed\\s*(—|:|-)\\s*", RegexOption.IGNORE_CASE)

        fun isUser(message: UiMessage) = message.role.equals("user", ignoreCase = true) || message.role.equals("human", ignoreCase = true)

        fun isToolCall(part: MessagePart): Boolean {
            val type = part.type.lowercase()
            return type == "tool" || type == "tool_call" || type == "dynamic-tool" || type.startsWith("tool-")
        }

        /** A diagnostic part: an error state, or error text outside a tool call. */
        fun isFailurePart(part: MessagePart): Boolean =
            part.state.trim().equals("error", ignoreCase = true) || (part.error_text.isNotBlank() && !isToolCall(part))

        private fun isRetryable(part: MessagePart): Boolean = when (part.type) {
            "text" -> part.text.isNotBlank()
            "file", "attachment", "image" -> part.url.isNotEmpty() || part.data_.size > 0
            else -> false
        }

        /** The failure of the latest turn, when the conversation or card reports "failed". */
        fun resolve(messages: List<UiMessage>, conversationStatus: String?, cardRuntime: String?): TurnFailure? {
            val failed = listOf(conversationStatus, cardRuntime).any { it?.trim()?.lowercase() == "failed" }
            if (!failed) return null
            val failedIndex = messages.indexOfLast { !isUser(it) && it.parts.any(::isFailurePart) }
            val log = if (failedIndex < 0) "" else messages[failedIndex].parts.filter(::isFailurePart)
                .map { it.error_text.ifBlank { it.text }.trim() }.filter { it.isNotEmpty() }.joinToString("\n\n")
            val searchEnd = if (failedIndex < 0) messages.size else failedIndex
            val request = messages.take(searchEnd).lastOrNull { isUser(it) && it.parts.any(::isRetryable) }
            return TurnFailure(summary(log), log.ifEmpty { FALLBACK_LOG }, messages.getOrNull(failedIndex)?.id, request?.parts.orEmpty())
        }

        fun summary(log: String): String {
            val line = log.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: return FALLBACK_SUMMARY
            val stripped = line.replace(prefix, "").trim().ifEmpty { return FALLBACK_SUMMARY }
            return if (stripped.length > 180) stripped.take(179).trimEnd() + "…" else stripped
        }
    }
}

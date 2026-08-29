package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.UiMessage

internal data class ConversationTurnFailure(
    val summary: String,
    val log: String,
    val retryParts: List<MessagePart>,
)

internal fun resolveConversationTurnFailure(
    messages: List<UiMessage>,
    conversationStatus: String,
    cardRuntime: String,
): ConversationTurnFailure? {
    if (listOf(conversationStatus, cardRuntime).none { it.trim().equals("failed", ignoreCase = true) }) return null

    val failedMessageIndex = messages.indexOfLast { message ->
        !message.role.equals("user", ignoreCase = true) &&
            !message.role.equals("human", ignoreCase = true) &&
            message.partsList.any(MessagePart::isTurnFailurePart)
    }
    val diagnostic = failedMessageIndex.takeIf { it >= 0 }
        ?.let(messages::get)
        ?.partsList
        ?.filter(MessagePart::isTurnFailurePart)
        ?.mapNotNull { part ->
            part.errorText.ifBlank { part.text }.trim().takeIf(String::isNotEmpty)
        }
        ?.joinToString("\n\n")
        .orEmpty()
    val log = diagnostic.ifBlank { "The harness turn failed without producing diagnostic output." }
    val retryEnd = failedMessageIndex.takeIf { it >= 0 } ?: messages.size
    val retryParts = messages.subList(0, retryEnd).asReversed().firstOrNull { message ->
        (message.role.equals("user", ignoreCase = true) || message.role.equals("human", ignoreCase = true)) &&
            message.partsList.any(MessagePart::isRetryableTurnPart)
    }?.partsList.orEmpty()

    return ConversationTurnFailure(
        summary = conciseTurnFailureSummary(log),
        log = log,
        retryParts = retryParts,
    )
}

internal fun MessagePart.isTurnFailurePart(): Boolean =
    state.trim().equals("error", ignoreCase = true) ||
        (errorText.isNotBlank() && type != "dynamic-tool" && !type.startsWith("tool-"))

private fun MessagePart.isRetryableTurnPart(): Boolean = when (type.lowercase()) {
    "text" -> text.isNotBlank()
    "file", "attachment", "image" -> url.isNotBlank() || data.size() > 0
    else -> false
}

private fun conciseTurnFailureSummary(log: String): String {
    var line = log.lineSequence().map(String::trim).firstOrNull(String::isNotEmpty)
        ?: "The harness exited unexpectedly."
    listOf("Turn failed — ", "Turn failed: ", "Turn failed - ").firstOrNull {
        line.startsWith(it, ignoreCase = true)
    }?.let { line = line.drop(it.length).trim() }
    if (line.length > 180) line = line.take(179).trimEnd() + "…"
    return line.ifBlank { "The harness exited unexpectedly." }
}

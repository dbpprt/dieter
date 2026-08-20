package com.dbpprt.nauclio.connection

import com.dbpprt.nauclio.v1.CreateConversationRequest
import com.dbpprt.nauclio.v1.MessagePart
import com.dbpprt.nauclio.v1.UiMessage

internal fun optimisticChatMessage(request: CreateConversationRequest, messageId: String): UiMessage? {
    if (request.deferStart) return null
    val parts = buildList {
        request.prompt.trim().takeIf(String::isNotBlank)?.let { prompt ->
            add(MessagePart.newBuilder().setType("text").setText(prompt).build())
        }
        addAll(request.attachmentsList)
    }
    if (parts.isEmpty()) return null
    return UiMessage.newBuilder()
        .setId(messageId)
        .setRole("user")
        .addAllParts(parts)
        .build()
}

internal fun resolveConversationId(
    conversationId: String?,
    resolutions: Map<String, String>,
): String? = conversationId?.let { resolutions[it] ?: it }

package com.dbpprt.dieter.connection

import com.dbpprt.dieter.data.AndroidOutboxEntry
import com.dbpprt.dieter.data.OutboxKind
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.UiMessage

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

internal fun optimisticConversationId(entry: AndroidOutboxEntry): String = entry.serverId ?: entry.optimisticId

internal fun optimisticInitialMessageId(entry: AndroidOutboxEntry): String? {
    if (entry.kind != OutboxKind.CREATE_CHAT) return null
    val request = runCatching { CreateConversationRequest.parseFrom(entry.request) }.getOrNull() ?: return null
    return optimisticChatMessage(request, "${entry.optimisticId}_initial")?.id
}

/**
 * Keeps durable local sends visible while a foreground or background stream is
 * still catching up with the unary mutation response.
 */
internal fun overlayOptimisticMessages(
    snapshot: ConversationSnapshot,
    entries: List<AndroidOutboxEntry>,
): ConversationSnapshot {
    val cardId = snapshot.detail.card.id.ifBlank { snapshot.conversation.cardId }
    if (cardId.isBlank()) return snapshot
    val conversation = snapshot.conversation.toBuilder()
    var changed = false
    entries.forEach { entry ->
        val optimistic = when (entry.kind) {
            OutboxKind.SEND_MESSAGE -> {
                val request = runCatching { SendMessageRequest.parseFrom(entry.request) }.getOrNull()
                    ?: return@forEach
                if (request.cardId != cardId || snapshot.conversation.queueList.any { it.id == entry.optimisticId }) {
                    return@forEach
                }
                UiMessage.newBuilder()
                    .setId(entry.optimisticId)
                    .setRole("user")
                    .addAllParts(request.partsList)
                    .build()
            }
            OutboxKind.CREATE_CHAT -> {
                if (optimisticConversationId(entry) != cardId) return@forEach
                val request = runCatching { CreateConversationRequest.parseFrom(entry.request) }.getOrNull()
                    ?: return@forEach
                optimisticChatMessage(request, "${entry.optimisticId}_initial") ?: return@forEach
            }
            OutboxKind.CREATE_CARD -> return@forEach
        }
        val alreadyVisible = conversation.messagesList.any { message ->
            message.id == optimistic.id ||
                entry.kind == OutboxKind.CREATE_CHAT && message.isUserMessage()
        }
        if (!alreadyVisible) {
            conversation.addMessages(optimistic)
            changed = true
        }
    }
    return if (changed) snapshot.toBuilder().setConversation(conversation).build() else snapshot
}

/** True only once the accepted mutation is represented by durable sync data. */
internal fun outboxEntryIsSynced(
    entry: AndroidOutboxEntry,
    cardIds: Set<String>,
    conversations: List<ConversationSnapshot>,
): Boolean {
    val serverId = entry.serverId ?: return false
    return when (entry.kind) {
        OutboxKind.CREATE_CARD -> serverId in cardIds
        OutboxKind.CREATE_CHAT -> {
            if (serverId !in cardIds) return false
            val request = runCatching { CreateConversationRequest.parseFrom(entry.request) }.getOrNull()
                ?: return false
            if (optimisticChatMessage(request, "${entry.optimisticId}_initial") == null) return true
            conversations
                .firstOrNull { it.detail.card.id == serverId || it.conversation.cardId == serverId }
                ?.conversation
                ?.messagesList
                ?.any(UiMessage::isUserMessage) == true
        }
        OutboxKind.SEND_MESSAGE -> {
            val request = runCatching { SendMessageRequest.parseFrom(entry.request) }.getOrNull()
                ?: return false
            conversations
                .firstOrNull { it.detail.card.id == request.cardId || it.conversation.cardId == request.cardId }
                ?.conversation
                ?.let { conversation ->
                    conversation.messagesList.any { it.id == serverId } ||
                        conversation.queueList.any { it.id == serverId }
                } == true
        }
    }
}

private fun UiMessage.isUserMessage(): Boolean =
    role.equals("user", ignoreCase = true) || role.equals("human", ignoreCase = true)

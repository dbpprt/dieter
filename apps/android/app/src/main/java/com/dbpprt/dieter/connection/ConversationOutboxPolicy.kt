package com.dbpprt.dieter.connection

import com.dbpprt.dieter.data.AndroidOutboxEntry
import com.dbpprt.dieter.data.OutboxKind
import com.dbpprt.dieter.data.OutboxState
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.StartCardRequest
import com.dbpprt.dieter.v1.UiMessage
import io.grpc.Status

internal fun isServerConversationId(id: String): Boolean = !id.startsWith("local_")

internal fun outboxFailureIsPermanent(error: Throwable): Boolean = when (Status.fromThrowable(error).code) {
    Status.Code.NOT_FOUND,
    Status.Code.INVALID_ARGUMENT,
    Status.Code.PERMISSION_DENIED,
    Status.Code.FAILED_PRECONDITION,
    -> true
    else -> false
}

internal fun readableRpcError(error: Throwable): String {
    val status = Status.fromThrowable(error)
    val message = status.description
        ?.replace(Regex("[\\r\\n\\t]+"), " ")
        ?.replace(Regex("(?i)bearer\\s+[^ ]+"), "Bearer [redacted]")
        ?.trim()
        ?.take(500)
        .orEmpty()
    return if (message.isBlank()) "gRPC ${status.code}" else "gRPC ${status.code}: $message"
}

internal fun nextOutboxEntry(
    entries: List<AndroidOutboxEntry>,
    endpointId: String,
    nowMillis: Long = System.currentTimeMillis(),
): AndroidOutboxEntry? = entries.firstOrNull {
    it.endpointId == endpointId &&
        it.serverId == null &&
        it.state != OutboxState.FAILED &&
        (it.nextAttemptAtMillis == null || it.nextAttemptAtMillis <= nowMillis)
}

internal fun nextOutboxEndpoint(
    entries: List<AndroidOutboxEntry>,
    currentEndpointId: String,
    onlineEndpointIds: Set<String>,
    nowMillis: Long = System.currentTimeMillis(),
): String? = entries.firstOrNull {
    it.endpointId != currentEndpointId &&
        it.endpointId in onlineEndpointIds &&
        it.serverId == null &&
        it.state != OutboxState.FAILED &&
        (it.nextAttemptAtMillis == null || it.nextAttemptAtMillis <= nowMillis)
}?.endpointId

internal fun outboxBackoffMillis(attempts: Int): Long =
    (750L shl attempts.coerceAtMost(4)).coerceAtMost(15_000L)

internal fun retargetOutboxDependencies(
    entries: List<AndroidOutboxEntry>,
    optimisticId: String,
    serverId: String,
): List<AndroidOutboxEntry> = entries.map { entry ->
    if (entry.kind != OutboxKind.SEND_MESSAGE || entry.serverId != null) return@map entry
    val request = runCatching { SendMessageRequest.parseFrom(entry.request) }.getOrNull() ?: return@map entry
    if (request.cardId != optimisticId) entry
    else entry.copy(request = request.toBuilder().setCardId(serverId).build().toByteArray())
}

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

internal fun overlayPendingCardStarts(
    cards: List<Card>,
    boards: List<Board>,
    entries: List<AndroidOutboxEntry>,
): List<Card> {
    val pendingStarts = entries
        .filter { it.kind == OutboxKind.START_CARD && it.state != OutboxState.FAILED }
        .associateBy(AndroidOutboxEntry::optimisticId)
    if (pendingStarts.isEmpty()) return cards
    val boardsById = boards.associateBy(Board::getId)
    return cards.map { card ->
        if (card.initialPromptSentAt.isNotBlank() || card.id !in pendingStarts) return@map card
        val runningLane = boardsById[card.boardId]?.lanesList?.firstOrNull {
            it.id.equals("running", ignoreCase = true)
        }?.id ?: boardsById[card.boardId]?.lanesList?.firstOrNull {
            it.name.equals("running", ignoreCase = true)
        }?.id ?: return@map card
        card.toBuilder().setLane(runningLane).setRuntime("starting").build()
    }
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
            OutboxKind.START_CARD -> return@forEach
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
    startedCardIds: Set<String> = emptySet(),
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
        OutboxKind.START_CARD -> {
            val request = runCatching { StartCardRequest.parseFrom(entry.request) }.getOrNull()
                ?: return false
            request.cardId in startedCardIds
        }
    }
}

private fun UiMessage.isUserMessage(): Boolean =
    role.equals("user", ignoreCase = true) || role.equals("human", ignoreCase = true)

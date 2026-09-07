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
import com.google.protobuf.ByteString
import io.grpc.Status
import java.time.Instant

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

data class MachineOutboxSummary(
    val messageCount: Int,
    val changeCount: Int,
    val retrying: Boolean,
    val failed: Boolean,
) {
    val itemCount: Int get() = messageCount + changeCount

    val deliveryLabel: String
        get() {
            val noun = when {
                changeCount == 0 -> if (messageCount == 1) "message" else "messages"
                messageCount == 0 -> if (changeCount == 1) "change" else "changes"
                else -> if (itemCount == 1) "item" else "items"
            }
            val suffix = if (failed) "needs attention." else "delivers when it reconnects."
            return "$itemCount $noun queued — $suffix"
        }
}

internal fun machineOutboxSummaries(entries: List<AndroidOutboxEntry>): Map<String, MachineOutboxSummary> =
    entries.filter { it.serverId == null }
        .groupBy(AndroidOutboxEntry::endpointId)
        .mapValues { (_, pending) ->
            MachineOutboxSummary(
                messageCount = pending.count { it.kind == OutboxKind.SEND_MESSAGE },
                changeCount = pending.count { it.kind != OutboxKind.SEND_MESSAGE },
                retrying = pending.any { it.state == OutboxState.RETRYING },
                failed = pending.any { it.state == OutboxState.FAILED },
            )
        }

internal fun retargetOutboxEndpoints(
    entries: List<AndroidOutboxEntry>,
    cardProjects: Map<String, String>,
    projectEndpoints: Map<String, String>,
): List<AndroidOutboxEntry> = entries.map { entry ->
    if (entry.serverId != null) return@map entry
    val projectId = when (entry.kind) {
        OutboxKind.CREATE_CARD, OutboxKind.CREATE_CHAT ->
            runCatching { CreateConversationRequest.parseFrom(entry.request).projectId }.getOrNull()
        OutboxKind.SEND_MESSAGE ->
            runCatching { SendMessageRequest.parseFrom(entry.request).cardId }.getOrNull()?.let(cardProjects::get)
        OutboxKind.START_CARD ->
            runCatching { StartCardRequest.parseFrom(entry.request).cardId }.getOrNull()?.let(cardProjects::get)
    }
    val endpointId = projectId?.let(projectEndpoints::get).orEmpty()
    if (endpointId.isBlank() || endpointId == entry.endpointId) entry else entry.copy(endpointId = endpointId)
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

    data class Candidate(
        val entry: AndroidOutboxEntry,
        val message: UiMessage,
        val suppressWhenUserMessageExists: Boolean,
    )

    val ownedIds = mutableSetOf<String>()
    val candidates = entries.mapNotNull { entry ->
        val candidate = when (entry.kind) {
            OutboxKind.SEND_MESSAGE -> {
                val request = runCatching { SendMessageRequest.parseFrom(entry.request) }.getOrNull()
                    ?: return@mapNotNull null
                if (request.cardId != cardId) return@mapNotNull null
                ownedIds += entry.optimisticId
                if (snapshot.conversation.queueList.any { it.id == entry.optimisticId }) return@mapNotNull null
                Candidate(entry, UiMessage.newBuilder()
                    .setId(entry.optimisticId)
                    .setRole("user")
                    .setMetadataJson(optimisticMessageMetadata(entry.createdAtMillis))
                    .addAllParts(request.partsList)
                    .build(), false)
            }
            OutboxKind.CREATE_CHAT -> {
                if (optimisticConversationId(entry) != cardId) return@mapNotNull null
                val request = runCatching { CreateConversationRequest.parseFrom(entry.request) }.getOrNull()
                    ?: return@mapNotNull null
                val optimistic = optimisticChatMessage(request, "${entry.optimisticId}_initial")
                    ?: return@mapNotNull null
                ownedIds += optimistic.id
                Candidate(
                    entry,
                    optimistic.toBuilder()
                        .setMetadataJson(optimisticMessageMetadata(entry.createdAtMillis))
                        .build(),
                    true,
                )
            }
            OutboxKind.CREATE_CARD -> return@mapNotNull null
            OutboxKind.START_CARD -> return@mapNotNull null
        }
        candidate
    }
    if (ownedIds.isEmpty()) return snapshot

    val messages = snapshot.conversation.messagesList.filterNot { it.id in ownedIds }.toMutableList()
    candidates.sortedWith(compareBy<Candidate> { it.entry.createdAtMillis }.thenBy { it.entry.commandId })
        .forEach { candidate ->
            if (candidate.suppressWhenUserMessageExists && messages.any(UiMessage::isUserMessage)) return@forEach
            val insertionIndex = messages.indexOfFirst { message ->
                messageCreatedAtMillis(message)?.let { it > candidate.entry.createdAtMillis } == true
            }.let { if (it < 0) messages.size else it }
            messages.add(insertionIndex, candidate.message)
        }

    if (messages == snapshot.conversation.messagesList) return snapshot
    return snapshot.toBuilder()
        .setConversation(snapshot.conversation.toBuilder().clearMessages().addAllMessages(messages))
        .build()
}

private fun optimisticMessageMetadata(createdAtMillis: Long): ByteString =
    ByteString.copyFromUtf8("{\"createdAt\":\"${Instant.ofEpochMilli(createdAtMillis)}\"}")

private fun messageCreatedAtMillis(message: UiMessage): Long? = runCatching {
    val value = Regex("\"createdAt\"\\s*:\\s*\"([^\"]+)\"")
        .find(message.metadataJson.toStringUtf8())
        ?.groupValues
        ?.get(1)
        ?: return null
    Instant.parse(value).toEpochMilli()
}.getOrNull()

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

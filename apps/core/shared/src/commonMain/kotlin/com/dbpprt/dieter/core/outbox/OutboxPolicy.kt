package com.dbpprt.dieter.core.outbox

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.SendMessageRequest
import com.dbpprt.dieter.api.v1.StartCardRequest
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.journal.OutboxEntry
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.journal.OutboxState
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Duration
import kotlin.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/** Per-machine queue status for machine rows and banners. */
data class MachineOutboxSummary(
    val messageCount: Int,
    val changeCount: Int,
    val retrying: Boolean,
    val failed: Boolean,
    val failureMessage: String? = null,
) {
    val itemCount: Int get() = messageCount + changeCount

    /** The daemon's disk is full; delivery retries every minute. */
    val storageBlocked: Boolean get() = Failures.isInsufficientStorage(failureMessage)

    /** "3 messages queued — delivers when it reconnects." */
    val deliveryLabel: String
        get() {
            val noun = when {
                changeCount == 0 -> if (messageCount == 1) "message" else "messages"
                messageCount == 0 -> if (changeCount == 1) "change" else "changes"
                else -> if (itemCount == 1) "item" else "items"
            }
            val suffix = when {
                failed -> "needs attention."
                storageBlocked -> "free disk space on this machine; retries automatically every minute."
                else -> "delivers when it reconnects."
            }
            return "$itemCount $noun queued — $suffix"
        }
}

/**
 * Pure outbox rules shared by delivery, reconciliation, and presentation.
 * Ported from the Mac `DieterOutboxPolicy` and Android `ConversationOutboxPolicy`.
 */
object OutboxPolicy {
    const val LOCAL_PREFIX = "local_"

    val OutboxEntry.createsConversation: Boolean
        get() = kind == OutboxKind.OUTBOX_KIND_CREATE_CARD || kind == OutboxKind.OUTBOX_KIND_CREATE_CHAT

    val OutboxEntry.accepted: Boolean get() = server_id.isNotEmpty()

    fun isServerBacked(conversationId: String): Boolean = !conversationId.startsWith(LOCAL_PREFIX)

    fun localConversationId(commandId: String): String = LOCAL_PREFIX + commandId.replace("-", "")

    /**
     * The daemon gives an idempotent create the ID `c_` + the first 12 bytes of
     * SHA-256(client_id NUL command_id), so a streamed row can be correlated
     * before the unary reply arrives.
     */
    fun expectedConversationId(clientId: String, commandId: String): String? {
        val client = clientId.trim()
        val command = commandId.trim()
        if (client.isEmpty() || command.isEmpty() || client.length > 200 || command.length > 200) return null
        return "c_" + "$client\u0000$command".encodeUtf8().sha256().hex().take(24)
    }

    fun createRequest(entry: OutboxEntry): CreateConversationRequest? =
        if (entry.createsConversation) runCatching { CreateConversationRequest.ADAPTER.decode(entry.request) }.getOrNull() else null

    fun sendRequest(entry: OutboxEntry): SendMessageRequest? =
        if (entry.kind == OutboxKind.OUTBOX_KIND_SEND_MESSAGE) runCatching { SendMessageRequest.ADAPTER.decode(entry.request) }.getOrNull() else null

    fun startRequest(entry: OutboxEntry): StartCardRequest? =
        if (entry.kind == OutboxKind.OUTBOX_KIND_START_CARD) runCatching { StartCardRequest.ADAPTER.decode(entry.request) }.getOrNull() else null

    /** Every ID a conversation-creating entry may appear under. */
    fun conversationIds(entry: OutboxEntry): List<String> = buildList {
        add(entry.optimistic_id)
        if (entry.accepted) add(entry.server_id)
        if (entry.createsConversation) expectedConversationId(entry.client_id, entry.command_id)?.let(::add)
    }

    /** The daemon's ID for an unacknowledged create that sync already shows. */
    fun synchronizedConversationId(entry: OutboxEntry, visibleIds: Set<String>): String? {
        if (entry.accepted || !entry.createsConversation) return null
        return expectedConversationId(entry.client_id, entry.command_id)?.takeIf { it in visibleIds }
    }

    /** A create that asked to run immediately is only complete once its first turn was admitted. */
    fun creationRequiresStart(entry: OutboxEntry): Boolean {
        val request = createRequest(entry) ?: return false
        return !request.defer_start && (entry.kind == OutboxKind.OUTBOX_KIND_CREATE_CHAT || request.lane.equals("running", ignoreCase = true))
    }

    fun creationIsComplete(entry: OutboxEntry, card: Card): Boolean =
        !creationRequiresStart(entry) || card.initial_prompt_sent_at.isNotEmpty()

    /**
     * Next deliverable entry, trying [daemonIds] in order. Entries keep their
     * per-machine order, and a send waits for the create it depends on.
     */
    fun next(entries: List<OutboxEntry>, daemonIds: List<String>, now: Instant): OutboxEntry? =
        daemonIds.firstNotNullOfOrNull { daemonId ->
            entries.firstOrNull { entry ->
                entry.daemon_id == daemonId && deliverable(entry, entries) &&
                    (entry.next_attempt_at_millis == 0L || entry.next_attempt_at_millis <= now.toEpochMilliseconds())
            }
        }

    /** Time until the earliest scheduled retry on [daemonIds], or null when nothing waits. */
    fun nextRetryDelay(entries: List<OutboxEntry>, daemonIds: Set<String>, now: Instant): Duration? =
        entries.asSequence()
            .filter { it.daemon_id in daemonIds && deliverable(it, entries) && it.next_attempt_at_millis != 0L }
            .map { Instant.fromEpochMilliseconds(it.next_attempt_at_millis) - now }
            .minOrNull()
            ?.coerceAtLeast(Duration.ZERO)

    private fun deliverable(entry: OutboxEntry, entries: List<OutboxEntry>): Boolean =
        !entry.accepted && entry.state != OutboxState.OUTBOX_STATE_FAILED && !hasPendingCreation(entry, entries)

    /**
     * A follow-up to a conversation that is still being created must wait for
     * that create's acknowledgement, including while it retries or failed.
     */
    fun hasPendingCreation(entry: OutboxEntry, entries: List<OutboxEntry>): Boolean {
        val target = sendRequest(entry)?.card_id ?: startRequest(entry)?.card_id ?: return false
        return entries.any { other ->
            other.daemon_id == entry.daemon_id && !other.accepted && other.createsConversation && target in conversationIds(other)
        }
    }

    fun backoff(attempts: Int, lastError: String?): Duration =
        if (Failures.isInsufficientStorage(lastError)) Backoff.OUTBOX_STORAGE.initial else Backoff.OUTBOX.delay(attempts)

    /** Points undelivered sends and starts at the daemon's ID once a create was accepted. */
    fun retargetDependencies(entries: List<OutboxEntry>, from: String, to: String): List<OutboxEntry> = entries.map { entry ->
        if (entry.accepted) return@map entry
        sendRequest(entry)?.takeIf { it.card_id == from }?.let { request ->
            return@map entry.copy(request = SendMessageRequest.ADAPTER.encode(request.copy(card_id = to)).toByteString())
        }
        startRequest(entry)?.takeIf { it.card_id == from }?.let { request ->
            return@map entry.copy(
                request = StartCardRequest.ADAPTER.encode(request.copy(card_id = to)).toByteString(),
                optimistic_id = to,
            )
        }
        entry
    }

    /**
     * Replaces the optimistic row with the daemon's. When sync already shows
     * the server row, the optimistic one is dropped instead of duplicated.
     */
    fun retargetedCards(cards: List<Card>, from: String, to: String, authoritative: Card? = null): List<Card> {
        if (from == to) return cards
        if (cards.any { it.id == to }) {
            var keptServer = false
            return cards.mapNotNull { card ->
                when {
                    card.id == from -> null
                    card.id != to -> card
                    keptServer -> null
                    else -> card.also { keptServer = true }
                }
            }
        }
        var retargeted = false
        return cards.mapNotNull { card ->
            when {
                card.id != from -> card
                retargeted -> null
                else -> {
                    retargeted = true
                    if (authoritative?.id == to) authoritative else card.copy(id = to)
                }
            }
        }
    }

    /** The row shown for an undelivered or unsynchronized create. */
    fun optimisticCard(entry: OutboxEntry): Card? {
        val request = createRequest(entry) ?: return null
        val chat = entry.kind == OutboxKind.OUTBOX_KIND_CREATE_CHAT
        val created = Instant.fromEpochMilliseconds(entry.created_at_millis).toString()
        return Card(
            id = entry.server_id.ifEmpty { entry.optimistic_id },
            scope = if (chat) "chat" else "board",
            project_id = request.project_id,
            board_id = if (chat) "" else request.board_id,
            checkout_id = request.checkout_id,
            owner_daemon_id = entry.daemon_id,
            lane = request.lane,
            title = request.title,
            initial_prompt = request.prompt,
            provider = request.provider,
            model = request.model,
            effort = request.effort,
            provider_options = request.provider_options,
            label_ids = request.label_ids,
            workspace_mode = request.workspace_mode,
            workspace_branch = request.workspace_branch,
            workspace_base_branch = request.workspace_base_branch,
            workspace_base_remote = request.workspace_base_remote,
            remote_publish_mode = request.remote_publish_mode,
            runtime = if (entry.state == OutboxState.OUTBOX_STATE_FAILED) "failed" else "pending",
            created_at = created,
            updated_at = created,
            last_activity_at = created,
        )
    }

    /** The chat's first user message, shown until the transcript has one. */
    fun optimisticInitialMessage(entry: OutboxEntry): UiMessage? {
        if (entry.kind != OutboxKind.OUTBOX_KIND_CREATE_CHAT) return null
        val request = createRequest(entry) ?: return null
        if (request.defer_start) return null
        val parts = buildList {
            request.prompt.trim().takeIf { it.isNotEmpty() }?.let { add(MessagePart(type = "text", text = it)) }
            addAll(request.attachments)
        }
        if (parts.isEmpty()) return null
        return UiMessage(id = "${entry.optimistic_id}_initial", role = "user", parts = parts, metadata_json = createdAtMetadata(entry.created_at_millis))
    }

    /**
     * Overlays local sends at their chronological transcript position. A
     * failed send stays where it was made instead of jumping after newer turns.
     */
    fun overlayOptimisticMessages(snapshot: ConversationSnapshot, entries: List<OutboxEntry>): ConversationSnapshot {
        val conversation = snapshot.conversation ?: Conversation()
        val cardId = snapshot.detail?.card?.id?.ifEmpty { null } ?: conversation.card_id
        if (cardId.isEmpty()) return snapshot

        class Candidate(val entry: OutboxEntry, val message: UiMessage, val onlyWithoutUserMessage: Boolean)

        val owned = HashSet<String>()
        val candidates = mutableListOf<Candidate>()
        val queued = mutableListOf<Pair<OutboxEntry, SendMessageRequest>>()
        for (entry in entries) {
            when (entry.kind) {
                OutboxKind.OUTBOX_KIND_SEND_MESSAGE -> {
                    val request = sendRequest(entry)?.takeIf { it.card_id == cardId } ?: continue
                    owned += entry.optimistic_id
                    if (entry.placement == OutboxPlacement.OUTBOX_PLACEMENT_QUEUE && entry.state != OutboxState.OUTBOX_STATE_FAILED) {
                        queued += entry to request
                        continue
                    }
                    candidates += Candidate(
                        entry,
                        UiMessage(id = entry.optimistic_id, role = "user", parts = request.parts, metadata_json = createdAtMetadata(entry.created_at_millis)),
                        onlyWithoutUserMessage = false,
                    )
                }
                OutboxKind.OUTBOX_KIND_CREATE_CHAT -> {
                    if (cardId !in conversationIds(entry)) continue
                    val message = optimisticInitialMessage(entry) ?: continue
                    owned += message.id
                    candidates += Candidate(entry, message, onlyWithoutUserMessage = true)
                }
                else -> Unit
            }
        }
        if (owned.isEmpty()) return snapshot

        val queue = conversation.queue.filterNot { it.id in owned }.toMutableList()
        val queuedIds = queue.mapTo(HashSet()) { it.id }
        for ((entry, request) in queued.sortedWith(compareBy({ it.first.created_at_millis }, { it.first.command_id }))) {
            if (!queuedIds.add(entry.optimistic_id)) continue
            queue += QueuedMessage(
                id = entry.optimistic_id,
                parts = request.parts,
                created_at = Instant.fromEpochMilliseconds(entry.created_at_millis).toString(),
                selection = HarnessSelection(request.provider, request.model, request.effort, request.provider_options),
            )
        }
        // The daemon may already list a delivered send in its queue; never show it twice.
        val serverQueued = conversation.queue.mapTo(HashSet()) { it.id }
        val messages = conversation.messages.filterNot { it.id in owned }.toMutableList()
        for (candidate in candidates.sortedWith(compareBy({ it.entry.created_at_millis }, { it.entry.command_id }))) {
            if (candidate.message.id in serverQueued) continue
            if (candidate.onlyWithoutUserMessage && messages.any(::isUserMessage)) continue
            val index = messages.indexOfFirst { message ->
                messageCreatedAt(message)?.let { it.toEpochMilliseconds() > candidate.entry.created_at_millis } == true
            }.let { if (it < 0) messages.size else it }
            messages.add(index, candidate.message)
        }
        if (messages == conversation.messages && queue == conversation.queue) return snapshot
        return snapshot.copy(conversation = conversation.copy(messages = messages, queue = queue))
    }

    /** True once the accepted command is represented by durable sync data. */
    fun isSynced(entry: OutboxEntry, cards: Map<String, Card>, conversations: Map<String, ConversationSnapshot>): Boolean {
        val serverId = entry.server_id.ifEmpty { return false }
        return when (entry.kind) {
            OutboxKind.OUTBOX_KIND_CREATE_CARD -> cards[serverId]?.let { creationIsComplete(entry, it) } == true
            OutboxKind.OUTBOX_KIND_CREATE_CHAT -> {
                val card = cards[serverId] ?: return false
                if (!creationIsComplete(entry, card)) return false
                if (optimisticInitialMessage(entry) == null) return true
                // Without the tail the daemon's initial_prompt_sent_at is the evidence.
                val conversation = conversations[serverId]?.conversation ?: return card.initial_prompt_sent_at.isNotEmpty()
                conversation.messages.any(::isUserMessage)
            }
            OutboxKind.OUTBOX_KIND_SEND_MESSAGE -> {
                val cardId = sendRequest(entry)?.card_id ?: return false
                val conversation = conversations[cardId]?.conversation ?: return false
                conversation.messages.any { it.id == serverId } || conversation.queue.any { it.id == serverId }
            }
            OutboxKind.OUTBOX_KIND_START_CARD -> {
                val cardId = startRequest(entry)?.card_id ?: return false
                cards[cardId]?.initial_prompt_sent_at?.isNotEmpty() == true
            }
            else -> true
        }
    }

    fun summaries(entries: List<OutboxEntry>): Map<String, MachineOutboxSummary> =
        entries.filter { !it.accepted }.groupBy { it.daemon_id }.mapValues { (_, pending) ->
            MachineOutboxSummary(
                messageCount = pending.count { it.kind == OutboxKind.OUTBOX_KIND_SEND_MESSAGE },
                changeCount = pending.count { it.kind != OutboxKind.OUTBOX_KIND_SEND_MESSAGE },
                retrying = pending.any { it.state == OutboxState.OUTBOX_STATE_RETRYING },
                failed = pending.any { it.state == OutboxState.OUTBOX_STATE_FAILED },
                failureMessage = pending.lastOrNull { it.state == OutboxState.OUTBOX_STATE_FAILED }?.last_error?.ifEmpty { null }
                    ?: pending.lastOrNull { Failures.isInsufficientStorage(it.last_error) }?.last_error,
            )
        }

    /** IDs the UI marks while an entry is in flight: the card or message and its aliases. */
    fun presentationIds(entry: OutboxEntry): Set<String> = buildSet {
        add(entry.optimistic_id)
        if (entry.accepted) add(entry.server_id)
        if (entry.createsConversation) expectedConversationId(entry.client_id, entry.command_id)?.let(::add)
        optimisticInitialMessage(entry)?.let { add(it.id) }
    }

    fun isUserMessage(message: UiMessage): Boolean =
        message.role.equals("user", ignoreCase = true) || message.role.equals("human", ignoreCase = true)

    private fun createdAtMetadata(millis: Long) =
        JsonObject(mapOf("createdAt" to JsonPrimitive(Instant.fromEpochMilliseconds(millis).toString()))).toString().encodeUtf8()

    fun messageCreatedAt(message: UiMessage): Instant? {
        if (message.metadata_json.size == 0) return null
        val metadata = runCatching { Json.parseToJsonElement(message.metadata_json.utf8()).jsonObject }.getOrNull() ?: return null
        return Timestamps.parse(metadata["createdAt"]?.jsonPrimitive?.contentOrNull)
    }
}

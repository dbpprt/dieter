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
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.presentation.MessageMetadata
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.Failures
import kotlin.time.Duration
import kotlin.time.Instant
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
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

    /** "1 message queued", "3 changes queued", or "2 items queued" for a mix. */
    val queuedLabel: String
        get() {
            val queued = when {
                changeCount == 0 -> Counts.of(messageCount, "message")
                messageCount == 0 -> Counts.of(changeCount, "change")
                else -> Counts.of(itemCount, "item")
            }
            return "$queued queued"
        }

    /** "3 messages queued — delivers when it reconnects." */
    val deliveryLabel: String
        get() {
            val suffix = when {
                failed -> "needs attention."
                storageBlocked -> "free disk space on this machine; retries automatically every minute."
                else -> "delivers when it reconnects."
            }
            return "$queuedLabel — $suffix"
        }

    /** Appended to the machine's status line: " · attention needed", " · low disk space", " · retrying", or " · queued". */
    val statusSuffix: String
        get() = when {
            failed -> " · attention needed"
            storageBlocked -> " · low disk space"
            retrying -> " · retrying"
            else -> " · queued"
        }

    /** The machine's conversations show the low-disk banner: a full disk holds delivery and nothing was rejected. */
    val storageBanner: Boolean get() = storageBlocked && !failed

    /** Rejected work first, then a full disk, then transient retries; otherwise sending while [machineOnline], else waiting. */
    fun phase(machineOnline: Boolean): DeliveryPhase = when {
        failed -> DeliveryPhase.FAILED
        storageBlocked -> DeliveryPhase.WAITING_FOR_STORAGE
        retrying -> DeliveryPhase.RETRYING
        machineOnline -> DeliveryPhase.SENDING
        else -> DeliveryPhase.WAITING
    }

    /** The delivery toast's title, e.g. "Delivering to Studio" or "Low disk space on Studio". */
    fun title(machineName: String, machineOnline: Boolean): String = when (phase(machineOnline)) {
        DeliveryPhase.SENDING -> "Delivering to $machineName"
        DeliveryPhase.WAITING -> "Waiting for $machineName"
        DeliveryPhase.WAITING_FOR_STORAGE -> "Low disk space on $machineName"
        DeliveryPhase.RETRYING -> "Retrying delivery to $machineName"
        DeliveryPhase.FAILED -> "Delivery to $machineName failed"
    }

    /** The delivery toast's detail: what is queued and what happens next; a rejection shows the daemon's reason. */
    fun detail(machineName: String, machineOnline: Boolean): String = when (phase(machineOnline)) {
        DeliveryPhase.SENDING -> "$queuedLabel · Sending now"
        DeliveryPhase.WAITING -> "$queuedLabel · Sends when it reconnects"
        DeliveryPhase.WAITING_FOR_STORAGE -> "$queuedLabel. Free disk space on $machineName; retries automatically every minute."
        DeliveryPhase.RETRYING -> "$queuedLabel · Trying again automatically"
        DeliveryPhase.FAILED -> failureMessage?.takeIf { it.isNotBlank() } ?: "$queuedLabel · Try again when the machine is available"
    }

    /** The toast's retry button: "Try Again" after a failure or while retrying, "Retry Now" while waiting, none while sending. */
    fun retryTitle(machineOnline: Boolean): String = when (phase(machineOnline)) {
        DeliveryPhase.FAILED, DeliveryPhase.RETRYING -> "Try Again"
        DeliveryPhase.WAITING, DeliveryPhase.WAITING_FOR_STORAGE -> "Retry Now"
        DeliveryPhase.SENDING -> ""
    }
}

/** Where a machine's queued work stands, as its delivery toast shows it. */
enum class DeliveryPhase { SENDING, WAITING, WAITING_FOR_STORAGE, RETRYING, FAILED }

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
                MessageMetadata.createdAt(message)?.let { it.toEpochMilliseconds() > candidate.entry.created_at_millis } == true
            }.let { if (it < 0) messages.size else it }
            messages.add(index, candidate.message)
        }
        if (messages == conversation.messages && queue == conversation.queue) return snapshot
        return snapshot.copy(conversation = conversation.copy(messages = messages, queue = queue))
    }

    /** True once the accepted command shows in the account view: its card, or its owner's activity. */
    fun isSynced(entry: OutboxEntry, cards: Map<String, Card>, activities: Map<String, Conversation>): Boolean {
        val serverId = entry.server_id.ifEmpty { return false }
        return when (entry.kind) {
            OutboxKind.OUTBOX_KIND_CREATE_CARD -> cards[serverId]?.let { creationIsComplete(entry, it) } == true
            OutboxKind.OUTBOX_KIND_CREATE_CHAT -> {
                val card = cards[serverId] ?: return false
                if (!creationIsComplete(entry, card)) return false
                if (optimisticInitialMessage(entry) == null) return true
                // Without its activity the daemon's initial_prompt_sent_at is the evidence.
                val conversation = activities[serverId] ?: return card.initial_prompt_sent_at.isNotEmpty()
                conversation.messages.any(::isUserMessage)
            }
            OutboxKind.OUTBOX_KIND_SEND_MESSAGE -> {
                val cardId = sendRequest(entry)?.card_id ?: return false
                val conversation = activities[cardId] ?: return false
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
}

package com.dbpprt.dieter.core.outbox

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.SendMessageRequest
import com.dbpprt.dieter.api.v1.StartCardRequest
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.journal.OutboxEntry
import com.dbpprt.dieter.core.journal.OutboxJournal
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.journal.OutboxState
import com.dbpprt.dieter.core.machines.MachineChoice
import com.dbpprt.dieter.core.outbox.OutboxPolicy.accepted
import com.dbpprt.dieter.core.outbox.OutboxPolicy.createsConversation
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.CardOverlay
import com.dbpprt.dieter.core.store.PendingItem
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.sync.DirectoryProjection
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.uuid.Uuid
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString.Companion.toByteString

/** What the UI needs to mark in-flight work. */
data class OutboxView(
    val entries: List<OutboxEntry> = emptyList(),
    /** Conversations that exist only locally or are not yet synchronized. */
    val pendingCardIds: Set<String> = emptySet(),
    /** Optimistic user messages not yet in the daemon's transcript. */
    val pendingMessageIds: Set<String> = emptySet(),
    /** Accepted by the daemon, waiting for sync. */
    val acceptedIds: Set<String> = emptySet(),
    /** Definitively rejected; the user retries or discards. */
    val failedIds: Set<String> = emptySet(),
    val machines: Map<String, MachineOutboxSummary> = emptyMap(),
    /** Local conversation ID → the daemon's ID, so selections and drafts can follow. */
    val resolutions: Map<String, String> = emptyMap(),
    /** The journal could not be written; nothing new is accepted until it can. */
    val storageError: String? = null,
    /**
     * Cards whose start waits in the outbox or was accepted and not synced
     * yet (not failed); they show as starting until sync reports the turn.
     */
    val startingCardIds: Set<String> = emptySet(),
) {
    fun failure(id: String): String? =
        entries.firstOrNull { id in OutboxPolicy.presentationIds(it) && it.state == OutboxState.OUTBOX_STATE_FAILED }?.last_error

    fun resolve(id: String): String = resolutions[id] ?: id
}

/**
 * The durable outbox for one gateway account: create card/chat, send message,
 * and start card. Every command is journaled atomically before it is
 * acknowledged, delivered at least once per machine in order, and applied
 * exactly once by the daemon. Confined to the core dispatcher.
 */
class Outbox(
    private val clientId: String,
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    private var storage: CoreStorage? = null
    private var journal = OutboxJournal()
    private val overlays = HashSet<String>()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val mutableView = MutableStateFlow(OutboxView())
    val view: StateFlow<OutboxView> = mutableView.asStateFlow()

    private val entries: List<OutboxEntry> get() = journal.entries

    /** Switches to [storage]'s journal, e.g. when the active gateway changes. */
    fun bind(storage: CoreStorage?) {
        if (storage != null && storage.directory == this.storage?.directory) return
        overlays.forEach(store::rollbackOverlay)
        overlays.clear()
        val loaded = storage?.let { runCatching { load(it) } }
        // An unreadable journal is kept on disk untouched and nothing new is accepted.
        this.storage = storage.takeIf { loaded?.isSuccess == true }
        journal = loaded?.getOrNull() ?: OutboxJournal(version = VERSION)
        publish(loaded?.exceptionOrNull()?.let { "Could not recover pending changes: ${Failures.message(it)}" })
        wake.trySend(Unit)
    }

    private fun load(storage: CoreStorage): OutboxJournal {
        val bytes = storage.read(FILE) ?: return OutboxJournal(version = VERSION)
        val loaded = OutboxJournal.ADAPTER.decode(bytes)
        if (loaded.version > VERSION) {
            throw CoreException(FailureKind.UPDATE_REQUIRED, "Pending messages were saved by a newer Dieter version. Update Dieter to recover them.")
        }
        return loaded
    }

    /**
     * Applies [change] atomically. Growth beyond the bounds is rejected, but
     * an existing journal above them can still drain.
     */
    private fun <R> transaction(change: (MutableList<OutboxEntry>, MutableMap<String, String>) -> R): R {
        val target = storage ?: throw CoreException(FailureKind.TRANSIENT, "Sign in to a gateway before sending.")
        val nextEntries = journal.entries.toMutableList()
        val resolutions = LinkedHashMap<String, String>()
        for (id in journal.resolution_order) journal.resolutions[id]?.let { resolutions[id] = it }
        val result = change(nextEntries, resolutions)
        while (resolutions.size > MAX_RESOLUTIONS) resolutions.remove(resolutions.keys.first())
        if (nextEntries == journal.entries && resolutions == journal.resolutions) return result
        if (nextEntries.size > maxOf(MAX_ENTRIES, journal.entries.size)) throw full()
        val next = OutboxJournal(
            version = VERSION, revision = journal.revision + 1, entries = nextEntries,
            resolutions = resolutions, resolution_order = resolutions.keys.toList(),
        )
        val bytes = OutboxJournal.ADAPTER.encode(next)
        if (bytes.size > MAX_BYTES && bytes.size > OutboxJournal.ADAPTER.encodedSize(journal)) throw full()
        try {
            target.write(FILE, bytes)
        } catch (error: Throwable) {
            publish("Could not save pending changes: ${Failures.message(error)}")
            throw CoreException(FailureKind.OUT_OF_STORAGE, "Could not save pending changes: ${Failures.message(error)}", error)
        }
        journal = next
        publish(null)
        wake.trySend(Unit)
        return result
    }

    private fun full() = CoreException(
        FailureKind.PERMANENT,
        "Pending changes have reached the local storage limit. Send or discard queued items before adding more.",
    )

    // --- Commands -------------------------------------------------------

    /**
     * Queues a card or chat. [submissionId] makes a capture retry idempotent:
     * the same submission always maps to the same command.
     */
    fun createConversation(request: CreateConversationRequest, chat: Boolean, submissionId: String? = null): Card {
        val commandId = submissionId?.takeIf { it.isNotBlank() } ?: newCommandId()
        val stable = request.copy(client_id = clientId, command_id = commandId)
        val daemonId = daemonForCreate(stable)
        val encoded = CreateConversationRequest.ADAPTER.encode(stable).toByteString()
        val entry = transaction { entries, _ ->
            entries.firstOrNull { it.command_id == commandId }?.let { existing ->
                if (existing.request != encoded) throw CoreException(FailureKind.PERMANENT, "An admitted task cannot be changed during retry.")
                return@transaction existing
            }
            OutboxEntry(
                command_id = commandId, client_id = clientId, daemon_id = daemonId,
                kind = if (chat) OutboxKind.OUTBOX_KIND_CREATE_CHAT else OutboxKind.OUTBOX_KIND_CREATE_CARD,
                request = encoded, optimistic_id = OutboxPolicy.localConversationId(commandId),
                created_at_millis = clock.now().toEpochMilliseconds(),
            ).also(entries::add)
        }
        return store.state.value.card(entry.server_id.ifEmpty { entry.optimistic_id }) ?: OutboxPolicy.optimisticCard(entry)!!
    }

    /** Queues a user message; returns its ID. A send during an active turn renders in the queue. */
    fun sendMessage(
        cardId: String,
        parts: List<MessagePart>,
        selection: HarnessSelection = HarnessSelection(),
        placement: OutboxPlacement = OutboxPlacement.OUTBOX_PLACEMENT_TRANSCRIPT,
    ): String {
        val target = view.value.resolve(cardId)
        val commandId = newCommandId()
        val messageId = "msg_" + Uuid.random().toHexString()
        val request = SendMessageRequest(
            card_id = target, parts = parts, provider = selection.provider, model = selection.model, effort = selection.effort,
            provider_options = selection.provider_options, client_id = clientId, command_id = commandId, message_id = messageId,
        )
        val daemonId = daemonForCard(target)
        transaction { entries, _ ->
            entries += OutboxEntry(
                command_id = commandId, client_id = clientId, daemon_id = daemonId, kind = OutboxKind.OUTBOX_KIND_SEND_MESSAGE,
                request = SendMessageRequest.ADAPTER.encode(request).toByteString(), optimistic_id = messageId,
                placement = placement, created_at_millis = clock.now().toEpochMilliseconds(),
            )
        }
        return messageId
    }

    /** Queues the start of a card's first turn; a failed start is re-armed instead of duplicated. */
    fun startCard(cardId: String, hasDraftAttachments: Boolean = false) {
        val target = view.value.resolve(cardId)
        store.directoryProjection.item(target)?.let { card ->
            if (!CardPolicy.canStart(card, store.directoryProjection.board(card.board_id), hasDraftAttachments)) {
                throw CoreException(FailureKind.PERMANENT, "Only a never-started todo card with a task can be started.")
            }
        }
        val daemonId = daemonForCard(target)
        transaction { entries, _ ->
            val index = entries.indexOfFirst { it.kind == OutboxKind.OUTBOX_KIND_START_CARD && it.optimistic_id == target && !it.accepted }
            if (index >= 0) {
                if (entries[index].state == OutboxState.OUTBOX_STATE_FAILED) entries[index] = entries[index].rearmed()
                return@transaction
            }
            val commandId = newCommandId()
            entries += OutboxEntry(
                command_id = commandId, client_id = clientId, daemon_id = daemonId, kind = OutboxKind.OUTBOX_KIND_START_CARD,
                request = StartCardRequest.ADAPTER.encode(StartCardRequest(card_id = target, client_id = clientId, command_id = commandId)).toByteString(),
                optimistic_id = target, created_at_millis = clock.now().toEpochMilliseconds(),
            )
        }
    }

    /** Re-arms failed or waiting commands for [id] (a conversation, message, or card). */
    fun retry(id: String) = transaction { entries, _ ->
        for (index in entries.indices) {
            val entry = entries[index]
            if (!entry.accepted && entry.state != OutboxState.OUTBOX_STATE_QUEUED && id in OutboxPolicy.presentationIds(entry)) {
                entries[index] = entry.rearmed()
            }
        }
    }

    fun retryMachine(daemonId: String) = transaction { entries, _ ->
        for (index in entries.indices) {
            if (entries[index].daemon_id == daemonId && !entries[index].accepted) entries[index] = entries[index].rearmed()
        }
    }

    /** Drops an undelivered command and everything that depends on it; returns the removed entries. */
    fun discard(id: String): List<OutboxEntry> = transaction { entries, _ ->
        val entry = entries.firstOrNull { id in OutboxPolicy.presentationIds(it) && !it.accepted } ?: return@transaction emptyList()
        val aliases = OutboxPolicy.conversationIds(entry).toSet()
        val dependents = entries.filter { candidate ->
            candidate !== entry && candidate.daemon_id == entry.daemon_id && !candidate.accepted && entry.createsConversation &&
                ((OutboxPolicy.sendRequest(candidate)?.card_id ?: OutboxPolicy.startRequest(candidate)?.card_id) in aliases)
        }
        val removed = listOf(entry) + dependents
        entries.removeAll { candidate -> removed.any { it.command_id == candidate.command_id } }
        removed
    }

    fun discardMachine(daemonId: String): Int = transaction { entries, _ ->
        val before = entries.size
        entries.removeAll { it.daemon_id == daemonId && !it.accepted }
        before - entries.size
    }

    // --- Delivery -------------------------------------------------------

    /**
     * Delivers until cancelled. [reachable] lists machines that can take
     * commands now. Nothing is replayed after a definitive rejection, and a
     * cancelled delivery is retried as-is.
     */
    suspend fun run(reachable: Flow<List<String>>) = coroutineScope {
        val targets = MutableStateFlow<List<String>>(emptyList())
        launch {
            reachable.distinctUntilChanged().collect {
                targets.value = it
                wake.trySend(Unit)
            }
        }
        while (true) {
            val daemons = targets.value
            val now = clock.now()
            val entry = OutboxPolicy.next(entries, daemons, now)
            if (entry == null) {
                val wait = OutboxPolicy.nextRetryDelay(entries, daemons.toSet(), now) ?: Duration.INFINITE
                withTimeoutOrNull(wait.coerceAtLeast(MIN_WAIT)) { wake.receive() }
                continue
            }
            deliver(entry)
        }
    }

    private suspend fun deliver(entry: OutboxEntry) {
        try {
            val serverId: String = sessions.call(entry.daemon_id) { client ->
                when (entry.kind) {
                    OutboxKind.OUTBOX_KIND_CREATE_CARD, OutboxKind.OUTBOX_KIND_CREATE_CHAT -> {
                        val request = CreateConversationRequest.ADAPTER.decode(entry.request)
                        val card = if (entry.kind == OutboxKind.OUTBOX_KIND_CREATE_CHAT) client.CreateChat().execute(request) else client.CreateCard().execute(request)
                        if (!OutboxPolicy.creationIsComplete(entry, card)) {
                            throw CoreException(
                                FailureKind.PERMANENT,
                                "The conversation was saved, but its first turn was not started. Check the machine's available storage and update its daemon before retrying.",
                            )
                        }
                        card.id
                    }
                    OutboxKind.OUTBOX_KIND_SEND_MESSAGE ->
                        client.SendMessage().execute(SendMessageRequest.ADAPTER.decode(entry.request)).message_id.ifEmpty { entry.optimistic_id }
                    OutboxKind.OUTBOX_KIND_START_CARD -> {
                        val request = StartCardRequest.ADAPTER.decode(entry.request)
                        val response = client.StartCard().execute(request)
                        response.card?.id?.ifEmpty { null } ?: request.card_id
                    }
                    else -> throw CoreException(FailureKind.PERMANENT, "Unknown pending command.")
                }
            }
            transaction { entries, resolutions ->
                val index = entries.indexOfFirst { it.command_id == entry.command_id }
                if (index < 0) return@transaction
                entries[index] = entries[index].copy(
                    server_id = serverId, accepted_at_millis = clock.now().toEpochMilliseconds(),
                    state = OutboxState.OUTBOX_STATE_QUEUED, last_error = "", next_attempt_at_millis = 0,
                )
                if (entry.createsConversation) accept(entries, resolutions, entry.optimistic_id, serverId)
            }
            reconcile()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val message = Failures.message(error)
            val permanent = Failures.dropsCommand(error)
            logger.warn(TAG, "command ${entry.command_id} (${entry.kind}) for ${entry.daemon_id} failed: $message; permanent=$permanent")
            try {
                transaction { entries, _ ->
                    val index = entries.indexOfFirst { it.command_id == entry.command_id && !it.accepted }
                    if (index < 0) return@transaction
                    val attempts = entries[index].attempts + 1
                    entries[index] = entries[index].copy(
                        attempts = attempts, last_error = message,
                        state = if (permanent) OutboxState.OUTBOX_STATE_FAILED else OutboxState.OUTBOX_STATE_RETRYING,
                        next_attempt_at_millis = if (permanent) 0 else (clock.now() + OutboxPolicy.backoff(attempts, message)).toEpochMilliseconds(),
                    )
                }
            } catch (storageFailure: CoreException) {
                logger.warn(TAG, "could not record the failure of ${entry.command_id}", storageFailure)
            }
        }
    }

    private fun accept(entries: MutableList<OutboxEntry>, resolutions: MutableMap<String, String>, localId: String, serverId: String) {
        if (localId == serverId) return
        val retargeted = OutboxPolicy.retargetDependencies(entries, localId, serverId)
        entries.clear()
        entries.addAll(retargeted)
        resolutions.remove(localId)
        resolutions[localId] = serverId
    }

    // --- Reconciliation and presentation ---------------------------------

    /**
     * Correlates creates the account view already shows, then removes
     * accepted commands it reflects, sends by their owners' activity. Call
     * after the account view changes.
     */
    fun reconcile(activities: Map<String, Conversation> = store.state.value.activities) {
        if (storage == null) return
        if (entries.isEmpty()) return publish(view.value.storageError)
        val directory = store.directoryProjection
        val cards = directory.allItems.associateBy { it.id }
        val now = clock.now().toEpochMilliseconds()
        runCatching {
            transaction { entries, resolutions ->
                for (index in entries.indices) {
                    val entry = entries[index]
                    val serverId = OutboxPolicy.synchronizedConversationId(entry, cards.keys) ?: continue
                    val card = cards.getValue(serverId)
                    if (!OutboxPolicy.creationIsComplete(entry, card)) continue
                    entries[index] = entry.copy(server_id = serverId, accepted_at_millis = now, state = OutboxState.OUTBOX_STATE_QUEUED, last_error = "")
                    accept(entries, resolutions, entry.optimistic_id, serverId)
                }
                entries.removeAll { entry ->
                    entry.accepted && (OutboxPolicy.isSynced(entry, cards, activities) || now - entry.accepted_at_millis > ACCEPTED_RETENTION.inWholeMilliseconds)
                }
            }
        }.onFailure { logger.warn(TAG, "could not reconcile pending changes", it) }
        publish(view.value.storageError)
    }

    /** An opened conversation is evidence too: its messages settle pending sends. */
    fun reconcileConversation(snapshot: ConversationSnapshot) {
        val conversation = snapshot.conversation ?: return
        val id = snapshot.detail?.card?.id?.ifEmpty { null } ?: conversation.card_id.ifEmpty { return }
        reconcile(store.state.value.activities + (id to conversation))
    }

    /** Local sends and a pending chat's first message, merged into [snapshot]. */
    fun overlay(snapshot: ConversationSnapshot): ConversationSnapshot = OutboxPolicy.overlayOptimisticMessages(snapshot, entries)

    private fun publish(storageError: String?) {
        val current = entries
        val directory = store.directoryProjection
        store.setPendingItems(pendingItems(current, directory))
        syncStartOverlays(current)
        mutableView.value = OutboxView(
            entries = current,
            pendingCardIds = current.filter { it.kind != OutboxKind.OUTBOX_KIND_SEND_MESSAGE }.flatMapTo(HashSet(), OutboxPolicy::conversationIds),
            pendingMessageIds = buildSet {
                for (entry in current) {
                    if (entry.kind == OutboxKind.OUTBOX_KIND_SEND_MESSAGE) add(entry.optimistic_id)
                    OutboxPolicy.optimisticInitialMessage(entry)?.let { add(it.id) }
                }
            },
            acceptedIds = current.filter { it.accepted }.flatMapTo(HashSet(), OutboxPolicy::presentationIds),
            failedIds = current.filter { it.state == OutboxState.OUTBOX_STATE_FAILED }.flatMapTo(HashSet(), OutboxPolicy::presentationIds),
            machines = OutboxPolicy.summaries(current),
            resolutions = journal.resolutions,
            storageError = storageError,
            startingCardIds = current.filter { it.kind == OutboxKind.OUTBOX_KIND_START_CARD && it.state != OutboxState.OUTBOX_STATE_FAILED }.mapTo(HashSet()) { it.optimistic_id },
        )
    }

    private fun pendingItems(entries: List<OutboxEntry>, directory: DirectoryProjection): Map<String, PendingItem> = buildMap {
        for (entry in entries) {
            val card = OutboxPolicy.optimisticCard(entry) ?: continue
            // A create for a project this account no longer lists has nowhere to render.
            if (directory.projects.isNotEmpty() && card.project_id.isNotEmpty() && card.project_id !in directory.projects) continue
            put(card.id, PendingItem(card, entry.daemon_id, OutboxPolicy.conversationIds(entry).filterTo(HashSet()) { it.isNotEmpty() && it != card.id }))
        }
    }

    private fun syncStartOverlays(entries: List<OutboxEntry>) {
        val active = entries.filter { it.kind == OutboxKind.OUTBOX_KIND_START_CARD && it.state != OutboxState.OUTBOX_STATE_FAILED }
        val activeIds = active.mapTo(HashSet()) { it.command_id }
        for (id in overlays - activeIds) store.rollbackOverlay(id)
        overlays.retainAll(activeIds)
        for (entry in active) {
            if (!overlays.add(entry.command_id)) continue
            store.addOverlay(StartOverlay(entry.command_id, entry.optimistic_id) { boardId -> store.directoryProjection.board(boardId) })
        }
    }

    // --- Machine resolution ---------------------------------------------

    private fun daemonForCreate(request: CreateConversationRequest): String {
        val directory = store.directoryProjection
        if (request.checkout_id.isNotEmpty()) {
            return directory.checkoutMachine(request.project_id, request.checkout_id)
                ?: throw CoreException(FailureKind.TRANSIENT, "The checkout's machine is unavailable; keep the draft and reconnect.")
        }
        if (directory.projects[request.project_id] == null) {
            throw CoreException(FailureKind.TRANSIENT, "The project is not available yet; keep the draft and reconnect.")
        }
        return choice.checkout(request.project_id) ?: throw CoreException(FailureKind.PERMANENT, "This project has no checkout to run on.")
    }

    private fun daemonForCard(cardId: String): String {
        entries.firstOrNull { it.createsConversation && cardId in OutboxPolicy.conversationIds(it) }?.let { return it.daemon_id }
        val directory = store.directoryProjection
        val card = directory.item(cardId)
            ?: throw CoreException(FailureKind.PERMANENT, "The conversation is no longer available.")
        return directory.owner(card) ?: throw CoreException(FailureKind.TRANSIENT, "The conversation's machine is unavailable; reconnect and try again.")
    }

    private fun OutboxEntry.rearmed() = copy(state = OutboxState.OUTBOX_STATE_QUEUED, attempts = 0, last_error = "", next_attempt_at_millis = 0)

    private fun newCommandId() = Uuid.random().toString()

    private class StartOverlay(override val operationId: String, override val cardId: String, private val board: (String) -> Board?) : CardOverlay {
        override fun apply(card: Card): Card = CardPolicy.started(card, board(card.board_id)) ?: card
        override fun satisfiedBy(card: Card): Boolean = card.initial_prompt_sent_at.isNotEmpty()
    }

    companion object {
        const val FILE = "outbox.pb"
        const val VERSION = 1

        const val MAX_ENTRIES = 1_000
        const val MAX_BYTES = 64 * 1024 * 1024
        const val MAX_RESOLUTIONS = 256

        /** An accepted command only lingers so the UI does not flicker while sync catches up. */
        val ACCEPTED_RETENTION = 2.minutes
        private val MIN_WAIT = Duration.parse("50ms")
        private const val TAG = "Outbox"
    }
}

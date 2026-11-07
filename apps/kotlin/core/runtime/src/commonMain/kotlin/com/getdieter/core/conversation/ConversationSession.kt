package com.getdieter.core.conversation

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.CardDetail
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.ConversationSnapshot
import com.getdieter.api.v1.ConversationUpdate
import com.getdieter.api.v1.GetConversationRequest
import com.getdieter.api.v1.GetToolOutputRequest
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.QueuedMessage
import com.getdieter.api.v1.RemoveQueuedMessageRequest
import com.getdieter.api.v1.ToolOutput
import com.getdieter.api.v1.UiMessage
import com.getdieter.api.v1.WatchConversationRequest
import com.getdieter.core.board.BoardOperations
import com.getdieter.core.board.CardOperation
import com.getdieter.core.board.Runtimes
import com.getdieter.core.composition.Attachments
import com.getdieter.core.composition.ConversationDrafts
import com.getdieter.core.composition.DraftKey
import com.getdieter.core.connection.MachineSync
import com.getdieter.core.connection.SyncState
import com.getdieter.core.outbox.Outbox
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.outbox.OutboxView
import com.getdieter.core.presentation.Parts
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.selection.AgentControls
import com.getdieter.core.selection.Selections
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.sync.TranscriptFreshness
import com.getdieter.core.v1.OutboxPlacement
import com.getdieter.core.v1.OutboxState
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.pow
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

data class ConversationConfig(
    /** Messages per unary read and history page. */
    val pageSize: Int = 60,
    /** Messages in the streamed live window. */
    val watchLimit: Int = 30,
    val watchInterval: Duration = 250.milliseconds,
    /** A stream that has not delivered by then is raced by a unary read. */
    val hedgeDelay: Duration = 500.milliseconds,
    val readTimeout: Duration = 15.seconds,
    val retention: TranscriptRetention = TranscriptRetention.DESKTOP,
    /** Open conversations kept streaming at once; the least recently used closes. */
    val maxOpen: Int = 8,
    /** Recently opened conversations kept in memory for instant reopening. */
    val cacheSize: Int = 24,
)

/** An open conversation as the UI renders it. */
data class ConversationView(
    val cardId: String,
    val daemonId: String? = null,
    val transcript: TranscriptState = TranscriptState(),
    /** The live window with this device's pending sends merged in. */
    val presented: ConversationSnapshot? = null,
    /** No transcript yet. */
    val loading: Boolean = true,
    /** Waiting for the owner to confirm the current state; cached messages stay readable. */
    val syncing: Boolean = false,
    val error: String? = null,
    val refreshedAt: Instant? = null,
    /** The conversation exists only locally; the outbox is creating it. */
    val pending: Boolean = false,
    /** A message this client sent has not been answered yet; the agent shows as working. */
    val awaitingReply: Boolean = false,
    /** A failed turn's retry was sent and has not run yet. */
    val retrying: Boolean = false,
    /** A newer account activity preview; used for live status, never as full transcript content. */
    val activity: Conversation? = null,
) {
    val card: Card?
        get() = presented?.detail?.card

    val conversation: Conversation?
        get() = presented?.conversation

    /** Loaded history then the live window, with pending sends merged in; the live copy wins. */
    val messages: List<UiMessage>
        get() {
            val live = presented?.conversation?.messages.orEmpty()
            val liveIds = live.mapTo(HashSet()) { it.id }
            return transcript.older.filter { it.id.isEmpty() || it.id !in liveIds } + live
        }
}

/**
 * One open conversation on the machine that runs it: a live watch with a hedged first read, history
 * paging within a retention budget, and the conversation actions (send, queue edits, steer, retry,
 * mark read). The stream resubscribes on its own; it never reconnects the app. Confined to the core
 * dispatcher.
 */
class ConversationSession
internal constructor(
    cardId: String,
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val outbox: Outbox,
    private val board: BoardOperations,
    private val drafts: ConversationDrafts,
    private val config: ConversationConfig,
    private val clock: Clock,
    private val logger: CoreLogger,
    parent: CoroutineScope,
    private val cached: TranscriptState?,
    private val onTranscript: (String, TranscriptState) -> Unit,
    /** A machine's agent catalog once it has loaded, else null. */
    private val catalog: (daemonId: String) -> List<Harness>? = { null },
    private val syncs: StateFlow<Map<String, MachineSync>>? = null,
) {
    private val scope =
        CoroutineScope(parent.coroutineContext + SupervisorJob(parent.coroutineContext.job))
    private val mutableView =
        MutableStateFlow(
            ConversationView(
                cardId,
                pending = !OutboxPolicy.isServerBacked(cardId),
                syncing = OutboxPolicy.isServerBacked(cardId),
            )
        )
    val view: StateFlow<ConversationView> = mutableView.asStateFlow()
    private var transcript = cached ?: TranscriptState()
    private var confirmed = false
    private var interrupted = false
    private var paused = false
    private var readError: String? = null
    private var refreshedAt: Instant? = null
    private var latestActivity: Conversation? = null
    private var recovery: Job? = null
    internal val updatesPaused: Boolean
        get() = paused

    private var historyRequest = 0L
    private val toolOutputs = LinkedHashMap<String, ToolOutput>()

    /** A send awaiting its reply: cleared by a new reply, a finished turn, or a failed delivery. */
    private data class Awaiting(
        val messageId: String,
        val replies: Int,
        val sawTurn: Boolean = false,
        val retry: Boolean = false,
    )

    private var awaiting: Awaiting? = null
    // Keep an acknowledged handoff latched until that message leaves the queue. A second
    // cancellation must never reach the next turn while the transcript is catching up.
    private var steeringMessageId: String? = null

    val cardId: String
        get() = mutableView.value.cardId

    private val daemonId: String?
        get() = mutableView.value.daemonId

    internal fun start() {
        scope.launch { outbox.view.collect { publish() } }
        // Account activity can advance while the full transcript stream is delayed. Observe both
        // sources, including activity-only changes that do not alter the card's metadata.
        scope.launch {
            store.state
                .map { it.card(cardId) to it.activities[cardId] }
                .distinctUntilChanged()
                .collect { publish() }
        }
        scope.launch { syncs?.collect { publish() } }
        scope.launch { sessions.gateways.collect { publish() } }
        scope.launch {
            try {
                var id = cardId
                if (!OutboxPolicy.isServerBacked(id)) {
                    // A conversation still being created renders from its outbox entry until the
                    // daemon has it.
                    mutableView.update { it.copy(daemonId = owner(id)) }
                    id = outbox.view.first { view -> view.resolutions[id] != null }.resolve(id)
                    transcript = TranscriptState()
                    mutableView.update { it.copy(cardId = id, pending = false, syncing = true) }
                }
                mutableView.update { it.copy(daemonId = owner(id)) }
                publish()
                watch()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                paused = true
                readError = Failures.message(error)
                publish()
            }
        }
        publish()
    }

    // --- Reading ------------------------------------------------------------

    private suspend fun watch() {
        val owner = daemonId ?: return
        val id = cardId
        // Resume cached messages after their last event, keeping syncing visible until the first
        // frame.
        var requireSnapshot = transcript.snapshot == null
        var failures = 0
        while (true) {
            var received = false
            // Disconnected, there is nothing to retry: subscribe once a gateway session exists.
            val gateway = sessions.gateways.filterNotNull().first()
            try {
                val after = if (requireSnapshot) 0L else transcript.lastSeq
                sessions.call(owner) { client ->
                    coroutineScope {
                        val call = client.WatchConversation()
                        val updates =
                            call.executeIn(
                                this,
                                WatchConversationRequest(
                                    card_id = id,
                                    limit = config.watchLimit,
                                    interval_ms = config.watchInterval.inWholeMilliseconds.toInt(),
                                    after_seq = after,
                                ),
                            )
                        try {
                            for (update in updates) {
                                received = true
                                accept(update)
                                requireSnapshot = false
                            }
                        } finally {
                            call.cancel()
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (missing: ConversationReducer.MissingSnapshot) {
                requireSnapshot = true
            } catch (error: Throwable) {
                if (
                    !Failures.isRetryableRead(error) &&
                        Failures.kind(error) != FailureKind.UNAUTHENTICATED
                ) {
                    logger.info(TAG, "conversation $id stopped: ${Failures.message(error)}")
                    paused = true
                    readError = "Conversation updates paused: ${Failures.message(error)}"
                    publish()
                    return
                }
            }
            failures = if (received) 1 else failures + 1
            interrupted = true
            publish()
            // A new session, e.g. back in the foreground, resubscribes at once.
            val replaced =
                withTimeoutOrNull(resubscribeDelay(failures)) {
                    sessions.gateways.first { it !== gateway }
                    true
                } == true
            if (replaced) failures = 0
        }
    }

    /**
     * A delayed first frame (cached opens too), or activity ahead of a quiet/stalled transcript,
     * gets a bounded unary read. Healthy idle watches need no periodic polling or silence timeout.
     */
    private suspend fun recover() {
        delay(config.hedgeDelay)
        while (needsRead() && !paused) {
            val owner = daemonId ?: return
            sessions.gateways.filterNotNull().first()
            if (!needsRead()) return
            if (syncs?.value?.get(owner)?.state in setOf(SyncState.OFFLINE, SyncState.INCOMPATIBLE))
                return
            try {
                val snapshot =
                    sessions.call(owner, config.readTimeout) {
                        it.GetConversation()
                            .execute(
                                GetConversationRequest(card_id = cardId, limit = config.pageSize)
                            )
                    }
                accept(ConversationUpdate(snapshot = snapshot))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                readError = "Could not refresh conversation: ${Failures.message(error)}"
                publish()
            }
            if (!needsRead()) return
            delay(config.readTimeout)
        }
    }

    private fun accept(update: ConversationUpdate) {
        val previous = transcript.conversation
        val incoming =
            update.snapshot?.conversation
                ?: Conversation(last_seq = update.last_seq, updated_at = update.updated_at)
        val next = ConversationReducer.apply(transcript, update, config.retention)
        if (previous == null || TranscriptFreshness.compare(incoming, previous) >= 0) {
            confirmed = true
            interrupted = false
            if (!paused) readError = null
            refreshedAt = clock.now()
        }
        if (next == transcript) {
            publish()
            return
        }
        transcript = next
        adopt()
    }

    /** Settles pending sends with what the owner reported. */
    private fun adopt() {
        val snapshot = transcript.snapshot ?: return
        outbox.reconcileConversation(snapshot)
        onTranscript(cardId, transcript)
        publish()
    }

    /** Re-reads the live window, e.g. on pull-to-refresh. */
    suspend fun refresh() {
        val owner = daemonId ?: return
        val snapshot =
            sessions.call(owner) {
                it.GetConversation()
                    .execute(GetConversationRequest(card_id = cardId, limit = config.pageSize))
            }
        accept(ConversationUpdate(snapshot = snapshot))
    }

    // --- History --------------------------------------------------------------

    /** Loads up to one page of earlier messages; false when nothing was added. */
    suspend fun loadEarlier(): Boolean {
        val owner = daemonId ?: return false
        val history = transcript.history
        if (!history.hasMore || history.start <= 0 || history.loading) return false
        val request = ++historyRequest
        setHistory { it.copy(loading = true) }
        try {
            var cursor = history.start
            var added = emptyList<UiMessage>()
            var total = history.total
            var hasMore = history.hasMore
            // A byte-bounded page can hold fewer messages than asked for.
            while (hasMore && cursor > 0 && added.size < config.pageSize) {
                val page =
                    sessions.call(owner) {
                        it.GetConversation()
                            .execute(
                                GetConversationRequest(
                                    card_id = cardId,
                                    limit = config.pageSize,
                                    before = cursor,
                                )
                            )
                    }
                if (request != historyRequest) return false
                val range = page.page
                if (
                    range == null ||
                        range.end != cursor ||
                        range.start >= cursor ||
                        page.detail?.card?.id?.let { it != cardId } == true
                ) {
                    throw CoreException(
                        FailureKind.CONFLICT,
                        "Conversation history changed. Jump to latest to refresh it.",
                    )
                }
                val known = transcript.messages.mapTo(HashSet()) { it.id } + added.map { it.id }
                added = page.conversation?.messages.orEmpty().filter { it.id !in known } + added
                cursor = range.start
                total = maxOf(total, range.total)
                hasMore = range.has_more && cursor > 0
            }
            if (added.isEmpty()) {
                setHistory { it.copy(loading = false, start = cursor, hasMore = hasMore) }
                return false
            }
            val (kept, removed) =
                config.retention.window(added + transcript.older, keepingEarlier = true)
            transcript =
                transcript.copy(
                    older = kept,
                    history =
                        transcript.history.copy(
                            start = cursor,
                            total = total,
                            hasMore = hasMore,
                            loading = false,
                            browsingEarlier = transcript.history.browsingEarlier || removed > 0,
                        ),
                )
            onTranscript(cardId, transcript)
            publish()
            return true
        } catch (error: Throwable) {
            if (request == historyRequest) setHistory { it.copy(loading = false) }
            if (error !is CancellationException)
                mutableView.update { it.copy(error = Failures.message(error)) }
            throw error
        }
    }

    /** While browsing earlier history, loads the next page toward the live tail. */
    suspend fun loadLater(): Boolean {
        val owner = daemonId ?: return false
        val history = transcript.history
        if (!history.browsingEarlier || history.loading) return false
        val end = history.start + transcript.older.size
        val livePage = transcript.snapshot?.page
        val total = maxOf(history.total, livePage?.total ?: 0)
        if (end >= total) return returnToLatest().let { false }
        val request = ++historyRequest
        setHistory { it.copy(loading = true) }
        try {
            val page =
                sessions.call(owner) {
                    it.GetConversation()
                        .execute(
                            GetConversationRequest(
                                card_id = cardId,
                                limit = config.pageSize,
                                before = minOf(total, end + config.pageSize),
                            )
                        )
                }
            if (request != historyRequest) return false
            val range =
                page.page
                    ?: throw CoreException(
                        FailureKind.CONFLICT,
                        "Conversation history changed. Jump to latest to refresh it.",
                    )
            if (range.start > end)
                throw CoreException(
                    FailureKind.CONFLICT,
                    "Conversation history changed. Jump to latest to refresh it.",
                )
            val pageEnd = range.start + (page.conversation?.messages?.size ?: 0)
            if (pageEnd <= end) {
                setHistory { it.copy(loading = false) }
                return false
            }
            val reconnects = livePage != null && pageEnd >= livePage.start
            val liveIds =
                if (reconnects)
                    transcript.conversation?.messages.orEmpty().mapTo(HashSet()) { it.id }
                else emptySet()
            val known = transcript.older.mapTo(HashSet()) { it.id }
            val fresh =
                page.conversation?.messages.orEmpty().filter {
                    it.id !in known && it.id !in liveIds
                }
            val (kept, removed) =
                config.retention.window(transcript.older + fresh, keepingEarlier = false)
            val start = history.start + removed
            transcript =
                transcript.copy(
                    older = kept,
                    history =
                        history.copy(
                            start = start,
                            hasMore = start > 0,
                            loading = false,
                            browsingEarlier = !reconnects,
                            total = total,
                        ),
                )
            onTranscript(cardId, transcript)
            publish()
            return true
        } catch (error: Throwable) {
            if (request == historyRequest) setHistory { it.copy(loading = false) }
            if (error !is CancellationException)
                mutableView.update { it.copy(error = Failures.message(error)) }
            throw error
        }
    }

    /** Drops loaded history and follows the live tail again. */
    fun returnToLatest() {
        historyRequest++
        val page = transcript.snapshot?.page
        transcript =
            transcript.copy(
                older = emptyList(),
                history =
                    ConversationHistory(
                        start = page?.start ?: 0,
                        total = page?.total ?: 0,
                        hasMore = page?.has_more ?: false,
                    ),
            )
        publish()
    }

    private fun setHistory(change: (ConversationHistory) -> ConversationHistory) {
        transcript = transcript.copy(history = change(transcript.history))
        publish()
    }

    // --- Actions ----------------------------------------------------------------

    private fun card(): Card =
        store.directoryProjection.item(cardId)
            ?: transcript.snapshot?.detail?.card
            ?: throw CoreException(
                FailureKind.PERMANENT,
                "The conversation is no longer available.",
            )

    /**
     * A send while the agent works, or behind queued messages, joins the queue
     * ([Companion.placement]).
     */
    fun placement(): OutboxPlacement =
        placement(runCatching { card() }.getOrNull(), transcript.conversation)

    /**
     * Queues a message durably; returns its ID. Its agent is [selection], else the composer's
     * choice, else the conversation's agent, with the rules of [Selections.forSend] against
     * [harnesses] (the conversation machine's catalog). It joins the queue while the agent works or
     * messages wait ([placement]).
     */
    fun send(
        parts: List<MessagePart>,
        selection: HarnessSelection? = null,
        harnesses: List<Harness>? = machineCatalog(),
    ): String {
        checkSendable(parts)
        val card = card()
        val chosen = selection ?: draftKey()?.let { drafts.state.value[it] }?.selection
        val agent =
            Selections.forSend(
                chosen,
                card,
                harnesses,
                locked = Selections.locked(card, transcript.messages.isNotEmpty()),
            )
        return outbox.sendMessage(cardId, parts, agent, placement()).also(::await)
    }

    private fun await(messageId: String, retry: Boolean = false) {
        awaiting = Awaiting(messageId, replies(transcript.messages), retry = retry)
        publish()
    }

    /** Assistant messages with something to show; an empty turn envelope is not a reply. */
    private fun replies(messages: List<UiMessage>): Int = messages.count {
        !Parts.isUser(it) && it.parts.any { part -> Parts.isVisible(part, showReasoning = true) }
    }

    /** Sends the composer draft and clears exactly what was sent. */
    fun sendDraft(): String? {
        val key = DraftKey(daemonId ?: return null, cardId)
        val draft = drafts.draft(key)
        if (!draft.hasContent) return null
        val id = send(Attachments.messageParts(draft.text, draft.attachments), draft.selection)
        drafts.acceptSend(key, draft.revision)
        return id
    }

    // --- Agent -------------------------------------------------------------------

    /** The conversation machine's agent catalog once it has loaded, else null. */
    private fun machineCatalog(): List<Harness>? = daemonId?.let(catalog)

    /** This conversation's composer draft, once its machine is known. */
    private fun draftKey(): DraftKey? = daemonId?.let { DraftKey(it, cardId) }

    /**
     * The composer's agent pickers ([AgentControls.forComposer]) against [harnesses]: the
     * composer's choice while it differs from the card's agent, else the card's agent. Null until
     * the card is known.
     */
    fun agentControls(harnesses: List<Harness>? = machineCatalog()): AgentControls? {
        val card = runCatching { card() }.getOrNull() ?: return null
        val draft = draftKey()?.let { drafts.state.value[it] }?.selection
        return AgentControls.forComposer(
            draft,
            card,
            harnesses.orEmpty(),
            hasMessages = transcript.messages.isNotEmpty(),
        )
    }

    /**
     * Applies a picker choice to the composer's agent for the next message: [choose] gets the
     * pickers ([agentControls]) and returns the next selection. False before the conversation's
     * machine and card are known.
     */
    fun chooseAgent(
        harnesses: List<Harness>? = machineCatalog(),
        choose: (AgentControls) -> HarnessSelection,
    ): Boolean {
        val key = draftKey() ?: return false
        val controls = agentControls(harnesses) ?: return false
        drafts.setSelection(key, choose(controls))
        return true
    }

    /**
     * Drops a composer choice the conversation now runs with, or can no longer take, so the
     * composer follows the card again.
     */
    private fun reconcileAgent() {
        val key = draftKey() ?: return
        val draft = drafts.state.value[key]?.selection ?: return
        val card = runCatching { card() }.getOrNull() ?: return
        if (Selections.pending(draft, card, machineCatalog().orEmpty()) == null)
            drafts.setSelection(key, null)
    }

    /** Only the next queued message may interrupt the running turn. */
    fun canSteer(messageId: String): Boolean {
        val conversation = transcript.conversation ?: return false
        if (steeringMessageId != null) return false
        if (
            board.view.value.operations[cardId] == CardOperation.CANCELLING ||
                conversation.status == "cancelling" ||
                runCatching { card().runtime == "cancelling" }.getOrDefault(false)
        )
            return false
        val working =
            Runtimes.isActive(conversation.status) ||
                runCatching { Runtimes.isActive(card().runtime) }.getOrDefault(false)
        return working &&
            messageId.isNotEmpty() &&
            conversation.queue.firstOrNull()?.id == messageId
    }

    /** Stops the running turn so the next queued message runs now. */
    suspend fun steer(messageId: String): Boolean {
        if (steeringMessageId == messageId) return true
        if (!canSteer(messageId)) return false
        steeringMessageId = messageId
        try {
            return board.cancel(cardId).also { if (!it) steeringMessageId = null }
        } catch (error: Throwable) {
            steeringMessageId = null
            throw error
        }
    }

    /**
     * Removes a queued message. With [edit], its text, attachments, and agent choice return to the
     * composer; a failure leaves the draft unchanged.
     */
    suspend fun removeQueued(messageId: String, edit: Boolean): QueuedMessage? {
        val owner = daemonId ?: return null
        val key = DraftKey(owner, cardId)
        if (edit && !drafts.beginQueueEdit(key, messageId)) return null
        var removed: QueuedMessage? = null
        try {
            removed =
                sessions.call(owner) {
                    it.RemoveQueuedMessage()
                        .execute(
                            RemoveQueuedMessageRequest(card_id = cardId, message_id = messageId)
                        )
                }
            transcript.snapshot?.let { snapshot ->
                val conversation = snapshot.conversation ?: Conversation()
                transcript =
                    transcript.copy(
                        snapshot =
                            snapshot.copy(
                                conversation =
                                    conversation.copy(
                                        queue = conversation.queue.filterNot { it.id == messageId }
                                    )
                            )
                    )
                publish()
            }
            return removed
        } finally {
            if (edit) drafts.finishQueueEdit(key, messageId, removed)
        }
    }

    fun turnFailure(): TurnFailure? =
        TurnFailure.resolve(
            transcript.messages,
            transcript.conversation?.status,
            runCatching { card().runtime }.getOrNull(),
        )

    /**
     * Sends the failed turn's request again with the conversation's own agent, once until it runs.
     */
    fun retryFailedTurn(): String? {
        if (awaiting?.retry == true) return null
        val failure = turnFailure() ?: return null
        if (failure.retryParts.isEmpty()) return null
        val card = card()
        return outbox
            .sendMessage(
                cardId,
                failure.retryParts,
                HarnessSelection(card.provider, card.model, card.effort, card.provider_options),
            )
            .also { await(it, retry = true) }
    }

    /**
     * Records the reply as seen once it is loaded and shown at the latest position. Receipts for a
     * reply the transcript does not contain yet, or while browsing history, are never sent.
     */
    suspend fun markReadIfVisible(): Boolean {
        val card = runCatching { card() }.getOrNull() ?: return false
        val conversation = transcript.conversation ?: return false
        if (card.response_seq <= card.seen_response_seq) return false
        if (conversation.last_seq < card.response_seq) return false
        if (transcript.history.browsingEarlier) return false
        if (conversation.messages.none { it.id == card.response_message_id }) return false
        return board.markRead(cardId, card.response_seq)
    }

    /** A tool call's full payload, cached per revision. */
    suspend fun toolOutput(messageId: String, toolCallId: String, revision: String): ToolOutput {
        val owner =
            daemonId
                ?: throw CoreException(
                    FailureKind.TRANSIENT,
                    "The conversation's machine is unavailable.",
                )
        val key = "$messageId\u0000$toolCallId\u0000$revision"
        toolOutputs[key]?.let {
            return it
        }
        val output =
            sessions.call(owner) {
                it.GetToolOutput()
                    .execute(
                        GetToolOutputRequest(
                            card_id = cardId,
                            message_id = messageId,
                            tool_call_id = toolCallId,
                            revision = revision,
                        )
                    )
            }
        toolOutputs[key] = output
        while (toolOutputs.size > TOOL_OUTPUT_CACHE) toolOutputs.remove(toolOutputs.keys.first())
        return output
    }

    fun close() {
        // Include local queue edits and history changes, not only the last received frame.
        if (transcript.snapshot != null) onTranscript(cardId, transcript)
        scope.cancel()
    }

    // --- Presentation --------------------------------------------------------------

    private fun needsRead(): Boolean {
        if (!OutboxPolicy.isServerBacked(cardId)) return false
        val current = transcript.conversation
        return !confirmed ||
            interrupted ||
            (latestActivity?.let {
                current == null || TranscriptFreshness.compare(it, current) > 0
            } == true) ||
            (store.state.value.card(cardId)?.response_seq ?: 0) > (current?.last_seq ?: 0)
    }

    private fun publish() {
        if (transcript.conversation?.queue?.none { it.id == steeringMessageId } == true)
            steeringMessageId = null
        store.state.value.activities[cardId]?.let { incoming ->
            if (latestActivity?.let { TranscriptFreshness.compare(incoming, it) > 0 } != false)
                latestActivity = incoming
        }
        val outboxView = outbox.view.value
        val presented = presentedSnapshot(outboxView)
        val activity = latestActivity?.takeIf {
            transcript.conversation?.let { current -> TranscriptFreshness.compare(it, current) > 0 }
                ?: true
        }
        val health = daemonId?.let { syncs?.value?.get(it) }
        val healthError =
            when (health?.state) {
                SyncState.OFFLINE ->
                    "The conversation's machine is offline. Displayed activity may be out of date."
                SyncState.STALE ->
                    "The conversation's machine is not responding. Displayed activity may be out of date."
                SyncState.INCOMPATIBLE -> "The conversation's machine needs an update."
                else -> null
            }
        val needsRead = needsRead()
        settleAwaiting(presented, outboxView)
        mutableView.update {
            it.copy(
                transcript = transcript,
                presented = presented,
                activity = activity,
                loading =
                    presented?.conversation == null &&
                        readError == null &&
                        healthError == null &&
                        !paused,
                syncing = !it.pending && !paused && (needsRead || health?.current == false),
                refreshedAt = refreshedAt,
                error = healthError ?: readError,
                awaitingReply = awaiting != null,
                retrying = awaiting?.retry == true,
            )
        }
        reconcileAgent()
        if (needsRead && !paused && daemonId != null && recovery?.isActive != true)
            recovery = scope.launch { recover() }
    }

    /** A reply, a turn that started and ended, or a rejected send ends the wait. */
    private fun settleAwaiting(presented: ConversationSnapshot?, outboxView: OutboxView) {
        val pending = awaiting ?: return
        val card = presented?.detail?.card
        val status = presented?.conversation?.status
        val active = (card != null && Runtimes.isActive(card, status)) || Runtimes.isActive(status)
        awaiting =
            when {
                pending.messageId in outboxView.failedIds -> null
                replies(transcript.messages) > pending.replies -> null
                pending.sawTurn && !active -> null
                active -> pending.copy(sawTurn = true)
                else -> pending
            }
    }

    private fun presentedSnapshot(outboxView: OutboxView): ConversationSnapshot? {
        val base = transcript.snapshot ?: pendingSnapshot(outboxView) ?: return null
        val card =
            store.directoryProjection.item(cardId)?.let { directory ->
                base.detail?.card?.let { com.getdieter.core.sync.mergeCardState(it, directory) }
                    ?: directory
            } ?: base.detail?.card
        return outbox.overlay(base.copy(detail = (base.detail ?: CardDetail()).copy(card = card)))
    }

    /** A conversation the outbox is still creating: its optimistic row and first message. */
    private fun pendingSnapshot(outboxView: OutboxView): ConversationSnapshot? {
        val entry =
            outboxView.entries.firstOrNull { cardId in OutboxPolicy.conversationIds(it) }
                ?: return null
        val card = OutboxPolicy.optimisticCard(entry) ?: return null
        val status = if (entry.state == OutboxState.OUTBOX_STATE_FAILED) "failed" else "pending"
        val request = OutboxPolicy.createRequest(entry)
        return ConversationSnapshot(
            detail = CardDetail(card = card),
            conversation =
                Conversation(
                    card_id = card.id,
                    status = status,
                    draft_attachments =
                        if (request?.defer_start == true) request.attachments else emptyList(),
                ),
        )
    }

    private fun owner(id: String): String {
        outbox.view.value.entries
            .firstOrNull { id in OutboxPolicy.conversationIds(it) }
            ?.let {
                return it.daemon_id
            }
        val directory = store.directoryProjection
        val card =
            directory.item(id)
                ?: cached?.snapshot?.detail?.card
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "The conversation is no longer available.",
                )
        return directory.owner(card)
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "The conversation's machine is unavailable.",
            )
    }

    companion object {
        private const val TAG = "Conversation"
        private const val TOOL_OUTPUT_CACHE = 32

        /**
         * A send while the agent works ([card]'s runtime or [conversation]'s status), or behind
         * queued messages, joins the queue.
         */
        fun placement(card: Card?, conversation: Conversation?): OutboxPlacement {
            val working =
                (card != null && Runtimes.isActive(card, conversation?.status)) ||
                    Runtimes.isActive(conversation?.status)
            return if (working || conversation?.queue.orEmpty().isNotEmpty())
                OutboxPlacement.OUTBOX_PLACEMENT_QUEUE
            else OutboxPlacement.OUTBOX_PLACEMENT_TRANSCRIPT
        }

        /**
         * Fails unless [parts] can be sent: some text or an attachment, with attachments within the
         * daemon's limits.
         */
        fun checkSendable(parts: List<MessagePart>) {
            if (parts.none { it.type != "text" || it.text.isNotBlank() })
                throw CoreException(FailureKind.PERMANENT, "Write a message or attach a file.")
            Attachments.limitError(parts.filter { it.type != "text" })?.let {
                throw CoreException(FailureKind.PERMANENT, it)
            }
        }

        /** The first resubscription is immediate; repeated failures back off to 5 s. */
        fun resubscribeDelay(consecutiveFailures: Int): Duration {
            if (consecutiveFailures <= 1) return Duration.ZERO
            val seconds = minOf(5.0, 0.25 * 1.8.pow(consecutiveFailures - 2))
            return (seconds * 1000).toLong().milliseconds
        }
    }
}

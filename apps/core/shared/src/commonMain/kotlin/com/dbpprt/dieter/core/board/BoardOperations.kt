package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.ArchiveCardRequest
import com.dbpprt.dieter.api.v1.BoardRef
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.DraftAgentSettings
import com.dbpprt.dieter.api.v1.ForkChatRequest
import com.dbpprt.dieter.api.v1.GetCardRequest
import com.dbpprt.dieter.api.v1.MarkConversationReadRequest
import com.dbpprt.dieter.api.v1.MergeCardRequest
import com.dbpprt.dieter.api.v1.MoveCardRequest
import com.dbpprt.dieter.api.v1.PinChatRequest
import com.dbpprt.dieter.api.v1.RenameCardRequest
import com.dbpprt.dieter.api.v1.SetCardLabelsRequest
import com.dbpprt.dieter.api.v1.UpdateCardRequest
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.CardOverlay
import com.dbpprt.dieter.core.store.WorkspaceStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.uuid.Uuid
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Card operations in flight and their last failures, for badges and inline errors. */
data class BoardOperationsView(
    val operations: Map<String, CardOperation> = emptyMap(),
    val errors: Map<String, String> = emptyMap(),
    /** Moves sync has not confirmed yet; lane ordering applies them. */
    val moves: Map<String, PendingMove> = emptyMap(),
)

/**
 * Direct card and chat mutations. Each shows its effect immediately as an
 * overlay, applies the daemon's answer through the causal card merge, and
 * rolls back on failure. One operation per card at a time: a second one
 * fails as transient while the first runs. A mutation returns false when
 * there is nothing to change. Confined to the core dispatcher.
 */
class BoardOperations(private val sessions: MachineSessions, private val store: WorkspaceStore) {
    private val mutableView = MutableStateFlow(BoardOperationsView())
    val view: StateFlow<BoardOperationsView> = mutableView.asStateFlow()

    /** Moves [cardId] to [lane], optionally between two cards of that lane. */
    suspend fun move(cardId: String, lane: String, anchors: DropAnchors = DropAnchors()): Boolean {
        val card = card(cardId)
        if (Cards.isChat(card)) throw CoreException(FailureKind.PERMANENT, "Chat conversations do not belong to board lanes.")
        // Moving an unstarted card into running starts it, which only its owner can do.
        val starts = lane.equals(Lanes.RUNNING, ignoreCase = true) && card.initial_prompt_sent_at.isEmpty()
        val daemon = if (starts) owner(card) else replica(card)
        val request = MoveCardRequest(
            card_id = cardId, lane = lane, after_card_id = anchors.afterCardId, before_card_id = anchors.beforeCardId,
            expected_revision = card.placement_revision,
        )
        val move = PendingMove(lane, anchors.afterCardId, anchors.beforeCardId)
        return mutate(
            cardId, CardOperation.MOVING, daemon,
            overlay = FieldOverlay(cardId, apply = { it.copy(lane = lane) }, satisfied = { it.placement_revision != card.placement_revision }),
            onStart = { mutableView.update { it.copy(moves = it.moves + (cardId to move)) } },
            onEnd = { mutableView.update { it.copy(moves = it.moves - cardId) } },
        ) { it.MoveCard().execute(request) }
    }

    /** Moves a card to its board's done lane. */
    suspend fun finish(cardId: String): Boolean {
        val card = card(cardId)
        val done = Lanes.done(store.directoryProjection.board(card.board_id)) ?: throw CoreException(FailureKind.PERMANENT, "This board has no done lane.")
        return move(cardId, done.id)
    }

    /** Replaces the card's labels, keeping their order and dropping duplicates. */
    suspend fun setLabels(cardId: String, labelIds: List<String>): Boolean {
        val card = card(cardId)
        val ids = labelIds.filter { it.isNotBlank() }.distinct()
        if (ids == card.label_ids) return false
        return mutate(cardId, CardOperation.LABELING, replica(card), FieldOverlay(cardId, { it.copy(label_ids = ids) }, { it.label_ids == ids })) {
            it.SetCardLabels().execute(SetCardLabelsRequest(card_id = cardId, label_ids = ids))
        }
    }

    suspend fun addLabel(cardId: String, labelId: String): Boolean {
        val card = card(cardId)
        if (labelId.isBlank() || labelId in card.label_ids) return false
        return setLabels(cardId, card.label_ids + labelId)
    }

    suspend fun setPinned(cardId: String, pinned: Boolean): Boolean {
        val card = card(cardId)
        if (card.pinned == pinned) return false
        return mutate(cardId, CardOperation.PINNING, replica(card), FieldOverlay(cardId, { it.copy(pinned = pinned) }, { it.pinned == pinned })) {
            it.PinChat().execute(PinChatRequest(card_id = cardId, pinned = pinned))
        }
    }

    suspend fun rename(cardId: String, title: String): Boolean {
        val card = card(cardId)
        val trimmed = title.trim()
        if (trimmed.isEmpty() || trimmed == card.title) return false
        return mutate(cardId, CardOperation.RENAMING, replica(card), FieldOverlay(cardId, { it.copy(title = trimmed) }, { it.title == trimmed })) {
            it.RenameCard().execute(RenameCardRequest(card_id = cardId, title = trimmed))
        }
    }

    /** Edits a never-started todo card's title, task, and agent. */
    suspend fun updateDraft(cardId: String, title: String, prompt: String, agent: DraftAgentSettings? = null): Boolean {
        val card = card(cardId)
        if (!CardPolicy.canEditDraft(card)) throw CoreException(FailureKind.PERMANENT, "Only a todo card whose task was never sent can be edited.")
        val request = UpdateCardRequest(card_id = cardId, title = title.trim(), initial_prompt = prompt, agent_settings = agent)
        return mutate(
            cardId, CardOperation.UPDATING, owner(card),
            FieldOverlay(cardId, { it.copy(title = request.title.ifEmpty { it.title }, initial_prompt = prompt) }, { it.initial_prompt == prompt }),
        ) { it.UpdateCard().execute(request) }
    }

    /**
     * Saves the edit card form under [CardPolicy.draftProblem]: a
     * never-started draft takes the new title, task, and agent; a card whose
     * task was sent only takes a new title.
     */
    suspend fun edit(cardId: String, title: String, prompt: String, agent: DraftAgentSettings? = null): Boolean {
        val card = card(cardId)
        CardPolicy.draftProblem(card, title, prompt, agent)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        if (CardPolicy.canEditDraft(card)) return updateDraft(cardId, title, prompt, agent)
        return rename(cardId, title)
    }

    /** Archives a card or chat; it leaves every live view. */
    suspend fun archive(cardId: String): Boolean {
        val card = card(cardId)
        if (card.archived) return false
        return mutate(cardId, CardOperation.ARCHIVING, replica(card), FieldOverlay(cardId, { it.copy(archived = true) }, { it.archived })) {
            it.ArchiveCard().execute(ArchiveCardRequest(card_id = cardId, archived = true))
        }
    }

    /** Restores [card], as listed by [archivedCards] or the chat archive, to the live views. */
    suspend fun restore(card: Card): Boolean {
        if (!card.archived) return false
        return mutate(card.id, CardOperation.ARCHIVING, replica(card), overlay = null) {
            it.ArchiveCard().execute(ArchiveCardRequest(card_id = card.id, archived = false))
        }
    }

    /** Stops the running turn; the card shows "cancelling" until its runtime settles. */
    suspend fun cancel(cardId: String): Boolean {
        val card = card(cardId)
        return mutate(
            cardId, CardOperation.CANCELLING, owner(card),
            FieldOverlay(cardId, { if (Runtimes.isActive(it.runtime)) it.copy(runtime = "cancelling") else it }, { !Runtimes.isActive(it.runtime) }),
            confirm = false,
        ) { client ->
            client.CancelCard().execute(GetCardRequest(card_id = cardId))
            null
        }
    }

    /** Folds an idle card's queue-free conversation into [targetId]; the source moves to done. */
    suspend fun merge(sourceId: String, targetId: String): Boolean {
        val source = card(sourceId)
        val target = card(targetId)
        if (!CardPolicy.canMerge(source, target)) throw CoreException(FailureKind.PERMANENT, "These cards cannot be merged.")
        return mutate(sourceId, CardOperation.MERGING, owner(source), overlay = null) {
            it.MergeCard().execute(MergeCardRequest(card_id = sourceId, target_card_id = targetId))
        }
    }

    /** Branches a chat at [messageId] (the whole conversation when blank); returns the fork. */
    suspend fun fork(cardId: String, messageId: String = ""): Card {
        val card = card(cardId)
        var fork: Card? = null
        mutate(cardId, CardOperation.FORKING, owner(card), overlay = null) { client ->
            client.ForkChat().execute(ForkChatRequest(source_card_id = cardId, message_id = messageId)).also { fork = it }
        }
        return fork ?: throw CoreException(FailureKind.TRANSIENT, "The fork was not created.")
    }

    /**
     * Records that the reply up to [responseSeq] was seen. The daemon ignores
     * stale receipts and the causal merge keeps newer replies unread.
     */
    suspend fun markRead(cardId: String, responseSeq: Long): Boolean {
        val card = card(cardId)
        if (responseSeq <= card.seen_response_seq || responseSeq != card.response_seq) return false
        if (view.value.operations.containsKey(cardId)) return false
        return mutate(cardId, CardOperation.READING, owner(card), overlay = null, reportErrors = false) {
            it.MarkConversationRead().execute(MarkConversationReadRequest(card_id = cardId, response_seq = responseSeq))
        }
    }

    /** Archived cards of one board, read on demand from a replica. */
    suspend fun archivedCards(boardId: String): List<Card> {
        val board = store.directoryProjection.board(boardId) ?: throw CoreException(FailureKind.PERMANENT, "The board is no longer available.")
        val daemon = store.directoryProjection.projectReplicas[board.project_id]
            ?: throw CoreException(FailureKind.TRANSIENT, "The project's machine is unavailable.")
        return sessions.call(daemon) { it.ListArchivedCards().execute(BoardRef(board_id = boardId)) }.cards
    }

    private suspend fun mutate(
        cardId: String,
        operation: CardOperation,
        daemonId: String,
        overlay: FieldOverlay?,
        confirm: Boolean = true,
        reportErrors: Boolean = true,
        onStart: () -> Unit = {},
        onEnd: () -> Unit = {},
        call: suspend (DieterServiceClient) -> Card?,
    ): Boolean {
        // Repeating the change in flight (a double tap) is a no-op; a different change is refused.
        view.value.operations[cardId]?.let { running ->
            if (running == operation) return false
            throw CoreException(FailureKind.TRANSIENT, "Another change to this card is still in progress.")
        }
        mutableView.update { it.copy(operations = it.operations + (cardId to operation), errors = it.errors - cardId) }
        onStart()
        overlay?.let(store::addOverlay)
        try {
            val result = sessions.call(daemonId, call)
            result?.let { store.foldCard(it, daemonId) }
            if (overlay != null) {
                if (confirm || result == null) store.confirmOverlay(overlay.operationId) else store.rollbackOverlay(overlay.operationId)
            }
            return true
        } catch (error: Throwable) {
            overlay?.let { store.rollbackOverlay(it.operationId) }
            if (error is CancellationException) throw error
            if (reportErrors) mutableView.update { it.copy(errors = (it.errors - cardId + (cardId to Failures.message(error))).toList().takeLast(MAX_ERRORS).toMap()) }
            throw error
        } finally {
            onEnd()
            mutableView.update { it.copy(operations = it.operations - cardId) }
        }
    }


    /** Drops the errors of cards that left every live view. */
    fun retainErrors(present: (String) -> Boolean) {
        if (view.value.errors.keys.all(present)) return
        mutableView.update { state -> state.copy(errors = state.errors.filterKeys(present)) }
    }

    /** Account or gateway changed: the errors belong to the previous one. */
    fun reset() = mutableView.update { it.copy(errors = emptyMap()) }

    private fun card(id: String): Card = store.directoryProjection.item(id)
        ?: throw CoreException(FailureKind.PERMANENT, "The card is no longer available.")

    /** Shared placement and metadata can be written to any replica of the project. */
    private fun replica(card: Card): String = store.directoryProjection.projectReplicas[card.project_id]
        ?: card.owner_daemon_id.ifEmpty { null }
        ?: throw CoreException(FailureKind.TRANSIENT, "The project's machine is unavailable.")

    /** Turns, reads, and edits of the task run on the machine that executes the conversation. */
    private fun owner(card: Card): String = store.directoryProjection.owner(card) ?: replica(card)

    private companion object {
        /** Inline errors kept at once; the oldest goes first. */
        const val MAX_ERRORS = 64
    }

    private class FieldOverlay(override val cardId: String, private val apply: (Card) -> Card, private val satisfied: (Card) -> Boolean) : CardOverlay {
        override val operationId: String = Uuid.random().toString()
        override fun apply(card: Card): Card = apply.invoke(card)
        override fun satisfiedBy(card: Card): Boolean = satisfied(card)
    }
}

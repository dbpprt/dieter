package com.getdieter.mobile.store

import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.UiMessage
import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import com.getdieter.core.client.Keyed
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** The open conversation: its scope, detail tab, drafts, and the commands it sends. */
class ConversationModel
internal constructor(
    private val context: StoreContext,
    private val outbox: StateFlow<OutboxSlice>,
) {
    val slice = MutableStateFlow(ConversationSlice())
    val selectedCard = MutableStateFlow("")
    val detailTab = MutableStateFlow("Conversation")
    val draftTexts = MutableStateFlow<Map<String, String>>(emptyMap())
    private var subscription: ClientSubscription? = null
    private var boundScope = ""
    private val resolvedScopes = mutableMapOf<String, String>()
    private var generation = 0
    private val draftJobs = mutableMapOf<String, Job>()
    private val draftDaemons = mutableMapOf<String, String>()

    /** True while the open conversation shows its terminals. */
    internal val showsTerminal: Boolean
        get() = selectedCard.value.isNotEmpty() && detailTab.value == "Terminal"

    /** The server ID a new task resolved to, or [cardId] itself. */
    internal fun resolve(cardId: String) = outbox.value.resolutions[cardId] ?: cardId

    internal fun loadDrafts() = context.action {
        val loaded =
            context.core.dispatch(Command(list_drafts = ListDrafts())).drafts?.drafts.orEmpty()
        loaded.forEach {
            if (it.card_id !in draftDaemons) draftDaemons[it.card_id] = it.daemon_id
        }
        draftTexts.value = loaded.associate { it.card_id to it.text } + draftTexts.value
    }

    internal fun follow(next: OutboxSlice) {
        resolvedScopes.keys.retainAll(next.resolutions.values.toSet())
        next.resolutions[selectedCard.value]?.let { resolved ->
            // The core keeps the open local-ID scope alive as its server ID arrives.
            // Reopening here lets asynchronous release of the old scope close that
            // same resolved session. Update navigation and keep its observation.
            if (resolved != selectedCard.value) {
                resolvedScopes[resolved] = boundScope
                selectedCard.value = resolved
            }
        }
    }

    /** Binds the conversation scope. Call [MobileStore.openConversation] to navigate. */
    internal fun bind(requested: String) {
        val id = resolve(requested)
        if (id == selectedCard.value) return
        generation += 1
        val current = generation
        subscription?.close()
        slice.value = ConversationSlice(card_id = id, loading = true)
        selectedCard.value = id
        boundScope = resolvedScopes[id] ?: id
        detailTab.value = "Conversation"
        subscription =
            context.observe(Slice.SLICE_CONVERSATION, boundScope) { update ->
                if (current == generation && !context.closed) {
                    update.conversation?.let { slice.value = it }
                    update.conversation_delta?.let { slice.value = fold(slice.value, it) }
                    update.failure?.let { context.error.value = it.message }
                }
            }
        context.action {
            context.core.dispatch(
                Command(set_visible_conversation = SetVisibleConversation(card_id = id))
            )
        }
    }

    internal fun unbind() {
        generation += 1
        subscription?.close()
        subscription = null
        selectedCard.value = ""
        detailTab.value = "Conversation"
        context.action {
            context.core.dispatch(Command(set_visible_conversation = SetVisibleConversation()))
        }
    }

    /** Stops observing for good; late updates of the open conversation are dropped. */
    internal fun release() {
        generation += 1
        subscription?.close()
    }

    suspend fun send(
        text: String,
        cardId: String = selectedCard.value,
        parts: List<MessagePart> = emptyList(),
    ) {
        context.core.dispatch(
            Command(send_message = SendMessage(card_id = cardId, text = text, parts = parts))
        )
        saveDraft(cardId, "")
    }

    fun move(lane: String) {
        val id = selectedCard.value
        context.action {
            context.core.dispatch(Command(move_card = MoveCard(card_id = id, lane = lane)))
        }
    }

    fun stop() {
        val id = selectedCard.value
        context.action { context.core.dispatch(Command(cancel_card = CancelCard(card_id = id))) }
    }

    fun start() {
        val id = selectedCard.value
        context.action { context.core.dispatch(Command(start_card = StartCard(card_id = id))) }
    }

    fun loadEarlier() {
        val id = selectedCard.value
        context.action {
            context.core.dispatch(
                Command(load_earlier_messages = LoadEarlierMessages(card_id = id))
            )
        }
    }

    fun retryTurn() {
        val id = selectedCard.value
        context.action {
            context.core.dispatch(Command(retry_failed_turn = RetryFailedTurn(card_id = id)))
        }
    }

    fun saveDraft(id: String, text: String) {
        draftTexts.value = draftTexts.value + (id to text)
        val daemon = slice.value.daemon_id
        draftDaemons[id] = daemon
        draftJobs.remove(id)?.cancel()
        draftJobs[id] =
            context.scope.launch {
                delay(300)
                try {
                    context.core.dispatch(
                        Command(
                            set_draft_text =
                                SetDraftText(daemon_id = daemon, card_id = id, text = text)
                        )
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    context.error.value = failure.message ?: "Unable to save the draft."
                }
            }
    }

    suspend fun flushDrafts() {
        draftJobs.values.forEach { it.cancel() }
        draftJobs.clear()
        draftTexts.value.forEach { (id, text) ->
            val daemon = draftDaemons[id].orEmpty()
            if (daemon.isNotEmpty())
                context.core.dispatch(Command(set_draft_text = SetDraftText(daemon, id, text)))
        }
    }
}

// Snapshot folding is UI protocol plumbing. No ordering or business policy lives here.
private fun fold(base: ConversationSlice, delta: ConversationDelta) =
    base.copy(
        card = delta.card,
        conversation = delta.conversation,
        messages =
            Keyed.apply(
                base.messages,
                delta.upserted_messages,
                delta.removed_message_ids,
                delta.message_order.takeIf { delta.order_changed },
                UiMessage::id,
            ),
        loading = delta.loading,
        syncing = delta.syncing,
        error = delta.error,
        pending = delta.pending,
        has_earlier = delta.has_earlier,
        loading_earlier = delta.loading_earlier,
        browsing_earlier = delta.browsing_earlier,
        retrying = delta.retrying,
        refreshed_at_millis = delta.refreshed_at_millis,
        turn_failure = delta.turn_failure,
        project = delta.project,
        board = delta.board,
        page = delta.page,
        card_id = delta.card_id.ifEmpty { base.card_id },
        daemon_id = delta.daemon_id,
        earlier_count = delta.earlier_count,
        state = delta.state,
        timeline =
            Keyed.apply(
                base.timeline,
                delta.upserted_timeline,
                delta.removed_timeline_ids,
                delta.timeline_order.takeIf { delta.timeline_order_changed },
                TimelineItem::id,
            ),
        unattached_plan_ids = delta.unattached_plan_ids,
    )

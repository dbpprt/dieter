package com.dbpprt.dieter.mobile

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.core.client.Keyed
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The same typed core contract on Android/JVM and through the Apple byte bridge. */
interface MobileCore {
    suspend fun dispatch(command: Command): Result

    fun observe(slice: Slice, scope: String, receive: (Update) -> Unit): ClientSubscription
}

class RuntimeMobileCore(private val api: ClientApi) : MobileCore {
    override suspend fun dispatch(command: Command) = api.dispatch(command)

    override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
        api.observe(slice, scope, receive)
}

enum class MobileTab {
    BOARD,
    CHATS,
    MACHINES,
}

/** View lifetime and navigation only; the existing core decides all task behavior. */
class MobileStore(val core: MobileCore, dispatcher: CoroutineDispatcher = Dispatchers.Main) {
    // Explicit choices use the core's selection validation; null uses its remembered defaults.
    var agentSelection: com.dbpprt.dieter.api.v1.HarnessSelection? = null
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val commands = Mutex()
    val session = MutableStateFlow(SessionSlice())
    val workspace = MutableStateFlow(WorkspaceSlice())
    val outbox = MutableStateFlow(OutboxSlice())
    val board = MutableStateFlow(BoardViewSlice())
    val conversation = MutableStateFlow(ConversationSlice())
    val tab = MutableStateFlow(MobileTab.BOARD)
    val selectedCard = MutableStateFlow("")
    val selectedBoard = MutableStateFlow("")
    val creating = MutableStateFlow(false)
    val signInUrl = MutableStateFlow("")
    val busy = MutableStateFlow(false)
    val error = MutableStateFlow("")
    private val subscriptions = mutableListOf<ClientSubscription>()
    private var conversationSubscription: ClientSubscription? = null
    private var conversationScope = ""
    private val resolvedScopes = mutableMapOf<String, String>()
    private var generation = 0
    private var closed = false

    init {
        subscriptions +=
            observe(Slice.SLICE_SESSION, "") { update ->
                update.session?.let { session.value = it }
            }
        subscriptions +=
            observe(Slice.SLICE_WORKSPACE, "") { update ->
                update.workspace?.let { workspace.value = it }
                update.workspace_delta?.let { workspace.value = fold(workspace.value, it) }
            }
        subscriptions +=
            observe(Slice.SLICE_OUTBOX, "") { update ->
                update.outbox?.let { next ->
                    outbox.value = next
                    resolvedScopes.keys.retainAll(next.resolutions.values.toSet())
                    next.resolutions[selectedCard.value]?.let { resolved ->
                        // The core keeps the open local-ID scope alive as its server ID arrives.
                        // Reopening here lets asynchronous release of the old scope close that
                        // same resolved session. Update navigation and keep its observation.
                        if (resolved != selectedCard.value) {
                            resolvedScopes[resolved] = conversationScope
                            selectedCard.value = resolved
                        }
                    }
                    next.storage_error.takeIf { it.isNotEmpty() }?.let { error.value = it }
                    next.failures.values.firstOrNull()?.let { error.value = it }
                }
            }
        subscriptions +=
            observe(Slice.SLICE_BOARD_VIEW, BOARD_SCOPE) { update ->
                update.board_view?.let { board.value = it }
            }
    }

    private fun observe(slice: Slice, key: String, receive: (Update) -> Unit) =
        core.observe(slice, key) { update ->
            scope.launch { if (!closed) receive(update) }
        }

    fun chooseBoard(id: String) {
        selectedBoard.value = id
        action {
            core.dispatch(
                Command(
                    board_view =
                        BoardViewCommand(scope = BOARD_SCOPE, bind = BoardViewTarget(board_id = id))
                )
            )
        }
    }

    fun openCard(requested: String) {
        val id = outbox.value.resolutions[requested] ?: requested
        if (id == selectedCard.value) return
        generation += 1
        val current = generation
        conversationSubscription?.close()
        conversation.value = ConversationSlice(card_id = id, loading = true)
        selectedCard.value = id
        conversationScope = resolvedScopes[id] ?: id
        creating.value = false
        conversationSubscription =
            observe(Slice.SLICE_CONVERSATION, conversationScope) { update ->
                if (current == generation && !closed) {
                    update.conversation?.let { conversation.value = it }
                    update.conversation_delta?.let {
                        conversation.value = fold(conversation.value, it)
                    }
                    update.failure?.let { error.value = it.message }
                }
            }
        action {
            core.dispatch(Command(set_visible_conversation = SetVisibleConversation(card_id = id)))
        }
    }

    fun back() {
        generation += 1
        conversationSubscription?.close()
        conversationSubscription = null
        selectedCard.value = ""
        creating.value = false
        action { core.dispatch(Command(set_visible_conversation = SetVisibleConversation())) }
    }

    suspend fun create(title: String, prompt: String, run: Boolean): String {
        val destination =
            workspace.value.boards.firstOrNull { it.id == selectedBoard.value }
                ?: workspace.value.boards.firstOrNull()
                ?: error("Choose a board first.")
        val result =
            core.dispatch(
                Command(
                    create_conversation =
                        CreateConversation(
                            intent =
                                CreationIntent(
                                    project_id = destination.project_id,
                                    board_id = destination.id,
                                    title = title,
                                    prompt = prompt,
                                    selection = agentSelection,
                                    lane = if (run) "running" else "todo",
                                    workspace_mode = "project",
                                )
                        )
                )
            )
        return result.card?.id ?: error("The core returned no task.")
    }

    suspend fun send(text: String, cardId: String = selectedCard.value) {
        core.dispatch(Command(send_message = SendMessage(card_id = cardId, text = text)))
    }

    fun move(lane: String) {
        val id = selectedCard.value
        action { core.dispatch(Command(move_card = MoveCard(card_id = id, lane = lane))) }
    }

    fun stop() {
        val id = selectedCard.value
        action { core.dispatch(Command(cancel_card = CancelCard(card_id = id))) }
    }

    fun start() {
        val id = selectedCard.value
        action { core.dispatch(Command(start_card = StartCard(card_id = id))) }
    }

    fun signIn(url: String) = action {
        signInUrl.value =
            core
                .dispatch(Command(begin_sign_in = BeginSignIn(url)))
                .sign_in_started
                ?.authorize_url
                .orEmpty()
    }

    fun completeSignIn(url: String) = action {
        core.dispatch(Command(complete_sign_in = CompleteSignIn(url)))
    }

    fun retry() = action { core.dispatch(Command(reconnect = Reconnect())) }

    fun loadEarlier() {
        val id = selectedCard.value
        action { core.dispatch(Command(load_earlier_messages = LoadEarlierMessages(card_id = id))) }
    }

    fun retryTurn() {
        val id = selectedCard.value
        action { core.dispatch(Command(retry_failed_turn = RetryFailedTurn(card_id = id))) }
    }

    fun action(block: suspend () -> Unit) {
        if (closed) return
        scope.launch {
            commands.withLock {
                busy.value = true
                error.value = ""
                try {
                    block()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    error.value = failure.message ?: "The action failed."
                } finally {
                    busy.value = false
                }
            }
        }
    }

    fun close() {
        if (closed) return
        closed = true
        generation += 1
        conversationSubscription?.close()
        subscriptions.forEach(ClientSubscription::close)
        scope.cancel()
    }

    companion object {
        const val BOARD_SCOPE = "compose-mobile-board"
    }
}

// Snapshot folding is UI protocol plumbing. No ordering or business policy lives here.
private fun fold(base: WorkspaceSlice, delta: WorkspaceDelta) =
    base.copy(
        projects = delta.projects,
        boards = delta.boards,
        cards =
            Keyed.apply(
                base.cards,
                delta.upserted_cards,
                delta.removed_card_ids,
                delta.card_order.takeIf { delta.order_changed },
                Card::id,
            ),
        pending_card_ids = delta.pending_card_ids,
        loaded = delta.loaded,
        retired_boards = delta.retired_boards,
        board_attention = delta.board_attention,
        project_hosts = delta.project_hosts,
    )

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

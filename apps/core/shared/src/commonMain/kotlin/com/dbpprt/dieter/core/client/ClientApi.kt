package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.ActivityRow
import com.dbpprt.dieter.client.v1.ActivitySlice
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ConversationDelta
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.GatewayEntry
import com.dbpprt.dieter.client.v1.GatewaySelected
import com.dbpprt.dieter.client.v1.MachineEntry
import com.dbpprt.dieter.client.v1.MachineOutbox
import com.dbpprt.dieter.client.v1.MessageQueued
import com.dbpprt.dieter.client.v1.OutboxSlice
import com.dbpprt.dieter.client.v1.PageLoaded
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.client.v1.SessionSlice
import com.dbpprt.dieter.client.v1.SignInStarted
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.WorkspaceDelta
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.activity.ActivitySection
import com.dbpprt.dieter.core.board.DropAnchors
import com.dbpprt.dieter.core.conversation.ConversationSession
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.files.FileConflictException
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** A command the core rejected, with the kind the UI acts on. */
class ClientFailure(val failure: Failure) : Exception(failure.message)

/** An active observation; [close] stops it and releases what it opened. */
fun interface ClientSubscription {
    fun close()
}

/**
 * The schema-first UI contract (D7): one command dispatcher and one slice
 * observer over [CoreRuntime]. Android may keep using the runtime's flows
 * directly; Apple reaches the core only through this, as encoded bytes.
 */
class ClientApi(private val runtime: CoreRuntime) {
    private val conversationRefs = mutableMapOf<String, Int>()

    /** Runs [command]; throws [ClientFailure] with a classified reason. */
    suspend fun dispatch(command: Command): Result = try {
        runtime.onCore { execute(command) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: ClientFailure) {
        throw failure
    } catch (error: Throwable) {
        throw ClientFailure(classify(error))
    }

    private suspend fun execute(command: Command): Result {
        val done = Result(done = Done())
        command.adopt_session?.let { adopt ->
            if (adopt.session_token.isBlank()) invalid("The session token is empty.")
            val gateway = gateway(adopt.gateway_url, adopt.name)
            runtime.adoptSession(gateway, adopt.session_token)
            return Result(gateway_selected = GatewaySelected(gateway.origin))
        }
        command.begin_sign_in?.let { return Result(sign_in_started = SignInStarted(runtime.beginSignIn(gateway(it.gateway_url, "")))) }
        command.complete_sign_in?.let { return Result(gateway_selected = GatewaySelected(runtime.completeSignIn(it.callback_url).origin)) }
        command.sign_out?.let { runtime.signOut(); return done }
        command.select_gateway?.let { runtime.selectGateway(it.origin); return done }
        command.attach_machine?.let { runtime.attachMachine(it.daemon_id); return done }
        command.set_connected?.let { runtime.setConnected(it.connected); return done }
        command.set_foreground?.let { runtime.setActive(it.foreground); return done }
        command.create_conversation?.let { create ->
            val request = create.request ?: invalid("A conversation request is required.")
            return Result(card = runtime.createConversation(request, create.chat, create.submission_id.ifEmpty { null }))
        }
        command.send_message?.let { send ->
            val placement = if (send.queue) OutboxPlacement.OUTBOX_PLACEMENT_QUEUE else OutboxPlacement.OUTBOX_PLACEMENT_TRANSCRIPT
            val id = runtime.sendMessage(send.card_id, send.parts, send.selection ?: HarnessSelection(), placement)
            return Result(message_queued = MessageQueued(id))
        }
        command.start_card?.let { runtime.startCard(it.card_id, it.has_draft_attachments); return done }
        command.move_card?.let { board { move(it.card_id, it.lane, DropAnchors(it.after_card_id, it.before_card_id)) }; return done }
        command.finish_card?.let { board { finish(it.card_id) }; return done }
        command.set_card_labels?.let { board { setLabels(it.card_id, it.label_ids) }; return done }
        command.set_card_pinned?.let { board { setPinned(it.card_id, it.pinned) }; return done }
        command.rename_card?.let { board { rename(it.card_id, it.title) }; return done }
        command.archive_card?.let { board { archive(it.card_id) }; return done }
        command.restore_card?.let { restore ->
            val card = runtime.board.archivedCards(restore.board_id).firstOrNull { it.id == restore.card_id }
                ?: invalid("The archived card is no longer available.")
            board { restore(card) }
            return done
        }
        command.cancel_card?.let { board { cancel(it.card_id) }; return done }
        command.mark_card_read?.let { read ->
            val card = runtime.workspace.state.value.card(read.card_id) ?: invalid("The card is no longer available.")
            board { markRead(card.id, card.response_seq) }
            return done
        }
        command.retry_pending?.let { if (it.daemon_id.isNotEmpty()) runtime.retryPendingOn(it.daemon_id) else runtime.retryPending(it.id); return done }
        command.discard_pending?.let { if (it.daemon_id.isNotEmpty()) runtime.discardPendingOn(it.daemon_id) else runtime.discardPending(it.id); return done }
        command.load_earlier_messages?.let { return Result(page_loaded = PageLoaded(conversation(it.card_id).loadEarlier())) }
        command.return_to_latest?.let { conversation(it.card_id).returnToLatest(); return done }
        command.refresh_conversation?.let { conversation(it.card_id).refresh(); return done }
        command.set_visible_conversation?.let { visible ->
            runtime.visibleConversationId = visible.card_id.ifEmpty { null }
            if (visible.card_id.isNotEmpty()) runtime.conversations.session(visible.card_id)?.markReadIfVisible()
            return done
        }
        command.rename_machine?.let { runtime.renameMachine(it.daemon_id, it.name); return done }
        command.revoke_machine?.let { runtime.revokeMachine(it.daemon_id); return done }
        invalid("This command is not supported by this core.")
    }

    private suspend fun board(block: suspend com.dbpprt.dieter.core.board.BoardOperations.() -> Boolean) {
        if (!runtime.board.block()) {
            val error = runtime.board.view.value.errors.values.lastOrNull()
            throw ClientFailure(Failure(Failure.Kind.KIND_TRANSIENT, error ?: "The change was not applied."))
        }
    }

    private fun conversation(cardId: String): ConversationSession =
        runtime.conversations.session(cardId) ?: invalid("Open the conversation first.")

    private fun gateway(url: String, name: String): Gateway =
        Gateway.parse(url, name.ifEmpty { "Custom" }) ?: invalid("That is not a valid gateway address.")

    private fun invalid(message: String): Nothing = throw ClientFailure(Failure(Failure.Kind.KIND_INVALID, message))

    // --- Observation ------------------------------------------------------------------

    /**
     * Delivers [slice] to [observer] on the core dispatcher: a snapshot first,
     * then deltas for keyed slices. [scope] is the card ID for conversations.
     */
    fun observe(slice: Slice, scope: String, observer: (Update) -> Unit): ClientSubscription {
        var sequence = 0L
        fun emit(update: Update) = observer(update.copy(slice = slice, scope = scope, sequence = ++sequence))
        val job: Job = when (slice) {
            Slice.SLICE_SESSION -> collect(sessionSlices()) { emit(Update(session = it)) }
            Slice.SLICE_WORKSPACE -> {
                var previous: WorkspaceSlice? = null
                collect(workspaceSlices()) { next ->
                    val last = previous
                    previous = next
                    if (last == null) emit(Update(workspace = next)) else workspaceDelta(last, next)?.let { emit(Update(workspace_delta = it)) }
                }
            }
            Slice.SLICE_OUTBOX -> collect(outboxSlices()) { emit(Update(outbox = it)) }
            Slice.SLICE_ACTIVITY -> collect(activitySlices()) { emit(Update(activity = it)) }
            Slice.SLICE_CONVERSATION -> {
                var previous: ConversationSlice? = null
                val opened = runtime.scope.launch {
                    val session = retain(scope)
                    try {
                        session.view.map(::conversationSlice).distinctUntilChanged().collect { next ->
                            val last = previous
                            previous = next
                            if (last == null) emit(Update(conversation = next)) else conversationDelta(last, next)?.let { emit(Update(conversation_delta = it)) }
                        }
                    } finally {
                        release(scope)
                    }
                }
                opened
            }
            else -> throw ClientFailure(Failure(Failure.Kind.KIND_INVALID, "Unknown slice $slice"))
        }
        return ClientSubscription { job.cancel() }
    }

    private fun <T> collect(flow: Flow<T>, block: (T) -> Unit): Job =
        runtime.scope.launch { flow.distinctUntilChanged().collect { block(it) } }

    private fun retain(cardId: String): ConversationSession {
        conversationRefs[cardId] = (conversationRefs[cardId] ?: 0) + 1
        return runtime.conversations.open(cardId)
    }

    private fun release(cardId: String) {
        val count = (conversationRefs[cardId] ?: 1) - 1
        if (count > 0) {
            conversationRefs[cardId] = count
        } else {
            conversationRefs.remove(cardId)
            runtime.conversations.close(cardId)
        }
    }

    fun sessionSlices(): Flow<SessionSlice> = combine(
        runtime.connection.state, runtime.connection.machines, runtime.accounts.state, runtime.sessions.routes,
    ) { connection, machines, accounts, routes ->
        val active = accounts.active
        SessionSlice(
            phase = SessionSlice.Phase.valueOf("PHASE_${connection.phase.name}"),
            gateway_origin = active.origin,
            gateways = accounts.gateways.map { GatewayEntry(it.origin, it.name, it.origin == active.origin, accounts.desiredConnected[it.origin] ?: true) },
            signed_in = runtime.credentials.token(active) != null,
            attached_machine_id = connection.attachedMachineId.orEmpty(),
            error = connection.error.orEmpty(),
            retry_at_millis = connection.retryAt?.toEpochMilliseconds() ?: 0,
            machines = machines.all.map { machine ->
                val route = routes[machine.id]
                MachineEntry(
                    id = machine.id, name = machine.name, online = machine.online(machines.evaluatedAt), attached = machine.id == connection.attachedMachineId,
                    route = route?.kind?.label.orEmpty(), route_latency_millis = route?.latency?.inWholeMilliseconds ?: 0,
                    platform = machine.remoteDesktop?.platform.orEmpty(), release_version = machine.releaseVersion, compatible = machine.compatible,
                )
            },
            client_id = runtime.clientId,
        )
    }

    fun workspaceSlices(): Flow<WorkspaceSlice> = runtime.workspace.state.map { view ->
        WorkspaceSlice(
            projects = view.projects, boards = view.boards.values.flatten(), cards = view.allItems,
            pending_card_ids = view.pendingCardIds.sorted(), loaded = view.loaded, project_replicas = view.projectReplicas,
        )
    }

    fun outboxSlices(): Flow<OutboxSlice> = runtime.outbox.view.map { view ->
        OutboxSlice(
            pending_card_ids = view.pendingCardIds.sorted(), pending_message_ids = view.pendingMessageIds.sorted(),
            accepted_ids = view.acceptedIds.sorted(), failed_ids = view.failedIds.sorted(),
            machines = view.machines.map { (daemonId, summary) ->
                MachineOutbox(daemonId, summary.itemCount, if (summary.failed) summary.itemCount else 0, summary.failureMessage.orEmpty())
            }.sortedBy { it.daemon_id },
            resolutions = view.resolutions,
        )
    }

    fun activitySlices(): Flow<ActivitySlice> = runtime.activity().map { items ->
        ActivitySlice(
            items.map { item ->
                ActivityRow(
                    card = item.card, kind = item.kind.name,
                    section = when (item.section) {
                        ActivitySection.ATTENTION -> ActivityRow.Section.SECTION_ATTENTION
                        ActivitySection.RUNNING -> ActivityRow.Section.SECTION_RUNNING
                        ActivitySection.RECENT -> ActivityRow.Section.SECTION_RECENT
                    },
                    detail = item.detail, at_millis = item.at?.toEpochMilliseconds() ?: 0, started_at_millis = item.start?.toEpochMilliseconds() ?: 0,
                    project_name = item.projectName.orEmpty(), board_name = item.boardName.orEmpty(), chat = item.chat,
                )
            },
        )
    }

    companion object {
        fun classify(error: Throwable): Failure = when (error) {
            is ClientFailure -> error.failure
            is FileConflictException -> Failure(Failure.Kind.KIND_CONFLICT, error.message.orEmpty())
            is CoreException -> Failure(
                when (error.kind) {
                    FailureKind.TRANSIENT -> Failure.Kind.KIND_TRANSIENT
                    FailureKind.PERMANENT -> Failure.Kind.KIND_PERMANENT
                    FailureKind.UNAUTHENTICATED -> Failure.Kind.KIND_UNAUTHENTICATED
                    FailureKind.UPDATE_REQUIRED -> Failure.Kind.KIND_UPDATE_REQUIRED
                    else -> Failure.Kind.KIND_PERMANENT
                },
                error.message.orEmpty(),
            )
            else -> Failure(if (Failures.isRetryableRead(error)) Failure.Kind.KIND_TRANSIENT else Failure.Kind.KIND_PERMANENT, Failures.message(error))
        }

        fun conversationSlice(view: ConversationView): ConversationSlice = ConversationSlice(
            card_id = view.cardId, daemon_id = view.daemonId.orEmpty(), card = view.card,
            conversation = view.conversation?.copy(messages = emptyList()), messages = view.messages,
            loading = view.loading, syncing = view.syncing, error = view.error.orEmpty(), pending = view.pending,
            has_earlier = view.transcript.history.hasMore, loading_earlier = view.transcript.history.loading,
            browsing_earlier = view.transcript.history.browsingEarlier,
        )

        /** Keyed changes between two workspace snapshots; null when nothing changed. */
        fun workspaceDelta(previous: WorkspaceSlice, next: WorkspaceSlice): WorkspaceDelta? {
            if (previous == next) return null
            val cards = Keyed.diff(previous.cards, next.cards, Card::id)
            return WorkspaceDelta(
                projects = next.projects, boards = next.boards, upserted_cards = cards.upserted, removed_card_ids = cards.removed,
                card_order = if (cards.orderChanged) next.cards.map(Card::id) else emptyList(), order_changed = cards.orderChanged,
                pending_card_ids = next.pending_card_ids, loaded = next.loaded, project_replicas = next.project_replicas,
            )
        }

        fun conversationDelta(previous: ConversationSlice, next: ConversationSlice): ConversationDelta? {
            if (previous == next) return null
            val messages = Keyed.diff(previous.messages, next.messages, UiMessage::id)
            return ConversationDelta(
                card = next.card, conversation = next.conversation, upserted_messages = messages.upserted, removed_message_ids = messages.removed,
                message_order = if (messages.orderChanged) next.messages.map(UiMessage::id) else emptyList(), order_changed = messages.orderChanged,
                loading = next.loading, syncing = next.syncing, error = next.error, pending = next.pending,
                has_earlier = next.has_earlier, loading_earlier = next.loading_earlier, browsing_earlier = next.browsing_earlier,
            )
        }

        /** Applies [delta] to [base], as a Kotlin observer (and the tests) would. */
        fun apply(base: WorkspaceSlice, delta: WorkspaceDelta): WorkspaceSlice = base.copy(
            projects = delta.projects, boards = delta.boards,
            cards = Keyed.apply(base.cards, delta.upserted_cards, delta.removed_card_ids, delta.card_order.takeIf { delta.order_changed }, Card::id),
            pending_card_ids = delta.pending_card_ids, loaded = delta.loaded, project_replicas = delta.project_replicas,
        )

        fun apply(base: ConversationSlice, delta: ConversationDelta): ConversationSlice = base.copy(
            card = delta.card, conversation = delta.conversation,
            messages = Keyed.apply(base.messages, delta.upserted_messages, delta.removed_message_ids, delta.message_order.takeIf { delta.order_changed }, UiMessage::id),
            loading = delta.loading, syncing = delta.syncing, error = delta.error, pending = delta.pending,
            has_earlier = delta.has_earlier, loading_earlier = delta.loading_earlier, browsing_earlier = delta.browsing_earlier,
        )
    }
}

/** Keyed list diffs: upserts, removals, and whether the surviving order changed. */
object Keyed {
    data class Diff<T>(val upserted: List<T>, val removed: List<String>, val orderChanged: Boolean)

    fun <T> diff(previous: List<T>, next: List<T>, key: (T) -> String): Diff<T> {
        val before = previous.associateBy(key)
        val nextKeys = next.map(key)
        val upserted = next.filter { before[key(it)] != it }
        val nextSet = nextKeys.toHashSet()
        val removed = previous.map(key).filter { it !in nextSet }
        // Appending new items at the end keeps the order; anything else resends it.
        val survivors = previous.map(key).filter { it in nextSet }
        val orderChanged = nextKeys.take(survivors.size) != survivors || nextKeys.size != nextKeys.toHashSet().size
        return Diff(upserted, removed, orderChanged)
    }

    fun <T> apply(base: List<T>, upserted: List<T>, removed: List<String>, order: List<String>?, key: (T) -> String): List<T> {
        val removedSet = removed.toHashSet()
        val items = LinkedHashMap<String, T>()
        base.forEach { if (key(it) !in removedSet) items[key(it)] = it }
        upserted.forEach { items[key(it)] = it }
        return order?.mapNotNull { items[it] } ?: items.values.toList()
    }
}

package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.DraftText
import com.dbpprt.dieter.client.v1.Drafts
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.FolderScope as ClientFolderScope
import com.dbpprt.dieter.client.v1.MessageQueued
import com.dbpprt.dieter.client.v1.PageLoaded
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.client.v1.SearchHit
import com.dbpprt.dieter.client.v1.SearchResults
import com.dbpprt.dieter.client.v1.SignInStarted
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.board.BoardOperations
import com.dbpprt.dieter.core.board.DropAnchors
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.composition.DraftKey
import com.dbpprt.dieter.core.conversation.ConversationSession
import com.dbpprt.dieter.core.files.FileConflictException
import com.dbpprt.dieter.core.files.FilesView
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.core.presentation.ConversationPresenter
import com.dbpprt.dieter.core.presentation.TimelineCache
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.screens.LocalClipboard
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.search.TaskSearchIndex
import com.dbpprt.dieter.core.store.WorkspaceView
import com.dbpprt.dieter.core.workspace.ProjectChangesView
import com.dbpprt.dieter.core.workspace.WorkspaceReviewView
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import okio.ByteString

/** A command the core rejected, with the kind the UI acts on. */
class ClientFailure(val failure: Failure) : Exception(failure.message)

/** An active observation; [close] stops it and releases what it opened. */
fun interface ClientSubscription {
    fun close()
}

/**
 * What a host supplies for screen sharing: its media engine, pasteboard, and
 * stream policy. [routes] replaces the machine's signaling route, for an
 * isolated screen fixture only.
 */
class ScreenHost(
    val engines: (scope: String) -> ScreenMediaEngineFactory,
    val clipboard: LocalClipboard?,
    val config: ScreenConfig,
    val routes: ((daemonId: String) -> ScreenRouteFactory)? = null,
)

/**
 * The schema-first UI contract: one command dispatcher and one slice
 * observer over [CoreRuntime]. Apple reaches the core only through this, as
 * encoded bytes; Android uses the runtime directly. View-owned surfaces
 * (files, terminals, review, screens, ...) exist per observed scope.
 */
class ClientApi(private val runtime: CoreRuntime, private val screenHost: ScreenHost? = null) {
    private val surfaces = ViewSurfaces(runtime, screenHost)

    /** The palette's index, rebuilt when the workspace changes. */
    private var searchIndex: Pair<WorkspaceView, TaskSearchIndex>? = null

    init {
        runtime.onGatewayChange(surfaces::resetAccount)
    }

    /** Runs [command]; throws [ClientFailure] with a classified reason. */
    suspend fun dispatch(command: Command): Result = try {
        runtime.onCore { execute(command) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        throw ClientFailure(classify(error))
    }

    private suspend fun execute(command: Command): Result {
        val done = Result(done = Done())
        command.adopt_session?.let { adopt ->
            if (adopt.session_token.isBlank()) invalid("The session token is empty.")
            runtime.adoptSession(gateway(adopt.gateway_url, adopt.name), adopt.session_token)
            return done
        }
        command.begin_sign_in?.let { return Result(sign_in_started = SignInStarted(runtime.beginSignIn(gateway(it.gateway_url, "")))) }
        command.complete_sign_in?.let { runtime.completeSignIn(it.callback_url); return done }
        command.sign_out?.let { runtime.signOut(); return done }
        command.select_gateway?.let { runtime.selectGateway(it.origin); return done }
        command.attach_machine?.let { runtime.attachMachine(it.daemon_id); return done }
        command.set_connected?.let { runtime.setConnected(it.connected); return done }
        command.reconnect?.let { runtime.reconnect(); return done }
        command.set_foreground?.let { runtime.setActive(it.foreground); return done }
        command.set_show_reasoning?.let { runtime.conversations.setShowReasoning(it.show); return done }
        command.create_conversation?.let { create ->
            val intent = create.intent ?: invalid("Describe the conversation to create.")
            return Result(card = runtime.createFromIntent(intent, create.chat, create.submission_id.ifEmpty { null }))
        }
        command.creation_preview?.let { return Result(creation_preview = (surfaces.creationPreviews[it.scope] ?: invalid("Open the creation preview first.")).bind(it)) }
        command.send_message?.let { send ->
            val parts = Attachments.messageParts(send.text, send.parts)
            return Result(message_queued = MessageQueued(runtime.sendMessage(send.card_id, parts, send.selection)))
        }
        command.choose_agent?.let { choose ->
            val choice = choose.choice ?: invalid("Choose an agent setting.")
            val session = conversation(choose.card_id)
            if (!session.chooseAgent(session.view.value.daemonId?.let(runtime::loadedCatalog)) { it.choosing(choice) }) invalid("The conversation is still loading.")
            return done
        }
        command.start_card?.let { runtime.startCard(it.card_id, it.has_draft_attachments); return done }
        command.move_card?.let { board { move(it.card_id, it.lane, DropAnchors(it.after_card_id, it.before_card_id)) }; return done }
        command.finish_card?.let { board { finish(it.card_id) }; return done }
        command.set_card_labels?.let { board { setLabels(it.card_id, it.label_ids) }; return done }
        command.set_card_pinned?.let { board { setPinned(it.card_id, it.pinned) }; return done }
        command.rename_card?.let { board { rename(it.card_id, it.title) }; return done }
        command.archive_card?.let { board { archive(it.card_id) }; return done }
        command.restore_card?.let { restore ->
            // A chat has no board; it is archived on its own machine.
            val archived = if (restore.board_id.isEmpty()) runtime.archivedChats() else runtime.board.archivedCards(restore.board_id)
            val card = archived.firstOrNull { it.id == restore.card_id } ?: invalid("The archived card is no longer available.")
            board { restore(card) }
            return done
        }
        command.cancel_card?.let { board { cancel(it.card_id) }; return done }
        command.add_card_label?.let { board { addLabel(it.card_id, it.label_id) }; return done }
        command.update_card_draft?.let { board { edit(it.card_id, it.title, it.prompt, it.agent) }; return done }
        command.merge_card?.let { board { merge(it.source_card_id, it.target_card_id) }; return done }
        command.fork_card?.let { return Result(card = runtime.board.fork(it.card_id, it.message_id)) }
        command.list_archived_cards?.let { return Result(cards = Cards(runtime.board.archivedCards(it.board_id))) }
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
        command.load_later_messages?.let { return Result(page_loaded = PageLoaded(conversation(it.card_id).loadLater())) }
        command.retry_failed_turn?.let { return Result(message_queued = MessageQueued(conversation(it.card_id).retryFailedTurn().orEmpty())) }
        command.remove_queued_message?.let { remove ->
            val removed = conversation(remove.card_id).removeQueued(remove.message_id, remove.edit) ?: invalid("The message is no longer queued.")
            return Result(queued_message = removed)
        }
        command.steer_conversation?.let {
            if (!conversation(it.card_id).steer(it.message_id)) invalid("Only the next queued message can interrupt the running turn.")
            return done
        }
        command.load_tool_output?.let { return Result(tool_output = conversation(it.card_id).toolOutput(it.message_id, it.tool_call_id, it.revision)) }
        command.set_visible_conversation?.let { visible ->
            runtime.visibleConversationId = visible.card_id.ifEmpty { null }
            if (visible.card_id.isNotEmpty()) runtime.conversations.session(visible.card_id)?.markReadIfVisible()
            return done
        }
        command.set_project_order?.let { runtime.navigation.setProjectOrder(it.project_ids); return done }
        command.set_project_expanded?.let { runtime.navigation.setProjectExpanded(it.project_id, it.expanded); return done }
        command.set_chat_section_collapsed?.let { runtime.navigation.setChatSectionCollapsed(it.project_id, it.collapsed); return done }
        command.set_chats_show_all?.let { runtime.navigation.setChatsShowAll(it.project_id, it.show_all); return done }
        command.set_lane_descending?.let { runtime.navigation.setLaneDescending(it.board_id, it.lane_id, it.descending); return done }
        command.set_folders?.let { set ->
            val scope = if (set.scope == ClientFolderScope.FOLDER_SCOPE_CHATS) FolderScope.CHATS else FolderScope.PROJECTS
            runtime.navigation.setFolders(scope, set.folders.map { NavigationFolder(it.id, it.name, it.item_ids, it.expanded) })
            return done
        }
        command.navigation?.let { return runtime.applyNavigation(it) }
        command.list_drafts?.let {
            val drafts = runtime.drafts.state.value.mapNotNull { (key, draft) ->
                draft.text.takeIf { it.isNotEmpty() }?.let { DraftText(key.daemonId, key.conversationId, it) }
            }
            return Result(drafts = Drafts(drafts))
        }
        command.set_draft_text?.let { set ->
            if (set.card_id.isBlank()) invalid("A draft needs a conversation.")
            runtime.drafts.setText(DraftKey(set.daemon_id, set.card_id), set.text)
            return done
        }
        command.remember_creation?.let { remember ->
            runtime.creation.remember(
                selection = remember.selection,
                projectId = remember.project_id.ifEmpty { null },
                boardId = remember.board_id.ifEmpty { null },
                checkoutId = remember.checkout_id.ifEmpty { null },
            )
            return done
        }
        command.search?.let { search ->
            val workspace = runtime.workspace.state.value
            val index = searchIndex?.takeIf { it.first === workspace }?.second
                ?: TaskSearchIndex(TaskSearchIndex.documents(workspace.allItems, workspace.projects, workspace.boards.values.flatten()))
                    .also { searchIndex = workspace to it }
            val hits = index.search(search.query, SEARCH_LIMIT)
            return Result(search_results = SearchResults(hits.map { SearchHit(it.id, it.title, it.location, it.chat) }))
        }
        command.rename_machine?.let { runtime.renameMachine(it.daemon_id, it.name); return done }
        command.revoke_machine?.let { runtime.revokeMachine(it.daemon_id); return done }
        command.ensure_metadata?.let { runtime.metadata.ensure(it.daemon_id, it.refresh); return done }
        command.use_gateway?.let { runtime.useGateway(Gateway.parse(it.url, it.name.trim()) ?: invalid("That is not a valid gateway address.")); return done }
        command.remove_gateway?.let { runtime.removeGateway(it.origin); return done }
        command.resync?.let { runtime.resync(); return done }
        // Surfaces a view owns; scoped commands need the view's observation first.
        command.files?.let { return (surfaces.files[it.scope] ?: invalid("Open the files surface first.")).execute(it) }
        command.file_tree?.let { return (surfaces.fileTrees[it.scope] ?: invalid("Open the file tree first.")).execute(it) }
        command.terminals?.let {
            val overview = surfaces.overviews[it.scope]
            val terminals = surfaces.terminals[it.scope] ?: overview?.terminals ?: invalid("Open the terminals first.")
            return terminals.execute(it, overview)
        }
        command.terminal_overview?.let { return (surfaces.overviews[it.scope] ?: invalid("Open the terminal overview first.")).execute(it) }
        command.review?.let { return (surfaces.reviews[it.scope] ?: invalid("Open the review first.")).execute(it) }
        command.project_changes?.let { return (surfaces.projectChanges[it.scope] ?: invalid("Open the project changes first.")).execute(it) }
        command.screen?.let {
            val surface = surfaces.screens[it.scope] ?: invalid("Open the screen first.")
            surface.execute(it) { daemonId -> screenHost?.routes?.invoke(daemonId) ?: runtime.screenRoutes(daemonId) }
            return done
        }
        command.processes?.let { return (surfaces.processes[it.scope] ?: invalid("Open the processes first.")).execute(it) }
        command.board_view?.let { return (surfaces.boardViews[it.scope] ?: invalid("Open the board view first.")).execute(it) }
        command.chats?.let { return (surfaces.chats[it.scope] ?: invalid("Open the chats list first.")).execute(it) }
        // An empty scope reaches the surface of the view that observes without one.
        command.schedules?.let { return surfaces.schedules.scoped(it.scope, "Open the schedules first.").execute(it, ::harnesses) }
        // Machine telemetry and the project workspaces list have one surface each.
        command.telemetry?.let { return surfaces.telemetry.unscoped().execute(it) }
        command.project_workspaces?.let { return surfaces.projectWorkspaces.unscoped().execute(it) }
        // Provider quotas are account-wide and bound to no view.
        command.quotas?.let { return runtime.quotas.execute(it) }
        command.admin?.let { return runtime.administer(it) }
        invalid("Choose a command.")
    }

    /** [daemonId]'s agents as its loaded catalog lists them. */
    private fun harnesses(daemonId: String): List<Harness> = runtime.loadedCatalog(daemonId).orEmpty()

    /** A board mutation reports its own failure; one with nothing to change succeeds. */
    private suspend fun board(block: suspend BoardOperations.() -> Boolean) {
        runtime.board.block()
    }

    private fun conversation(cardId: String): ConversationSession =
        runtime.conversations.session(cardId) ?: invalid("Open the conversation first.")

    private fun gateway(url: String, name: String): Gateway =
        Gateway.parse(url, name.ifEmpty { "Custom" }) ?: invalid("That is not a valid gateway address.")

    // --- Observation ------------------------------------------------------------------

    /**
     * Delivers [slice] to [observer] on the core dispatcher: a snapshot first,
     * then deltas for keyed slices. [scope] is the card ID for conversations
     * and the owning view for view-owned surfaces. A slice whose surface
     * cannot open delivers one update carrying the failure; an unspecified
     * slice throws [ClientFailure].
     */
    fun observe(slice: Slice, scope: String, observer: (Update) -> Unit): ClientSubscription {
        var sequence = 0L
        fun emit(update: Update) = observer(update.copy(slice = slice, scope = scope, sequence = ++sequence))
        val job: Job = when (slice) {
            Slice.SLICE_SESSION -> collect(runtime.sessionSlices()) { emit(Update(session = it)) }
            Slice.SLICE_WORKSPACE -> {
                var previous: WorkspaceSlice? = null
                collect(runtime.workspaceSlices()) { next ->
                    val last = previous
                    previous = next
                    if (last == null) emit(Update(workspace = next)) else Deltas.workspace(last, next)?.let { emit(Update(workspace_delta = it)) }
                }
            }
            Slice.SLICE_OUTBOX -> collect(runtime.outboxSlices()) { emit(Update(outbox = it)) }
            Slice.SLICE_ACTIVITY -> collect(runtime.activitySlices()) { emit(Update(activity = it)) }
            Slice.SLICE_METADATA -> collect(runtime.metadataSlices()) { emit(Update(metadata = it)) }
            Slice.SLICE_BOARD -> collect(runtime.boardSlices()) { emit(Update(board = it)) }
            Slice.SLICE_NAVIGATION -> collect(runtime.navigationSlices()) { emit(Update(navigation = it)) }
            Slice.SLICE_CREATION -> collect(
                combine(runtime.creation.state, runtime.workspace.state, runtime.connection.active) { saved, workspace, active -> creationSlice(saved, workspace, active?.attachedMachineId) },
            ) { emit(Update(creation = it)) }
            Slice.SLICE_QUOTAS -> collect(runtime.quotas.view.map(::quotasSlice)) { emit(Update(quotas = it)) }
            Slice.SLICE_FILES -> observeSurface(surfaces.files, scope, ::emit) { files ->
                var previous: FilesView? = null
                files.view.map { next ->
                    // An update that keeps the open document leaves it out.
                    val unchanged = previous != null && previous?.document == next.document
                    previous = next
                    Update(files = filesSlice(next, unchanged))
                }
            }
            Slice.SLICE_FILE_TREE -> observeSurface(surfaces.fileTrees, scope, ::emit) { tree -> tree.view.map { Update(file_tree = fileTreeSlice(it)) } }
            Slice.SLICE_REVIEW -> observeSurface(surfaces.reviews, scope, ::emit) { review ->
                // Availability and the pull request follow the card, which the
                // workspace carries; display rows the view already has are left out.
                var previous: WorkspaceReviewView? = null
                combine(review.view, runtime.workspace.state) { view, workspace -> view to view.cardId?.let(workspace::card) }
                    .distinctUntilChanged()
                    .map { (view, card) ->
                        val unchanged = reviewDiffUnchanged(previous, view)
                        previous = view
                        reviewSlice(view, card, unchanged)
                    }
                    .distinctUntilChanged().map { Update(review = it) }
            }
            Slice.SLICE_PROJECT_CHANGES -> observeSurface(surfaces.projectChanges, scope, ::emit) { changes ->
                var previous: ProjectChangesView? = null
                changes.view.map { next ->
                    // Display rows the view already has are left out.
                    val unchanged = previous?.layout === next.layout
                    previous = next
                    Update(project_changes = projectChangesSlice(next, unchanged))
                }
            }
            Slice.SLICE_SCREEN -> observeSurface(surfaces.screens, scope, ::emit) { surface ->
                var cursor: ByteString? = null
                var first = true
                surface.view.map { (view, displays) ->
                    // The cursor image is sent only when it changed.
                    val unchanged = !first && view.cursorImage == cursor
                    first = false
                    cursor = view.cursorImage
                    Update(screen = screenSlice(view, displays, surface.session.preferences, unchanged))
                }
            }
            Slice.SLICE_PROCESSES -> observeSurface(surfaces.processes, scope, ::emit) { processes -> processes.view.map { Update(processes = processesSlice(it)) } }
            Slice.SLICE_BOARD_VIEW -> observeSurface(surfaces.boardViews, scope, ::emit) { board ->
                board.view.map(::boardViewSlice).distinctUntilChanged().map { Update(board_view = it) }
            }
            Slice.SLICE_CHATS -> observeSurface(surfaces.chats, scope, ::emit) { chats ->
                chats.view.map(::chatsSlice).distinctUntilChanged().map { Update(chats = it) }
            }
            Slice.SLICE_TELEMETRY -> observeSurface(surfaces.telemetry, Surfaces.UNSCOPED, ::emit) { telemetry -> telemetry.view.map { Update(telemetry = telemetrySlice(it)) } }
            Slice.SLICE_SCHEDULES -> observeSurface(surfaces.schedules, scope, ::emit) { schedules ->
                // Agent names follow the owners' catalogs as they load.
                combine(schedules.view, runtime.metadata.machines) { view, machines ->
                    Update(schedules = schedulesSlice(view) { machines[it]?.harnesses?.harnesses.orEmpty() })
                }
            }
            Slice.SLICE_CREATION_PREVIEW -> observeSurface(surfaces.creationPreviews, scope, ::emit) { form -> form.view.map { Update(creation_preview = it) } }
            Slice.SLICE_TERMINALS -> observeSurface(surfaces.terminals, scope, ::emit) { terminals ->
                val outputs = TerminalOutputs()
                terminals.view.map { Update(terminals = terminalsSlice(it, outputs)) }
            }
            Slice.SLICE_TERMINAL_OVERVIEW -> observeSurface(surfaces.overviews, scope, ::emit) { overview ->
                // Machines that come online, return after a restart, or failed to
                // list are listed again while the overview is shown.
                launch {
                    while (true) {
                        delay(OVERVIEW_RELIST)
                        overview.relistIfStale()
                    }
                }
                val outputs = TerminalOutputs()
                combine(overview.view, overview.terminals.view) { view, terminals -> Update(terminal_overview = overviewSlice(view, terminalsSlice(terminals, outputs))) }
            }
            Slice.SLICE_CONVERSATION -> {
                var previous: ConversationSlice? = null
                observeSurface(surfaces.conversations, scope, ::emit) { cardId ->
                    val session = runtime.conversations.open(cardId)
                    // Unchanged messages keep their steps between updates.
                    val timeline = TimelineCache()
                    // The composers' agent choices; typing alone changes none of them.
                    val selections = runtime.drafts.state.map { drafts -> drafts.mapNotNull { (key, draft) -> draft.selection?.let { key to it } }.toMap() }.distinctUntilChanged()
                    val device = combine(runtime.metadata.machines, runtime.conversations.showReasoning, selections, ::Triple)
                    combine(session.view, runtime.outbox.view, runtime.board.view, runtime.workspace.state, device) { view, outbox, board, workspace, (machines, showReasoning, chosen) ->
                        val presented = ConversationPresenter.presentForClient(view, outbox, workspace, board.operations, machines, showReasoning, timeline)
                        conversationSlice(view, presented, composerAgent(view, presented.card, chosen, machines))
                    }.distinctUntilChanged().map { next ->
                        val last = previous
                        previous = next
                        if (last == null) Update(conversation = next) else Deltas.conversation(last, next)?.let { Update(conversation_delta = it) }
                    }
                }
            }
            Slice.SLICE_UNSPECIFIED -> invalid("Choose a slice to observe.")
        }
        return ClientSubscription { job.cancel() }
    }

    private fun <T> collect(flow: Flow<T>, block: (T) -> Unit): Job =
        runtime.scope.launch { flow.distinctUntilChanged().collect { block(it) } }

    /**
     * Retains [surfaces]' instance for [scope], delivers [updates] of it, and
     * releases it when the observation ends. A surface that cannot open is
     * reported as one update carrying the failure.
     */
    private fun <T> observeSurface(
        surfaces: Surfaces<T>,
        scope: String,
        emit: (Update) -> Unit,
        updates: CoroutineScope.(T) -> Flow<Update?>,
    ): Job = runtime.scope.launch {
        val surface = try {
            surfaces.retain(scope)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            emit(Update(failure = classify(error)))
            return@launch
        }
        try {
            updates(surface).collect { update -> update?.let(emit) }
        } finally {
            surfaces.release(scope)
        }
    }

    private companion object {
        val OVERVIEW_RELIST = 3.seconds

        /** The command palette's hits. */
        const val SEARCH_LIMIT = 30
    }
}

internal fun invalid(message: String): Nothing = throw ClientFailure(Failure(Failure.Kind.KIND_INVALID, message))

/** The contract's failure for [error], classified for the UI. */
internal fun classify(error: Throwable): Failure = when (error) {
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

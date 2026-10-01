package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.BoardSlice
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.ConversationState
import com.dbpprt.dieter.client.v1.CreationSlice
import com.dbpprt.dieter.client.v1.DraftText
import com.dbpprt.dieter.client.v1.Drafts
import com.dbpprt.dieter.client.v1.FailedOperation
import com.dbpprt.dieter.client.v1.FeedStatus
import com.dbpprt.dieter.client.v1.FileTreeFolder
import com.dbpprt.dieter.client.v1.FileTreeSlice
import com.dbpprt.dieter.client.v1.FilesSlice
import com.dbpprt.dieter.client.v1.GatewayBuild
import com.dbpprt.dieter.client.v1.MachineMetadata
import com.dbpprt.dieter.client.v1.MetadataSlice
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.PendingCardMove
import com.dbpprt.dieter.core.board.BoardOperationsView
import com.dbpprt.dieter.core.composition.DraftKey
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.connection.ConnectionState
import com.dbpprt.dieter.core.conversation.TurnFailure
import com.dbpprt.dieter.core.files.FileTree
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.screens.DisplayMatchView
import com.dbpprt.dieter.core.screens.DisplayMatching
import com.dbpprt.dieter.core.screens.LocalClipboard
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.screens.ScreenPreferences
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.screens.ScreenSurface
import com.dbpprt.dieter.core.screens.ScreenView
import com.dbpprt.dieter.client.v1.ScreenSlice
import okio.ByteString
import com.dbpprt.dieter.core.executions.ProcessTarget
import com.dbpprt.dieter.core.executions.Processes
import com.dbpprt.dieter.core.executions.ProcessesView
import com.dbpprt.dieter.core.search.TaskSearchIndex
import com.dbpprt.dieter.client.v1.ProcessesSlice
import com.dbpprt.dieter.client.v1.SearchHit
import com.dbpprt.dieter.client.v1.SearchResults
import com.dbpprt.dieter.core.admin.TelemetryView
import com.dbpprt.dieter.core.quotas.QuotasView
import com.dbpprt.dieter.client.v1.MachineReadings
import com.dbpprt.dieter.client.v1.QuotasSlice
import com.dbpprt.dieter.client.v1.Samples
import com.dbpprt.dieter.client.v1.TelemetrySlice
import com.dbpprt.dieter.client.v1.AdminCommand
import com.dbpprt.dieter.client.v1.Archives
import com.dbpprt.dieter.client.v1.ConflictRecord
import com.dbpprt.dieter.client.v1.Projects
import com.dbpprt.dieter.core.workspace.ProjectWorkspaceSettings
import com.dbpprt.dieter.core.workspace.ValidationCommandDraft
import com.dbpprt.dieter.core.workspace.ChangeSection
import com.dbpprt.dieter.core.workspace.DiffLine
import com.dbpprt.dieter.core.workspace.DiffLineKind
import com.dbpprt.dieter.core.workspace.MergeStrategy
import com.dbpprt.dieter.core.workspace.ProjectChanges
import com.dbpprt.dieter.core.workspace.ProjectChangesView
import com.dbpprt.dieter.core.workspace.ProjectWorkspacesView
import com.dbpprt.dieter.core.workspace.WorkspaceAvailability
import com.dbpprt.dieter.core.workspace.WorkspaceReview
import com.dbpprt.dieter.core.workspace.WorkspaceReviewView
import com.dbpprt.dieter.client.v1.DiffRow
import com.dbpprt.dieter.client.v1.Outcome
import com.dbpprt.dieter.client.v1.ProjectChangeSelect
import com.dbpprt.dieter.client.v1.ProjectChangesSlice
import com.dbpprt.dieter.client.v1.ProjectWorkspacesSlice
import com.dbpprt.dieter.client.v1.ReviewSlice
import com.dbpprt.dieter.core.schedules.SchedulesView
import com.dbpprt.dieter.client.v1.SchedulesSlice
import com.dbpprt.dieter.core.terminals.TerminalOverview
import com.dbpprt.dieter.core.terminals.TerminalOverviewView
import com.dbpprt.dieter.core.terminals.TerminalRendererSink
import com.dbpprt.dieter.core.terminals.TerminalReplayCursor
import com.dbpprt.dieter.core.terminals.TerminalScope
import com.dbpprt.dieter.core.terminals.TerminalScopeKind
import com.dbpprt.dieter.core.terminals.Terminals
import com.dbpprt.dieter.core.terminals.TerminalsView
import com.dbpprt.dieter.client.v1.OverviewTerminal
import com.dbpprt.dieter.client.v1.TerminalOutput
import com.dbpprt.dieter.client.v1.TerminalOverviewSlice
import com.dbpprt.dieter.client.v1.TerminalTarget
import com.dbpprt.dieter.client.v1.TerminalsSlice
import okio.Buffer
import com.dbpprt.dieter.core.files.FilesTarget
import com.dbpprt.dieter.core.files.FilesView
import com.dbpprt.dieter.core.identity.Accounts
import com.dbpprt.dieter.core.connection.MachineDirectory
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxState
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.outbox.OutboxView
import com.dbpprt.dieter.core.presentation.ConversationPresenter
import com.dbpprt.dieter.core.presentation.LiveActivities
import com.dbpprt.dieter.core.session.MachineRoute
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
import com.dbpprt.dieter.core.state.CreationPreferences
import com.dbpprt.dieter.core.store.WorkspaceView
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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

class ClientApi(private val runtime: CoreRuntime, private val screenHost: ScreenHost? = null) {
    private val conversationRefs = mutableMapOf<String, Int>()
    private val files = Surfaces { runtime.files() }
    private val fileTrees = Surfaces { runtime.fileTree() }
    private val terminalSurfaces = Surfaces(Terminals::stop) { runtime.terminals() }
    private val overviews = Surfaces<TerminalOverview>({ it.terminals.stop() }) { runtime.terminalOverview() }
    private val screens = Surfaces<ScreenSurface>(ScreenSurface::close) { scope ->
        val host = screenHost ?: throw ClientFailure(Failure(Failure.Kind.KIND_PERMANENT, "Screen sharing is unavailable on this device."))
        // Each view's engines render into that view.
        ScreenSurface(runtime.screen(host.engines(scope), host.config, host.clipboard), runtime.scope)
    }
    private val processSurfaces = Surfaces<Processes>({ it.bind(null, active = false) }) { Processes(runtime.sessions, runtime.scope) }
    /** The palette's index, rebuilt when the workspace changes. */
    private var searchIndex: Pair<WorkspaceView, TaskSearchIndex>? = null
    private val reviews = Surfaces<WorkspaceReview>({ it.setActive(false); it.bind(null, null) }) { runtime.workspaceReview() }
    private val projectChanges = Surfaces<ProjectChanges>({ it.setActive(false); it.bind(null, null, null) }) { runtime.projectChanges() }

    /**
     * View-owned instances of a core surface, by scope, while observed;
     * [close] stops what the last observer leaves running.
     */
    private class Surfaces<T>(private val close: (T) -> Unit = {}, private val create: (scope: String) -> T) {
        private val open = mutableMapOf<String, Pair<T, Int>>()

        fun retain(scope: String): T {
            val (surface, refs) = open[scope] ?: (create(scope) to 0)
            open[scope] = surface to refs + 1
            return surface
        }

        fun release(scope: String) {
            val (surface, refs) = open[scope] ?: return
            if (refs > 1) {
                open[scope] = surface to refs - 1
                return
            }
            open.remove(scope)
            close(surface)
        }

        operator fun get(scope: String): T? = open[scope]?.first
    }

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
            // A chat has no board; it is archived on its own machine.
            val archived = if (restore.board_id.isEmpty()) archivedChats() else runtime.board.archivedCards(restore.board_id)
            val card = archived.firstOrNull { it.id == restore.card_id } ?: invalid("The archived card is no longer available.")
            board { restore(card) }
            return done
        }
        command.cancel_card?.let { board { cancel(it.card_id) }; return done }
        command.add_card_label?.let { board { addLabel(it.card_id, it.label_id) }; return done }
        command.update_card_draft?.let { board { updateDraft(it.card_id, it.title, it.prompt, it.agent) }; return done }
        command.merge_card?.let { board { merge(it.source_card_id, it.target_card_id) }; return done }
        command.fork_card?.let { return Result(card = runtime.board.fork(it.card_id, it.message_id, it.title)) }
        command.list_archived_cards?.let { return Result(cards = Cards(runtime.board.archivedCards(it.board_id))) }
        command.clear_card_error?.let { runtime.board.clearError(it.card_id); return done }
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
        command.set_pinned_projects?.let { runtime.navigation.setPinnedProjects(it.project_ids); return done }
        command.set_pinned_chat_order?.let { runtime.navigation.setPinnedChatOrder(it.card_ids); return done }
        command.set_project_expanded?.let { runtime.navigation.setProjectExpanded(it.project_id, it.expanded); return done }
        command.set_chat_section_collapsed?.let { runtime.navigation.setChatSectionCollapsed(it.project_id, it.collapsed); return done }
        command.set_chats_show_all?.let { runtime.navigation.setChatsShowAll(it.project_id, it.show_all); return done }
        command.set_lane_descending?.let { runtime.navigation.setLaneDescending(it.board_id, it.lane_id, it.descending); return done }
        command.set_folders?.let { set ->
            val scope = if (set.scope == com.dbpprt.dieter.client.v1.FolderScope.FOLDER_SCOPE_CHATS) FolderScope.CHATS else FolderScope.PROJECTS
            runtime.navigation.setFolders(scope, set.folders.map { NavigationFolder(it.id, it.name, it.item_ids, it.expanded) })
            return done
        }
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
                workspaceMode = remember.workspace_mode.ifEmpty { null }?.let(WorkspaceMode::parse),
                projectId = remember.project_id.ifEmpty { null },
                boardId = remember.board_id.ifEmpty { null },
            )
            return done
        }
        command.files?.let { command ->
            val surface = files[command.scope] ?: invalid("Open the files surface first.")
            // A save while one runs, or without a text document, is ignored.
            command.save?.let { save -> surface.save(save.text)?.let { return Result(file_document = it) } }
            command.bind?.let { surface.bind(filesTarget(it)) }
            command.load?.let { surface.load(it.path.ifEmpty { surface.view.value.directory }) }
            command.navigate?.let { surface.navigate(it.path) }
            command.back?.let { surface.goBack() }
            command.forward?.let { surface.goForward() }
            command.parent?.let { surface.parent() }
            command.show_hidden?.let { surface.setShowHidden(it.on) }
            command.open_?.let { surface.open(it.path) }
            command.reload?.let { surface.reload() }
            command.create?.let { surface.create(it.name, it.directory) }
            command.move?.let { surface.move(it.source, it.destination) }
            command.delete?.let { surface.delete(it.path, it.recursive) }
            command.close?.let { surface.close() }
            return Result(files = filesSlice(surface.view.value, documentUnchanged = false))
        }
        command.terminals?.let { command ->
            val surface = terminalSurfaces[command.scope] ?: overviews[command.scope]?.terminals ?: invalid("Open the terminals first.")
            command.create?.let { create ->
                val created = surface.create(
                    create.name.trim(), create.shell, create.working_directory.ifEmpty { null },
                    create.columns.takeIf { it > 0 } ?: 120, create.rows.takeIf { it > 0 } ?: 36,
                )
                return Result(terminal = created)
            }
            command.bind?.let { surface.bind(terminalScope(it)) }
            command.active?.let { surface.setActive(it.on) }
            command.load?.let { surface.load() }
            command.select?.let { surface.select(it.terminal_id.ifEmpty { null }) }
            command.rename?.let { surface.rename(it.terminal_id, it.name) }
            command.close?.let { surface.close(it.terminal_id) }
            command.input?.let { surface.input(it.data_.toByteArray()) }
            command.grid?.let { surface.gridChanged(it.columns, it.rows) }
            // A close or rename through the overview's terminals updates its list.
            (command.close?.terminal_id ?: command.rename?.terminal_id)?.let { overviews[command.scope]?.follow(it) }
            return Result(terminals = terminalsSlice(surface.view.value, null))
        }
        command.review?.let { command ->
            val review = reviews[command.scope] ?: invalid("Open the review first.")
            command.start?.let { start -> return review.start(start.kind, start.parameters)?.let { Result(git_operation = it) } ?: Result(review = reviewSlice(review.view.value)) }
            command.add_comment?.let { add ->
                val line = review.view.value.diffLines.firstOrNull { it.id == add.row_id } ?: invalid("That line is no longer in the diff.")
                return review.addComment(line, add.body, add.author)?.let { Result(change_comment = it) } ?: Result(review = reviewSlice(review.view.value))
            }
            command.merge?.let { merge ->
                val strategy = MergeStrategy.entries.firstOrNull { it.wire == merge.strategy } ?: invalid("Choose a merge strategy.")
                val merged = review.mergeFlow(strategy, merge.subject, merge.body, merge.validate, merge.remove_workspace, merge.move_to_done)
                return Result(outcome = Outcome(succeeded = merged))
            }
            command.bind?.let { review.bind(it.card_id.ifEmpty { null }, it.daemon_id.ifEmpty { null }) }
            command.active?.let { review.setActive(it.on) }
            command.refresh?.let { review.refresh() }
            command.select?.let { review.select(it.path.ifEmpty { null }, it.commit.ifEmpty { null }) }
            command.load_more_diff?.let { review.loadMoreDiff() }
            command.cancel_operation?.let { review.cancelOperation() }
            command.update_settings?.let {
                review.updateSettings(WorkspaceMode.parse(it.mode), it.branch, it.base_branch, it.base_remote, it.publish_mode)
            }
            command.clear_toast?.let { review.clearToast() }
            command.clear_error?.let { review.clearError() }
            return Result(review = reviewSlice(review.view.value))
        }
        command.project_changes?.let { command ->
            val changes = projectChanges[command.scope] ?: invalid("Open the project changes first.")
            command.run?.let { run -> return Result(outcome = Outcome(succeeded = changes.run(run.kind, run.parameters))) }
            command.bind?.let { changes.bind(it.project_id.ifEmpty { null }, it.checkout_id.ifEmpty { null }, it.daemon_id.ifEmpty { null }) }
            command.active?.let { changes.setActive(it.on) }
            command.refresh?.let { changes.refresh() }
            command.select?.let { changes.select(it.path, if (it.staged) ChangeSection.STAGED else ChangeSection.UNSTAGED) }
            command.deselect?.let { changes.deselect() }
            command.dismiss?.let { changes.dismissMessages() }
            command.load_more_diff?.let { changes.loadMoreDiff() }
            return Result(project_changes = projectChangesSlice(changes.view.value))
        }
        command.admin?.let { admin(it)?.let { result -> return result } ?: return done }
        command.screen?.let { command ->
            val surface = screens[command.scope] ?: invalid("Open the screen first.")
            val session = surface.session
            command.control?.let { session.transferControl(it.on) }
            command.clipboard?.let { session.performClipboard(it.operation) }
            command.clipboard_enabled?.let { session.setClipboardEnabled(it.on) }
            command.connect?.let { session.connect(screenHost?.routes?.invoke(it.daemon_id) ?: runtime.screenRoutes(it.daemon_id)) }
            command.disconnect?.let { session.disconnect() }
            command.viewport?.let { session.viewport(it.width_points, it.height_points, it.scale) }
            command.preferences?.let { wanted ->
                session.setPreferences {
                    it.copy(
                        codec = wanted.codec, maxFps = wanted.max_fps.takeIf { fps -> fps > 0 } ?: it.maxFps, quality = wanted.quality,
                        displayId = wanted.display_id.ifEmpty { null }, clipboard = wanted.clipboard,
                    )
                }
            }
            command.pointer?.let { session.pointer(it.x, it.y) }
            command.button?.let { session.button(it.button, it.down, it.clicks, it.x, it.y, it.modifiers) }
            command.scroll?.let { session.scroll(it.dx, it.dy, it.phase, it.momentum, it.modifiers, it.precise) }
            command.key?.let { session.key(it.hid, it.down, it.repeat, it.modifiers) }
            command.text?.let { session.text(it.text, it.modifiers) }
            command.release_input?.let { session.releaseInput() }
            command.resume?.let { session.resume() }
            command.sleep?.let { session.sleep() }
            command.focused?.let { session.setFocused(it.on) }
            command.match_display?.let {
                surface.matchDisplay(if (it.width > 0 && it.height > 0) DisplayMatching.Target(it.width, it.height, it.scale, it.refresh) else null)
            }
            command.refresh?.let { session.configure(refresh = true) }
            // Input is frequent and its effect arrives with the next update.
            return done
        }
        command.processes?.let { command ->
            val processes = processSurfaces[command.scope] ?: invalid("Open the processes first.")
            command.bind?.let {
                val target = if (it.daemon_id.isEmpty() || it.card_id.isEmpty()) null else ProcessTarget(it.daemon_id, it.project_id, it.card_id)
                processes.bind(target, it.active)
            }
            command.select?.let { processes.select(it.execution_id) }
            command.stop?.let { processes.stopSelected() }
            return Result(processes = processesSlice(processes.view.value))
        }
        command.search?.let { search ->
            val workspace = runtime.workspace.state.value
            val index = searchIndex?.takeIf { it.first === workspace }?.second
                ?: TaskSearchIndex(TaskSearchIndex.documents(workspace.allItems, workspace.projects, workspace.boards.values.flatten()))
                    .also { searchIndex = workspace to it }
            val hits = index.search(search.query, search.limit.takeIf { it > 0 } ?: 30)
            return Result(search_results = SearchResults(hits.map { SearchHit(it.id, it.title, it.location, it.chat) }))
        }
        command.telemetry?.let { command ->
            val telemetry = runtime.telemetry
            command.perform?.let { perform ->
                return telemetry.perform(perform.action)?.let { Result(machine_operation = it) } ?: done
            }
            command.select?.let { telemetry.select(it.daemon_id.ifEmpty { null }, it.active) }
            command.refresh_all?.let { telemetry.refreshAll(it.daemon_ids) }
            command.unavailable?.let { telemetry.unavailable(it.daemon_id, it.message) }
            return done
        }
        command.quotas?.let { command ->
            val quotas = runtime.quotas
            command.consume_reset?.let { return Result(outcome = Outcome(succeeded = quotas.consumeReset(it.account_key))) }
            command.load?.let { quotas.load(it.refresh) }
            command.set_included?.let { quotas.setIncluded(it.provider, it.account_key, it.included) }
            return done
        }
        command.project_workspaces?.let { command ->
            val workspaces = runtime.projectWorkspaces
            command.load?.let { workspaces.load(it.project_id) }
            command.remove?.let { remove ->
                val workspace = workspaces.view.value.workspaces.firstOrNull { it.card_id == remove.card_id } ?: invalid("The workspace is no longer listed.")
                workspaces.remove(workspace, remove.discard)
            }
            return Result(project_workspaces = projectWorkspacesSlice(workspaces.view.value))
        }
        command.schedules?.let { command ->
            val schedules = runtime.schedules
            command.details?.let { return Result(schedule = schedules.details(it.schedule_id)) }
            command.save?.let { save ->
                val draft = save.draft ?: invalid("A schedule draft is required.")
                return Result(schedule = schedules.save(draft, save.schedule_id.ifEmpty { null }, save.checkout_id.ifEmpty { null }))
            }
            command.set_enabled?.let { return Result(schedule = schedules.setEnabled(it.schedule_id, it.enabled)) }
            command.run_now?.let { return Result(schedule_run = schedules.runNow(it.schedule_id)) }
            command.bind?.let { schedules.bind(it.project_id.ifEmpty { null }) }
            command.load?.let { schedules.load() }
            command.load_more?.let { schedules.loadMore() }
            command.select?.let { schedules.select(it.schedule_id) }
            command.load_more_runs?.let { schedules.loadMoreRuns() }
            command.preview?.let { schedules.preview(it.cron, it.timezone) }
            command.close_editor?.let { schedules.closeEditor() }
            command.delete?.let { schedules.delete(it.schedule_id) }
            command.clear_action_error?.let { schedules.clearActionError() }
            return Result(schedules = schedulesSlice(schedules.view.value))
        }
        command.terminal_overview?.let { command ->
            val overview = overviews[command.scope] ?: invalid("Open the terminal overview first.")
            command.load?.let { overview.load(it.preferred_daemon_id.ifEmpty { null }) }
            command.select?.let { overview.select(it.terminal_id) }
            command.create?.let {
                overview.create(it.daemon_id, it.project_id, it.checkout_id, it.machine_home, it.name, it.shell, it.working_directory)
            }
            return Result(terminal_overview = overviewSlice(overview.view.value, terminalsSlice(overview.terminals.view.value, null)))
        }
        command.file_tree?.let { command ->
            val surface = fileTrees[command.scope] ?: invalid("Open the file tree first.")
            command.bind?.let { surface.bind(filesTarget(it)) }
            command.load?.let { surface.load(it.path) }
            command.toggle?.let { surface.toggle(it.path) }
            command.reveal?.let { surface.reveal(it.path) }
            command.refresh?.let { surface.refresh() }
            command.show_hidden?.let { surface.setShowHidden(it.on) }
            return Result(file_tree = fileTreeSlice(surface.view.value))
        }
        command.rename_machine?.let { runtime.renameMachine(it.daemon_id, it.name); return done }
        command.revoke_machine?.let { runtime.revokeMachine(it.daemon_id); return done }
        command.ensure_metadata?.let { runtime.metadata.ensure(it.daemon_id, it.refresh); return done }
        command.set_gateways?.let { set ->
            val gateways = set.gateways.map { gateway(it.url, it.name) }
            runtime.setGateways(gateways, set.active_origin.ifEmpty { null })
            return done
        }
        command.resync?.let { runtime.resync(); return done }
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
            Slice.SLICE_METADATA -> collect(metadataSlices()) { emit(Update(metadata = it)) }
            Slice.SLICE_BOARD -> collect(boardSlices()) { emit(Update(board = it)) }
            Slice.SLICE_NAVIGATION -> collect(navigationSlices()) { emit(Update(navigation = it)) }
            Slice.SLICE_FILES -> runtime.scope.launch {
                val surface = files.retain(scope)
                var previous: FilesView? = null
                try {
                    surface.view.collect { next ->
                        val unchanged = previous != null && previous?.document == next.document
                        previous = next
                        emit(Update(files = filesSlice(next, unchanged)))
                    }
                } finally {
                    files.release(scope)
                }
            }
            Slice.SLICE_FILE_TREE -> runtime.scope.launch {
                val surface = fileTrees.retain(scope)
                try {
                    surface.view.collect { emit(Update(file_tree = fileTreeSlice(it))) }
                } finally {
                    fileTrees.release(scope)
                }
            }
            Slice.SLICE_REVIEW -> runtime.scope.launch {
                val review = reviews.retain(scope)
                try {
                    // Availability follows the card, which the workspace carries.
                    combine(review.view, runtime.workspace.state) { view, workspace -> reviewSlice(view, view.cardId?.let(workspace::card)) }
                        .distinctUntilChanged().collect { emit(Update(review = it)) }
                } finally {
                    reviews.release(scope)
                }
            }
            Slice.SLICE_PROJECT_CHANGES -> runtime.scope.launch {
                val changes = projectChanges.retain(scope)
                try {
                    changes.view.collect { emit(Update(project_changes = projectChangesSlice(it))) }
                } finally {
                    projectChanges.release(scope)
                }
            }
            Slice.SLICE_PROJECT_WORKSPACES -> collect(runtime.projectWorkspaces.view.map(::projectWorkspacesSlice)) { emit(Update(project_workspaces = it)) }
            Slice.SLICE_SCREEN -> runtime.scope.launch {
                val surface = try {
                    screens.retain(scope)
                } catch (failure: ClientFailure) {
                    emit(Update(failure = failure.failure))
                    return@launch
                }
                var cursor: ByteString? = null
                var first = true
                try {
                    surface.view.collect { (view, displays) ->
                        val unchanged = !first && view.cursorImage == cursor
                        first = false
                        cursor = view.cursorImage
                        emit(Update(screen = screenSlice(view, displays, surface.session.preferences, unchanged)))
                    }
                } finally {
                    screens.release(scope)
                }
            }
            Slice.SLICE_PROCESSES -> runtime.scope.launch {
                val processes = processSurfaces.retain(scope)
                try {
                    processes.view.collect { emit(Update(processes = processesSlice(it))) }
                } finally {
                    processSurfaces.release(scope)
                }
            }
            Slice.SLICE_TELEMETRY -> collect(runtime.telemetry.view.map(::telemetrySlice)) { emit(Update(telemetry = it)) }
            Slice.SLICE_QUOTAS -> collect(runtime.quotas.view.map(::quotasSlice)) { emit(Update(quotas = it)) }
            Slice.SLICE_SCHEDULES -> collect(runtime.schedules.view.map(::schedulesSlice)) { emit(Update(schedules = it)) }
            Slice.SLICE_TERMINALS -> runtime.scope.launch {
                val surface = terminalSurfaces.retain(scope)
                val outputs = TerminalOutputs()
                try {
                    surface.view.collect { emit(Update(terminals = terminalsSlice(it, outputs))) }
                } finally {
                    terminalSurfaces.release(scope)
                }
            }
            Slice.SLICE_TERMINAL_OVERVIEW -> runtime.scope.launch {
                val overview = overviews.retain(scope)
                val outputs = TerminalOutputs()
                // Machines that come online, return after a restart, or failed to
                // list are listed again while the overview is shown.
                val relist = launch {
                    while (true) {
                        delay(OVERVIEW_RELIST)
                        overview.relistIfStale()
                    }
                }
                try {
                    combine(overview.view, overview.terminals.view, ::Pair).collect { (view, terminals) ->
                        emit(Update(terminal_overview = overviewSlice(view, terminalsSlice(terminals, outputs))))
                    }
                } finally {
                    overviews.release(scope)
                }
            }
            Slice.SLICE_CREATION -> collect(runtime.creation.state.map(::creationSlice)) { emit(Update(creation = it)) }
            Slice.SLICE_CONVERSATION -> {
                var previous: ConversationSlice? = null
                val opened = runtime.scope.launch {
                    val session = retain(scope)
                    try {
                        combine(session.view, runtime.outbox.view, runtime.board.view, runtime.workspace.state) { view, outbox, board, workspace ->
                            conversationSlice(view).copy(state = conversationState(view, outbox, board, workspace))
                        }.distinctUntilChanged().collect { next ->
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
        combine(runtime.connection.state, runtime.connection.machines, runtime.accounts.state, runtime.sessions.routes, ::SessionInputs),
        runtime.connection.feedStatus, runtime.connection.freshness, runtime.connection.gatewayInformation,
    ) { inputs, feed, freshness, gateway ->
        val (connection, machines, accounts, routes) = inputs
        val active = accounts.active
        val rows = machines.all.map { MachineRows.of(it, it.online(machines.evaluatedAt), routes[it.id], connection.attachedMachineId) }
        val connected = connection.phase == ConnectionPhase.CONNECTED
        val now = runtime.platform.clock.now()
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
                    local = route?.kind == RouteKind.LOCAL,
                    platform = machine.remoteDesktop?.platform.orEmpty(), release_version = machine.releaseVersion, compatible = machine.compatible,
                    last_seen_at = machine.lastSeenAt, minimum_release_version = machine.minimumReleaseVersion,
                    incompatibility = machine.incompatibilityDescription.orEmpty(),
                    remote_desktop_ready = machine.remoteDesktop?.ready == true, remote_desktop_reason = machine.remoteDesktop?.reason.orEmpty(),
                    compatibility = machine.compatibility.name,
                    sync_warnings = freshness[machine.id]?.let { MachineRows.syncWarnings(rows, mapOf(machine.id to it), connected, now) }.orEmpty(),
                )
            },
            client_id = runtime.clientId,
            feed = FeedStatus(
                daemon_id = feed.daemonId.orEmpty(), live = feed.live, projection_pending = feed.projectionPending,
                last_applied_at_millis = feed.lastAppliedAt?.toEpochMilliseconds() ?: 0,
            ),
            sync_warnings = MachineRows.syncWarnings(rows, freshness, connected, now),
            gateway_build = gateway?.let { GatewayBuild(it.release_version, it.source_revision, it.built_at) },
        )
    }

    private data class SessionInputs(
        val connection: ConnectionState,
        val machines: MachineDirectory,
        val accounts: Accounts,
        val routes: Map<String, MachineRoute>,
    )

    fun metadataSlices(): Flow<MetadataSlice> = runtime.metadata.machines.map { machines ->
        MetadataSlice(
            machines.mapValues { (_, metadata) ->
                MachineMetadata(
                    harnesses = metadata.harnesses, settings_options = metadata.settingsOptions, runtime = metadata.runtime,
                    refreshed_at_millis = metadata.refreshedAt?.toEpochMilliseconds() ?: 0, error = metadata.error.orEmpty(), loaded = metadata.loaded,
                )
            },
        )
    }

    fun boardSlices(): Flow<BoardSlice> = runtime.board.view.map { view ->
        BoardSlice(
            operations = view.operations.mapValues { it.value.name }, errors = view.errors,
            moves = view.moves.map { (cardId, move) -> PendingCardMove(cardId, move.lane, move.afterCardId, move.beforeCardId) }.sortedBy { it.card_id },
        )
    }

    fun navigationSlices(): Flow<NavigationSlice> = combine(runtime.navigationKv.values, runtime.navigationKv.status) { values, status ->
        val layout = NavigationLayout(values)
        fun folders(scope: FolderScope) = layout.folders(scope).map { com.dbpprt.dieter.client.v1.NavigationFolder(it.id, it.name, it.itemIds, it.expanded) }
        NavigationSlice(
            project_order = layout.ordered("projects-order"), pinned_projects = layout.ordered("projects-pinned"),
            pinned_chat_order = layout.ordered("pinned-order"),
            project_folders = folders(FolderScope.PROJECTS), chat_folders = folders(FolderScope.CHATS),
            expanded_projects = layout.flagged("projects-disclosure", true),
            collapsed_chat_sections = layout.flagged("chats-section", false),
            chats_show_all = layout.flagged("chats-disclosure", true),
            lane_sorts = layout.laneSorts(), pending = status.pending,
            error = (status.deliveryError ?: status.watchError).orEmpty(), caught_up = status.caughtUp,
        )
    }

    private fun filesTarget(target: com.dbpprt.dieter.client.v1.FilesTarget): FilesTarget? =
        if (target.daemon_id.isEmpty() || target.project_id.isEmpty()) null
        else FilesTarget(target.daemon_id, target.project_id, target.checkout_id, target.card_id)

    private fun filesSlice(view: FilesView, documentUnchanged: Boolean) = FilesSlice(
        target = view.target?.let { com.dbpprt.dieter.client.v1.FilesTarget(it.daemonId, it.projectId, it.checkoutId, it.cardId) },
        directory = view.directory, entries = view.entries, show_hidden = view.showHidden,
        listing_loading = view.listingLoading, listing_error = view.listingError.orEmpty(), selected_path = view.selectedPath,
        document = if (documentUnchanged) null else view.document, document_unchanged = documentUnchanged,
        document_loading = view.documentLoading, document_error = view.documentError.orEmpty(), conflict = view.conflict,
        saving = view.saving, can_go_back = view.canGoBack, can_go_forward = view.canGoForward,
    )

    /** Archived chats of every online machine; an unreachable one is skipped. */
    private suspend fun archivedChats(): List<Card> = runtime.connection.machines.value.online.filter { it.compatible }.flatMap { machine ->
        try {
            runtime.admin.archivedChats(machine.id)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            emptyList()
        }
    }

    /** Runs an administration command; null when it has no result. */
    private suspend fun admin(command: AdminCommand): Result? {
        val admin = runtime.admin
        command.create_project?.let {
            return Result(
                created_project = admin.createProject(
                    it.daemon_id, it.path, it.name, it.create, it.board_name.ifEmpty { "Main" }, it.workflow.ifEmpty { "review" },
                    it.base_remote, it.base_branch, it.validation,
                ),
            )
        }
        command.update_project?.let {
            return Result(project = admin.updateProject(it.project_id, it.name, it.summary, it.prompt, if (it.set_hostnames) it.hostnames else null))
        }
        command.set_project_archived?.let { return Result(project = admin.setProjectArchived(it.project_id, it.archived)) }
        command.archived_projects?.let {
            return Result(projects = Projects(if (it.daemon_id.isEmpty()) admin.archivedProjects() else admin.archivedProjects(it.daemon_id)))
        }
        command.consolidate?.let { return Result(project = admin.consolidate(it.source_id, it.destination_id)) }
        command.directories?.let { return Result(directory_listing = admin.directories(it.daemon_id, it.path)) }
        command.attach_checkout?.let { return Result(checkout = admin.attachCheckout(it.daemon_id, it.project_id, it.path, it.name)) }
        command.detach_checkout?.let { admin.detachCheckout(it.project_id, it.checkout_id); return null }
        command.create_board?.let {
            return Result(
                board = admin.createBoard(
                    it.project_id, it.name, it.workflow.ifEmpty { "review" }, it.description, it.done_archive_policy.ifEmpty { "never" },
                    it.base_remote, it.publish_mode.ifEmpty { "manual" },
                ),
            )
        }
        command.rename_board?.let { return Result(board = admin.renameBoard(it.board_id, it.name)) }
        command.set_archive_policy?.let { return Result(board = admin.setArchivePolicy(it.board_id, it.policy)) }
        command.set_git_settings?.let { return Result(board = admin.setGitSettings(it.board_id, it.base_remote, it.publish_mode)) }
        command.set_hostnames?.let { return Result(board = admin.setHostnames(it.board_id, it.hostnames, it.append)) }
        command.set_board_retired?.let { return Result(board = admin.setBoardRetired(it.board_id, it.retired)) }
        command.create_label?.let { return Result(board = admin.createLabel(it.board_id, it.name, it.color, it.instructions)) }
        command.update_label?.let { return Result(board = admin.updateLabel(it.board_id, it.label_id, it.name, it.color, it.instructions)) }
        command.delete_label?.let { return Result(board = admin.deleteLabel(it.board_id, it.label_id)) }
        command.prompt_settings?.let { return Result(prompt_settings = admin.promptSettings(it.daemon_id)) }
        command.update_prompt_settings?.let { return Result(prompt_settings = admin.updatePromptSettings(it.daemon_id, it.context, it.board_skill, it.chat_skill)) }
        command.settings?.let { return Result(settings = admin.settings(it.project_id.ifEmpty { null })) }
        command.update_settings?.let { update ->
            val settings = update.settings ?: invalid("Settings are required.")
            return Result(settings = admin.updateSettings(update.project_id.ifEmpty { null }, settings))
        }
        command.settings_options?.let { return Result(settings_options = admin.settingsOptions(it.project_id.ifEmpty { null })) }
        command.set_project_prompt?.let { return Result(project = admin.setProjectPrompt(it.scope_id, it.template)) }
        command.set_board_prompt?.let { return Result(board = admin.setBoardPrompt(it.scope_id, it.template)) }
        command.preview_prompt?.let {
            return Result(prompt_preview = admin.previewPrompt(it.project_id, it.board_id, it.card_id, it.label_ids, it.checkout_id.ifEmpty { null }))
        }
        command.conflict?.let { return Result(conflict = ConflictRecord(admin.conflict(it.project_id.ifEmpty { null }, it.key))) }
        command.resolve_conflict?.let { resolve ->
            val record = resolve.record ?: invalid("The conflict record is required.")
            return Result(conflict = ConflictRecord(admin.resolve(resolve.project_id.ifEmpty { null }, record, resolve.value_json, resolve.deleted)))
        }
        command.archives?.let {
            val (projects, cards) = admin.archives(it.project_id, it.board_id.ifEmpty { null })
            return Result(archives = Archives(projects, cards))
        }
        command.workspace_settings?.let { update ->
            val project = runtime.workspace.state.value.project(update.project_id) ?: invalid("The project is no longer available.")
            val validation = if (update.set_validation) update.validation.map(ValidationCommandDraft::from) else null
            return Result(
                project = ProjectWorkspaceSettings.update(
                    runtime.sessions, runtime.workspace, project, update.base_remote, update.base_branch, update.checkout_id.ifEmpty { null }, validation,
                ).also(runtime.workspace::overlayProject),
            )
        }
        command.conversation_workspace?.let { return Result(workspace = admin.conversationWorkspace(it.card_id)) }
        command.update_conversation_workspace?.let {
            return Result(card = admin.updateConversationWorkspace(it.card_id, WorkspaceMode.parse(it.mode), it.branch, it.base_branch, it.base_remote, it.publish_mode))
        }
        command.archived_chats?.let { return Result(cards = Cards(archivedChats())) }
        command.read_file?.let { return Result(file_document = admin.readFile(it.daemon_id, it.project_id, it.checkout_id, it.card_id, it.path)) }
        invalid("Unknown administration command.")
    }

    private fun diffRows(lines: List<DiffLine>) = lines.map { line ->
        DiffRow(
            id = line.id,
            kind = when (line.kind) {
                DiffLineKind.HEADER -> DiffRow.Kind.KIND_HEADER
                DiffLineKind.HUNK -> DiffRow.Kind.KIND_HUNK
                DiffLineKind.CONTEXT -> DiffRow.Kind.KIND_CONTEXT
                DiffLineKind.ADDITION -> DiffRow.Kind.KIND_ADDITION
                DiffLineKind.DELETION -> DiffRow.Kind.KIND_DELETION
            },
            text = line.text, old_line = line.oldLine ?: 0, new_line = line.newLine ?: 0,
        )
    }

    private fun reviewSlice(view: WorkspaceReviewView, card: Card? = null): ReviewSlice = ReviewSlice(
        card_id = view.cardId.orEmpty(), daemon_id = view.daemonId.orEmpty(), workspace = view.workspace, changeset = view.changeset,
        scm = view.scm, comments = view.comments, loading = view.loading, error = view.error.orEmpty(),
        selected_path = view.selectedPath.orEmpty(), selected_commit = view.selectedCommit.orEmpty(),
        diff = view.diff?.copy(patch = ""), diff_rows = diffRows(view.diffLines), diff_loading = view.diffLoading,
        operation = view.operation, logs = view.logs, submitting = view.submitting, needs_reconciliation = view.needsReconciliation,
        surface_removed = view.surfaceRemoved, merge_step = view.mergeStep?.name?.lowercase().orEmpty(), toast = view.toast.orEmpty(),
        operation_active = view.operationActive, conflicted = view.conflicted,
        availability = card?.let {
            val availability = WorkspaceAvailability.of(it, view.workspace, view.changeset, view.scm, view.operation, view.submitting || view.needsReconciliation)
            com.dbpprt.dieter.client.v1.WorkspaceAvailability(
                allowed = REVIEW_KINDS.filter(availability::allows), allows_merge_flow = availability.allowsMergeFlow,
                merge_destination = availability.mergeDestination, has_review_branch = availability.hasReviewBranch,
                agent_active = availability.agentActive, operation_active = availability.operationActive, conflicted = availability.conflicted,
                has_remote = availability.hasRemote, dirty = availability.dirty, changed_files = availability.changedFiles,
                has_commits = availability.hasCommits, branch = availability.branch, base = availability.base, publish = availability.publish,
                mode = availability.mode.wire,
            )
        },
    )

    private fun projectChangesSlice(view: ProjectChangesView) = ProjectChangesSlice(
        project_id = view.projectId.orEmpty(), checkout_id = view.checkoutId.orEmpty(), daemon_id = view.daemonId.orEmpty(),
        changes = view.changes, selection = view.selection?.let { (path, section) -> ProjectChangeSelect(path, section == ChangeSection.STAGED) },
        diff = view.diff?.copy(patch = ""), diff_rows = diffRows(view.diffLines), diff_loading = view.diffLoading, operation = view.operation,
        pending_kind = view.pendingKind.orEmpty(), needs_reconciliation = view.needsReconciliation, refreshing = view.refreshing,
        refresh_error = view.refreshError.orEmpty(), diff_error = view.diffError.orEmpty(), operation_error = view.operationError.orEmpty(),
        notice = view.notice.orEmpty(), busy = view.busy, mutations_disabled = view.mutationsDisabled, summary = view.summary.orEmpty(),
    )

    private fun projectWorkspacesSlice(view: ProjectWorkspacesView) = ProjectWorkspacesSlice(
        project_id = view.projectId.orEmpty(), workspaces = view.workspaces, loading = view.loading, error = view.error.orEmpty(),
        pending = view.pending.sorted(), errors = view.errors,
    )

    private fun screenSlice(view: ScreenView, displays: DisplayMatchView, preferences: ScreenPreferences, cursorUnchanged: Boolean) = ScreenSlice(
        phase = when (view.phase) {
            ScreenPhase.Idle -> "idle"
            ScreenPhase.Loading -> "loading"
            is ScreenPhase.PermissionRequired -> "permission_required"
            is ScreenPhase.Unsupported -> "unsupported"
            ScreenPhase.Connecting -> "connecting"
            ScreenPhase.WaitingForHostApproval -> "waiting_for_host_approval"
            ScreenPhase.Streaming -> "streaming"
            is ScreenPhase.Reconnecting -> "reconnecting"
            is ScreenPhase.Failed -> "failed"
        },
        phase_label = view.phase.label,
        problem = view.phase.problem ?: (view.phase as? ScreenPhase.Reconnecting)?.reason.orEmpty(),
        active = view.phase.active, capabilities = view.capabilities, state = view.state, session_id = view.sessionId, ready = view.ready,
        control_active = view.controlActive, can_transfer_control = view.canTransferControl, control_transferring = view.controlTransferring,
        control_error = view.controlError.orEmpty(), codec_fallback_reason = view.codecFallbackReason.orEmpty(),
        clipboard_enabled = view.clipboardEnabled, clipboard_error = view.clipboardError.orEmpty(), clipboard_busy = view.clipboardBusy,
        clipboard_operations = view.clipboardOperations,
        cursor_image = if (cursorUnchanged) ByteString.EMPTY else view.cursorImage ?: ByteString.EMPTY, cursor_image_unchanged = cursorUnchanged,
        cursor_x = view.cursorX, cursor_y = view.cursorY, cursor_visible = view.cursorVisible, cursor_width = view.cursorWidth,
        cursor_height = view.cursorHeight, cursor_hotspot_x = view.cursorHotspotX, cursor_hotspot_y = view.cursorHotspotY,
        route_label = view.routeLabel,
        preferences = com.dbpprt.dieter.client.v1.ScreenPreferences(
            codec = preferences.codec, max_fps = preferences.maxFps, quality = preferences.quality, display_id = preferences.displayId.orEmpty(),
            clipboard = preferences.clipboard,
        ),
        display_status = displays.status, display_busy = displays.busy,
    )

    private fun processesSlice(view: ProcessesView) = ProcessesSlice(
        daemon_id = view.target?.daemonId.orEmpty(), project_id = view.target?.projectId.orEmpty(), card_id = view.target?.cardId.orEmpty(),
        processes = view.processes, selected_id = view.selectedId.orEmpty(), stdout = view.stdout, stderr = view.stderr,
        output_truncated = view.outputTruncated, loading = view.loading, stopping = view.stopping, error = view.error.orEmpty(),
        running = view.running, can_stop = view.canStop,
    )

    private fun telemetrySlice(view: TelemetryView) = TelemetrySlice(
        daemon_id = view.daemonId.orEmpty(),
        machines = view.machines.mapValues { (_, machine) ->
            MachineReadings(
                information = machine.information, loading = machine.loading, error = machine.error.orEmpty(),
                cpu_history = machine.cpuHistory, gpu_history = machine.gpuHistory.mapValues { Samples(it.value) },
            )
        },
        operation_pending = view.operationPending, operation_result = view.operationResult.orEmpty(),
    )

    private fun quotasSlice(view: QuotasView) = QuotasSlice(
        groups = view.groups, loading = view.loading, error = view.error.orEmpty(), mutating = view.mutating.sorted(), live = view.live,
    )

    private fun schedulesSlice(view: SchedulesView) = SchedulesSlice(
        project_id = view.projectId.orEmpty(), schedules = view.schedules, total_count = view.totalCount,
        next_page_token = view.nextPageToken, loaded = view.loaded, loading = view.loading, loading_more = view.loadingMore,
        error = view.error.orEmpty(), action_error = view.actionError.orEmpty(), selected_id = view.selectedId.orEmpty(),
        runs = view.runs, runs_next_page_token = view.runsNextPageToken, runs_loading = view.runsLoading,
        runs_loading_more = view.runsLoadingMore, preview = view.preview, preview_error = view.previewError.orEmpty(),
    )

    private fun terminalScope(target: TerminalTarget): TerminalScope? =
        if (target.daemon_id.isEmpty()) null
        else TerminalScope(
            target.daemon_id,
            when (target.kind) {
                TerminalTarget.Kind.KIND_PROJECT -> TerminalScopeKind.PROJECT
                TerminalTarget.Kind.KIND_CARD -> TerminalScopeKind.CARD
                else -> TerminalScopeKind.MACHINE
            },
            target.project_id, target.checkout_id, target.card_id,
        )

    /** [outputs] is the observer's replay position; command results carry no output. */
    private fun terminalsSlice(view: TerminalsView, outputs: TerminalOutputs?) = TerminalsSlice(
        target = view.scope?.let { scope ->
            TerminalTarget(
                daemon_id = scope.daemonId,
                kind = when (scope.kind) {
                    TerminalScopeKind.MACHINE -> TerminalTarget.Kind.KIND_MACHINE
                    TerminalScopeKind.PROJECT -> TerminalTarget.Kind.KIND_PROJECT
                    TerminalScopeKind.CARD -> TerminalTarget.Kind.KIND_CARD
                },
                project_id = scope.projectId, checkout_id = scope.checkoutId, card_id = scope.cardId,
            )
        },
        terminals = view.terminals, selected_id = view.selectedId.orEmpty(), loading = view.loading,
        error = view.error.orEmpty(), stream_connected = view.streamConnected, active = view.active,
        output = outputs?.next(view).orEmpty(),
    )

    private fun overviewSlice(view: TerminalOverviewView, terminals: TerminalsSlice) = TerminalOverviewSlice(
        entries = view.entries.map { OverviewTerminal(it.id, it.daemonId, it.machineName, it.terminal) },
        selected_id = view.selectedId.orEmpty(), loading = view.loading, errors = view.errors,
        no_machines = view.noMachines, terminals = terminals,
    )

    /**
     * One observer's replay position in each retained screen, so it receives
     * every byte once; a new epoch or a trimmed-away position replays what is
     * retained after a reset.
     */
    private class TerminalOutputs {
        private val cursors = HashMap<String, TerminalReplayCursor>()

        fun next(view: TerminalsView): List<TerminalOutput> {
            cursors.keys.retainAll(view.screens.keys)
            return view.screens.mapNotNull { (id, screen) ->
                var reset = false
                val written = Buffer()
                cursors.getOrPut(id, ::TerminalReplayCursor).apply(
                    screen,
                    object : TerminalRendererSink {
                        override fun reset() {
                            reset = true
                            written.clear()
                        }

                        override fun feed(bytes: ByteArray) {
                            written.write(bytes)
                        }

                        override fun redraw() {}
                    },
                )
                if (!reset && written.size == 0L) null else TerminalOutput(id, reset, written.readByteString())
            }
        }
    }

    private fun fileTreeSlice(view: FileTree.TreeView) = FileTreeSlice(
        folders = view.folders.entries.sortedBy { it.key }.map { (path, entries) -> FileTreeFolder(path, entries) },
        expanded = view.expanded.sorted(), loading = view.loading.sorted(), error = view.error.orEmpty(), show_hidden = view.showHidden,
    )

    private fun creationSlice(saved: CreationPreferences) = CreationSlice(
        selection = HarnessSelection(saved.provider, saved.model, saved.effort, saved.provider_options),
        workspace_mode = saved.workspace_mode, project_id = saved.project_id, boards = saved.boards,
    )

    fun workspaceSlices(): Flow<WorkspaceSlice> = runtime.workspace.state.map { view ->
        WorkspaceSlice(
            projects = view.projects, boards = view.boards.values.flatten(), cards = view.allItems,
            pending_card_ids = view.pendingCardIds.sorted(), loaded = view.loaded, project_replicas = view.projectReplicas,
            retired_boards = view.retiredBoards, settings = view.settings,
        )
    }

    fun outboxSlices(): Flow<OutboxSlice> = runtime.outbox.view.map { view ->
        OutboxSlice(
            pending_card_ids = view.pendingCardIds.sorted(), pending_message_ids = view.pendingMessageIds.sorted(),
            accepted_ids = view.acceptedIds.sorted(), failed_ids = view.failedIds.sorted(),
            machines = view.machines.map { (daemonId, summary) ->
                MachineOutbox(
                    daemonId, summary.itemCount, if (summary.failed) summary.itemCount else 0, summary.failureMessage.orEmpty(),
                    message_count = summary.messageCount, change_count = summary.changeCount, retrying = summary.retrying,
                )
            }.sortedBy { it.daemon_id },
            resolutions = view.resolutions,
            failures = view.failedIds.associateWith { view.failure(it).orEmpty() }.filterValues { it.isNotEmpty() },
            storage_error = view.storageError.orEmpty(),
            failed_operations = view.entries.filter { it.state == OutboxState.OUTBOX_STATE_FAILED }.sortedBy { it.created_at_millis }.map { entry ->
                val target = entry.server_id.ifEmpty { entry.optimistic_id }
                FailedOperation(
                    id = entry.optimistic_id, label = operationLabel(entry.kind), target_id = target,
                    failure = entry.last_error.ifEmpty { "The queued operation failed." }, created_at_millis = entry.created_at_millis,
                )
            },
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
        private val OVERVIEW_RELIST = 3.seconds
        private val REVIEW_KINDS = listOf(
            "commit", "update", "validate", "merge_local", "push", "create_pr", "refresh_pr", "merge_pr",
            "adopt", "discard", "cleanup", "continue_conflict", "abort_conflict",
        )

        fun operationLabel(kind: OutboxKind): String = when (kind) {
            OutboxKind.OUTBOX_KIND_CREATE_CARD -> "Create card"
            OutboxKind.OUTBOX_KIND_CREATE_CHAT -> "Create chat"
            OutboxKind.OUTBOX_KIND_SEND_MESSAGE -> "Send message"
            OutboxKind.OUTBOX_KIND_START_CARD -> "Start card"
            else -> "Queued operation"
        }

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
            awaiting_reply = view.awaitingReply, retrying = view.retrying,
            refreshed_at_millis = view.refreshedAt?.toEpochMilliseconds() ?: 0,
            turn_failure = TurnFailure.resolve(view.transcript.messages, view.transcript.conversation?.status, view.card?.runtime)?.let {
                com.dbpprt.dieter.client.v1.TurnFailure(it.summary, it.log, it.failedMessageId.orEmpty(), it.retryParts.isNotEmpty())
            },
            project = view.presented?.detail?.project, board = view.presented?.detail?.board, page = view.presented?.page,
            earlier_count = view.messages.size - view.presented?.conversation?.messages.orEmpty().size,
        )

        /** What the conversation screen shows besides the transcript, as the presenter reads [view]. */
        fun conversationState(view: ConversationView, outbox: OutboxView, board: BoardOperationsView, workspace: WorkspaceView): ConversationState {
            val card = view.card ?: workspace.card(view.cardId)
            val cardBoard = card?.board_id?.let(workspace::board)
            val operation = card?.id?.let(board.operations::get)
            val plain = ConversationPresenter.present(view, outbox, cardBoard, operation, showReasoning = false, fallbackCard = card)
            // Only the live label depends on reasoning; resolve it from the same turn.
            val conversation = view.conversation
            val excluded = conversation?.queue.orEmpty().mapTo(HashSet()) { it.id } + outbox.pendingMessageIds + outbox.failedIds
            val live = conversation?.messages.orEmpty().filterNot { it.id in excluded }
            val reasoning = LiveActivities.resolve(
                live, conversation?.pending_tools.orEmpty(), conversation?.task_plans.orEmpty(), true,
                conversation?.status, plain.runtime, conversation?.provider_status,
            )
            return ConversationState(
                runtime = plain.runtime, active_turn = plain.activeTurn, working = plain.working,
                live_activity = if (plain.working) plain.liveActivity.english() else "",
                live_reasoning = if (plain.working) reasoning.english() else "",
                turn_started_at_millis = plain.turnStart?.toEpochMilliseconds() ?: 0,
                responding_model = plain.respondingModel.orEmpty(), unsent_task = plain.unsentTask.orEmpty(),
                steerable_id = plain.steerableId.orEmpty(), interrupting = plain.interrupting,
                ready_for_review = plain.readyForReview, can_start = plain.canStart, starting = plain.starting,
                context_used_tokens = plain.contextUsage?.usedTokens ?: 0, context_window_tokens = plain.contextUsage?.windowTokens ?: 0,
            )
        }

        /** Keyed changes between two workspace snapshots; null when nothing changed. */
        fun workspaceDelta(previous: WorkspaceSlice, next: WorkspaceSlice): WorkspaceDelta? {
            if (previous == next) return null
            val cards = Keyed.diff(previous.cards, next.cards, Card::id)
            return WorkspaceDelta(
                projects = next.projects, boards = next.boards, upserted_cards = cards.upserted, removed_card_ids = cards.removed,
                card_order = if (cards.orderChanged) next.cards.map(Card::id) else emptyList(), order_changed = cards.orderChanged,
                pending_card_ids = next.pending_card_ids, loaded = next.loaded, project_replicas = next.project_replicas,
                retired_boards = next.retired_boards, settings = next.settings,
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
                awaiting_reply = next.awaiting_reply, retrying = next.retrying, refreshed_at_millis = next.refreshed_at_millis,
                turn_failure = next.turn_failure, project = next.project, board = next.board, page = next.page,
                card_id = next.card_id, daemon_id = next.daemon_id, earlier_count = next.earlier_count, state = next.state,
            )
        }

        /** Applies [delta] to [base], as a Kotlin observer (and the tests) would. */
        fun apply(base: WorkspaceSlice, delta: WorkspaceDelta): WorkspaceSlice = base.copy(
            projects = delta.projects, boards = delta.boards,
            cards = Keyed.apply(base.cards, delta.upserted_cards, delta.removed_card_ids, delta.card_order.takeIf { delta.order_changed }, Card::id),
            pending_card_ids = delta.pending_card_ids, loaded = delta.loaded, project_replicas = delta.project_replicas,
            retired_boards = delta.retired_boards, settings = delta.settings,
        )

        fun apply(base: ConversationSlice, delta: ConversationDelta): ConversationSlice = base.copy(
            card = delta.card, conversation = delta.conversation,
            messages = Keyed.apply(base.messages, delta.upserted_messages, delta.removed_message_ids, delta.message_order.takeIf { delta.order_changed }, UiMessage::id),
            loading = delta.loading, syncing = delta.syncing, error = delta.error, pending = delta.pending,
            has_earlier = delta.has_earlier, loading_earlier = delta.loading_earlier, browsing_earlier = delta.browsing_earlier,
            awaiting_reply = delta.awaiting_reply, retrying = delta.retrying, refreshed_at_millis = delta.refreshed_at_millis,
            turn_failure = delta.turn_failure, project = delta.project, board = delta.board, page = delta.page,
            card_id = delta.card_id.ifEmpty { base.card_id }, daemon_id = delta.daemon_id, earlier_count = delta.earlier_count,
            state = delta.state,
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

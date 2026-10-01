package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.client.v1.AdoptSession
import com.dbpprt.dieter.client.v1.ArchiveCard
import com.dbpprt.dieter.client.v1.BoardSlice
import com.dbpprt.dieter.client.v1.ClearCardError
import com.dbpprt.dieter.client.v1.CreationSlice
import com.dbpprt.dieter.client.v1.EnsureMetadata
import com.dbpprt.dieter.client.v1.FileTreeCommand
import com.dbpprt.dieter.client.v1.FileTreeSlice
import com.dbpprt.dieter.client.v1.FilesCommand
import com.dbpprt.dieter.client.v1.FilesCreate
import com.dbpprt.dieter.client.v1.FilesPath
import com.dbpprt.dieter.client.v1.FilesSlice
import com.dbpprt.dieter.client.v1.FilesTarget
import com.dbpprt.dieter.client.v1.FilesText
import com.dbpprt.dieter.client.v1.FilesToggle
import com.dbpprt.dieter.client.v1.FolderScope
import com.dbpprt.dieter.client.v1.ForkCard
import com.dbpprt.dieter.client.v1.GatewayConfig
import com.dbpprt.dieter.client.v1.ListArchivedCards
import com.dbpprt.dieter.client.v1.ListDrafts
import com.dbpprt.dieter.client.v1.MetadataSlice
import com.dbpprt.dieter.client.v1.NavigationFolder
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.RememberCreation
import com.dbpprt.dieter.client.v1.Resync
import com.dbpprt.dieter.client.v1.RetryFailedTurn
import com.dbpprt.dieter.client.v1.SetDraftText
import com.dbpprt.dieter.client.v1.SetFolders
import com.dbpprt.dieter.client.v1.SetGateways
import com.dbpprt.dieter.client.v1.SetLaneDescending
import com.dbpprt.dieter.client.v1.SetProjectExpanded
import com.dbpprt.dieter.client.v1.SetProjectOrder
import com.dbpprt.dieter.client.v1.UpdateCardDraft
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.client.v1.SaveSchedule
import com.dbpprt.dieter.client.v1.ScheduleEnabled
import com.dbpprt.dieter.client.v1.ScheduleId
import com.dbpprt.dieter.client.v1.SchedulePreview
import com.dbpprt.dieter.client.v1.ScheduleProject
import com.dbpprt.dieter.client.v1.ScheduleStep
import com.dbpprt.dieter.client.v1.SchedulesCommand
import com.dbpprt.dieter.client.v1.SchedulesSlice
import com.dbpprt.dieter.client.v1.CreateTerminal
import com.dbpprt.dieter.client.v1.TerminalId
import com.dbpprt.dieter.client.v1.TerminalInput
import com.dbpprt.dieter.client.v1.TerminalOverviewCommand
import com.dbpprt.dieter.client.v1.TerminalOverviewLoad
import com.dbpprt.dieter.client.v1.TerminalOverviewSlice
import com.dbpprt.dieter.client.v1.TerminalRename
import com.dbpprt.dieter.client.v1.TerminalStep
import com.dbpprt.dieter.client.v1.TerminalTarget
import com.dbpprt.dieter.client.v1.TerminalToggle
import com.dbpprt.dieter.client.v1.TerminalsCommand
import com.dbpprt.dieter.client.v1.TerminalsSlice
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.CreateConversation
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.RenameCard
import com.dbpprt.dieter.client.v1.SendMessage
import com.dbpprt.dieter.client.v1.SessionSlice
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import okio.ByteString.Companion.encodeUtf8

/**
 * The D7 contract end to end: a UI that only dispatches commands and applies
 * observed snapshots and deltas signs in, sees the workspace, creates and
 * renames a card, and chats, exactly as the Apple façade does with bytes.
 */
class ClientApiEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    /** Folds updates as a UI would; a sequence gap fails the test. */
    private class Mirror {
        val session = MutableStateFlow<SessionSlice?>(null)
        val workspace = MutableStateFlow<WorkspaceSlice?>(null)
        val conversation = MutableStateFlow<ConversationSlice?>(null)
        private val sequences = mutableMapOf<Slice, Long>()

        fun accept(update: Update) {
            val last = sequences[update.slice] ?: 0
            check(update.sequence == last + 1) { "missed an update of ${update.slice}: $last → ${update.sequence}" }
            sequences[update.slice] = update.sequence
            update.session?.let { session.value = it }
            update.workspace?.let { workspace.value = it }
            update.workspace_delta?.let { delta -> workspace.value = ClientApi.apply(checkNotNull(workspace.value), delta) }
            update.conversation?.let { conversation.value = it }
            update.conversation_delta?.let { delta -> conversation.value = ClientApi.apply(checkNotNull(conversation.value), delta) }
        }
    }

    @Test
    fun aByteOnlyUiSignsInCreatesRenamesAndChats() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, token = null)
        val api = ClientApi(runtime)
        val mirror = Mirror()
        val subscriptions = listOf(Slice.SLICE_SESSION, Slice.SLICE_WORKSPACE).map { slice ->
            api.observe(slice, "") { update -> mirror.accept(Update.ADAPTER.decode(update.encode())) }
        }

        val invalid = assertFailsWith<ClientFailure> { api.dispatch(Command(adopt_session = AdoptSession(gateway_url = fixture.url, session_token = ""))) }
        assertEquals(Failure.Kind.KIND_INVALID, invalid.failure.kind)
        api.dispatch(Command(adopt_session = AdoptSession(gateway_url = fixture.url, session_token = fixture.token, name = "Isolated")))
        val session = mirror.session.await(30.seconds, describe = { "connected: ${mirror.session.value}" }) { it?.phase == SessionSlice.Phase.PHASE_CONNECTED }!!
        assertTrue(session.signed_in)
        assertEquals(fixture.daemonId, session.attached_machine_id)
        assertTrue(session.machines.any { it.id == fixture.daemonId && it.online && it.attached })
        mirror.workspace.await(describe = { "project" }) { slice -> slice?.projects?.any { it.id == fixture.projectId } == true }

        val created = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(
                        project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "From the client contract",
                        prompt = "hello", defer_start = true, workspace_mode = "project",
                    ),
                ),
            ),
        ).card!!
        mirror.workspace.await(describe = { "created card" }) { slice -> slice?.cards?.any { it.title == "From the client contract" } == true }
        val serverId = mirror.workspace.await(30.seconds, describe = { "synced card" }) { slice ->
            slice?.cards?.any { OutboxPolicy.isServerBacked(it.id) && it.title == "From the client contract" } == true
        }!!.cards.first { it.title == "From the client contract" }.id
        assertTrue(created.id.isNotEmpty())
        api.dispatch(Command(rename_card = RenameCard(card_id = serverId, title = "Renamed through bytes")))
        mirror.workspace.await(describe = { "renamed" }) { slice -> slice?.cards?.any { it.id == serverId && it.title == "Renamed through bytes" } == true }
        assertEquals(mirror.workspace.value, api.workspaceSlices().await { true }, "folded deltas equal a fresh snapshot")

        val chat = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(project_id = fixture.projectId, title = "chat", prompt = "first", provider = "mock", model = "mock", effort = "low", workspace_mode = "project"),
                    chat = true,
                ),
            ),
        ).card!!
        val watching = api.observe(Slice.SLICE_CONVERSATION, chat.id) { mirror.accept(Update.ADAPTER.decode(it.encode())) }
        fun replies() = mirror.conversation.value?.messages.orEmpty().count { it.role == "assistant" }
        mirror.conversation.await(60.seconds, describe = { "first reply: ${mirror.conversation.value}" }) { replies() >= 1 && it?.conversation?.status !in setOf("running", "starting") }
        val cardId = mirror.conversation.value!!.card_id
        api.dispatch(Command(send_message = SendMessage(card_id = cardId, parts = listOf(MessagePart(type = "text", text = "second")))))
        mirror.conversation.await(60.seconds, describe = { "second reply: ${mirror.conversation.value}" }) { replies() >= 2 && it?.conversation?.status !in setOf("running", "starting") }
        assertEquals(
            listOf("first", "second"),
            mirror.conversation.value!!.messages.filter { it.role == "user" }.flatMap { it.parts }.filter { it.type == "text" }.map { it.text },
        )
        watching.close()
        subscriptions.forEach { it.close() }
    }

    @Test
    fun theMacSessionContractCoversMetadataBoardEditsAndConversationState() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, token = null)
        val api = ClientApi(runtime)
        val mirror = Mirror()
        suspend fun step(name: String, command: Command) =
            try { api.dispatch(command) } catch (failure: ClientFailure) { throw AssertionError("$name: ${failure.message}", failure) }
        val metadata = MutableStateFlow<MetadataSlice?>(null)
        val board = MutableStateFlow<BoardSlice?>(null)
        val subscriptions = listOf(Slice.SLICE_SESSION, Slice.SLICE_WORKSPACE).map { slice ->
            api.observe(slice, "") { update -> mirror.accept(Update.ADAPTER.decode(update.encode())) }
        } + api.observe(Slice.SLICE_METADATA, "") { metadata.value = Update.ADAPTER.decode(it.encode()).metadata } +
            api.observe(Slice.SLICE_BOARD, "") { board.value = Update.ADAPTER.decode(it.encode()).board }
        api.dispatch(Command(adopt_session = AdoptSession(gateway_url = fixture.url, session_token = fixture.token, name = "Isolated")))
        val session = mirror.session.await(30.seconds, describe = { "live feed: ${mirror.session.value}" }) {
            it?.phase == SessionSlice.Phase.PHASE_CONNECTED && it.feed?.live == true
        }!!
        val machine = session.machines.single { it.id == fixture.daemonId }
        assertEquals("COMPATIBILITY_STATUS_COMPATIBLE", machine.compatibility)
        assertTrue(machine.last_seen_at.isNotEmpty() || machine.online)
        assertEquals(machine.route == "Local", machine.local, "a loopback plane marks the machine as this device: ${machine.route}")
        assertEquals(fixture.daemonId, session.feed!!.daemon_id)
        assertTrue(session.feed!!.last_applied_at_millis > 0)
        assertEquals(emptyList(), session.sync_warnings)
        board.await(describe = { "board slice" }) { it != null }

        // Metadata loads on request and arrives through its slice.
        step("metadata", Command(ensure_metadata = EnsureMetadata(daemon_id = fixture.daemonId)))
        val loaded = metadata.await(30.seconds, describe = { "metadata: ${metadata.value}" }) { it?.machines?.get(fixture.daemonId)?.loaded == true }!!
        assertTrue(loaded.machines.getValue(fixture.daemonId).harnesses!!.harnesses.any { it.id == "mock" })

        // Gateways are edited as a list; the active one stays connected.
        api.dispatch(
            Command(
                set_gateways = SetGateways(
                    gateways = listOf(GatewayConfig(fixture.url, "Isolated"), GatewayConfig("http://127.0.0.1:9", "Spare")),
                    active_origin = session.gateway_origin,
                ),
            ),
        )
        mirror.session.await(describe = { "two gateways" }) { it?.gateways?.size == 2 }
        assertFailsWith<ClientFailure> { api.dispatch(Command(set_gateways = SetGateways(gateways = listOf(GatewayConfig("http://example.com", "Remote plaintext"))))) }

        // Layout edits show at once and drain to the attached machine.
        val navigation = MutableStateFlow<NavigationSlice?>(null)
        val navigationWatch = api.observe(Slice.SLICE_NAVIGATION, "") { navigation.value = Update.ADAPTER.decode(it.encode()).navigation }
        step("project order", Command(set_project_order = SetProjectOrder(project_ids = listOf(fixture.projectId))))
        step("lane sort", Command(set_lane_descending = SetLaneDescending(board_id = fixture.boardId, lane_id = "todo", descending = false)))
        step("expand project", Command(set_project_expanded = SetProjectExpanded(project_id = fixture.projectId, expanded = true)))
        step(
            "folders",
            Command(
                set_folders = SetFolders(
                    scope = FolderScope.FOLDER_SCOPE_PROJECTS,
                    folders = listOf(NavigationFolder(id = "f_work", name = " Work ", item_ids = listOf(fixture.projectId), expanded = true)),
                ),
            ),
        )
        val laid = navigation.await(30.seconds, describe = { "navigation: ${navigation.value}" }) { slice ->
            slice?.pending == 0 && slice.caught_up && slice.project_folders.singleOrNull()?.name == "Work"
        }!!
        assertEquals(listOf(fixture.projectId), laid.project_order)
        assertEquals(listOf(fixture.projectId), laid.project_folders.single().item_ids)
        assertEquals("ascending", laid.lane_sorts["${fixture.boardId}.todo"])
        assertEquals(listOf(fixture.projectId), laid.expanded_projects)
        assertFailsWith<AssertionError> {
            step("duplicate folder", Command(set_folders = SetFolders(folders = listOf(NavigationFolder(id = "a", name = "Same"), NavigationFolder(id = "b", name = "same")))))
        }
        navigationWatch.close()

        // A files surface lists, creates, opens, and saves on the project's machine.
        val filesSlice = MutableStateFlow<FilesSlice?>(null)
        val filesWatch = api.observe(Slice.SLICE_FILES, "files-test") { filesSlice.value = Update.ADAPTER.decode(it.encode()).files }
        fun files(action: FilesCommand) = Command(files = action.copy(scope = "files-test"))
        step("files bind", files(FilesCommand(bind = FilesTarget(daemon_id = fixture.daemonId, project_id = fixture.projectId))))
        // The command's result is the surface after it, without waiting for an update.
        val listed = step("files load", files(FilesCommand(load = FilesPath()))).files!!
        assertTrue(!listed.listing_loading && listed.entries.isNotEmpty(), "load result: $listed")
        filesSlice.await(30.seconds, describe = { "listing: ${filesSlice.value}" }) { it?.listing_loading == false && it.entries.isNotEmpty() }
        step("files create", files(FilesCommand(create = FilesCreate(name = "core-notes.txt"))))
        filesSlice.await(describe = { "created: ${filesSlice.value?.entries?.map { it.name }}" }) { slice -> slice?.entries?.any { it.name == "core-notes.txt" } == true }
        step("files open", files(FilesCommand(open_ = FilesPath(path = "core-notes.txt"))))
        filesSlice.await(describe = { "opened" }) { it?.selected_path == "core-notes.txt" && it.document != null && !it.document_loading }
        val saved = step("files save", files(FilesCommand(save = FilesText(text = "written through the core\n")))).file_document!!
        assertEquals("written through the core\n", saved.content)
        // An update that does not change the document leaves it out.
        step("files hidden", files(FilesCommand(show_hidden = FilesToggle(on = true))))
        filesSlice.await(describe = { "hidden shown" }) { it?.show_hidden == true && it.document_unchanged && it.document == null }
        val tree = MutableStateFlow<FileTreeSlice?>(null)
        val treeWatch = api.observe(Slice.SLICE_FILE_TREE, "tree-test") { tree.value = Update.ADAPTER.decode(it.encode()).file_tree }
        step("tree bind", Command(file_tree = FileTreeCommand(scope = "tree-test", bind = FilesTarget(daemon_id = fixture.daemonId, project_id = fixture.projectId))))
        step("tree load", Command(file_tree = FileTreeCommand(scope = "tree-test", load = FilesPath())))
        tree.await(30.seconds, describe = { "tree: ${tree.value}" }) { slice -> slice?.folders?.any { folder -> folder.path == "" && folder.entries.any { it.name == "core-notes.txt" } } == true }
        assertFailsWith<AssertionError> { step("unknown surface", Command(files = FilesCommand(scope = "missing", load = FilesPath()))) }
        filesWatch.close()
        treeWatch.close()

        // A machine terminal streams its output to each observer once, and the
        // overview's terminals take the same commands under its scope.
        val terms = MutableStateFlow<TerminalsSlice?>(null)
        val written = MutableStateFlow("")
        val termsWatch = api.observe(Slice.SLICE_TERMINALS, "terms-test") { update ->
            val slice = Update.ADAPTER.decode(update.encode()).terminals!!
            for (chunk in slice.output) written.update { (if (chunk.reset) "" else it) + chunk.data_.utf8() }
            terms.value = slice
        }
        fun terminals(action: TerminalsCommand) = Command(terminals = action.copy(scope = "terms-test"))
        step("terminals bind", terminals(TerminalsCommand(bind = TerminalTarget(daemon_id = fixture.daemonId))))
        step("terminals active", terminals(TerminalsCommand(active = TerminalToggle(on = true))))
        step("terminals load", terminals(TerminalsCommand(load = TerminalStep())))
        val shell = step("terminals create", terminals(TerminalsCommand(create = CreateTerminal(name = "contract", shell = "sh", columns = 100, rows = 30)))).terminal!!
        step("terminals input", terminals(TerminalsCommand(input = TerminalInput(data_ = "echo contract-$((6*7))\n".encodeUtf8()))))
        written.await(20.seconds, describe = { "output: ${written.value}" }) { it.contains("contract-42") }
        step("terminals second input", terminals(TerminalsCommand(input = TerminalInput(data_ = "echo second-$((1+1))\n".encodeUtf8()))))
        written.await(20.seconds, describe = { "output: ${written.value}" }) { it.contains("second-2") }
        assertEquals(1, written.value.split("contract-42").size - 1, "an observer receives each byte once: ${written.value}")
        assertEquals(shell.id, terms.value?.selected_id)
        val renamed = step("terminals rename", terminals(TerminalsCommand(rename = TerminalRename(terminal_id = shell.id, name = "renamed")))).terminals!!
        assertTrue(renamed.output.isEmpty(), "command results carry no output")
        assertEquals("renamed", renamed.terminals.first { it.id == shell.id }.name)

        val overviewWritten = MutableStateFlow("")
        val overviewSlice = MutableStateFlow<TerminalOverviewSlice?>(null)
        val overviewWatch = api.observe(Slice.SLICE_TERMINAL_OVERVIEW, "overview-test") { update ->
            val slice = Update.ADAPTER.decode(update.encode()).terminal_overview!!
            for (chunk in slice.terminals?.output.orEmpty()) overviewWritten.update { (if (chunk.reset) "" else it) + chunk.data_.utf8() }
            overviewSlice.value = slice
        }
        val overview = step(
            "overview load",
            Command(terminal_overview = TerminalOverviewCommand(scope = "overview-test", load = TerminalOverviewLoad(preferred_daemon_id = fixture.daemonId))),
        ).terminal_overview!!
        assertTrue(overview.entries.any { it.terminal?.id == shell.id }, "overview: ${overview.entries}")
        assertEquals(fixture.daemonId, overview.terminals?.target?.daemon_id)
        step("overview terminals active", Command(terminals = TerminalsCommand(scope = "overview-test", active = TerminalToggle(on = true))))
        overviewWritten.await(20.seconds, describe = { "overview output: ${overviewWritten.value}" }) { it.contains("second-2") }
        // A rename and a close through the overview's terminals show in its list.
        step("overview rename", Command(terminals = TerminalsCommand(scope = "overview-test", rename = TerminalRename(terminal_id = shell.id, name = "overview name"))))
        overviewSlice.await(describe = { "renamed in the overview: ${overviewSlice.value?.entries}" }) { slice ->
            slice?.entries?.any { it.terminal?.id == shell.id && it.terminal?.name == "overview name" } == true
        }
        step("overview close", Command(terminals = TerminalsCommand(scope = "overview-test", close = TerminalId(terminal_id = shell.id))))
        overviewSlice.await(describe = { "closed in the overview: ${overviewSlice.value?.entries}" }) { slice ->
            slice != null && slice.entries.none { it.terminal?.id == shell.id }
        }
        overviewWatch.close()
        val closed = step("terminals reload", terminals(TerminalsCommand(load = TerminalStep()))).terminals!!
        assertTrue(closed.terminals.none { it.id == shell.id }, "closed: ${closed.terminals}")
        termsWatch.close()

        // Schedules: a draft is saved on the project's machine, paused, run,
        // and deleted; each command returns its result or the schedules.
        val schedules = MutableStateFlow<SchedulesSlice?>(null)
        val schedulesWatch = api.observe(Slice.SLICE_SCHEDULES, "") { schedules.value = Update.ADAPTER.decode(it.encode()).schedules }
        fun schedulesCommand(action: SchedulesCommand) = Command(schedules = action)
        step("schedules bind", schedulesCommand(SchedulesCommand(bind = ScheduleProject(project_id = fixture.projectId))))
        val scheduleList = step("schedules load", schedulesCommand(SchedulesCommand(load = ScheduleStep()))).schedules!!
        assertTrue(scheduleList.loaded && scheduleList.project_id == fixture.projectId, "listed: $scheduleList")
        step("schedules preview", schedulesCommand(SchedulesCommand(preview = SchedulePreview(cron = "0 9 * * 1-5", timezone = "Europe/Berlin"))))
        schedules.await(30.seconds, describe = { "preview: ${schedules.value}" }) { it?.preview?.size == 5 }
        val scheduleDraft = ScheduleDraft(
            board_id = fixture.boardId, name = "Contract", cron = "0 9 * * 1-5", timezone = "UTC", enabled = true, action = "draft",
            title_template = "Contract · {{date}}", prompt_template = "Summarize {{project}}", provider = "mock", model = "mock", effort = "low",
            open_card_policy = "skip_if_open", workspace_mode = "project",
        )
        val savedSchedule = step("schedules save", schedulesCommand(SchedulesCommand(save = SaveSchedule(draft = scheduleDraft)))).schedule!!
        assertEquals("Contract", savedSchedule.name)
        val paused = step("schedules pause", schedulesCommand(SchedulesCommand(set_enabled = ScheduleEnabled(schedule_id = savedSchedule.id, enabled = false)))).schedule!!
        assertTrue(!paused.enabled)
        val run = step("schedules run", schedulesCommand(SchedulesCommand(run_now = ScheduleId(schedule_id = savedSchedule.id)))).schedule_run!!
        assertEquals(savedSchedule.id, run.schedule_id)
        val full = step("schedules details", schedulesCommand(SchedulesCommand(details = ScheduleId(schedule_id = savedSchedule.id)))).schedule!!
        assertEquals("Summarize {{project}}", full.prompt_template)
        val deleted = step("schedules delete", schedulesCommand(SchedulesCommand(delete = ScheduleId(schedule_id = savedSchedule.id)))).schedules!!
        assertTrue(deleted.schedules.none { it.id == savedSchedule.id }, "deleted: ${deleted.schedules}")
        step("schedules close editor", schedulesCommand(SchedulesCommand(close_editor = ScheduleStep())))
        schedules.await(describe = { "editor closed: ${schedules.value}" }) { it?.preview?.isEmpty() == true }
        schedulesWatch.close()

        // A never-started todo card's draft is edited, then archived and listed.
        val todo = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(
                        project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Draft", prompt = "first draft",
                        defer_start = true, workspace_mode = "project",
                    ),
                ),
            ),
        ).card!!
        val todoId = mirror.workspace.await(30.seconds, describe = { "synced draft" }) { slice ->
            slice?.cards?.any { OutboxPolicy.isServerBacked(it.id) && it.title == "Draft" } == true
        }!!.cards.first { it.title == "Draft" }.id
        assertTrue(todo.id.isNotEmpty())
        step("edit draft", Command(update_card_draft = UpdateCardDraft(card_id = todoId, title = "Edited draft", prompt = "second draft")))
        mirror.workspace.await(describe = { "edited" }) { slice -> slice?.cards?.any { it.id == todoId && it.title == "Edited draft" && it.initial_prompt == "second draft" } == true }
        step("archive", Command(archive_card = ArchiveCard(card_id = todoId)))
        mirror.workspace.await(describe = { "archived" }) { slice -> slice?.cards?.none { it.id == todoId } == true }
        val archived = step("list archived", Command(list_archived_cards = ListArchivedCards(board_id = fixture.boardId))).cards!!.cards
        assertTrue(archived.any { it.id == todoId })
        step("clear error", Command(clear_card_error = ClearCardError(card_id = todoId)))

        // A chat reports awaiting its reply, has no failed turn to retry, and forks.
        val chat = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(project_id = fixture.projectId, title = "chat", prompt = "first", provider = "mock", model = "mock", effort = "low", workspace_mode = "project"),
                    chat = true,
                ),
            ),
        ).card!!
        val watching = api.observe(Slice.SLICE_CONVERSATION, chat.id) { mirror.accept(Update.ADAPTER.decode(it.encode())) }
        fun replies() = mirror.conversation.value?.messages.orEmpty().count { it.role == "assistant" }
        mirror.conversation.await(60.seconds, describe = { "first reply" }) { replies() >= 1 && it?.conversation?.status !in setOf("running", "starting") }
        val cardId = mirror.conversation.value!!.card_id
        assertEquals(null, mirror.conversation.value!!.turn_failure)
        // The slice carries what a conversation header shows: project, board, and window.
        assertEquals(fixture.projectId, mirror.conversation.value!!.project?.id)
        assertTrue((mirror.conversation.value!!.page?.total ?: 0) >= mirror.conversation.value!!.messages.size)
        assertEquals(emptyList(), session.machines.single { it.id == fixture.daemonId }.sync_warnings)
        assertEquals("", step("retry", Command(retry_failed_turn = RetryFailedTurn(card_id = cardId))).message_queued!!.message_id)
        step("send", Command(send_message = SendMessage(card_id = cardId, parts = listOf(MessagePart(type = "text", text = "second")))))
        mirror.conversation.await(60.seconds, describe = { "second reply" }) {
            replies() >= 2 && it?.conversation?.status !in setOf("running", "starting") && it?.awaiting_reply == false
        }
        assertTrue(mirror.conversation.value!!.refreshed_at_millis > 0)
        // Drafts and creation choices stay on this device.
        step("draft", Command(set_draft_text = SetDraftText(daemon_id = fixture.daemonId, card_id = cardId, text = "unsent")))
        val drafts = step("drafts", Command(list_drafts = ListDrafts())).drafts!!.drafts
        assertEquals(listOf("unsent"), drafts.filter { it.daemon_id == fixture.daemonId && it.card_id == cardId }.map { it.text })
        step("clear draft", Command(set_draft_text = SetDraftText(daemon_id = fixture.daemonId, card_id = cardId, text = "")))
        assertTrue(step("drafts", Command(list_drafts = ListDrafts())).drafts!!.drafts.none { it.card_id == cardId })
        val creation = MutableStateFlow<CreationSlice?>(null)
        val creationWatch = api.observe(Slice.SLICE_CREATION, "") { creation.value = Update.ADAPTER.decode(it.encode()).creation }
        step(
            "remember",
            Command(
                remember_creation = RememberCreation(
                    selection = HarnessSelection("mock", "mock", "low"), workspace_mode = "project",
                    project_id = fixture.projectId, board_id = fixture.boardId,
                ),
            ),
        )
        creation.await(describe = { "creation: ${creation.value}" }) {
            it?.project_id == fixture.projectId && it.boards[fixture.projectId] == fixture.boardId &&
                it.selection?.provider == "mock" && it.workspace_mode == "project"
        }
        creationWatch.close()
        assertTrue(mirror.workspace.value!!.cards.any { it.id == cardId }, "card $cardId in ${mirror.workspace.value!!.cards.map { it.id + ":" + it.scope }}")
        val forked = step("fork", Command(fork_card = ForkCard(card_id = cardId, title = "Forked chat"))).card!!
        mirror.workspace.await(30.seconds, describe = { "forked" }) { slice -> slice?.cards?.any { it.id == forked.id } == true }

        // A clean sync reloads the workspace from scratch, even from a machine
        // with nothing new to send.
        delay(2.seconds)
        step("resync", Command(resync = Resync()))
        mirror.workspace.await(30.seconds, describe = { "resynced: ${mirror.workspace.value?.project_replicas}" }) { slice ->
            slice?.loaded == true && slice.cards.any { it.id == forked.id } && slice.project_replicas[fixture.projectId] == fixture.daemonId
        }
        // Creating right after a clean sync reaches the project's machine.
        val afterResync = step(
            "create after resync",
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(project_id = fixture.projectId, title = "after resync", prompt = "hi", provider = "mock", model = "mock", effort = "low", workspace_mode = "project"),
                    chat = true,
                ),
            ),
        ).card!!
        assertTrue(afterResync.id.isNotEmpty())
        watching.close()
        subscriptions.forEach { it.close() }
    }
}

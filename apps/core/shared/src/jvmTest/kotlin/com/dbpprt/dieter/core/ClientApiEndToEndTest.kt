package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.client.v1.AdoptSession
import com.dbpprt.dieter.client.v1.AgentChoice
import com.dbpprt.dieter.client.v1.ArchiveCard
import com.dbpprt.dieter.client.v1.BoardSlice
import com.dbpprt.dieter.client.v1.ChatsCommand
import com.dbpprt.dieter.client.v1.ChatsQuery
import com.dbpprt.dieter.client.v1.ChatsSlice
import com.dbpprt.dieter.client.v1.ChooseAgent
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.CreateConversation
import com.dbpprt.dieter.client.v1.CreateFolder
import com.dbpprt.dieter.client.v1.CreateTerminal
import com.dbpprt.dieter.client.v1.CreationCatalogState
import com.dbpprt.dieter.client.v1.CreationIntent
import com.dbpprt.dieter.client.v1.CreationPreview
import com.dbpprt.dieter.client.v1.CreationPreviewCommand
import com.dbpprt.dieter.client.v1.CreationSlice
import com.dbpprt.dieter.client.v1.EnsureMetadata
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.FileTreeCommand
import com.dbpprt.dieter.client.v1.FileTreeSlice
import com.dbpprt.dieter.client.v1.FilesCommand
import com.dbpprt.dieter.client.v1.FilesCreate
import com.dbpprt.dieter.client.v1.FilesPath
import com.dbpprt.dieter.client.v1.FilesSlice
import com.dbpprt.dieter.client.v1.FilesTarget
import com.dbpprt.dieter.client.v1.FilesText
import com.dbpprt.dieter.client.v1.FolderScope
import com.dbpprt.dieter.client.v1.ForkCard
import com.dbpprt.dieter.client.v1.GatewayConfig
import com.dbpprt.dieter.client.v1.ListArchivedCards
import com.dbpprt.dieter.client.v1.ListDrafts
import com.dbpprt.dieter.client.v1.MachineEntry
import com.dbpprt.dieter.client.v1.MetadataSlice
import com.dbpprt.dieter.client.v1.MoveCard
import com.dbpprt.dieter.client.v1.MoveProject
import com.dbpprt.dieter.client.v1.MoveToFolder
import com.dbpprt.dieter.client.v1.NavigationCommand
import com.dbpprt.dieter.client.v1.NavigationFolder
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.PinProject
import com.dbpprt.dieter.client.v1.RememberCreation
import com.dbpprt.dieter.client.v1.RenameCard
import com.dbpprt.dieter.client.v1.Resync
import com.dbpprt.dieter.client.v1.RetryFailedTurn
import com.dbpprt.dieter.client.v1.SaveSchedule
import com.dbpprt.dieter.client.v1.ScheduleDraftRequest
import com.dbpprt.dieter.client.v1.ScheduleEnabled
import com.dbpprt.dieter.client.v1.ScheduleId
import com.dbpprt.dieter.client.v1.SchedulePreview
import com.dbpprt.dieter.client.v1.ScheduleProject
import com.dbpprt.dieter.client.v1.SchedulesCommand
import com.dbpprt.dieter.client.v1.SchedulesSlice
import com.dbpprt.dieter.client.v1.SendMessage
import com.dbpprt.dieter.client.v1.SessionSlice
import com.dbpprt.dieter.client.v1.SetDraftText
import com.dbpprt.dieter.client.v1.SetFolders
import com.dbpprt.dieter.client.v1.SetGateways
import com.dbpprt.dieter.client.v1.SetLaneDescending
import com.dbpprt.dieter.client.v1.SetProjectExpanded
import com.dbpprt.dieter.client.v1.SetProjectOrder
import com.dbpprt.dieter.client.v1.SetShowReasoning
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Step
import com.dbpprt.dieter.client.v1.TerminalId
import com.dbpprt.dieter.client.v1.TerminalInput
import com.dbpprt.dieter.client.v1.TerminalOverviewCommand
import com.dbpprt.dieter.client.v1.TerminalOverviewLoad
import com.dbpprt.dieter.client.v1.TerminalOverviewSlice
import com.dbpprt.dieter.client.v1.TerminalRename
import com.dbpprt.dieter.client.v1.TerminalTarget
import com.dbpprt.dieter.client.v1.TerminalsCommand
import com.dbpprt.dieter.client.v1.TerminalsSlice
import com.dbpprt.dieter.client.v1.Toggle
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.UpdateCardDraft
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.IsolatedGateway
import com.dbpprt.dieter.core.testing.SliceFolds
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import okio.ByteString.Companion.encodeUtf8

/**
 * The client contract end to end: a UI that only dispatches commands and
 * applies observed snapshots and deltas signs in, sees the workspace, creates
 * and renames a card, and chats, exactly as the Apple façade does with bytes.
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
            update.workspace_delta?.let { delta -> workspace.value = SliceFolds.apply(checkNotNull(workspace.value), delta) }
            update.conversation?.let { conversation.value = it }
            update.conversation_delta?.let { delta -> conversation.value = SliceFolds.apply(checkNotNull(conversation.value), delta) }
        }
    }

    @Test
    fun aByteOnlyUiSignsInCreatesAndRenames() = e2e {
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
        assertEquals(fixture.daemonId, session.attached_machine_id)
        assertTrue(session.machines.any { it.id == fixture.daemonId && it.online })
        mirror.workspace.await(describe = { "project" }) { slice -> slice?.projects?.any { it.id == fixture.projectId } == true }

        val created = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    intent = CreationIntent(
                        project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "From the client contract",
                        prompt = "hello", workspace_mode = "project",
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
        val fresh = MutableStateFlow<WorkspaceSlice?>(null)
        val snapshot = api.observe(Slice.SLICE_WORKSPACE, "") { update -> if (fresh.value == null) fresh.value = update.workspace }
        assertEquals(mirror.workspace.value, fresh.await { it != null }, "folded deltas equal a fresh snapshot")
        snapshot.close()
        subscriptions.forEach { it.close() }
    }

    /** The contract test's isolated session. Each part below is its own method, so no method grows too large for the JVM. */
    private class Contract(val fixture: IsolatedGateway, val runtime: CoreRuntime, val api: ClientApi) {
        val mirror = Mirror()
        val metadata = MutableStateFlow<MetadataSlice?>(null)
        val board = MutableStateFlow<BoardSlice?>(null)

        suspend fun step(name: String, command: Command) =
            try { api.dispatch(command) } catch (failure: ClientFailure) { throw AssertionError("$name: ${failure.message}", failure) }
    }

    @Test
    fun theMacSessionContractCoversMetadataBoardEditsAndConversationState() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, token = null)
        with(Contract(fixture, runtime, ClientApi(runtime))) {
            val subscriptions = listOf(Slice.SLICE_SESSION, Slice.SLICE_WORKSPACE).map { slice ->
                api.observe(slice, "") { update -> mirror.accept(Update.ADAPTER.decode(update.encode())) }
            } + api.observe(Slice.SLICE_METADATA, "") { metadata.value = Update.ADAPTER.decode(it.encode()).metadata } +
                api.observe(Slice.SLICE_BOARD, "") { board.value = Update.ADAPTER.decode(it.encode()).board }
            val session = connect()
            val loaded = loadMetadata()
            editGateways(session)
            editNavigation()
            browseFiles()
            runTerminals()
            editSchedules(loaded)
            editBoardCards()
            val (cardId, watching) = chat(session)
            val checkoutId = rememberChoices(cardId)
            val forked = createFromIntent(cardId, checkoutId)
            listChats(cardId, forked)
            resync(forked)
            watching.close()
            subscriptions.forEach { it.close() }
        }
    }

    private suspend fun Contract.connect(): SessionSlice {
        api.dispatch(Command(adopt_session = AdoptSession(gateway_url = fixture.url, session_token = fixture.token, name = "Isolated")))
        val session = mirror.session.await(30.seconds, describe = { "live feed: ${mirror.session.value}" }) {
            it?.phase == SessionSlice.Phase.PHASE_CONNECTED && it.workspace_live
        }!!
        val machine = session.machines.single { it.id == fixture.daemonId }
        assertEquals("COMPATIBILITY_STATUS_COMPATIBLE", machine.compatibility)
        assertTrue(machine.last_seen_at.isNotEmpty() || machine.online)
        assertEquals(machine.route == "Local", machine.local, "a loopback plane marks the machine as this device: ${machine.route}")
        assertTrue(session.feed!!.last_applied_at_millis > 0)
        // The core words the connection and the machine rows, in name order.
        assertEquals("Connected", session.phase_label)
        assertEquals(null, session.notice)
        assertEquals(session.machines.sortedWith(compareBy<MachineEntry> { it.name.lowercase() }.thenBy { it.id }), session.machines)
        assertTrue(machine.available && machine.can_share_screen && machine.unavailable_message.isEmpty(), "$machine")
        assertEquals(false, machine.show_last_seen)
        assertTrue(if (machine.route.isEmpty()) machine.detail == "Attached" else machine.detail.startsWith("${machine.route} · "), machine.detail)
        board.await(describe = { "board slice" }) { it != null }
        return session
    }

    private suspend fun Contract.loadMetadata(): MetadataSlice {
        // Metadata loads on request and arrives through its slice.
        step("metadata", Command(ensure_metadata = EnsureMetadata(daemon_id = fixture.daemonId)))
        val loaded = metadata.await(30.seconds, describe = { "metadata: ${metadata.value}" }) { it?.machines?.get(fixture.daemonId)?.loaded == true }!!
        assertTrue(loaded.machines.getValue(fixture.daemonId).harnesses!!.harnesses.any { it.id == "mock" })
        return loaded
    }

    private suspend fun Contract.editGateways(session: SessionSlice) {
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
    }

    private suspend fun Contract.editNavigation() {
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
        assertFalse(NavigationLayout(runtime.navigationKv.values.value).laneDescending(fixture.boardId, "todo"), "the lane sorts ascending")
        assertEquals(listOf(fixture.projectId), laid.expanded_projects)
        assertFailsWith<AssertionError> {
            step("duplicate folder", Command(set_folders = SetFolders(folders = listOf(NavigationFolder(id = "a", name = "Same"), NavigationFolder(id = "b", name = "same")))))
        }
        // Edits made on the layout as shown: the core resolves folders, pins, and available projects.
        fun navigate(edit: NavigationCommand) = Command(navigation = edit)
        step("create folder", navigate(NavigationCommand(create_folder = CreateFolder(scope = FolderScope.FOLDER_SCOPE_CHATS, name = "Research"))))
        val research = navigation.await(30.seconds, describe = { "folder: ${navigation.value}" }) { slice -> slice?.chat_folders?.any { it.name == "Research" } == true }!!
            .chat_folders.single { it.name == "Research" }.id
        step("file chat", navigate(NavigationCommand(move_to_folder = MoveToFolder(scope = FolderScope.FOLDER_SCOPE_CHATS, item_id = "chat-x", folder_id = research))))
        step("pin project", navigate(NavigationCommand(pin_project = PinProject(project_id = fixture.projectId, pinned = true))))
        step("unfile project", navigate(NavigationCommand(move_to_folder = MoveToFolder(scope = FolderScope.FOLDER_SCOPE_PROJECTS, item_id = fixture.projectId))))
        step("move project to the end", navigate(NavigationCommand(move_project = MoveProject(project_id = fixture.projectId))))
        val arranged = navigation.await(30.seconds, describe = { "arranged: ${navigation.value}" }) { slice ->
            slice?.pending == 0 && slice.chat_folders.any { it.id == research && it.item_ids == listOf("chat-x") } &&
                slice.projects?.pinned == listOf(fixture.projectId) && fixture.projectId in slice.projects?.unfiled.orEmpty()
        }!!.projects!!
        assertEquals(fixture.projectId, arranged.order.last())
        assertEquals(emptyList(), arranged.folders.single { it.id == "f_work" }.item_ids)
        assertFailsWith<AssertionError> {
            step("duplicate name", navigate(NavigationCommand(create_folder = CreateFolder(scope = FolderScope.FOLDER_SCOPE_CHATS, name = " research "))))
        }
        navigationWatch.close()
    }

    private suspend fun Contract.browseFiles() {
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
        step("files hidden", files(FilesCommand(show_hidden = Toggle(on = true))))
        filesSlice.await(describe = { "hidden shown" }) { it?.show_hidden == true && it.document_unchanged && it.document == null }
        val tree = MutableStateFlow<FileTreeSlice?>(null)
        val treeWatch = api.observe(Slice.SLICE_FILE_TREE, "tree-test") { tree.value = Update.ADAPTER.decode(it.encode()).file_tree }
        step("tree bind", Command(file_tree = FileTreeCommand(scope = "tree-test", bind = FilesTarget(daemon_id = fixture.daemonId, project_id = fixture.projectId))))
        step("tree load", Command(file_tree = FileTreeCommand(scope = "tree-test", load = FilesPath())))
        tree.await(30.seconds, describe = { "tree: ${tree.value}" }) { slice -> slice?.folders?.any { folder -> folder.path == "" && folder.entries.any { it.name == "core-notes.txt" } } == true }
        assertFailsWith<AssertionError> { step("unknown surface", Command(files = FilesCommand(scope = "missing", load = FilesPath()))) }
        filesWatch.close()
        treeWatch.close()
    }

    private suspend fun Contract.runTerminals() {
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
        step("terminals active", terminals(TerminalsCommand(active = Toggle(on = true))))
        step("terminals load", terminals(TerminalsCommand(load = Step())))
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
        step("overview terminals active", Command(terminals = TerminalsCommand(scope = "overview-test", active = Toggle(on = true))))
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
        val closed = step("terminals reload", terminals(TerminalsCommand(load = Step()))).terminals!!
        assertTrue(closed.terminals.none { it.id == shell.id }, "closed: ${closed.terminals}")
        termsWatch.close()
    }

    private suspend fun Contract.editSchedules(loaded: MetadataSlice) {
        // Schedules: the editor's draft starts with the machine's first agent;
        // a draft is saved on the project's machine, paused, run, and deleted;
        // each command returns its result or the schedules, with their rows.
        val schedules = MutableStateFlow<SchedulesSlice?>(null)
        val schedulesWatch = api.observe(Slice.SLICE_SCHEDULES, "") { schedules.value = Update.ADAPTER.decode(it.encode()).schedules }
        fun schedulesCommand(action: SchedulesCommand) = Command(schedules = action)
        step("schedules bind", schedulesCommand(SchedulesCommand(bind = ScheduleProject(project_id = fixture.projectId))))
        val scheduleList = step("schedules load", schedulesCommand(SchedulesCommand(load = Step()))).schedules!!
        assertTrue(scheduleList.loaded && scheduleList.project_id == fixture.projectId, "listed: $scheduleList")
        assertEquals(if (scheduleList.schedules.isEmpty()) SchedulesSlice.State.STATE_EMPTY else SchedulesSlice.State.STATE_LOADED, scheduleList.state)
        assertEquals("${scheduleList.total_count} automation${if (scheduleList.total_count == 1) "" else "s"}", scheduleList.subtitle)
        assertEquals(scheduleList.schedules.map { it.id }, scheduleList.rows.map { it.id })
        step("schedules preview", schedulesCommand(SchedulesCommand(preview = SchedulePreview(cron = "0 9 * * 1-5", timezone = "Europe/Berlin"))))
        val previewed = schedules.await(30.seconds, describe = { "preview: ${schedules.value}" }) { it?.preview?.size == 5 }!!
        assertTrue(!previewed.preview_loading, "previewed: $previewed")
        val newDraft = step(
            "schedules new draft",
            schedulesCommand(SchedulesCommand(draft = ScheduleDraftRequest(selected_board_id = fixture.boardId, timezone = "Europe/Berlin"))),
        ).schedule_draft!!
        assertEquals(
            listOf(fixture.projectId, fixture.boardId, "0 9 * * 1-5", "Europe/Berlin", "worktree", "draft"),
            listOf(newDraft.project_id, newDraft.board_id, newDraft.cron, newDraft.timezone, newDraft.workspace_mode, newDraft.action),
        )
        assertTrue(newDraft.checkout_id.isNotEmpty(), "new draft: $newDraft")
        assertEquals(loaded.machines.getValue(fixture.daemonId).harnesses!!.harnesses.first().id, newDraft.provider, "a new draft starts with the machine's first agent")
        val scheduleDraft = ScheduleDraft(
            board_id = fixture.boardId, name = "Contract", cron = "0 9 * * 1-5", timezone = "UTC", enabled = true, action = "draft",
            title_template = "Contract · {{date}}", prompt_template = "Summarize {{project}}", provider = "mock", model = "mock", effort = "low",
            open_card_policy = "skip_if_open", workspace_mode = "project",
        )
        val savedSchedule = step("schedules save", schedulesCommand(SchedulesCommand(save = SaveSchedule(draft = scheduleDraft)))).schedule!!
        assertEquals("Contract", savedSchedule.name)
        val paused = step("schedules pause", schedulesCommand(SchedulesCommand(set_enabled = ScheduleEnabled(schedule_id = savedSchedule.id, enabled = false)))).schedule!!
        assertTrue(!paused.enabled)
        val pausedRow = schedules.await(describe = { "paused row: ${schedules.value?.rows}" }) { slice ->
            slice?.rows?.any { it.id == savedSchedule.id && it.status == "Paused" } == true
        }!!.rows.single { it.id == savedSchedule.id }
        assertEquals(listOf("Weekdays at 09:00 · UTC", "Todo"), listOf(pausedRow.timing, pausedRow.placement))
        val mock = loaded.machines.getValue(fixture.daemonId).harnesses!!.harnesses.first { it.id == "mock" }
        assertEquals(mock.name.ifEmpty { "mock" }, pausedRow.provider_label, "the owner's catalog names the agent")
        step("schedules run", schedulesCommand(SchedulesCommand(run_now = ScheduleId(schedule_id = savedSchedule.id))))
        val runRow = schedules.await(30.seconds, describe = { "run row: ${schedules.value?.run_rows}" }) { slice ->
            slice?.selected_id == savedSchedule.id && slice.run_rows.any { it.trigger == "Manual" }
        }!!.run_rows.first { it.trigger == "Manual" }
        assertTrue(runRow.status.isNotEmpty() && runRow.at.isNotEmpty(), "run row: $runRow")
        val editDraft = step("schedules edit draft", schedulesCommand(SchedulesCommand(draft = ScheduleDraftRequest(schedule_id = savedSchedule.id)))).schedule_draft!!
        assertEquals(
            listOf("Contract", "mock", "project", "UTC", "Summarize {{project}}"),
            listOf(editDraft.name, editDraft.provider, editDraft.workspace_mode, editDraft.timezone, editDraft.prompt_template),
        )
        assertTrue(!editDraft.enabled, "the paused schedule opens paused")
        val deleted = step("schedules delete", schedulesCommand(SchedulesCommand(delete = ScheduleId(schedule_id = savedSchedule.id)))).schedules!!
        assertTrue(deleted.schedules.none { it.id == savedSchedule.id }, "deleted: ${deleted.schedules}")
        step("schedules close editor", schedulesCommand(SchedulesCommand(close_editor = Step())))
        schedules.await(describe = { "editor closed: ${schedules.value}" }) { it?.preview?.isEmpty() == true }
        schedulesWatch.close()
        // A second view observes a schedules surface of its own and addresses it by its scope.
        val second = MutableStateFlow<SchedulesSlice?>(null)
        val secondWatch = api.observe(Slice.SLICE_SCHEDULES, "schedules-second") { second.value = Update.ADAPTER.decode(it.encode()).schedules }
        val bound = step("scoped bind", schedulesCommand(SchedulesCommand(scope = "schedules-second", bind = ScheduleProject(project_id = fixture.projectId)))).schedules!!
        assertEquals(fixture.projectId, bound.project_id)
        second.await(describe = { "scoped: ${second.value}" }) { it?.project_id == fixture.projectId }
        assertFailsWith<AssertionError> { step("unobserved scope", schedulesCommand(SchedulesCommand(scope = "nobody", load = Step()))) }
        secondWatch.close()
    }

    private suspend fun Contract.editBoardCards() {
        // A never-started todo card's draft is edited, then archived and listed.
        val todo = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    intent = CreationIntent(
                        project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Draft", prompt = "first draft",
                        selection = HarnessSelection("mock", "mock", "low"), workspace_mode = "project",
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
        // A change with nothing to do succeeds, and a failure reports the command's own error.
        step("unchanged title", Command(rename_card = RenameCard(card_id = todoId, title = "Edited draft")))
        val rejected = assertFailsWith<ClientFailure> { api.dispatch(Command(move_card = MoveCard(card_id = todoId, lane = "no-such-lane"))) }
        assertTrue(rejected.failure.message.isNotEmpty() && rejected.failure.message != "The change was not applied.", rejected.failure.message)
        step("unchanged after a failure", Command(rename_card = RenameCard(card_id = todoId, title = "Edited draft")))
        step("archive", Command(archive_card = ArchiveCard(card_id = todoId)))
        mirror.workspace.await(describe = { "archived" }) { slice -> slice?.cards?.none { it.id == todoId } == true }
        val archived = step("list archived", Command(list_archived_cards = ListArchivedCards(board_id = fixture.boardId))).cards!!.cards
        assertTrue(archived.any { it.id == todoId })
    }

    private suspend fun Contract.chat(session: SessionSlice): Pair<String, ClientSubscription> {
        // A chat reports awaiting its reply, has no failed turn to retry, and forks.
        val chat = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    intent = CreationIntent(project_id = fixture.projectId, title = "chat", prompt = "first", selection = HarnessSelection("mock", "mock", "low"), workspace_mode = "project"),
                    chat = true,
                ),
            ),
        ).card!!
        val watching = api.observe(Slice.SLICE_CONVERSATION, chat.id) { mirror.accept(Update.ADAPTER.decode(it.encode())) }
        fun replies() = mirror.conversation.value?.messages.orEmpty().count { it.role == "assistant" }
        mirror.conversation.await(60.seconds, describe = { "first reply" }) { replies() >= 1 && it?.conversation?.status !in setOf("running", "starting") }
        val cardId = mirror.conversation.value!!.card_id
        // The composer's agent comes from the core; a started chat keeps its provider.
        val agent = mirror.conversation.await(describe = { "agent: ${mirror.conversation.value?.state?.agent}" }) { it?.state?.agent?.selection?.provider == "mock" }!!.state!!.agent!!
        assertTrue(!agent.provider_enabled, "agent: $agent")
        val keeps = assertFailsWith<ClientFailure> { api.dispatch(Command(choose_agent = ChooseAgent(card_id = cardId, choice = AgentChoice(provider = "mock")))) }
        assertEquals(Failure.Kind.KIND_INVALID, keeps.failure.kind)
        assertEquals(null, mirror.conversation.value!!.turn_failure)
        // The slice carries what a conversation header shows: project, board, and window.
        assertEquals(fixture.projectId, mirror.conversation.value!!.project?.id)
        assertTrue((mirror.conversation.value!!.page?.total ?: 0) >= mirror.conversation.value!!.messages.size)
        assertEquals("", step("retry", Command(retry_failed_turn = RetryFailedTurn(card_id = cardId))).message_queued!!.message_id)
        step("send", Command(send_message = SendMessage(card_id = cardId, parts = listOf(MessagePart(type = "text", text = "second")))))
        mirror.conversation.await(60.seconds, describe = { "second reply" }) {
            replies() >= 2 && it?.conversation?.status !in setOf("running", "starting") && it?.state?.working == false
        }
        assertTrue(mirror.conversation.value!!.refreshed_at_millis > 0)
        // The transcript's rows travel beside the messages as keyed deltas, one row per user message.
        val folded = mirror.conversation.value!!
        assertEquals(folded.messages.filter { it.role == "user" }.map { "message:${it.id}" }, folded.timeline.filter { it.user }.map { it.id })
        assertTrue(folded.state!!.chat)
        // Reasoning traces are this device's preference; the conversation regroups for it.
        step("show reasoning", Command(set_show_reasoning = SetShowReasoning(show = true)))
        mirror.conversation.await(describe = { "reasoning shown" }) { it?.state?.show_reasoning == true }
        mirror.session.await(describe = { "the session shows reasoning" }) { it?.show_reasoning == true }
        assertTrue(runtime.conversations.showReasoning.value)
        assertEquals("true", runtime.platform.settings.string("conversations.show_reasoning"), "kept with this device's settings")
        step("hide reasoning", Command(set_show_reasoning = SetShowReasoning(show = false)))
        mirror.conversation.await(describe = { "reasoning hidden" }) { it?.state?.show_reasoning == false }
        mirror.session.await(describe = { "the session hides reasoning" }) { it?.show_reasoning == false }
        return cardId to watching
    }

    private suspend fun Contract.rememberChoices(cardId: String): String {
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
                    selection = HarnessSelection("mock", "mock", "low"), project_id = fixture.projectId, board_id = fixture.boardId,
                ),
            ),
        )
        creation.await(describe = { "creation: ${creation.value}" }) {
            it?.project_id == fixture.projectId && it.boards[fixture.projectId] == fixture.boardId && it.workspace_mode == "project"
        }
        // The checkout a new conversation runs on is the attached machine's.
        val checkoutId = creation.await(describe = { "checkouts: ${creation.value}" }) { it?.checkouts?.get(fixture.projectId)?.isNotEmpty() == true }!!.checkouts.getValue(fixture.projectId)
        assertEquals(fixture.daemonId, mirror.workspace.value!!.projects.single { it.id == fixture.projectId }.checkouts.single { it.id == checkoutId }.daemon_id)
        creationWatch.close()
        return checkoutId
    }

    private suspend fun Contract.createFromIntent(cardId: String, checkoutId: String): Card {
        // A creation form previews its intent with the core's defaults through its surface, then queues it.
        val previews = MutableStateFlow<CreationPreview?>(null)
        val previewWatch = api.observe(Slice.SLICE_CREATION_PREVIEW, "form-test") { previews.value = Update.ADAPTER.decode(it.encode()).creation_preview }
        fun form(intent: CreationIntent, choice: AgentChoice? = null) = Command(creation_preview = CreationPreviewCommand(scope = "form-test", intent = intent, choice = choice))
        val preview = step("preview creation", form(CreationIntent(project_id = fixture.projectId, prompt = "From an intent"))).creation_preview!!
        assertEquals(preview, previews.await(describe = { "previewed: ${previews.value}" }) { it == preview })
        assertEquals("", preview.problem, "preview: $preview")
        assertEquals(CreationCatalogState.CREATION_CATALOG_STATE_LIVE, preview.catalog)
        val intent = preview.intent!!
        assertEquals(listOf(fixture.boardId, checkoutId, "mock", "project"), listOf(intent.board_id, intent.checkout_id, intent.selection?.provider, intent.workspace_mode))
        assertTrue(preview.defers_start && preview.daemon_id == fixture.daemonId, "preview: $preview")
        assertTrue(preview.agent!!.providers.any { it.id == "mock" } && preview.agent!!.provider_enabled, "agent: ${preview.agent}")
        val chosen = step("choose agent", form(CreationIntent(project_id = fixture.projectId, prompt = "From an intent"), AgentChoice(provider = "mock"))).creation_preview!!
        assertEquals("mock", chosen.intent!!.selection!!.provider, "the choice applies to the bound intent")
        previewWatch.close()
        step("create from intent", Command(create_conversation = CreateConversation(intent = intent)))
        mirror.workspace.await(30.seconds, describe = { "intent card" }) { slice -> slice?.cards?.any { it.initial_prompt == "From an intent" && it.board_id == fixture.boardId } == true }
        val incomplete = assertFailsWith<ClientFailure> { api.dispatch(Command(create_conversation = CreateConversation(intent = CreationIntent(project_id = fixture.projectId)))) }
        assertEquals("Describe the task.", incomplete.failure.message)
        assertTrue(mirror.workspace.value!!.cards.any { it.id == cardId }, "card $cardId in ${mirror.workspace.value!!.cards.map { it.id + ":" + it.scope }}")
        val forked = step("fork", Command(fork_card = ForkCard(card_id = cardId))).card!!
        mirror.workspace.await(30.seconds, describe = { "forked" }) { slice -> slice?.cards?.any { it.id == forked.id } == true }
        return forked
    }

    private suspend fun Contract.listChats(cardId: String, forked: Card) {
        // The chats list shows live chats in their project's section, searches in place, and loads archived chats.
        val chats = MutableStateFlow<ChatsSlice?>(null)
        val chatsWatch = api.observe(Slice.SLICE_CHATS, "chats-test") { chats.value = Update.ADAPTER.decode(it.encode()).chats }
        chats.await(30.seconds, describe = { "chats: ${chats.value}" }) { slice ->
            slice != null && slice.projects.any { it.project_id == fixture.projectId && forked.id in it.chat_ids } && forked.id in slice.visible_ids
        }
        step("search chats", Command(chats = ChatsCommand(scope = "chats-test", query = ChatsQuery(text = "fork of"))))
        chats.await(describe = { "searched: ${chats.value}" }) { it != null && forked.id in it.visible_ids && cardId !in it.visible_ids }
        step("archived chats", Command(chats = ChatsCommand(scope = "chats-test", show_archived = Toggle(on = true))))
        chats.await(30.seconds, describe = { "archived: ${chats.value}" }) { it != null && !it.loading && it.error.isEmpty() && forked.id !in it.visible_ids }
        chatsWatch.close()
    }

    private suspend fun Contract.resync(forked: Card) {
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
                    intent = CreationIntent(project_id = fixture.projectId, title = "after resync", prompt = "hi", selection = HarnessSelection("mock", "mock", "low"), workspace_mode = "project"),
                    chat = true,
                ),
            ),
        ).card!!
        assertTrue(afterResync.id.isNotEmpty())
    }
}

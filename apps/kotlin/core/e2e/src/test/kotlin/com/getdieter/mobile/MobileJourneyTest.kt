package com.getdieter.mobile

import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientApi
import com.getdieter.core.composition.Attachments
import com.getdieter.core.testing.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.*
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.*

class MobileJourneyTest : EndToEnd() {
    @AfterTest fun cleanup() = tearDownRuntimes()

    @Test
    fun overviewTerminalStreamsWhileTheConversationSurfaceIsAlsoObserved() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val uiDispatcher = coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
        val store = MobileStore(RuntimeMobileCore(ClientApi(runtime)), uiDispatcher)
        try {
            store.push(MobileRoute.Tool(ToolPage.TERMINALS))
            store.session.slice.await {
                it.machines.any { machine -> machine.id == fixture.daemonId }
            }
            val created =
                store.core
                    .dispatch(
                        Command(
                            terminal_overview =
                                TerminalOverviewCommand(
                                    scope = MobileStore.TERMINAL_OVERVIEW_SCOPE,
                                    create =
                                        CreateOverviewTerminal(
                                            daemon_id = fixture.daemonId,
                                            name = "mobile",
                                            shell = "sh",
                                            machine_home = true,
                                        ),
                                )
                        )
                    )
                    .terminal_overview!!
            val id = created.selected_id
            val shell = created.entries.first { it.id == id }.terminal!!
            assertEquals("", shell.project_id, "machine-home shells need no project")
            assertEquals("", shell.card_id)
            assertTrue(shell.working_directory.isNotEmpty())
            store.push(MobileRoute.TerminalSession(id, ""))
            store.terminals.command(TerminalsCommand(active = Toggle(true)))
            store.terminals.acceptsInput.await(
                10.seconds,
                describe = {
                    "overview: ${store.terminals.overview.value}; error: ${store.error.value}"
                },
            ) {
                it
            }
            store.terminals.input(
                "echo mobile-$((6*7)); test \"\$PWD\" -ef \"\$HOME\" && echo at-machine-home\n"
                    .encodeToByteArray()
            )
            store.terminals.screens.await(
                15.seconds,
                describe = {
                    "machine-home output: ${store.terminals.screens.value[id]?.accessibilityText()}"
                },
            ) {
                val output = it[id]?.accessibilityText().orEmpty()
                output.contains("mobile-42") &&
                    output.lineSequence().any { it.trim() == "at-machine-home" }
            }

            // Leaving the surface stops observation, while the daemon-owned shell survives.
            store.terminals.command(TerminalsCommand(active = Toggle(false)))
            store.terminals.acceptsInput.await(10.seconds) { !it }
            store.pop()
            store.push(MobileRoute.TerminalSession(id, ""))
            store.terminals.command(TerminalsCommand(active = Toggle(true)))
            // An idle resumed watch acknowledges the cursor on its 15-second heartbeat.
            store.terminals.acceptsInput.await(20.seconds) { it }
            store.terminals.input("echo resumed-$((1+1))\n".encodeToByteArray())
            val output =
                store.terminals.screens
                    .await(15.seconds) {
                        it[id]?.accessibilityText()?.contains("resumed-2") == true
                    }
                    .getValue(id)
                    .accessibilityText()
            assertEquals(1, output.split("mobile-42").size - 1, "output is not replayed twice")
            store.terminals.command(TerminalsCommand(close = TerminalId(shell.id)))
            store.terminals.overview.await { it.entries.none { entry -> entry.id == id } }
            assertTrue(store.error.value.isEmpty(), store.error.value)
        } finally {
            store.close()
        }
    }

    @Test
    fun conversationTerminalLoadsExistingShellsAndRoutesTheirInput() = e2e {
        val fixture = fixture(seeded = true)
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val uiDispatcher = coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
        val store = MobileStore(RuntimeMobileCore(ClientApi(runtime)), uiDispatcher)
        try {
            val card =
                store.workspace.slice
                    .await { it.cards.isNotEmpty() }
                    .cards
                    .first { it.project_id == fixture.projectId }
            val shell =
                runtime.onMachine(fixture.daemonId) {
                    it.CreateTerminal()
                        .execute(
                            com.getdieter.api.v1.CreateTerminalRequest(
                                project_id = fixture.projectId,
                                card_id = card.id,
                                name = "conversation",
                                shell = "sh",
                                columns = 80,
                                rows = 24,
                            )
                        )
                }
            store.openConversation(card.id)
            store.conversation.slice.await { it.daemon_id == fixture.daemonId }
            store.push(MobileRoute.Pane(card.id, CardPane.TERMINAL))
            store.terminals.card.await(10.seconds) {
                it.terminals.any { terminal -> terminal.id == shell.id }
            }
            store.push(MobileRoute.TerminalSession(shell.id, card.id))
            store.terminals.command(TerminalsCommand(active = Toggle(true)))
            store.terminals.acceptsInput.await(10.seconds) { it }
            store.terminals.input("echo conversation-$((3*7))\n".encodeToByteArray())
            store.terminals.screens.await(15.seconds) {
                it[shell.id]?.accessibilityText()?.contains("conversation-21") == true
            }
            store.terminals.grid(90, 25)
            store.terminals.card.await(10.seconds) {
                it.terminals.any { terminal ->
                    terminal.id == shell.id && terminal.columns == 90 && terminal.rows == 25
                }
            }
            store.terminals.command(TerminalsCommand(rename = TerminalRename(shell.id, "renamed")))
            store.terminals.card.await(10.seconds) {
                it.terminals.any { terminal ->
                    terminal.id == shell.id && terminal.name == "renamed"
                }
            }
            store.terminals.command(TerminalsCommand(close = TerminalId(shell.id)))
            store.terminals.card.await(10.seconds) {
                it.terminals.none { terminal -> terminal.id == shell.id }
            }
            assertTrue(store.error.value.isEmpty(), store.error.value)
        } finally {
            store.close()
        }
    }

    @Test
    fun anUnavailableAgentCanBeReplacedAfterARejectedPickerChoice() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val uiDispatcher = coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
        val store = MobileStore(RuntimeMobileCore(ClientApi(runtime)), uiDispatcher)
        try {
            // A remembered agent reaches a machine where it is not installed.
            val unavailable = "not-installed-agent"
            val intent =
                CreationIntent(
                    project_id = fixture.projectId,
                    prompt = "Repair the picker",
                    selection = com.getdieter.api.v1.HarnessSelection(unavailable, "opus"),
                )
            store.creation.update(intent)
            store.creation.preview.await(15.seconds) {
                it.catalog == CreationCatalogState.CREATION_CATALOG_STATE_LIVE
            }
            assertTrue(store.creation.preview.value.agent!!.providers.none { it.id == unavailable })
            // An old menu's tap is rejected, then the current catalog can still be used.
            store.creation.update(intent, AgentChoice(provider = unavailable))
            store.error.await { it.contains("not available") }
            store.creation.update(store.creation.intent.value, AgentChoice(provider = "codex"))
            store.creation.preview.await {
                it.intent?.selection?.provider == "codex" && it.problem.isEmpty()
            }
            val alternate =
                store.creation.preview.value.agent!!
                    .models
                    .first {
                        it.id != store.creation.intent.value.selection?.model
                    }
                    .id
            store.creation.update(store.creation.intent.value, AgentChoice(model = alternate))
            store.creation.intent.await { it.selection?.model == alternate }
        } finally {
            store.close()
        }
    }

    @Test
    fun sharedTaskJourneySurvivesFollowUpAndSyncsToAnotherClient() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        val otherRuntime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        otherRuntime.awaitConnected()
        otherRuntime.awaitLoaded(fixture)
        val uiDispatcher = coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
        val first = MobileStore(RuntimeMobileCore(ClientApi(runtime)), uiDispatcher)
        val second = MobileStore(RuntimeMobileCore(ClientApi(otherRuntime)), uiDispatcher)
        try {
            first.workspace.slice.await { it.boards.any { board -> board.id == fixture.boardId } }
            first.boards.chooseBoard(fixture.boardId)
            first.boards.slice.await { it.lanes.isNotEmpty() }
            first.creation.agentSelection =
                com.getdieter.api.v1.HarnessSelection("mock", "mock", "low")
            val localId =
                first.creation.create(
                    "Shared mobile task",
                    "Explain this durable conversation",
                    run = true,
                )
            first.openConversation(localId)
            val cardId =
                first.workspace.outbox
                    .await { localId in it.resolutions }
                    .resolutions
                    .getValue(localId)
            runtime.awaitSynced(cardId)
            val completed =
                first.conversation.slice.await(
                    60.seconds,
                    describe = {
                        "reply for $cardId: selected=${first.conversation.selectedCard.value}, card=${first.conversation.slice.value.card?.provider}, failure=${first.conversation.slice.value.turn_failure}, messages=${first.conversation.slice.value.messages}"
                    },
                ) {
                    it.messages.any { message ->
                        message.role == "assistant" &&
                            message.parts.any { part ->
                                part.text.startsWith("Mock harness received:")
                            }
                    } && it.state?.working == false
                }
            assertNull(completed.turn_failure)
            assertEquals("Shared mobile task", first.conversation.slice.value.card?.title)
            first.conversation.send("Continue in the same task")
            first.conversation.slice.await(60.seconds) {
                it.messages.any { message ->
                    message.role == "assistant" &&
                        message.parts.any { part ->
                            part.text.contains("Mock harness received: Continue in the same task")
                        }
                } && it.state?.working == false
            }
            assertEquals(cardId, first.conversation.slice.value.card_id)
            first.conversation.move("review")
            second.workspace.slice.await {
                it.cards.any { card -> card.id == cardId && card.lane == "review" }
            }
            first.pop()
            assertTrue(first.conversation.selectedCard.value.isEmpty())
            first.openConversation(cardId)
            first.conversation.slice.await {
                it.messages.any { message ->
                    message.parts.any { part -> part.text.contains("Continue in the same task") }
                }
            }
            first.push(MobileRoute.Tool(ToolPage.FILES, fixture.projectId))
            first.files.slice.await { it.entries.any { entry -> entry.name == "README.md" } }
            first.core.dispatch(
                Command(
                    files =
                        FilesCommand(
                            scope = MobileStore.FILES_SCOPE,
                            open_ = FilesPath("README.md"),
                        )
                )
            )
            first.files.slice.await { it.document?.content?.contains("# Isolated E2E") == true }
            first.push(MobileRoute.Tool(ToolPage.SCHEDULES, fixture.projectId))
            first.schedules.slice.await { it.loaded }
            assertTrue(first.schedules.slice.value.error.isEmpty())
            val selectionBeforeRefresh = first.conversation.selectedCard.value
            first.session.refresh()
            assertTrue(first.session.refreshing.value)
            first.session.refreshing.await { !it }
            assertTrue(first.session.slice.value.synced)
            assertTrue(first.workspace.slice.value.cards.any { it.id == cardId })
            assertEquals(selectionBeforeRefresh, first.conversation.selectedCard.value)
            assertTrue(first.error.value.isEmpty(), first.error.value)
        } finally {
            first.close()
            second.close()
        }
    }

    @Test
    fun refreshingKeepsTheListAndWaitsForReplayWithoutDuplicatingRequests() = runBlocking {
        val sent = mutableListOf<Command>()
        lateinit var publish: (Update) -> Unit
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    sent += command
                    return Result(done = Done())
                }

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.getdieter.core.client.ClientSubscription {
                    if (slice == Slice.SLICE_SESSION) publish = receive
                    return com.getdieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            publish(
                Update(
                    session =
                        SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTED, synced = true)
                )
            )
            val cached =
                WorkspaceSlice(
                    loaded = true,
                    cards = listOf(com.getdieter.api.v1.Card(id = "cached")),
                )
            store.workspace.slice.value = cached
            store.session.refresh()
            store.session.refresh()
            assertEquals(1, sent.count { it.resync != null })
            assertTrue(
                store.session.refreshing.value,
                "Admitting the command is not the end of the replay",
            )
            assertEquals(cached, store.workspace.slice.value)
            publish(Update(session = SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTING)))
            assertTrue(store.session.refreshing.value)
            publish(
                Update(
                    session =
                        SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTED, synced = true)
                )
            )
            assertFalse(store.session.refreshing.value)
            assertEquals(MobileStore.CHATS_SCOPE, sent.single { it.chats != null }.chats?.scope)
            assertNotNull(sent.single { it.chats != null }.chats?.reload)
            assertEquals(cached, store.workspace.slice.value)
            // Pulling while a previous connection is catching up still settles when it is live.
            publish(Update(session = SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTING)))
            store.session.refresh()
            assertTrue(store.session.refreshing.value)
            publish(
                Update(
                    session =
                        SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTED, synced = true)
                )
            )
            assertFalse(store.session.refreshing.value)
            assertEquals(2, sent.count { it.resync != null })
        } finally {
            store.close()
        }
    }

    @Test
    fun aRejectedRefreshStopsItsIndicatorAndCanBeRetried() = runBlocking {
        var attempts = 0
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    if (command.resync != null) {
                        attempts++
                        error("Unable to sync")
                    }
                    return Result(done = Done())
                }

                override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                    com.getdieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.session.refresh()
            assertFalse(store.session.refreshing.value)
            assertEquals("Unable to sync", store.error.value)
            store.session.refresh()
            assertEquals(2, attempts)
        } finally {
            store.close()
        }
    }

    @Test
    fun queuedActionsKeepTheTaskSelectedWhenTheyWereRequested() = runBlocking {
        val sent = mutableListOf<Command>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    sent += command
                    return Result(done = Done())
                }

                override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                    com.getdieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.openConversation("first")
            val release = CompletableDeferred<Unit>()
            store.action { release.await() }
            store.conversation.move("review")
            store.conversation.stop()
            store.conversation.start()
            store.conversation.loadEarlier()
            store.openConversation("second")
            release.complete(Unit)
            yield()
            assertEquals("first", sent.single { it.move_card != null }.move_card?.card_id)
            assertEquals("first", sent.single { it.cancel_card != null }.cancel_card?.card_id)
            assertEquals("first", sent.single { it.start_card != null }.start_card?.card_id)
            assertEquals(
                "first",
                sent.single { it.load_earlier_messages != null }.load_earlier_messages?.card_id,
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun switchingConversationsRejectsLateUpdatesFromClosedScopes() = runBlocking {
        val callbacks = mutableMapOf<String, (Update) -> Unit>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command) = Result(done = Done())

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.getdieter.core.client.ClientSubscription {
                    callbacks[scope] = receive
                    return com.getdieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        store.openConversation("first")
        val old = callbacks.getValue("first")
        store.openConversation("second")
        callbacks.getValue("second")(Update(conversation = ConversationSlice(card_id = "second")))
        old(Update(conversation = ConversationSlice(card_id = "first")))
        assertEquals("second", store.conversation.slice.value.card_id)
        store.close()
        callbacks.getValue("second")(Update(conversation = ConversationSlice(card_id = "late")))
        assertEquals("second", store.conversation.slice.value.card_id)
    }

    @Test
    fun terminalDeltasSurviveConflatedUiSnapshots() = runBlocking {
        val observers = mutableMapOf<Slice, (Update) -> Unit>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command) = Result(done = Done())

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.getdieter.core.client.ClientSubscription {
                    observers[slice] = receive
                    return com.getdieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            val entry =
                OverviewTerminal(
                    id = "machine|shell",
                    terminal = com.getdieter.api.v1.Terminal(id = "shell"),
                )
            val publish = observers.getValue(Slice.SLICE_TERMINAL_OVERVIEW)
            for ((index, text) in listOf("first", " second", " third").withIndex()) {
                publish(
                    Update(
                        terminal_overview =
                            TerminalOverviewSlice(
                                entries = listOf(entry),
                                selected_id = entry.id,
                                terminals =
                                    TerminalsSlice(
                                        output =
                                            listOf(
                                                TerminalOutput(
                                                    "shell",
                                                    index == 0,
                                                    okio.ByteString.of(*text.encodeToByteArray()),
                                                )
                                            )
                                    ),
                            )
                    )
                )
            }
            assertEquals(
                "first second third",
                store.terminals.screens.value.getValue(entry.id).accessibilityText(),
            )
            publish(
                Update(
                    terminal_overview =
                        TerminalOverviewSlice(
                            entries = listOf(entry),
                            selected_id = entry.id,
                            terminals =
                                TerminalsSlice(
                                    output =
                                        listOf(
                                            TerminalOutput(
                                                "shell",
                                                true,
                                                okio.ByteString.of(*"reset".encodeToByteArray()),
                                            )
                                        )
                                ),
                        )
                )
            )
            assertEquals(
                "reset",
                store.terminals.screens.value.getValue(entry.id).accessibilityText(),
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun cancelledPreviewCannotReplaceNewerInput() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    val request = command.creation_preview ?: return Result(done = Done())
                    if (request.intent?.prompt == "first") {
                        started.complete(Unit)
                        withContext(NonCancellable) { release.await() }
                    }
                    return Result(creation_preview = CreationPreview(intent = request.intent))
                }

                override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                    com.getdieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.creation.update(CreationIntent(prompt = "first"))
            withTimeout(5000) { started.await() }
            store.creation.update(CreationIntent(prompt = "second"))
            withTimeout(5000) { store.creation.preview.await { it.intent?.prompt == "second" } }
            release.complete(Unit)
            yield()
            assertEquals("second", store.creation.intent.value.prompt)
            assertEquals("second", store.creation.preview.value.intent?.prompt)
        } finally {
            release.complete(Unit)
            store.close()
        }
    }

    @Test
    fun backgroundFlushPersistsDraftBeforeDebounce() = runBlocking {
        val sent = mutableListOf<Command>()
        val callbacks = mutableMapOf<String, (Update) -> Unit>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    sent += command
                    return Result(done = Done())
                }

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.getdieter.core.client.ClientSubscription {
                    callbacks[scope] = receive
                    return com.getdieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.openConversation("card")
            callbacks.getValue("card")(
                Update(conversation = ConversationSlice(card_id = "card", daemon_id = "owner"))
            )
            store.conversation.saveDraft("card", "Keep this draft")
            store.conversation.flushDrafts()
            assertEquals(
                SetDraftText("owner", "card", "Keep this draft"),
                sent.single { it.set_draft_text != null }.set_draft_text,
            )
            store.files.syncBuffer("file", "original")
            store.files.editBuffer("file", "original", "my edits")
            store.files.syncBuffer("file", "external change")
            assertEquals(
                MobileFileBuffer("original", "my edits"),
                store.files.buffers.value["file"],
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun sharesWaitForTheWorkspaceAndOpenTheirDestinationOnce() = runBlocking {
        val observers = mutableMapOf<Slice, (Update) -> Unit>()
        val fake =
            object : MobileCore {
                // Like the core, previews return the intent without its attachments, here
                // before the machine's agent models have loaded.
                override suspend fun dispatch(command: Command) =
                    command.creation_preview?.let {
                        Result(
                            creation_preview =
                                CreationPreview(
                                    problem = "Loading agent models…",
                                    intent = it.intent?.copy(attachments = emptyList()),
                                )
                        )
                    } ?: Result(done = Done())

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.getdieter.core.client.ClientSubscription {
                    observers[slice] = receive
                    return com.getdieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            val screenshot =
                com.getdieter.api.v1.MessagePart(
                    type = "file",
                    filename = "layout.png",
                    media_type = "image/png",
                    data_ = okio.ByteString.of(1, 2, 3),
                )
            store.sharing.receive(
                SharedItems("Tighten the layout", listOf(screenshot), ShareDestination.NEW_TASK)
            )
            assertNull(store.routes.value.modal)
            observers.getValue(Slice.SLICE_WORKSPACE)(
                Update(workspace = WorkspaceSlice(loaded = true))
            )
            assertEquals(MobileRoute.NewTask(false), store.routes.value.modal)
            store.creation.preview.await { it.intent?.prompt == "Tighten the layout" }
            // Once the models load, the core's own preview of the form clears the problem.
            observers.getValue(Slice.SLICE_CREATION_PREVIEW)(
                Update(
                    creation_preview =
                        CreationPreview(intent = CreationIntent(prompt = "Tighten the layout"))
                )
            )
            assertEquals("", store.creation.preview.value.problem)
            assertEquals("Tighten the layout", store.creation.intent.value.prompt)
            assertEquals(listOf(screenshot), store.creation.intent.value.attachments)
            // Later workspace updates do not reopen a delivered share.
            store.dismiss()
            observers.getValue(Slice.SLICE_WORKSPACE)(
                Update(workspace = WorkspaceSlice(loaded = true))
            )
            assertNull(store.routes.value.modal)

            store.sharing.receive(
                SharedItems("Look at this", listOf(screenshot), ShareDestination.CHAT)
            )
            assertEquals(MobileRoute.ShareTarget(chat = true), store.routes.value.modal)
            store.sharing.shareInto("chat")
            assertNull(store.routes.value.modal)
            assertEquals("chat", store.conversation.selectedCard.value)
            val delivered = assertNotNull(store.sharing.takeComposerShare("chat"))
            assertEquals("Look at this", delivered.text)
            assertEquals(listOf(screenshot), delivered.attachments)
            assertNull(store.sharing.takeComposerShare("chat"))

            // Too many files are reported and none are attached.
            store.sharing.receive(
                SharedItems(
                    "",
                    List(Attachments.MAX_COUNT + 1) { screenshot },
                    ShareDestination.TASK,
                )
            )
            assertEquals(Attachments.TOO_MANY, store.error.value)
            assertEquals(MobileRoute.ShareTarget(chat = false), store.routes.value.modal)
            store.sharing.cancel()
            assertNull(store.routes.value.modal)
            assertTrue(store.sharing.composerShares.value.isEmpty())
        } finally {
            store.close()
        }
    }

    @Test
    fun navigationStacksBindTheVisibleRoutes() = runBlocking {
        val sent = mutableListOf<Command>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    sent += command
                    return Result(done = Done())
                }

                override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                    com.getdieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.selectTab(MobileTab.PROJECTS)
            store.push(MobileRoute.Board("board"))
            assertEquals("board", store.boards.selectedBoard.value)
            store.openConversation("card")
            assertEquals("card", store.conversation.selectedCard.value)
            store.push(MobileRoute.Pane("card", CardPane.CHANGES))
            assertEquals("Changes", store.conversation.detailTab.value)
            assertEquals("card", store.conversation.selectedCard.value)
            // A native back gesture reports the remaining depth.
            store.popTo(MobileTab.PROJECTS, 3)
            assertEquals("Conversation", store.conversation.detailTab.value)
            // Opening another card from the list replaces the open conversation.
            store.openConversation("other")
            assertEquals(3, store.routes.value.stack.size)
            assertEquals("other", store.conversation.selectedCard.value)
            // Other tabs keep their own stacks.
            store.selectTab(MobileTab.INBOX)
            assertTrue(store.conversation.selectedCard.value.isEmpty())
            store.selectTab(MobileTab.PROJECTS)
            assertEquals("other", store.conversation.selectedCard.value)
            // Selecting the current tab again returns to its root.
            store.selectTab(MobileTab.PROJECTS)
            assertEquals(1, store.routes.value.stack.size)
            assertTrue(store.conversation.selectedCard.value.isEmpty())
            store.newConversation(chat = true)
            assertEquals(MobileRoute.NewTask(true), store.routes.value.modal)
            assertTrue(store.handleBack())
            assertNull(store.routes.value.modal)
        } finally {
            store.close()
        }
    }
}

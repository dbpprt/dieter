package com.dbpprt.dieter.mobile

import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.testing.*
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.*
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.*

class MobileJourneyTest : EndToEnd() {
    @AfterTest fun cleanup() = tearDownRuntimes()

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
            first.workspace.await { it.boards.any { board -> board.id == fixture.boardId } }
            first.chooseBoard(fixture.boardId)
            first.board.await { it.lanes.isNotEmpty() }
            first.agentSelection = com.dbpprt.dieter.api.v1.HarnessSelection("mock", "mock", "low")
            val localId =
                first.create("Shared mobile task", "Explain this durable conversation", run = true)
            first.openConversation(localId)
            val cardId =
                first.outbox.await { localId in it.resolutions }.resolutions.getValue(localId)
            runtime.awaitSynced(cardId)
            val completed =
                first.conversation.await(
                    60.seconds,
                    describe = {
                        "reply for $cardId: selected=${first.selectedCard.value}, card=${first.conversation.value.card?.provider}, failure=${first.conversation.value.turn_failure}, messages=${first.conversation.value.messages}"
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
            assertEquals("Shared mobile task", first.conversation.value.card?.title)
            first.send("Continue in the same task")
            first.conversation.await(60.seconds) {
                it.messages.any { message ->
                    message.role == "assistant" &&
                        message.parts.any { part ->
                            part.text.contains("Mock harness received: Continue in the same task")
                        }
                } && it.state?.working == false
            }
            assertEquals(cardId, first.conversation.value.card_id)
            first.move("review")
            second.workspace.await {
                it.cards.any { card -> card.id == cardId && card.lane == "review" }
            }
            first.pop()
            assertTrue(first.selectedCard.value.isEmpty())
            first.openConversation(cardId)
            first.conversation.await {
                it.messages.any { message ->
                    message.parts.any { part -> part.text.contains("Continue in the same task") }
                }
            }
            first.push(MobileRoute.Tool(ToolPage.FILES))
            first.files.await { it.entries.any { entry -> entry.name == "README.md" } }
            first.core.dispatch(
                Command(
                    files =
                        FilesCommand(
                            scope = MobileStore.FILES_SCOPE,
                            open_ = FilesPath("README.md"),
                        )
                )
            )
            first.files.await { it.document?.content?.contains("# Isolated E2E") == true }
            first.push(MobileRoute.Tool(ToolPage.SCHEDULES))
            first.schedules.await { it.loaded }
            assertTrue(first.schedules.value.error.isEmpty())
        } finally {
            first.close()
            second.close()
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
                    com.dbpprt.dieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.openConversation("first")
            val release = CompletableDeferred<Unit>()
            store.action { release.await() }
            store.move("review")
            store.stop()
            store.start()
            store.loadEarlier()
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
                ): com.dbpprt.dieter.core.client.ClientSubscription {
                    callbacks[scope] = receive
                    return com.dbpprt.dieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        store.openConversation("first")
        val old = callbacks.getValue("first")
        store.openConversation("second")
        callbacks.getValue("second")(Update(conversation = ConversationSlice(card_id = "second")))
        old(Update(conversation = ConversationSlice(card_id = "first")))
        assertEquals("second", store.conversation.value.card_id)
        store.close()
        callbacks.getValue("second")(Update(conversation = ConversationSlice(card_id = "late")))
        assertEquals("second", store.conversation.value.card_id)
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
                ): com.dbpprt.dieter.core.client.ClientSubscription {
                    observers[slice] = receive
                    return com.dbpprt.dieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            val entry =
                OverviewTerminal(
                    id = "machine|shell",
                    terminal = com.dbpprt.dieter.api.v1.Terminal(id = "shell"),
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
                store.terminalScreens.value.getValue(entry.id).accessibilityText(),
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
                store.terminalScreens.value.getValue(entry.id).accessibilityText(),
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
                    com.dbpprt.dieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.preview(CreationIntent(prompt = "first"))
            withTimeout(5000) { started.await() }
            store.preview(CreationIntent(prompt = "second"))
            withTimeout(5000) { store.creationPreview.await { it.intent?.prompt == "second" } }
            release.complete(Unit)
            yield()
            assertEquals("second", store.creationIntent.value.prompt)
            assertEquals("second", store.creationPreview.value.intent?.prompt)
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
                ): com.dbpprt.dieter.core.client.ClientSubscription {
                    callbacks[scope] = receive
                    return com.dbpprt.dieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.openConversation("card")
            callbacks.getValue("card")(
                Update(conversation = ConversationSlice(card_id = "card", daemon_id = "owner"))
            )
            store.saveDraft("card", "Keep this draft")
            store.flushDrafts()
            assertEquals(
                SetDraftText("owner", "card", "Keep this draft"),
                sent.single { it.set_draft_text != null }.set_draft_text,
            )
            store.syncFileBuffer("file", "original")
            store.editFileBuffer("file", "original", "my edits")
            store.syncFileBuffer("file", "external change")
            assertEquals(MobileFileBuffer("original", "my edits"), store.fileBuffers.value["file"])
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
                ): com.dbpprt.dieter.core.client.ClientSubscription {
                    observers[slice] = receive
                    return com.dbpprt.dieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            val screenshot =
                com.dbpprt.dieter.api.v1.MessagePart(
                    type = "file",
                    filename = "layout.png",
                    media_type = "image/png",
                    data_ = okio.ByteString.of(1, 2, 3),
                )
            store.share(
                SharedItems("Tighten the layout", listOf(screenshot), ShareDestination.NEW_TASK)
            )
            assertNull(store.routes.value.modal)
            observers.getValue(Slice.SLICE_WORKSPACE)(
                Update(workspace = WorkspaceSlice(loaded = true))
            )
            assertEquals(MobileRoute.NewTask(false), store.routes.value.modal)
            store.creationPreview.await { it.intent?.prompt == "Tighten the layout" }
            // Once the models load, the core's own preview of the form clears the problem.
            observers.getValue(Slice.SLICE_CREATION_PREVIEW)(
                Update(
                    creation_preview =
                        CreationPreview(intent = CreationIntent(prompt = "Tighten the layout"))
                )
            )
            assertEquals("", store.creationPreview.value.problem)
            assertEquals("Tighten the layout", store.creationIntent.value.prompt)
            assertEquals(listOf(screenshot), store.creationIntent.value.attachments)
            // Later workspace updates do not reopen a delivered share.
            store.dismiss()
            observers.getValue(Slice.SLICE_WORKSPACE)(
                Update(workspace = WorkspaceSlice(loaded = true))
            )
            assertNull(store.routes.value.modal)

            store.share(SharedItems("Look at this", listOf(screenshot), ShareDestination.CHAT))
            assertEquals(MobileRoute.ShareTarget(chat = true), store.routes.value.modal)
            store.shareInto("chat")
            assertNull(store.routes.value.modal)
            assertEquals("chat", store.selectedCard.value)
            val delivered = assertNotNull(store.takeComposerShare("chat"))
            assertEquals("Look at this", delivered.text)
            assertEquals(listOf(screenshot), delivered.attachments)
            assertNull(store.takeComposerShare("chat"))

            // Too many files are reported and none are attached.
            store.share(
                SharedItems(
                    "",
                    List(Attachments.MAX_COUNT + 1) { screenshot },
                    ShareDestination.TASK,
                )
            )
            assertEquals(Attachments.TOO_MANY, store.error.value)
            assertEquals(MobileRoute.ShareTarget(chat = false), store.routes.value.modal)
            store.cancelShare()
            assertNull(store.routes.value.modal)
            assertTrue(store.composerShares.value.isEmpty())
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
                    com.dbpprt.dieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.selectTab(MobileTab.PROJECTS)
            store.push(MobileRoute.Board("board"))
            assertEquals("board", store.selectedBoard.value)
            store.openConversation("card")
            assertEquals("card", store.selectedCard.value)
            store.push(MobileRoute.Pane("card", CardPane.CHANGES))
            assertEquals("Changes", store.detailTab.value)
            assertEquals("card", store.selectedCard.value)
            // A native back gesture reports the remaining depth.
            store.popTo(MobileTab.PROJECTS, 3)
            assertEquals("Conversation", store.detailTab.value)
            // Opening another card from the list replaces the open conversation.
            store.openConversation("other")
            assertEquals(3, store.routes.value.stack.size)
            assertEquals("other", store.selectedCard.value)
            // Other tabs keep their own stacks.
            store.selectTab(MobileTab.INBOX)
            assertTrue(store.selectedCard.value.isEmpty())
            store.selectTab(MobileTab.PROJECTS)
            assertEquals("other", store.selectedCard.value)
            // Selecting the current tab again returns to its root.
            store.selectTab(MobileTab.PROJECTS)
            assertEquals(1, store.routes.value.stack.size)
            assertTrue(store.selectedCard.value.isEmpty())
            store.newConversation(chat = true)
            assertEquals(MobileRoute.NewTask(true), store.routes.value.modal)
            assertTrue(store.handleBack())
            assertNull(store.routes.value.modal)
        } finally {
            store.close()
        }
    }
}

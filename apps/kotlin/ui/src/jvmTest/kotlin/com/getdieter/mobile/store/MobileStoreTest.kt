package com.getdieter.mobile.store

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class MobileStoreTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    @Test
    fun backDismissesThenPopsThenReturnsToTheInbox() = runTest {
        val store = store(FakeMobileCore())
        try {
            store.selectTab(MobileTab.CHATS)
            store.push(MobileRoute.Tool(ToolPage.SETTINGS))
            store.present(MobileRoute.NewTask(chat = true))
            assertTrue(store.handleBack())
            assertNull(store.routes.value.modal)
            assertEquals(2, store.routes.value.stack.size)
            assertTrue(store.handleBack())
            assertEquals(listOf(MobileRoute.Root(MobileTab.CHATS)), store.routes.value.stack)
            assertTrue(store.handleBack())
            assertEquals(MobileTab.INBOX, store.routes.value.tab)
            assertFalse(store.handleBack())
        } finally {
            store.close()
        }
    }

    @Test
    fun openingAConversationBindsItsScopeAndEachPaneBindsItsOwn() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.selectTab(MobileTab.PROJECTS)
            store.push(MobileRoute.Board("board"))
            store.openConversation("card")
            runCurrent()
            assertEquals("board", store.boards.selectedBoard.value)
            assertEquals(
                BoardViewTarget(board_id = "board"),
                core.sentOf { it.board_view }.single().bind,
            )
            assertTrue(core.observing(Slice.SLICE_CONVERSATION, "card"))
            assertEquals(
                listOf("card"),
                core.sentOf { it.set_visible_conversation }.map { it.card_id },
            )
            core.publish(
                Slice.SLICE_CONVERSATION,
                "card",
                Update(
                    conversation =
                        ConversationSlice(
                            card_id = "card",
                            daemon_id = "owner",
                            card = com.getdieter.api.v1.Card(id = "card", project_id = "project"),
                        )
                ),
            )
            runCurrent()

            store.push(MobileRoute.Pane("card", CardPane.CHANGES))
            runCurrent()
            assertEquals("Changes", store.conversation.detailTab.value)
            val review = core.sentOf { it.review }.single()
            assertEquals(MobileStore.REVIEW_SCOPE, review.scope)
            assertEquals(ReviewTarget(card_id = "card", daemon_id = "owner"), review.bind)

            store.replaceTop(MobileRoute.Pane("card", CardPane.FILES))
            runCurrent()
            val files = core.sentOf { it.files }
            assertTrue(files.all { it.scope == MobileStore.FILES_SCOPE })
            assertEquals(
                FilesTarget(daemon_id = "owner", project_id = "project", card_id = "card"),
                files.first().bind,
            )
            assertNotNull(files[1].load)

            // Leaving the conversation releases its scope.
            store.selectTab(MobileTab.INBOX)
            runCurrent()
            assertTrue(store.conversation.selectedCard.value.isEmpty())
            assertFalse(core.observing(Slice.SLICE_CONVERSATION, "card"))
            assertEquals(
                listOf("card", ""),
                core.sentOf { it.set_visible_conversation }.map { it.card_id },
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun leavingADocumentReturnsTheFilesScopeToItsListing() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.push(MobileRoute.FilePath("README.md", file = true))
            runCurrent()
            assertEquals(FilesPath("README.md"), core.sentOf { it.files }.single().open_)
            core.publish(
                Slice.SLICE_FILES,
                MobileStore.FILES_SCOPE,
                Update(files = FilesSlice(selected_path = "README.md")),
            )
            runCurrent()
            store.pop()
            runCurrent()
            val close = core.sentOf { it.files }.last()
            assertEquals(MobileStore.FILES_SCOPE, close.scope)
            assertNotNull(close.close)
        } finally {
            store.close()
        }
    }

    @Test
    fun theNewTaskFormPreviewsOnceTypingPauses() = runTest {
        val core = FakeMobileCore { command ->
            command.creation_preview?.let {
                Result(creation_preview = CreationPreview(intent = it.intent))
            } ?: Result(done = Done())
        }
        val store = store(core)
        try {
            core.publish(
                Slice.SLICE_WORKSPACE,
                update =
                    Update(
                        workspace =
                            WorkspaceSlice(
                                loaded = true,
                                projects = listOf(Project(id = "project")),
                                boards = listOf(Board(id = "board", project_id = "project")),
                            )
                    ),
            )
            runCurrent()
            store.boards.chooseBoard("board")
            store.newConversation(chat = true)
            assertEquals(MobileRoute.NewTask(true), store.routes.value.modal)
            assertTrue(store.creation.chat.value)
            advanceTimeBy(50)
            store.creation.update(store.creation.intent.value.copy(prompt = "Hi"))
            advanceTimeBy(99)
            runCurrent()
            assertTrue(core.sentOf { it.creation_preview }.isEmpty())
            advanceTimeBy(1)
            runCurrent()
            val preview = core.sentOf { it.creation_preview }.single()
            assertEquals(MobileStore.FORM_SCOPE, preview.scope)
            assertTrue(preview.chat)
            assertEquals(
                "",
                preview.intent?.project_id,
                "Let the core restore the last chosen project",
            )
            assertEquals("", preview.intent?.board_id, "Let the core restore that project's board")
            assertEquals("Hi", preview.intent?.prompt)
            assertEquals("Hi", store.creation.preview.value.intent?.prompt)
        } finally {
            store.close()
        }
    }

    @Test
    fun submittingWaitsForTheLastAgentChoice() = runTest {
        val chosen = com.getdieter.api.v1.HarnessSelection("codex", "new-model", "high")
        val releasePreview = CompletableDeferred<Unit>()
        val core = FakeMobileCore { command ->
            when {
                command.creation_preview != null ->
                    Result(
                        creation_preview =
                            CreationPreview(
                                intent =
                                    command.creation_preview!!.intent!!.copy(selection = chosen)
                            )
                    )
                command.create_conversation != null ->
                    Result(card = com.getdieter.api.v1.Card(id = "created"))
                else -> Result(done = Done())
            }
        }
        val delayedCore =
            object : MobileCore by core {
                override suspend fun dispatch(command: Command): Result {
                    if (command.creation_preview != null) releasePreview.await()
                    return core.dispatch(command)
                }
            }
        val store = MobileStore(delayedCore, StandardTestDispatcher(testScheduler))
        try {
            store.creation.agentSelection =
                com.getdieter.api.v1.HarnessSelection("mock", "mock", "low")
            store.creation.update(
                CreationIntent(prompt = "Fix it"),
                AgentChoice(model = "new-model"),
            )
            val submission = async {
                store.creation.submit(store.creation.intent.value.copy(lane = "todo"))
            }
            runCurrent()
            assertTrue(core.sentOf { it.create_conversation }.isEmpty())
            releasePreview.complete(Unit)
            runCurrent()
            assertEquals("created", submission.await())
            val sent = core.sentOf { it.create_conversation }.single().intent!!
            assertEquals(chosen, sent.selection)
            assertNull(
                store.creation.initialIntent().selection,
                "The initial agent must not override the saved user choice on reopening",
            )
            assertEquals("todo", sent.lane)
            assertEquals("Fix it", sent.prompt)
        } finally {
            store.close()
        }
    }

    @Test
    fun aRefreshThatNeverCatchesUpStopsItsIndicatorAfterThirtySeconds() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            core.publish(
                Slice.SLICE_SESSION,
                update = Update(session = SessionSlice(synced = true)),
            )
            runCurrent()
            store.session.refresh()
            runCurrent()
            assertTrue(store.session.refreshing.value)
            assertEquals(1, core.sentOf { it.resync }.size)
            advanceTimeBy(29_999)
            runCurrent()
            assertTrue(store.session.refreshing.value)
            advanceTimeBy(1)
            runCurrent()
            assertFalse(store.session.refreshing.value)
            assertEquals("Sync is still catching up. Dieter will keep trying.", store.error.value)
            assertEquals(MobileStore.CHATS_SCOPE, core.sentOf { it.chats }.single().scope)
        } finally {
            store.close()
        }
    }

    @Test
    fun inputIsSentInOrderAndOverflowIsReported() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            repeat(65) { store.terminals.grid(it, 1) }
            assertEquals(
                "Input is arriving too quickly. Some input could not be sent; wait and try again.",
                store.error.value,
            )
            runCurrent()
            val grids = core.sentOf { it.terminals }
            assertTrue(grids.all { it.scope == MobileStore.TERMINAL_OVERVIEW_SCOPE })
            assertEquals((0 until 64).toList(), grids.map { it.grid?.columns })
        } finally {
            store.close()
        }
    }

    @Test
    fun aClosedStoreIgnoresLateUpdatesAndCommands() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        store.openConversation("card")
        runCurrent()
        val sent = core.sent.size
        store.close()
        core.publish(
            Slice.SLICE_CONVERSATION,
            "card",
            Update(conversation = ConversationSlice(card_id = "late")),
        )
        store.command(Command(reconnect = Reconnect()))
        store.terminals.input(byteArrayOf(1))
        runCurrent()
        assertEquals("card", store.conversation.slice.value.card_id)
        assertEquals(sent, core.sent.size)
    }
}

package com.getdieter.mobile.store

import com.getdieter.api.v1.MessagePart
import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.settings.DieterPalette
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import okio.ByteString.Companion.encodeUtf8

@OptIn(ExperimentalCoroutinesApi::class)
class HolderTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    private val image =
        MessagePart(
            type = "file",
            filename = "layout.png",
            media_type = "image/png",
            data_ = okio.ByteString.of(1, 2, 3),
        )

    @Test
    fun fileBuffersKeepEditsAndEvictOnlyUneditedDocumentsAtTheLimit() = runTest {
        val store = store(FakeMobileCore())
        val files = store.files
        try {
            files.syncBuffer("edited", "original")
            files.editBuffer("edited", "original", "my edits")
            files.syncBuffer("edited", "changed on disk")
            assertEquals(MobileFileBuffer("original", "my edits"), files.buffers.value["edited"])
            repeat(31) { files.syncBuffer("file-$it", "text") }
            assertEquals(32, files.buffers.value.size)
            // At the limit, the first unedited document makes room.
            files.syncBuffer("next", "text")
            assertEquals(32, files.buffers.value.size)
            assertNull(files.buffers.value["file-0"])
            assertEquals(MobileFileBuffer("text", "text"), files.buffers.value["next"])
            // Once every open document is edited, another cannot open.
            files.buffers.value.keys.toList().forEach { files.editBuffer(it, "", "changed") }
            files.syncBuffer("another", "text")
            assertNull(files.buffers.value["another"])
            assertEquals("Save or discard an open file before editing another.", store.error.value)
            store.error.value = ""
            files.editBuffer("another", "text", "typed")
            assertNull(files.buffers.value["another"])
            assertEquals("Save or discard an open file before editing another.", store.error.value)
            files.discardBuffer("next")
            files.editBuffer("another", "text", "typed")
            assertEquals(MobileFileBuffer("text", "typed"), files.buffers.value["another"])
            files.savedBuffer("another", "typed")
            assertEquals(MobileFileBuffer("typed", "typed"), files.buffers.value["another"])
        } finally {
            store.close()
        }
    }

    @Test
    fun aNewTaskShareWaitsForTheWorkspaceThenFillsTheForm() = runTest {
        val core = FakeMobileCore { command ->
            // Like the core, previews return the intent without its attachments.
            command.creation_preview?.let {
                Result(
                    creation_preview =
                        CreationPreview(intent = it.intent?.copy(attachments = emptyList()))
                )
            } ?: Result(done = Done())
        }
        val store = store(core)
        try {
            runCurrent()
            store.sharing.receive(
                SharedItems(
                    "Tighten the layout",
                    listOf(image),
                    ShareDestination.NEW_TASK,
                    problem = "One item could not be read.",
                )
            )
            runCurrent()
            assertNull(store.routes.value.modal)
            assertTrue(store.error.value.isEmpty())
            core.publish(
                Slice.SLICE_WORKSPACE,
                update = Update(workspace = WorkspaceSlice(loaded = true)),
            )
            runCurrent()
            assertEquals(MobileRoute.NewTask(false), store.routes.value.modal)
            assertEquals("One item could not be read.", store.error.value)
            advanceTimeBy(100)
            runCurrent()
            assertEquals(
                "Tighten the layout",
                core.sentOf { it.creation_preview }.single().intent?.prompt,
            )
            assertEquals("Tighten the layout", store.creation.intent.value.prompt)
            assertEquals(listOf(image), store.creation.intent.value.attachments)
            // A delivered share does not open again.
            store.dismiss()
            core.publish(
                Slice.SLICE_WORKSPACE,
                update = Update(workspace = WorkspaceSlice(loaded = true)),
            )
            runCurrent()
            assertNull(store.routes.value.modal)
        } finally {
            store.close()
        }
    }

    @Test
    fun aChatShareGoesToTheChosenComposerOnce() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            core.publish(
                Slice.SLICE_WORKSPACE,
                update = Update(workspace = WorkspaceSlice(loaded = true)),
            )
            runCurrent()
            store.sharing.receive(SharedItems("Look at this", listOf(image), ShareDestination.CHAT))
            assertEquals(MobileRoute.ShareTarget(chat = true), store.routes.value.modal)
            assertNotNull(store.sharing.target.value)
            store.sharing.shareInto("chat")
            runCurrent()
            assertNull(store.routes.value.modal)
            assertNull(store.sharing.target.value)
            assertEquals(MobileRoute.Conversation("chat"), store.routes.value.top)
            assertEquals("chat", store.conversation.selectedCard.value)
            val delivered = assertNotNull(store.sharing.takeComposerShare("chat"))
            assertEquals("Look at this", delivered.text)
            assertEquals(listOf(image), delivered.attachments)
            assertNull(store.sharing.takeComposerShare("chat"))

            store.sharing.receive(SharedItems("", listOf(image), ShareDestination.TASK))
            assertEquals(MobileRoute.ShareTarget(chat = false), store.routes.value.modal)
            store.sharing.cancel()
            assertNull(store.routes.value.modal)
            assertNull(store.sharing.target.value)
            assertTrue(store.sharing.composerShares.value.isEmpty())
        } finally {
            store.close()
        }
    }

    @Test
    fun draftsSaveWhenTypingPausesAndFlushAtOnce() = runTest {
        val core = FakeMobileCore { command ->
            if (command.list_drafts != null)
                Result(drafts = Drafts(drafts = listOf(DraftText("owner", "stored", "Kept"))))
            else Result(done = Done())
        }
        val store = store(core)
        val conversation = store.conversation
        try {
            runCurrent()
            assertEquals(mapOf("stored" to "Kept"), conversation.draftTexts.value)
            store.openConversation("card")
            runCurrent()
            core.publish(
                Slice.SLICE_CONVERSATION,
                "card",
                Update(conversation = ConversationSlice(card_id = "card", daemon_id = "owner")),
            )
            runCurrent()
            conversation.saveDraft("card", "Hel")
            advanceTimeBy(200)
            conversation.saveDraft("card", "Hello")
            advanceTimeBy(299)
            runCurrent()
            assertTrue(core.sentOf { it.set_draft_text }.isEmpty())
            advanceTimeBy(1)
            runCurrent()
            assertEquals(
                listOf(SetDraftText("owner", "card", "Hello")),
                core.sentOf { it.set_draft_text },
            )
            conversation.saveDraft("card", "Hello again")
            conversation.flushDrafts()
            advanceTimeBy(1_000)
            runCurrent()
            assertEquals(
                listOf(
                    SetDraftText("owner", "card", "Hello"),
                    SetDraftText("owner", "stored", "Kept"),
                    SetDraftText("owner", "card", "Hello again"),
                ),
                core.sentOf { it.set_draft_text },
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun aNewTaskFollowsItsServerIdAndKeepsItsObservation() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.openConversation("local")
            runCurrent()
            core.publish(
                Slice.SLICE_OUTBOX,
                update = Update(outbox = OutboxSlice(resolutions = mapOf("local" to "server"))),
            )
            runCurrent()
            assertEquals("server", store.conversation.selectedCard.value)
            assertTrue(core.observing(Slice.SLICE_CONVERSATION, "local"))
            assertFalse(core.observing(Slice.SLICE_CONVERSATION, "server"))

            // While the outbox resolves the local ID, reopening keeps observing its scope.
            store.pop()
            runCurrent()
            assertFalse(core.observing(Slice.SLICE_CONVERSATION, "local"))
            store.openConversation("local")
            runCurrent()
            assertEquals(MobileRoute.Conversation("server"), store.routes.value.top)
            assertTrue(core.observing(Slice.SLICE_CONVERSATION, "local"))

            // Once the outbox forgets it, the server ID is the conversation's own scope.
            store.pop()
            core.publish(Slice.SLICE_OUTBOX, update = Update(outbox = OutboxSlice()))
            runCurrent()
            store.openConversation("server")
            runCurrent()
            assertTrue(core.observing(Slice.SLICE_CONVERSATION, "server"))
            assertFalse(core.observing(Slice.SLICE_CONVERSATION, "local"))
        } finally {
            store.close()
        }
    }

    @Test
    fun cardTerminalsAppendResetAndForgetClosedTerminals() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        val terminals = store.terminals
        fun output(id: String, reset: Boolean, text: String) =
            TerminalOutput(id, reset, text.encodeUtf8())
        fun publish(ids: List<String>, vararg output: TerminalOutput) {
            core.publish(
                Slice.SLICE_TERMINALS,
                MobileStore.TERMINAL_SCOPE,
                Update(
                    terminals =
                        TerminalsSlice(
                            selected_id = "one",
                            terminals = ids.map { com.getdieter.api.v1.Terminal(id = it) },
                            rows = listOf(TerminalRow(id = "one", accepts_input = true)),
                            output = output.toList(),
                        )
                ),
            )
        }
        fun text(id: String) = terminals.screens.value.getValue(id).accessibilityText()
        try {
            store.openConversation("card")
            store.push(MobileRoute.Pane("card", CardPane.TERMINAL))
            runCurrent()
            assertEquals(
                TerminalTarget.Kind.KIND_CARD,
                core.sentOf { it.terminals }.first().bind?.kind,
            )
            publish(listOf("one", "two"), output("one", false, "first"), output("two", true, "x"))
            publish(listOf("one", "two"), output("one", false, " second"))
            runCurrent()
            assertEquals("first second", text("one"))
            assertEquals("one", terminals.visible.value)
            assertTrue(terminals.acceptsInput.value)
            assertTrue(terminals.card.value.output.isEmpty())
            publish(listOf("one"), output("one", true, "reset"))
            runCurrent()
            assertEquals("reset", text("one"))
            assertEquals(setOf("one"), terminals.screens.value.keys)

            // The overview's output is the overview's; it leaves the card's screens alone.
            core.publish(
                Slice.SLICE_TERMINAL_OVERVIEW,
                MobileStore.TERMINAL_OVERVIEW_SCOPE,
                Update(
                    terminal_overview =
                        TerminalOverviewSlice(
                            entries = listOf(OverviewTerminal(id = "machine|one")),
                            terminals = TerminalsSlice(output = listOf(output("one", true, "x"))),
                        )
                ),
            )
            runCurrent()
            assertEquals("reset", text("one"))
            assertEquals(listOf("machine|one"), terminals.overview.value.entries.map { it.id })
            assertTrue(terminals.overview.value.terminals?.output.orEmpty().isEmpty())
        } finally {
            store.close()
        }
    }

    @Test
    fun appearanceChoicesPersistAndRestore() {
        val saved = mutableMapOf("appearance" to "dark", "dynamic-color" to "true")
        val preferences = MobilePreferences(saved::get) { key, value -> saved[key] = value }
        val theme = ThemeModel(preferences)
        assertEquals("dark", theme.appearance.value)
        assertTrue(theme.dynamicColor.value)
        assertEquals(DieterPalette.DEFAULT, theme.palette.value)
        val chosen = DieterPalette.entries.last()
        theme.setAppearance("light")
        theme.setDynamicColor(false)
        theme.setPalette(chosen)
        assertEquals(
            mapOf("appearance" to "light", "dynamic-color" to "false", "palette" to chosen.slug),
            saved,
        )
        val restored = ThemeModel(preferences)
        assertEquals("light", restored.appearance.value)
        assertFalse(restored.dynamicColor.value)
        assertEquals(chosen, restored.palette.value)
    }
}

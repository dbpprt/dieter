package com.getdieter.mobile.desktop

import androidx.compose.ui.input.key.Key
import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

/** The desktop shell reads and drives the store's tab stacks, so scopes bind as on touch. */
@OptIn(ExperimentalCoroutinesApi::class)
class DesktopNavigationTest {
    private fun TestScope.store(
        core: FakeMobileCore = FakeMobileCore(),
        saved: MutableMap<String, String> = mutableMapOf(),
    ) =
        MobileStore(
            core,
            StandardTestDispatcher(testScheduler),
            MobilePreferences(saved::get) { k, v -> saved[k] = v },
        )

    private fun TestScope.seed(core: FakeMobileCore) {
        runCurrent()
        core.publish(
            Slice.SLICE_WORKSPACE,
            update =
                Update(
                    workspace =
                        WorkspaceSlice(
                            projects = listOf(Project(id = "atlas", name = "Atlas")),
                            boards =
                                listOf(
                                    Board(id = "main", project_id = "atlas", name = "Main"),
                                    Board(id = "ops", project_id = "atlas", name = "Ops"),
                                ),
                            cards =
                                listOf(
                                    Card(
                                        id = "task",
                                        project_id = "atlas",
                                        board_id = "main",
                                        title = "Ship it",
                                        lane = "running",
                                    ),
                                    Card(
                                        id = "chat",
                                        project_id = "atlas",
                                        scope = "chat",
                                        title = "Question",
                                    ),
                                ),
                            loaded = true,
                        )
                ),
        )
        runCurrent()
    }

    @Test
    fun eachTabStackReadsAsOneSidebarPlace() {
        val root = MobileNavigation()
        assertEquals(DesktopPlace(DesktopSection.INBOX, 1), root.desktopPlace())
        val board =
            root
                .copy(tab = MobileTab.PROJECTS)
                .with(
                    MobileTab.PROJECTS,
                    listOf(
                        MobileRoute.Root(MobileTab.PROJECTS),
                        MobileRoute.Project("atlas"),
                        MobileRoute.Board("main"),
                        MobileRoute.Conversation("task"),
                        MobileRoute.Pane("task", CardPane.CHANGES),
                    ),
                )
        assertEquals(
            DesktopPlace(DesktopSection.PROJECT, 3, "atlas", "main", ProjectPage.BOARD),
            board.desktopPlace(),
        )
        assertEquals(
            listOf(MobileRoute.Conversation("task"), MobileRoute.Pane("task", CardPane.CHANGES)),
            board.desktopDetail(),
        )
        val files =
            root
                .copy(tab = MobileTab.PROJECTS)
                .with(
                    MobileTab.PROJECTS,
                    listOf(
                        MobileRoute.Root(MobileTab.PROJECTS),
                        MobileRoute.Project("atlas"),
                        MobileRoute.Tool(ToolPage.FILES, "atlas"),
                        MobileRoute.FilePath("README.md", file = true),
                    ),
                )
        assertEquals(
            DesktopPlace(DesktopSection.PROJECT, 3, "atlas", page = ProjectPage.FILES),
            files.desktopPlace(),
        )
        fun more(vararg routes: MobileRoute) =
            root
                .copy(tab = MobileTab.MORE)
                .with(MobileTab.MORE, listOf(MobileRoute.Root(MobileTab.MORE)) + routes)
        assertEquals(
            DesktopSection.CHANNELS,
            more(MobileRoute.Channels, MobileRoute.Channel("atlas")).desktopPlace().section,
        )
        assertEquals(
            2,
            more(MobileRoute.Channels, MobileRoute.Channel("atlas")).desktopPlace().base,
        )
        assertEquals(
            DesktopSection.TERMINALS,
            more(MobileRoute.Tool(ToolPage.TERMINALS)).desktopPlace().section,
        )
        assertEquals(
            DesktopSection.SETTINGS,
            more(MobileRoute.Tool(ToolPage.SETTINGS)).desktopPlace().section,
        )
        assertEquals(
            DesktopPlace(DesktopSection.MACHINE, 2, machineId = "mini"),
            more(MobileRoute.Machine("mini")).desktopPlace(),
        )
        assertEquals(DesktopSection.PLACES, more().desktopPlace().section)
    }

    @Test
    fun sidebarDestinationsKeepWhatTheyShowedAndBindNothingNew() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            seed(core)
            store.openConversation("task")
            assertEquals(
                listOf(MobileRoute.Root(MobileTab.INBOX), MobileRoute.Conversation("task")),
                store.routes.value.stack,
            )
            store.openSection(DesktopSection.CHANNELS)
            assertEquals(DesktopSection.CHANNELS, store.routes.value.desktopPlace().section)
            // Back in the Inbox, its open conversation is still there.
            store.openSection(DesktopSection.INBOX)
            assertEquals(MobileRoute.Conversation("task"), store.routes.value.top)
            // Choosing the same destination again changes nothing, unlike a touch tab.
            store.openSection(DesktopSection.INBOX)
            assertEquals(MobileRoute.Conversation("task"), store.routes.value.top)
            store.openSection(DesktopSection.SETTINGS)
            assertEquals(
                listOf(MobileRoute.Root(MobileTab.MORE), MobileRoute.Tool(ToolPage.SETTINGS)),
                store.routes.value.stack,
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun projectsOpenTheirBoardAndCardsOpenWhereTheyLive() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            seed(core)
            store.openProject("atlas")
            runCurrent()
            assertEquals(
                listOf(
                    MobileRoute.Root(MobileTab.PROJECTS),
                    MobileRoute.Project("atlas"),
                    MobileRoute.Board("main"),
                ),
                store.routes.value.stack,
            )
            assertEquals("main", store.boards.selectedBoard.value)
            store.openProject("atlas", ProjectPage.FILES)
            assertEquals(MobileRoute.Tool(ToolPage.FILES, "atlas"), store.routes.value.top)
            store.openProject("atlas", ProjectPage.BOARD, "ops")
            assertEquals(MobileRoute.Board("ops"), store.routes.value.top)
            store.openCard("task")
            runCurrent()
            assertEquals(
                listOf(
                    MobileRoute.Root(MobileTab.PROJECTS),
                    MobileRoute.Project("atlas"),
                    MobileRoute.Board("main"),
                    MobileRoute.Conversation("task"),
                ),
                store.routes.value.stack,
            )
            assertTrue(core.observing(Slice.SLICE_CONVERSATION, "task"))
            // The board stays when its project is chosen again, and so does the conversation.
            store.openProject("atlas")
            assertEquals(MobileRoute.Conversation("task"), store.routes.value.top)
            store.openCard("chat")
            assertEquals(
                listOf(MobileRoute.Root(MobileTab.CHATS), MobileRoute.Conversation("chat")),
                store.routes.value.stack,
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun theTabTrackSwapsPanesAndCloseLeavesTheBoard() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            seed(core)
            store.openCard("task")
            store.showConversationPane("task", CardPane.CHANGES)
            runCurrent()
            assertEquals(MobileRoute.Pane("task", CardPane.CHANGES), store.routes.value.top)
            assertEquals("Changes", store.conversation.detailTab.value)
            store.showConversationPane("task", CardPane.FILES)
            assertEquals(MobileRoute.Pane("task", CardPane.FILES), store.routes.value.top)
            assertEquals(
                listOf(MobileRoute.Conversation("task"), MobileRoute.Pane("task", CardPane.FILES)),
                store.routes.value.desktopDetail(),
            )
            assertEquals(
                "task" to CardPane.FILES,
                store.routes.value.desktopDetail().conversationScope(),
            )
            store.showConversationPane("task", null)
            assertEquals(MobileRoute.Conversation("task"), store.routes.value.top)
            store.closeDetail()
            runCurrent()
            assertEquals(MobileRoute.Board("main"), store.routes.value.top)
            assertEquals("", store.conversation.selectedCard.value)
        } finally {
            store.close()
        }
    }

    @Test
    fun theInterfaceModeAndPaneWidthsPersist() = runTest {
        val saved = mutableMapOf<String, String>()
        val first = store(saved = saved)
        try {
            assertEquals(InterfaceMode.AUTOMATIC, first.layout.interfaceMode.value)
            first.layout.setInterfaceMode(InterfaceMode.DESKTOP)
            first.layout.setSidebarHidden(true)
            first.layout.setDesktopWidth(DesktopPane.INBOX, 9999f)
        } finally {
            first.close()
        }
        val second = store(saved = saved)
        try {
            assertEquals(InterfaceMode.DESKTOP, second.layout.interfaceMode.value)
            assertTrue(second.layout.sidebarHidden.value)
            assertEquals(
                DesktopPane.INBOX.max,
                second.layout.desktopWidths.value.getValue(DesktopPane.INBOX),
            )
            assertEquals(
                DesktopPane.MAIL.default,
                second.layout.desktopWidths.value.getValue(DesktopPane.MAIL),
            )
        } finally {
            second.close()
        }
    }

    @Test
    fun theDesktopShellNeedsADesktopSignalOrTheChoiceAndRoom() {
        assertFalse(DesktopLayout.shows(InterfaceMode.AUTOMATIC, host = false, 1920f, 1080f))
        assertTrue(DesktopLayout.shows(InterfaceMode.AUTOMATIC, host = true, 1920f, 1080f))
        assertTrue(DesktopLayout.shows(InterfaceMode.DESKTOP, host = false, 1280f, 800f))
        assertFalse(DesktopLayout.shows(InterfaceMode.TOUCH, host = true, 1920f, 1080f))
        // A phone-sized window keeps the touch shell even on DeX.
        assertFalse(DesktopLayout.shows(InterfaceMode.DESKTOP, host = true, 411f, 890f))
        assertFalse(DesktopLayout.shows(InterfaceMode.AUTOMATIC, host = true, 1280f, 360f))
    }

    @Test
    fun lanesShareTheBoardAndTheConversationLeavesItRoom() {
        assertEquals(264f, DesktopLayout.laneWidth(600f, 4))
        assertEquals((1200f - 27f) / 4, DesktopLayout.laneWidth(1200f, 4))
        assertEquals(520f, DesktopLayout.conversationWidth(1600f, 520f))
        assertEquals(
            1600f - DesktopLayout.MIN_BOARD_DP,
            DesktopLayout.conversationWidth(1600f, 5000f),
        )
        assertEquals(DesktopPane.CONVERSATION.min, DesktopLayout.conversationWidth(500f, 100f))
    }

    @Test
    fun shortcutsAreCtrlChords() {
        assertEquals(
            DesktopShortcut.PALETTE,
            DesktopShortcut.of(Key.K, ctrl = true, shift = false, alt = false),
        )
        assertEquals(
            DesktopShortcut.NEW_TASK,
            DesktopShortcut.of(Key.N, ctrl = true, shift = false, alt = false),
        )
        assertEquals(
            DesktopShortcut.NEW_CHAT,
            DesktopShortcut.of(Key.N, ctrl = true, shift = true, alt = false),
        )
        assertEquals(
            DesktopShortcut.CHATS,
            DesktopShortcut.of(Key.Four, ctrl = true, shift = false, alt = false),
        )
        assertEquals(
            DesktopShortcut.SETTINGS,
            DesktopShortcut.of(Key.Comma, ctrl = true, shift = false, alt = false),
        )
        assertEquals(
            DesktopShortcut.BACK,
            DesktopShortcut.of(Key.DirectionLeft, ctrl = false, shift = false, alt = true),
        )
        assertEquals(
            DesktopShortcut.ESCAPE,
            DesktopShortcut.of(Key.Escape, ctrl = false, shift = false, alt = false),
        )
        // Typing stays typing.
        assertNull(DesktopShortcut.of(Key.K, ctrl = false, shift = false, alt = false))
        assertNull(DesktopShortcut.of(Key.One, ctrl = true, shift = true, alt = false))
        assertNull(DesktopShortcut.of(Key.K, ctrl = true, shift = false, alt = true))
    }

    @Test
    fun thePaletteListsConversationsBeforePlacesAndCommands() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            seed(core)
            val empty = paletteEntries(store, "", emptyList())
            assertEquals("new-task", empty.first().id)
            val found =
                paletteEntries(
                    store,
                    "atl",
                    listOf(
                        SearchHit(card_id = "task", title = "Ship it", location = "Atlas · Main")
                    ),
                )
            assertEquals(listOf("card-task", "project-atlas"), found.take(2).map { it.id })
            val commands = paletteEntries(store, "settings", emptyList())
            assertEquals(listOf("open-settings"), commands.map { it.id })
            commands.single().run()
            assertEquals(DesktopSection.SETTINGS, store.routes.value.desktopPlace().section)
        } finally {
            store.close()
        }
    }

    @Test
    fun theMacTokensMixAsTheMacDoes() {
        assertEquals(0xE6E6E8L, DesktopTokens.mix(0xF5F5F7, 0x1C1C1E, .07f))
        val light =
            DesktopTokens.of(com.getdieter.mobile.settings.DieterPalette.MONOCHROME, dark = false)
        val dark =
            DesktopTokens.of(com.getdieter.mobile.settings.DieterPalette.MONOCHROME, dark = true)
        assertEquals(androidx.compose.ui.graphics.Color(0xFF1C1C1E), dark.canvas)
        assertEquals(androidx.compose.ui.graphics.Color(0xFF2C2C2E), dark.panel)
        assertEquals(androidx.compose.ui.graphics.Color(0xFF1C1C1E), light.text)
    }
}

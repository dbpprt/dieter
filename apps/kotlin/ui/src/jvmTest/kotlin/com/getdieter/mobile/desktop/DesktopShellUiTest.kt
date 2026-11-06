@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.desktop

import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.Dispatchers

/**
 * The desktop shell rendered offscreen at desktop sizes against a seeded fake core, driven with the
 * pointer and the keyboard. Each step leaves a screenshot under build/desktop-screenshots.
 */
class DesktopShellUiTest {
    private fun DesktopComposeUiTest.shot(name: String) {
        val directory = System.getProperty("dieter.screenshots") ?: return
        waitForIdle()
        val image = onRoot().captureToImage().toAwtImage()
        File(directory).mkdirs()
        ImageIO.write(image, "png", File(directory, "$name.png"))
    }

    private fun DesktopComposeUiTest.launch(
        mode: InterfaceMode = InterfaceMode.AUTOMATIC,
        host: Boolean = true,
        appearance: String = "light",
    ): Pair<MobileStore, FakeMobileCore> {
        val core = DesktopFixture.core()
        val store = MobileStore(core, Dispatchers.Unconfined)
        store.layout.setInterfaceMode(mode)
        store.theme.setAppearance(appearance)
        DesktopFixture.publish(core)
        setContent { MobileApp(store, desktopHost = host) }
        waitForIdle()
        return store to core
    }

    private fun DesktopComposeUiTest.ctrl(key: Key, shift: Boolean = false) =
        onNodeWithTag("desktop-shell").performKeyInput {
            keyDown(Key.CtrlLeft)
            if (shift) keyDown(Key.ShiftLeft)
            pressKey(key)
            if (shift) keyUp(Key.ShiftLeft)
            keyUp(Key.CtrlLeft)
        }

    @Test
    fun inboxBoardConversationAndPaletteWorkEndToEnd() =
        runDesktopComposeUiTest(width = 1440, height = 900) {
            val (store, core) = launch()
            try {
                // The sidebar: destinations, the expanded project with its pages and live work,
                // machines.
                onNodeWithTag("desktop-sidebar").assertIsDisplayed()
                onNodeWithTag("sidebar-inbox").assertIsDisplayed()
                onNodeWithTag("sidebar-project-atlas").assertIsDisplayed()
                onNodeWithTag("project-page-board-atlas").assertIsDisplayed()
                onNodeWithTag("sidebar-card-ship").assertIsDisplayed()
                onNodeWithTag("sidebar-machine-mini").assertIsDisplayed()
                // The Inbox list beside an empty detail panel.
                onNodeWithTag("activity-row-flaky").assertIsDisplayed()
                onNodeWithTag("finish-flaky").assertIsDisplayed()
                onNodeWithText("No conversation selected").assertIsDisplayed()
                shot("01-inbox")

                onNodeWithTag("activity-row-chat").performClick()
                DesktopFixture.publishConversation(core, "chat")
                waitForIdle()
                assertEquals(
                    listOf(MobileRoute.Root(MobileTab.INBOX), MobileRoute.Conversation("chat")),
                    store.routes.value.stack,
                )
                onNodeWithTag("conversation-panel").assertIsDisplayed()
                onNodeWithTag("conversation-title").assertTextEquals("How do we version the SDK?")
                // A chat has no Changes tab.
                onAllNodesWithTag("pane-tab-changes").assertCountEquals(0)
                shot("02-inbox-chat")

                // A project opens its board: every lane side by side, dense cards.
                onNodeWithTag("sidebar-project-atlas").performClick()
                DesktopFixture.publishBoard(core)
                waitForIdle()
                assertEquals(DesktopSection.PROJECT, store.routes.value.desktopPlace().section)
                listOf("todo", "running", "review", "done").forEach {
                    onNodeWithTag("board-lane-$it").assertIsDisplayed()
                }
                onNodeWithTag("board-title", useUnmergedTree = true).assertTextEquals("Main")
                onNodeWithTag("card-ship").assertIsDisplayed()
                onNodeWithTag("start-rate").assertIsDisplayed()
                onNodeWithText("Waiting for you").assertIsDisplayed()
                shot("03-board")

                // A card opens beside the board with its tab track.
                onNodeWithTag("card-ship").performClick()
                DesktopFixture.publishConversation(core, "ship")
                waitForIdle()
                onNodeWithTag("conversation-panel").assertIsDisplayed()
                onNodeWithTag("conversation-title")
                    .assertTextEquals("Ship the v2 pagination cursor")
                onNodeWithTag("board-lane-todo").assertIsDisplayed()
                shot("04-board-conversation")
                onNodeWithTag("pane-tab-changes").performClick()
                waitForIdle()
                assertEquals(MobileRoute.Pane("ship", CardPane.CHANGES), store.routes.value.top)
                assertEquals("Changes", store.conversation.detailTab.value)
                onNodeWithTag("pane-tab-conversation").performClick()
                waitForIdle()
                assertEquals(MobileRoute.Conversation("ship"), store.routes.value.top)

                // Ctrl+K: the palette searches through the core and opens what it finds.
                ctrl(Key.K)
                waitForIdle()
                onNodeWithTag("command-palette").assertIsDisplayed()
                onNodeWithTag("palette-search").performTextInput("flaky")
                mainClock.advanceTimeBy(400)
                waitUntil(timeoutMillis = 5_000) {
                    onAllNodesWithTag("palette-card-flaky").fetchSemanticsNodes().isNotEmpty()
                }
                shot("05-palette")
                onNodeWithTag("palette-search").performKeyInput { pressKey(Key.Enter) }
                waitForIdle()
                onAllNodesWithTag("command-palette").assertCountEquals(0)
                assertEquals(MobileRoute.Conversation("flaky"), store.routes.value.top)

                // Ctrl+W closes the conversation; the board keeps the window.
                ctrl(Key.W)
                waitForIdle()
                onAllNodesWithTag("conversation-panel").assertCountEquals(0)
                assertEquals(MobileRoute.Board("main"), store.routes.value.top)

                // Ctrl+4 and Ctrl+, reach Chats and Settings; the Interface choice is there.
                ctrl(Key.Four)
                waitForIdle()
                onNodeWithTag("chat-chat").assertIsDisplayed()
                shot("06-chats")
                ctrl(Key.Comma)
                waitForIdle()
                assertEquals(DesktopSection.SETTINGS, store.routes.value.desktopPlace().section)
                onNodeWithTag("interface-1").assertIsDisplayed()
                shot("07-settings")

                // Ctrl+N opens the new task form as a sheet over the workspace.
                ctrl(Key.N)
                waitForIdle()
                onNodeWithTag("desktop-modal").assertIsDisplayed()
                onNodeWithTag("desktop-shell").performKeyInput { pressKey(Key.Escape) }
                waitForIdle()
                onAllNodesWithTag("desktop-modal").assertCountEquals(0)

                // Ctrl+B hides the sidebar; the panes keep a button that brings it back.
                ctrl(Key.B)
                waitForIdle()
                onAllNodesWithTag("desktop-sidebar").assertCountEquals(0)
                onNodeWithTag("sidebar-show").performClick()
                waitForIdle()
                onNodeWithTag("desktop-sidebar").assertIsDisplayed()
            } finally {
                store.close()
            }
        }

    @Test
    fun theDarkBoardFillsAWideDisplay() =
        runDesktopComposeUiTest(width = 1920, height = 1080) {
            val (store, core) = launch(appearance = "dark")
            try {
                store.openProject("atlas")
                DesktopFixture.publishBoard(core)
                store.openConversation("flaky")
                DesktopFixture.publishConversation(core, "flaky")
                waitForIdle()
                onNodeWithTag("conversation-panel").assertIsDisplayed()
                listOf("todo", "running", "review", "done").forEach {
                    onNodeWithTag("board-lane-$it").assertIsDisplayed()
                }
                shot("08-dark-board-1080p")
            } finally {
                store.close()
            }
        }

    @Test
    fun aNewTaskOpenedUnderItsLocalIdShowsItsCard() =
        runDesktopComposeUiTest(width = 1440, height = 900) {
            val (store, core) = launch()
            try {
                store.openProject("atlas")
                DesktopFixture.publishBoard(core)
                // Creation opens the task under its outbox ID before the server's arrives.
                store.openConversation("local-ship")
                waitForIdle()
                core.publish(
                    com.getdieter.client.v1.Slice.SLICE_OUTBOX,
                    update =
                        com.getdieter.client.v1.Update(
                            outbox =
                                com.getdieter.client.v1.OutboxSlice(
                                    resolutions = mapOf("local-ship" to "ship")
                                )
                        ),
                )
                DesktopFixture.publishConversation(core, "ship")
                waitForIdle()
                onNodeWithTag("conversation-title")
                    .assertTextEquals("Ship the v2 pagination cursor")
            } finally {
                store.close()
            }
        }

    @Test
    fun aNarrowWindowFloatsTheSidebarAndAPhoneSizedOneIsTouch() =
        runDesktopComposeUiTest(width = 900, height = 700) {
            val (store, _) = launch()
            try {
                onNodeWithTag("desktop-shell").assertIsDisplayed()
                onAllNodesWithTag("desktop-sidebar").assertCountEquals(0)
                onNodeWithTag("sidebar-show").performClick()
                waitForIdle()
                onNodeWithTag("desktop-sidebar").assertIsDisplayed()
                shot("09-narrow-floating-sidebar")
                onNodeWithTag("sidebar-mail").performClick()
                waitForIdle()
                onAllNodesWithTag("desktop-sidebar").assertCountEquals(0)
                assertEquals(MobileTab.MAIL, store.routes.value.tab)
            } finally {
                store.close()
            }
        }

    @Test
    fun withoutADesktopSignalTheTouchShellShowsUntilDesktopIsChosen() =
        runDesktopComposeUiTest(width = 1440, height = 900) {
            val (store, _) = launch(host = false)
            try {
                onAllNodesWithTag("desktop-shell").assertCountEquals(0)
                onNodeWithTag("nav-inbox").assertIsDisplayed()
                store.layout.setInterfaceMode(InterfaceMode.DESKTOP)
                waitForIdle()
                onNodeWithTag("desktop-shell").assertIsDisplayed()
                store.layout.setInterfaceMode(InterfaceMode.TOUCH)
                waitForIdle()
                onAllNodesWithTag("desktop-shell").assertCountEquals(0)
            } finally {
                store.close()
            }
        }
}

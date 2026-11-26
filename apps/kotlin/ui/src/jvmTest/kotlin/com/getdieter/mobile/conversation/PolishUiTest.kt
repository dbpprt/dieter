@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.conversation

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.navigation.MobileTab
import com.getdieter.mobile.store.*
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlinx.coroutines.Dispatchers

/**
 * The polished chat window, two-pane layout and desktop panel rendered offscreen with a turn in
 * progress: grouped tool steps with a failed call, a thinking disclosure, the tailed user bubble,
 * the typing indicator and the glowing composer. Screenshots go to `desktop-screenshots/polish`.
 */
class PolishUiTest {
    private enum class Window(val width: Int, val height: Int) {
        PHONE(412, 915),
        FOLD(750, 832),
        FOLD_LANDSCAPE(832, 750),
        DESKTOP(1440, 900),
    }

    private val scale = 2f

    private fun text(rowId: String, user: Boolean, body: String) =
        TimelineItem(
            id = rowId,
            message_ids = listOf(rowId),
            user = user,
            copyable = true,
            groups =
                listOf(
                    TimelineStepGroup(
                        id = "$rowId:part:0",
                        steps =
                            listOf(
                                TimelineStep(
                                    id = "$rowId:part:0",
                                    message_id = rowId,
                                    kind = TimelineStepKind.TIMELINE_STEP_KIND_TEXT,
                                    text = body,
                                )
                            ),
                    )
                ),
        )

    private fun tool(
        rowId: String,
        index: Int,
        title: String,
        status: ToolCallStatus,
        label: String,
        attention: Boolean = false,
    ) =
        TimelineStep(
            id = "$rowId:part:$index",
            message_id = rowId,
            kind = TimelineStepKind.TIMELINE_STEP_KIND_TOOL,
            part_index = index,
            routine = true,
            tool_status = status,
            tool_title = title,
            tool_status_label = label,
            tool_attention = attention,
        )

    private val done = ToolCallStatus.TOOL_CALL_STATUS_COMPLETED

    /** A turn as the showcase fixture streams one, frozen mid-way through its race tests. */
    private fun conversation(id: String): ConversationSlice {
        val base = DesktopFixture.conversation(id)
        val work =
            TimelineItem(
                id = "a1",
                message_ids = listOf("a1"),
                copyable = true,
                groups =
                    listOf(
                        TimelineStepGroup(
                            id = "a1:part:0",
                            activity = true,
                            summary = "Reasoning · 2 file reads · 1 edit · 1 command",
                            steps =
                                listOf(
                                    TimelineStep(
                                        id = "a1:part:0",
                                        message_id = "a1",
                                        kind = TimelineStepKind.TIMELINE_STEP_KIND_REASONING,
                                        routine = true,
                                        text =
                                            "The limiter has to key on the API key, not the " +
                                                "tenant: one tenant can hold several keys with " +
                                                "different plans. A token bucket per key, sized " +
                                                "by the plan, keeps the middleware stateless.",
                                    ),
                                    tool(
                                        "a1",
                                        1,
                                        "Read internal/httpapi/router.go",
                                        done,
                                        "completed",
                                    ),
                                    tool("a1", 2, "Search Plan\\b in internal", done, "completed"),
                                    tool(
                                        "a1",
                                        3,
                                        "Edit internal/ratelimit/limiter.go",
                                        done,
                                        "completed",
                                    ),
                                    tool(
                                        "a1",
                                        4,
                                        "Run go test ./internal/ratelimit/...",
                                        ToolCallStatus.TOOL_CALL_STATUS_FAILED,
                                        "failed",
                                        attention = true,
                                    ),
                                ),
                        ),
                        TimelineStepGroup(
                            id = "a1:part:5",
                            steps =
                                listOf(
                                    TimelineStep(
                                        id = "a1:part:5",
                                        message_id = "a1",
                                        kind = TimelineStepKind.TIMELINE_STEP_KIND_TEXT,
                                        part_index = 5,
                                        text =
                                            "Each API key now gets its own token bucket, sized " +
                                                "by the key's plan:\n\n" +
                                                "- **Free:** 60 requests a minute, bursts of 20\n" +
                                                "- **Team:** 600 a minute, bursts of 120\n" +
                                                "- **Scale:** 3,000 a minute, bursts of 600\n\n" +
                                                "Rejected requests return `429 Too Many Requests` " +
                                                "with `Retry-After`, so SDKs can back off without " +
                                                "guessing. The first test run failed on a stale " +
                                                "fixture; fixing that next.",
                                    )
                                ),
                        ),
                    ),
            )
        val live =
            TimelineItem(
                id = "a2",
                message_ids = listOf("a2"),
                activity = true,
                summary = "1 command",
                groups =
                    listOf(
                        TimelineStepGroup(
                            id = "a2:part:0",
                            activity = true,
                            summary = "1 command",
                            steps =
                                listOf(
                                    tool(
                                        "a2",
                                        0,
                                        "Run go test -race -count=1 ./internal/...",
                                        ToolCallStatus.TOOL_CALL_STATUS_RUNNING,
                                        "running",
                                    )
                                ),
                        )
                    ),
            )
        return base.copy(
            card = base.card?.copy(lane = "running"),
            timeline =
                listOf(
                    text(
                        "u1",
                        true,
                        "Add per-key rate limiting to the public API. Start with the middleware " +
                            "chain and keep the limits configurable per plan.",
                    ),
                    work,
                    text("u2", true, "Good. Run the race tests and move it to review when green."),
                    live,
                ),
            state =
                ConversationState(
                    working = true,
                    live_activity = "Running go test -race -count=1 ./internal/ratelimit/...",
                    agent =
                        AgentControlsState(
                            provider_label = "Codex",
                            model_label = "GPT-5.6",
                            effort_label = "High",
                        ),
                    context_percent = 41,
                    can_halt = true,
                ),
        )
    }

    private fun DesktopComposeUiTest.shot(name: String) {
        val directory = System.getProperty("dieter.screenshots") ?: return
        waitForIdle()
        val folder = File(directory, "polish").apply { mkdirs() }
        val roots =
            onAllNodes(isRoot()).fetchSemanticsNodes().indices.map {
                onAllNodes(isRoot())[it].captureToImage().toAwtImage()
            }
        val image =
            java.awt.image.BufferedImage(
                roots[0].getWidth(null),
                roots[0].getHeight(null),
                java.awt.image.BufferedImage.TYPE_INT_ARGB,
            )
        val graphics = image.createGraphics()
        roots.forEach { graphics.drawImage(it, 0, 0, null) }
        graphics.dispose()
        ImageIO.write(image, "png", File(folder, "$name.png"))
    }

    private fun render(
        window: Window,
        dark: Boolean = false,
        desktop: Boolean = false,
        tab: MobileTab = MobileTab.INBOX,
        block: DesktopComposeUiTest.(MobileStore) -> Unit,
    ) =
        runDesktopComposeUiTest(
            width = (window.width * scale).toInt(),
            height = (window.height * scale).toInt(),
        ) {
            val core = DesktopFixture.core()
            val store = MobileStore(core, Dispatchers.Unconfined)
            store.layout.setInterfaceMode(
                if (desktop) InterfaceMode.DESKTOP else InterfaceMode.TOUCH
            )
            store.layout.setNavigationStyle(NavigationStyle.LENS)
            store.layout.setComposerStyle(ComposerStyle.CARD)
            store.theme.setAppearance(if (dark) "dark" else "light")
            store.theme.setPalette(com.getdieter.mobile.settings.DieterPalette.MONOCHROME)
            DesktopFixture.publish(core)
            DesktopFixture.publishBoard(core)
            setContent {
                CompositionLocalProvider(LocalDensity provides Density(scale)) {
                    MobileApp(store, desktopHost = false)
                }
            }
            waitForIdle()
            if (tab != MobileTab.INBOX) store.selectTab(tab)
            store.openConversation("ship")
            core.publish(
                Slice.SLICE_CONVERSATION,
                "ship",
                Update(conversation = conversation("ship")),
            )
            waitForIdle()
            try {
                block(store)
            } finally {
                store.close()
            }
        }

    @Test
    fun thePhoneTranscriptGroupsToolStepsAndShowsTheLiveTurn() {
        for (dark in listOf(false, true)) render(Window.PHONE, dark = dark) {
            val mode = if (dark) "dark" else "light"
            onNodeWithTag("working-indicator").assertIsDisplayed()
            onNodeWithTag("composer-card").assertIsDisplayed()
            // The transcript follows the live turn, so no jump pill shows.
            onAllNodesWithTag("jump-to-latest").assertCountEquals(0)
            shot("phone-conversation-$mode")
            // A touch, not the test's mouse: a hovering pointer would tint the row.
            onNodeWithContentDescription("Show Reasoning · 2 file reads · 1 edit · 1 command")
                .performTouchInput { click() }
            waitForIdle()
            onNodeWithTag("tool-steps", useUnmergedTree = true).assertIsDisplayed()
            onNodeWithText("failed", useUnmergedTree = true).assertIsDisplayed()
            // Open steps scroll the transcript; read it from the top for the picture.
            onNodeWithTag("conversation-timeline").performTouchInput { swipeDown() }
            waitForIdle()
            shot("phone-conversation-steps-$mode")
        }
    }

    @Test
    fun theFoldShowsPanelsBesideEachOther() {
        render(Window.FOLD) {
            onNodeWithTag("pane-divider").assertIsDisplayed()
            onNodeWithTag("floating-navigation").assertIsDisplayed()
            shot("fold-inbox-conversation-light")
        }
        render(Window.FOLD, dark = true, tab = MobileTab.PROJECTS) { store ->
            store.push(com.getdieter.mobile.navigation.MobileRoute.Board("main"))
            waitForIdle()
            store.openConversation("ship")
            waitForIdle()
            onNodeWithTag("board-lane-running").assertIsDisplayed()
            shot("fold-board-conversation-dark")
        }
        render(Window.FOLD_LANDSCAPE) { shot("fold-landscape-conversation-light") }
    }

    @Test
    fun theDesktopPanelFloatsTheComposerCard() {
        render(Window.DESKTOP, desktop = true) {
            onNodeWithTag("conversation-panel").assertIsDisplayed()
            onNodeWithTag("composer-card").assertIsDisplayed()
            shot("desktop-conversation-light")
        }
    }
}

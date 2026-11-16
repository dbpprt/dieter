@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.workspace

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.store.*
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

/**
 * The phone Inbox rendered offscreen at phone size: the core's sections as dense two-line rows,
 * with no tiles or usage strip, and the status filter in the filter menu.
 */
class InboxScreenUiTest {
    private val shownAt = kotlin.time.Clock.System.now().toEpochMilliseconds() - 7 * 60_000

    private fun row(
        id: String,
        title: String,
        kind: String,
        section: ActivityRow.Section,
        preview: String,
        needsYou: Boolean = false,
        pinned: Boolean = false,
        agents: String = "",
    ) =
        ActivityRow(
            card =
                Card(
                    id = id,
                    project_id = "atlas",
                    board_id = "main",
                    title = title,
                    lane = if (kind == "REVIEW") "review" else "todo",
                    owner_daemon_id = "mini",
                ),
            kind = kind,
            section = section,
            detail = preview,
            preview = preview,
            agents = agents,
            project_name = "Atlas API",
            board_name = "Main",
            needs_you = needsYou,
            can_finish = kind == "REVIEW" || kind == "FAILED",
            pinned = pinned,
            title = title,
            shown_at_millis = shownAt,
        )

    private val activity =
        ActivitySlice(
            rows =
                listOf(
                    row(
                        "ask",
                        "Pick the SDK registry",
                        "ANSWER",
                        ActivityRow.Section.SECTION_ATTENTION,
                        "Which registry should publish the SDK?",
                        needsYou = true,
                    ),
                    row(
                        "fail",
                        "Nightly backup check",
                        "FAILED",
                        ActivityRow.Section.SECTION_ATTENTION,
                        "Agent failed: disk full",
                        needsYou = true,
                        pinned = true,
                    ),
                    row(
                        "run",
                        "Ship the v2 pagination cursor",
                        "RUNNING",
                        ActivityRow.Section.SECTION_RUNNING,
                        "Updating the TypeScript client…",
                        agents = "2 agents",
                    ),
                    row(
                        "pin",
                        "Ship the new project picker",
                        "REVIEW",
                        ActivityRow.Section.SECTION_PINNED,
                        "Picker remembers the last project",
                        pinned = true,
                    ),
                    row(
                        "done",
                        "Rate-limit the public search endpoint",
                        "RECENT",
                        ActivityRow.Section.SECTION_RECENT,
                        "Finished",
                    ),
                ),
            summary =
                ActivitySummary(
                    running = 1,
                    attention = 2,
                    recent = 2,
                    review = 1,
                    hidden = 72,
                    headline = "2 need you · 1 running",
                ),
        )

    /**
     * Saves the window, or with an open menu its popup layer ([root] 1), when screenshots are on.
     */
    private fun DesktopComposeUiTest.shot(name: String, root: Int = 0) {
        val directory = System.getProperty("dieter.screenshots") ?: return
        waitForIdle()
        File(directory).mkdirs()
        val image = onAllNodes(isRoot())[root].captureToImage().toAwtImage()
        ImageIO.write(image, "png", File(directory, "$name.png"))
    }

    private fun DesktopComposeUiTest.launch(): MobileStore {
        val core = DesktopFixture.core()
        val store = MobileStore(core, Dispatchers.Unconfined)
        store.layout.setInterfaceMode(InterfaceMode.TOUCH)
        DesktopFixture.publish(core)
        core.publish(Slice.SLICE_ACTIVITY, update = Update(activity = activity))
        setContent { MobileApp(store, desktopHost = false) }
        waitForIdle()
        return store
    }

    @Test
    fun theInboxShowsCoreSectionsAsDenseRowsWithoutTilesOrUsage() =
        runDesktopComposeUiTest(width = 412, height = 915) {
            val store = launch()
            try {
                val tops =
                    listOf("needs_you", "running", "pinned", "recent").map {
                        onNodeWithTag("inbox-section-$it").getBoundsInRoot().top
                    }
                assertEquals(tops.sorted(), tops, "sections in the core's order")
                shot("inbox-phone")
                for (id in listOf("ask", "fail", "run", "pin", "done")) onNodeWithTag(
                        "activity-row-$id"
                    )
                    .assertIsDisplayed()
                val height = onNodeWithTag("activity-row-ask").getBoundsInRoot().height
                assertTrue(height >= 72.dp && height <= 80.dp, "a two-line row, not $height")

                onNodeWithText("2 need you · 1 running").assertExists()
                onNodeWithText(
                        "Atlas API: Updating the TypeScript client… · 2 agents",
                        useUnmergedTree = true,
                    )
                    .assertExists()
                onNodeWithTag("inbox-badge-answer", useUnmergedTree = true).assertExists()
                onNodeWithTag("inbox-badge-failed", useUnmergedTree = true).assertExists()
                onNodeWithTag("inbox-badge-review", useUnmergedTree = true).assertExists()
                onNodeWithTag("inbox-pinned-fail", useUnmergedTree = true).assertExists()
                onNodeWithTag("inbox-pinned-pin", useUnmergedTree = true).assertExists()
                onAllNodesWithTag("inbox-filter-running").assertCountEquals(0)
                onAllNodesWithText("% left", substring = true).assertCountEquals(0)
                onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("inbox-hidden"))
                onNodeWithText("72 hidden by Inbox rules", useUnmergedTree = true).assertExists()
            } finally {
                store.close()
            }
        }

    @Test
    fun theFilterMenuNarrowsRowsAndKeepsTheirSections() =
        runDesktopComposeUiTest(width = 412, height = 915) {
            val store = launch()
            try {
                onNodeWithTag("chrome-inbox-filter").performClick()
                waitForIdle()
                onNodeWithTag("menu-inbox-status-pinned").performClick()
                waitForIdle()
                onAllNodesWithTag("activity-row-ask").assertCountEquals(0)
                onAllNodesWithTag("activity-row-run").assertCountEquals(0)
                onNodeWithTag("activity-row-fail").assertIsDisplayed()
                onNodeWithTag("activity-row-pin").assertIsDisplayed()
                onNodeWithTag("inbox-section-needs_you").assertExists()
                onNodeWithTag("inbox-section-pinned").assertExists()
                onNodeWithText("Pinned · 2").assertExists()
                shot("inbox-phone-pinned-filter")
            } finally {
                store.close()
            }
        }

    @Test
    fun providerUsageMovesFromTheInboxToTheMoreSheet() =
        runDesktopComposeUiTest(width = 412, height = 915) {
            val store = launch()
            try {
                onNodeWithTag("nav-more").performClick()
                waitForIdle()
                onNodeWithTag("more-providers").assertExists()
            } finally {
                store.close()
            }
        }

    /**
     * Long-presses the "done" row [press] dp from the left; returns where its menu starts, in dp.
     */
    private fun menuLeftAfterPress(press: Float): Float {
        var left = 0f
        runDesktopComposeUiTest(width = 412, height = 915) {
            val store = launch()
            try {
                onNodeWithTag("activity-row-done").performTouchInput {
                    longClick(Offset(press * density, height / 2f))
                }
                waitForIdle()
                val item = onNodeWithTag("menu-inbox-pin-done", useUnmergedTree = true)
                left = item.fetchSemanticsNode().positionInWindow.x / density.density
                shot("inbox-row-menu-${press.toInt()}", root = 1)
            } finally {
                store.close()
            }
        }
        return left
    }

    @Test
    fun aLongPressOpensTheRowMenuAtThePressClearOfBothEdges() {
        val middle = menuLeftAfterPress(100f)
        assertTrue(middle in 95f..110f, "the menu opens at the press, not at $middle dp")
        val left = menuLeftAfterPress(2f)
        assertTrue(left in 16f..20f, "the menu keeps clear of the left edge, not at $left dp")
        // 248 dp wide on a 412 dp window: it moves inward to end 16 dp from the right.
        val right = menuLeftAfterPress(380f)
        assertTrue(right in 144f..152f, "the menu keeps clear of the right edge, not at $right dp")
    }
}

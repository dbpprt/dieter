package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.GetCardRequest
import com.dbpprt.dieter.e2e.IsolatedCore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

/** Long-press gestures against disposable conversations on the isolated daemon. */
class ActivityActionsEndToEndTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain
        .outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test fun activityMenuRenamesPinsAndArchivesBothConversationKinds() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(instrumentation.targetContext.packageName == "com.dbpprt.dieter.e2e")
        val args = InstrumentationRegistry.getArguments()
        val container = (compose.activity.application as DieterApplication).container
        val core = container.core
        fun serverCard(id: String) = runBlocking {
            core.onMachine(IsolatedCore.daemonId(container)) { it.GetCard().execute(GetCardRequest(card_id = id)) }
        }.card!!
        try {
            val connected = IsolatedCore.connect(container)
            val board = connected.boards.values.flatten().first { it.id == args.getString("isolatedBoardId") }
            val cards = listOf(false, true).map { chat ->
                IsolatedCore.createConversation(container, CreateConversationRequest(project_id = board.project_id, board_id = if (chat) "" else board.id, title = "Activity actions ${if (chat) "chat" else "card"}", lane = "running", prompt = "mock-activity-reply", provider = "mock", model = "mock", workspace_mode = "project"), chat)
            }
            cards.forEach { expected -> IsolatedCore.awaitCard(container) { it.id == expected.id && it.runtime == "idle" } }
            compose.onNodeWithTag("nav-activity").performClick()
            compose.onNodeWithContentDescription("Search activity").performClick()
            compose.onNodeWithTag("activity-search").performTextInput("Activity actions")
            cards.forEach { card ->
                longPress(card.id)
                val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                try {
                    File(instrumentation.targetContext.getExternalFilesDir(null), "activity-${card.scope}-menu.png").outputStream().use {
                        check(screenshot.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                } finally {
                    screenshot.recycle()
                }
                compose.onNodeWithTag("activity-rename-${card.id}").performClick()
                val title = "Activity actions renamed ${card.scope}"
                compose.onNodeWithTag("activity-rename-title-${card.id}").performTextReplacement(title)
                compose.onNodeWithTag("activity-rename-confirm-${card.id}").performClick()
                compose.waitUntil(15_000) {
                    compose.onAllNodesWithText(title).fetchSemanticsNodes().isNotEmpty()
                }
                assertEquals(title, serverCard(card.id).title)
                // A context action must not navigate into or acknowledge a transcript.
                compose.onNodeWithTag("nav-activity").assertIsSelected()
                compose.onNodeWithTag("message-input").assertDoesNotExist()
                if (card.scope == "chat") {
                    longPress(card.id)
                    compose.onNodeWithTag("activity-pin-${card.id}").performClick()
                    compose.waitUntil(15_000) { core.workspace.state.value.chats.any { it.id == card.id && it.pinned } }
                    assertTrue(serverCard(card.id).pinned)
                    longPress(card.id)
                    compose.onNodeWithText("Unpin").assertIsDisplayed()
                    compose.onNodeWithTag("activity-pin-${card.id}").performClick()
                    compose.waitUntil(15_000) { core.workspace.state.value.chats.any { it.id == card.id && !it.pinned } }
                }
                longPress(card.id)
                compose.onNodeWithTag("activity-archive-${card.id}").performClick()
                compose.waitUntil(15_000) {
                    compose.onAllNodesWithTag("activity-row-${card.id}").fetchSemanticsNodes().isEmpty()
                }
                assertTrue(serverCard(card.id).archived)
            }
            compose.onNodeWithText("All quiet here").assertDoesNotExist() // The search remains active.
            compose.onNodeWithText("No matching activity").assertIsDisplayed()
        } finally {
            IsolatedCore.disconnect(container)
        }
    }

    private fun longPress(id: String) {
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-$id"))
        compose.onNodeWithTag("activity-row-$id").performTouchInput { longClick() }
        compose.onNodeWithTag("activity-rename-$id").assertIsDisplayed().assertIsEnabled()
    }
}

package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.v1.CreateConversationRequest
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
        val endpoint = DieterEndpoint("activity-actions", "Activity actions fixture", "127.0.0.1",
            requireNotNull(args.getString("isolatedGatewayPort")).toInt(), false)
        val container = (compose.activity.application as DieterApplication).container
        val manager = container.connectionManager
        val repository = container.repository
        repository.setAccessToken(endpoint, requireNotNull(args.getString("isolatedGatewayToken")))
        manager.updateEndpoints(listOf(endpoint), selectedGatewayId = endpoint.id)
        manager.connect()
        manager.onAppForegrounded()
        try {
            val connected = runBlocking { withTimeout(30_000) { manager.state.first {
                it.phase == ConnectionPhase.CONNECTED && it.boards.isNotEmpty() &&
                    it.endpointConnections.any { machine -> machine.daemonId == args.getString("isolatedMachineId") && machine.online }
            } } }
            val board = connected.boards.first { it.id == args.getString("isolatedBoardId") }
            val cards = runBlocking {
                listOf(false, true).map { chat ->
                    repository.createConversation(CreateConversationRequest.newBuilder()
                        .setProjectId(board.projectId).setBoardId(if (chat) "" else board.id)
                        .setTitle("Activity actions ${if (chat) "chat" else "card"}")
                        .setLane("running").setPrompt("mock-activity-reply")
                        .setProvider("mock").setModel("mock").setWorkspaceMode("project").build(), chat)
                }
            }
            runBlocking {
                manager.refreshMachineDirectory(includeArchivedChats = true)
                withTimeout(30_000) { manager.state.first { current -> cards.all { expected ->
                    (current.cards + current.chats).any { it.id == expected.id && it.runtime == "idle" }
                } } }
            }
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
                assertEquals(title, runBlocking { repository.card(card.id).card.title })
                // A context action must not navigate into or acknowledge a transcript.
                compose.onNodeWithTag("nav-activity").assertIsSelected()
                compose.onNodeWithTag("message-input").assertDoesNotExist()
                if (card.scope == "chat") {
                    longPress(card.id)
                    compose.onNodeWithTag("activity-pin-${card.id}").performClick()
                    compose.waitUntil(15_000) { manager.state.value.chats.any { it.id == card.id && it.pinned } }
                    assertTrue(runBlocking { repository.card(card.id).card.pinned })
                    longPress(card.id)
                    compose.onNodeWithText("Unpin").assertIsDisplayed()
                    compose.onNodeWithTag("activity-pin-${card.id}").performClick()
                    compose.waitUntil(15_000) { manager.state.value.chats.any { it.id == card.id && !it.pinned } }
                }
                longPress(card.id)
                compose.onNodeWithTag("activity-archive-${card.id}").performClick()
                compose.waitUntil(15_000) {
                    compose.onAllNodesWithTag("activity-row-${card.id}").fetchSemanticsNodes().isEmpty()
                }
                assertTrue(runBlocking { repository.card(card.id).card.archived })
            }
            compose.onNodeWithText("All quiet here").assertDoesNotExist() // The search remains active.
            compose.onNodeWithText("No matching activity").assertIsDisplayed()
        } finally {
            manager.disconnect()
        }
    }

    private fun longPress(id: String) {
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-$id"))
        compose.onNodeWithTag("activity-row-$id").performTouchInput { longClick() }
        compose.onNodeWithTag("activity-rename-$id").assertIsDisplayed().assertIsEnabled()
    }
}

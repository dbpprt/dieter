package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.v1.CreateConversationRequest
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Real Activity → isolated gateway → conversation viewport coverage. */
@RunWith(AndroidJUnit4::class)
class ConversationJumpToLatestEndToEndTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

    @Test
    fun conversationOffersAndUsesJumpToLatestOnTheVisibleEmulator() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        require(token.isNotBlank()) { "Pass isolatedGatewayToken for the isolated gateway" }
        val port = arguments.getString("isolatedGatewayPort")?.toIntOrNull() ?: 14243
        val endpoint = DieterEndpoint(
            id = "android_conversation_scroll_e2e",
            label = "Isolated conversation gateway",
            host = "127.0.0.1",
            port = port,
        )
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val manager = container.connectionManager
        container.repository.setAccessToken(endpoint, token)
        manager.updateEndpoints(listOf(endpoint), selectedGatewayId = endpoint.id)
        manager.connect()
        manager.onAppForegrounded()

        val connected = runBlocking {
            withTimeout(30_000) {
                manager.state.first { state ->
                    state.phase == ConnectionPhase.CONNECTED && state.projects.isNotEmpty() && state.boards.isNotEmpty()
                }
            }
        }
        assertNotNull("Connection failed: ${manager.state.value.error}", connected)

        val board = connected.boards.first { candidate ->
            candidate.lanesList.any { lane -> lane.id.equals("todo", true) || lane.name.equals("todo", true) }
        }
        val todoLane = board.lanesList.first { lane ->
            lane.id.equals("todo", true) || lane.name.equals("todo", true)
        }.id
        val project = connected.projects.first { it.id == board.projectId }
        val harness = runBlocking { container.repository.harnesses().harnessesList.first() }
        val fixture = runBlocking {
            container.repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(project.id)
                    .setBoardId(board.id)
                    .setLane(todoLane)
                    .setTitle("Android jump-to-latest E2E ${UUID.randomUUID().toString().take(8)}")
                    .setPrompt((1..100).joinToString("\n") { "Unsent conversation fixture line $it." })
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setClientId("android-conversation-scroll-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )
        }

        try {
            runBlocking { manager.refreshMachineDirectory(includeArchivedChats = true) }
            manager.onAppForegrounded(project.id)
            runBlocking {
                withTimeout(10_000) { manager.state.first { state -> state.cards.any { it.id == fixture.id } } }
            }
            container.requestOpen(cardId = fixture.id)
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("conversation-list").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("conversation-list").performTouchInput { swipeDown(durationMillis = 500) }
            composeRule.waitUntil(5_000) {
                composeRule.onAllNodesWithTag("jump-to-latest").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("jump-to-latest").assertIsDisplayed()

            val context = instrumentation.targetContext
            val screenshotDirectory = arguments.getString("additionalTestOutputDir")
                ?.takeIf(String::isNotBlank)
                ?.let(::File)
                ?: requireNotNull(context.getExternalFilesDir(null))
            screenshotDirectory.mkdirs()
            val screenshot = File(screenshotDirectory, "conversation-jump-to-latest-e2e.png")
            screenshot.outputStream().use { output ->
                composeRule.onRoot()
                    .captureToImage()
                    .asAndroidBitmap()
                    .compress(Bitmap.CompressFormat.PNG, 100, output)
            }

            composeRule.onNodeWithTag("jump-to-latest").performClick()
            composeRule.waitForIdle()
            assertTrue(composeRule.onAllNodesWithTag("jump-to-latest").fetchSemanticsNodes().isEmpty())
        } finally {
            runBlocking { container.repository.archiveCard(fixture.id, true) }
        }
    }
}

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
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.e2e.IsolatedCore
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
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
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun conversationOffersAndUsesJumpToLatestOnTheVisibleEmulator() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val connected = IsolatedCore.connect(container)
        val board = connected.boards.values.flatten().first { candidate ->
            candidate.lanes.any { lane -> lane.id.equals("todo", true) || lane.name.equals("todo", true) }
        }
        val todoLane = board.lanes.first { lane ->
            lane.id.equals("todo", true) || lane.name.equals("todo", true)
        }.id
        val project = connected.projects.first { it.id == board.project_id }
        val fixture = IsolatedCore.createConversation(
            container,
            CreateConversationRequest(project_id = project.id, board_id = board.id, lane = todoLane, title = "Android jump-to-latest E2E ${UUID.randomUUID().toString().take(8)}", prompt = (1..100).joinToString("\n") { "Unsent conversation fixture line $it." }, provider = "mock", model = "mock", defer_start = true, workspace_mode = "project"),
            chat = false,
        )

        try {
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
            runBlocking { runCatching { container.core.onBoard { archive(fixture.id) } } }
            IsolatedCore.disconnect(container)
        }
    }
}

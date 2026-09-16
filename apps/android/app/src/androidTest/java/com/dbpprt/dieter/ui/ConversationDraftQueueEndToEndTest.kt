package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.StartCardRequest
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Visible Activity coverage for conversation-owned drafts and queue recall. */
@RunWith(AndroidJUnit4::class)
class ConversationDraftQueueEndToEndTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

    @Test
    fun draftsSurviveNavigationAndQueuedEditRestoresTheServerMessage() {
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val origin = DieterEndpoint(
            id = "android_composer_queue_e2e",
            label = "Isolated composer gateway",
            host = arguments.getString("isolatedGatewayHost")?.takeIf(String::isNotBlank) ?: "10.0.2.2",
            port = arguments.getString("isolatedGatewayPort")?.toIntOrNull() ?: 14243,
            secure = false,
        )
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val manager = container.connectionManager
        val repository = container.repository
        repository.setAccessToken(origin, token)
        manager.updateEndpoints(listOf(origin), selectedGatewayId = origin.id)
        manager.connect()
        manager.onAppForegrounded()
        val connected = runBlocking {
            withTimeout(30_000) {
                manager.state.first { state ->
                    state.phase == ConnectionPhase.CONNECTED && state.projects.isNotEmpty() &&
                        state.boards.isNotEmpty() && state.harnesses.isNotEmpty()
                }
            }
        }
        val board = connected.boards.first()
        val project = connected.projects.first { it.id == board.projectId }
        val harness = connected.harnesses.first { it.id == "mock" }
        val createdIds = mutableListOf<String>()
        var queuedMessageId = ""
        try {
            val first = runBlocking { createDeferredChat(repository, project.id, harness.id, harness.defaultModel, "First draft") }
            val second = runBlocking { createDeferredChat(repository, project.id, harness.id, harness.defaultModel, "Second draft") }
            createdIds += first.id
            createdIds += second.id
            runBlocking { manager.refreshMachineDirectory(includeArchivedChats = true) }
            runBlocking {
                withTimeout(15_000) {
                    manager.state.first { state ->
                        state.chats.any { it.id == first.id } && state.chats.any { it.id == second.id }
                    }
                }
            }
            manager.onAppForegrounded(project.id)

            container.requestOpen(cardId = first.id)
            composeRule.waitUntil(20_000) { composeRule.onAllNodesWithTag("message-input").fetchSemanticsNodes().isNotEmpty() }
            visibleNodeWithTag("message-input").performTextInput("draft for first")
            composeRule.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("chat-${second.id}").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("chat-${second.id}").performClick()
            composeRule.waitUntil(10_000) {
                runCatching {
                    visibleNodeWithTag("message-input").assert(
                        SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")),
                    )
                }.isSuccess
            }
            visibleNodeWithTag("message-input").performTextInput("draft for second")
            composeRule.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("chat-${first.id}").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("chat-${first.id}").performClick()
            composeRule.waitUntil(10_000) {
                runCatching { visibleNodeWithTag("message-input").assertTextEquals("draft for first") }.isSuccess
            }
            visibleNodeWithTag("message-input").assertTextEquals("draft for first")
            composeRule.activityRule.scenario.recreate()
            composeRule.waitUntil(15_000) {
                runCatching { visibleNodeWithTag("message-input").assertTextEquals("draft for first") }.isSuccess
            }
            capture("conversation-draft-restored-e2e.png")

            val queueCard = runBlocking {
                repository.createConversation(
                    CreateConversationRequest.newBuilder()
                        .setProjectId(project.id)
                        .setBoardId(board.id)
                        .setLane("todo")
                        .setTitle("Queue recall ${UUID.randomUUID().toString().take(8)}")
                        .setPrompt("mock-queue-hold")
                        .setProvider(harness.id)
                        .setModel(harness.defaultModel)
                        .setDeferStart(true)
                        .setWorkspaceMode("project")
                        .build(),
                    chat = false,
                )
            }
            createdIds += queueCard.id
            runBlocking {
                repository.startCard(
                    StartCardRequest.newBuilder()
                        .setCardId(queueCard.id)
                        .setClientId("android-queue-ui-e2e")
                        .setCommandId(UUID.randomUUID().toString())
                        .build(),
                )
                withTimeout(15_000) {
                    repository.watchConversation(queueCard.id, 8).first { snapshot ->
                        snapshot.conversation.status == "running" || snapshot.detail.card.runtime == "running"
                    }
                }
                val messageId = "msg_android_queue_ui_${UUID.randomUUID().toString().replace("-", "").take(12)}"
                val queued = repository.sendMessage(
                    SendMessageRequest.newBuilder()
                        .setCardId(queueCard.id)
                        .addParts(MessagePart.newBuilder().setType("text").setText("queued text to edit"))
                        .setProvider(harness.id)
                        .setModel(harness.defaultModel)
                        .setEffort(queueCard.effort)
                        .putAllProviderOptions(queueCard.providerOptionsMap)
                        .setClientId("android-queue-ui-e2e")
                        .setCommandId(UUID.randomUUID().toString())
                        .setMessageId(messageId)
                        .build(),
                )
                assertTrue(queued.queued)
                queuedMessageId = queued.messageId
                manager.refreshMachineDirectory(includeArchivedChats = true)
                withTimeout(15_000) {
                    manager.state.first { state ->
                        (state.cards + state.chats).any { it.id == queueCard.id }
                    }
                }
            }
            container.requestOpen(cardId = queueCard.id)
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("edit-queued-message-$queuedMessageId").fetchSemanticsNodes().isNotEmpty()
            }
            clickVisibleNodeWithTag("edit-queued-message-$queuedMessageId")
            composeRule.waitUntil(15_000) {
                runCatching { visibleNodeWithTag("message-input").assertTextEquals("queued text to edit") }.isSuccess
            }
            visibleNodeWithTag("message-input").assertTextEquals("queued text to edit")
            assertTrue(runBlocking { repository.conversation(queueCard.id).conversation.queueCount == 0 })
            capture("queued-message-restored-to-composer-e2e.png")
        } finally {
            createdIds.asReversed().forEach { id ->
                runBlocking {
                    runCatching { repository.cancelCard(id) }
                    runCatching { repository.archiveCard(id, true) }
                }
            }
            manager.updateEndpoints(DIETER_ENDPOINTS)
            manager.connect()
        }
    }

    private suspend fun createDeferredChat(
        repository: com.dbpprt.dieter.data.DieterRepository,
        projectId: String,
        provider: String,
        model: String,
        title: String,
    ) = repository.createConversation(
        CreateConversationRequest.newBuilder()
            .setProjectId(projectId)
            .setTitle("$title ${UUID.randomUUID().toString().take(8)}")
            .setPrompt("Deferred composer draft fixture")
            .setProvider(provider)
            .setModel(model)
            .setDeferStart(true)
            .setWorkspaceMode("project")
            .build(),
        chat = true,
    )

    private fun capture(name: String) {
        val arguments = InstrumentationRegistry.getArguments()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = arguments.getString("additionalTestOutputDir")
            ?.takeIf(String::isNotBlank)?.let(::File)
            ?: requireNotNull(context.getExternalFilesDir(null))
        directory.mkdirs()
        File(directory, name).outputStream().use { output ->
            composeRule.onRoot().captureToImage().asAndroidBitmap().compress(
                android.graphics.Bitmap.CompressFormat.PNG,
                100,
                output,
            )
        }
    }

    private fun clickVisibleNodeWithTag(tag: String) {
        visibleNodeWithTag(tag).performClick()
    }

    private fun visibleNodeWithTag(tag: String): SemanticsNodeInteraction {
        val width = composeRule.activity.resources.displayMetrics.widthPixels.toFloat()
        val nodes = composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes()
        val index = nodes.indexOfFirst { node ->
            node.boundsInRoot.right > 0f && node.boundsInRoot.left < width
        }
        assertTrue("No visible node found for $tag", index >= 0)
        return composeRule.onAllNodesWithTag(tag)[index]
    }
}

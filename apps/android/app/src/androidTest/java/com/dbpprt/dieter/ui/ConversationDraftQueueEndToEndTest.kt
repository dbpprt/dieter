package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
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
import com.dbpprt.dieter.DieterContainer
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.SendMessageRequest
import com.dbpprt.dieter.e2e.IsolatedCore
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
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun draftsSurviveNavigationAndQueuedEditRestoresTheServerMessage() {
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val core = container.core
        val connected = IsolatedCore.connect(container)
        val board = connected.boards.values.flatten().first()
        val project = connected.projects.first { it.id == board.project_id }
        val daemonId = project.checkouts.first { !it.detached }.daemon_id
        val harness = IsolatedCore.harnesses(container, daemonId).first { it.id == "mock" }
        val createdIds = mutableListOf<String>()
        var queuedMessageId = ""
        try {
            val first = createDeferredChat(container, project.id, harness.id, harness.default_model, "First draft")
            val second = createDeferredChat(container, project.id, harness.id, harness.default_model, "Second draft")
            createdIds += first.id
            createdIds += second.id

            // Real pager gestures still select routes; detail layout changes
            // must not be interpreted as another swipe.
            composeRule.onNodeWithTag("nav-activity").assertIsSelected()
            composeRule.onRoot().performTouchInput { swipeLeft(durationMillis = 500) }
            composeRule.onNodeWithTag("nav-board").assertIsSelected()
            composeRule.onRoot().performTouchInput { swipeRight(durationMillis = 500) }
            composeRule.onNodeWithTag("nav-activity").assertIsSelected()
            composeRule.onNodeWithTag("primary-navigation-pager")
                .performSemanticsAction(SemanticsActions.PageRight) { it() }
            composeRule.onNodeWithTag("nav-board").assertIsSelected()
            composeRule.onNodeWithTag("primary-navigation-pager")
                .performSemanticsAction(SemanticsActions.ScrollBy) { it(-100f, 0f) }
            composeRule.onNodeWithTag("nav-activity").assertIsSelected()
            container.requestOpen(cardId = first.id)
            composeRule.waitUntil(20_000) { composeRule.onAllNodesWithTag("message-input").fetchSemanticsNodes().isNotEmpty() }
            visibleNodeWithTag("message-input").performTextInput("draft for first")
            // Keystroke by keystroke, the field never waits on the core or rewinds to an older draft.
            for (character in ", typed fast") visibleNodeWithTag("message-input").performTextInput(character.toString())
            visibleNodeWithTag("message-input").assertTextEquals(FIRST_DRAFT)
            composeRule.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("chat-${second.id}").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("nav-chats").assertIsSelected()
            composeRule.onNodeWithTag("chat-${second.id}").assertIsDisplayed().performClick()
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
            composeRule.onNodeWithTag("nav-chats").assertIsSelected()
            composeRule.onNodeWithTag("chat-${first.id}").assertIsDisplayed().performClick()
            composeRule.waitUntil(10_000) {
                runCatching { visibleNodeWithTag("message-input").assertTextEquals(FIRST_DRAFT) }.isSuccess
            }
            visibleNodeWithTag("message-input").assertTextEquals(FIRST_DRAFT)
            composeRule.activityRule.scenario.recreate()
            composeRule.waitUntil(15_000) {
                runCatching { visibleNodeWithTag("message-input").assertTextEquals(FIRST_DRAFT) }.isSuccess
            }
            capture("conversation-draft-restored-e2e.png")

            val queueCard = IsolatedCore.createConversation(
                container,
                CreateConversationRequest(project_id = project.id, board_id = board.id, lane = "todo", title = "Queue recall ${UUID.randomUUID().toString().take(8)}", prompt = "mock-queue-hold", provider = harness.id, model = harness.default_model, defer_start = true, workspace_mode = "project"),
                chat = false,
            )
            createdIds += queueCard.id
            runBlocking {
                core.startCard(queueCard.id)
                withTimeout(15_000) { core.workspace.state.first { it.card(queueCard.id)?.runtime == "running" } }
                val messageId = "msg_android_queue_ui_${UUID.randomUUID().toString().replace("-", "").take(12)}"
                val queued = core.onMachine(daemonId) {
                    it.SendMessage().execute(
                        SendMessageRequest(card_id = queueCard.id, parts = listOf(MessagePart(type = "text", text = "queued text to edit")), provider = harness.id, model = harness.default_model, effort = queueCard.effort, provider_options = queueCard.provider_options, client_id = "android-queue-ui-e2e", command_id = UUID.randomUUID().toString(), message_id = messageId),
                    )
                }
                assertTrue(queued.queued)
                queuedMessageId = queued.message_id
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
            assertTrue(IsolatedCore.conversation(container, queueCard.id, daemonId).conversation?.queue.orEmpty().isEmpty())
            capture("queued-message-restored-to-composer-e2e.png")
        } catch (error: Throwable) {
            runCatching { capture("conversation-draft-queue-failure.png") }
            throw error
        } finally {
            createdIds.asReversed().forEach { id ->
                runBlocking {
                    runCatching { core.onBoard { cancel(id) } }
                    runCatching { core.onBoard { archive(id) } }
                }
            }
            IsolatedCore.disconnect(container)
        }
    }

    private companion object {
        const val FIRST_DRAFT = "draft for first, typed fast"
    }

    private fun createDeferredChat(
        container: DieterContainer,
        projectId: String,
        provider: String,
        model: String,
        title: String,
    ) = IsolatedCore.createConversation(
        container,
        CreateConversationRequest(project_id = projectId, title = "$title ${UUID.randomUUID().toString().take(8)}", prompt = "Deferred composer draft fixture", provider = provider, model = model, defer_start = true, workspace_mode = "project"),
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

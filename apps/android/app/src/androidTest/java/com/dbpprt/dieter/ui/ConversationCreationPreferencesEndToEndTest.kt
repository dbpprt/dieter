package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import com.dbpprt.dieter.v1.MessagePart
import com.google.protobuf.ByteString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.settings.ConversationCreationPreferences
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Real Activity -> isolated gateway coverage for card-to-chat create defaults. */
@RunWith(AndroidJUnit4::class)
class ConversationCreationPreferencesEndToEndTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun submittedCardSelectionIsPreselectedForTheNextChat() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val endpoint = DieterEndpoint(
            id = "android_creation_preferences_e2e",
            label = "Isolated creation preferences gateway",
            host = arguments.getString("isolatedGatewayHost")?.takeIf(String::isNotBlank) ?: "10.0.2.2",
            port = arguments.getString("isolatedGatewayPort")?.toIntOrNull() ?: 14243,
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
                    state.phase == ConnectionPhase.CONNECTED && state.projects.isNotEmpty() &&
                        state.boards.isNotEmpty() && state.harnesses.any { it.modelsCount > 0 } &&
                        state.harnessesEndpointId == state.endpoint?.id
                }
            }
        }
        assertNotNull("Connection failed: ${manager.state.value.error}", connected)
        val board = connected.boards.first()
        val project = connected.projects.first { it.id == board.projectId }
        val targetHarness = connected.harnesses.first { harness -> harness.modelsList.any { model ->
            providerOptionsForModel(harness, model.id).any { it.type == "boolean" }
        } }
        val targetModel = targetHarness.modelsList.last { model ->
            providerOptionsForModel(targetHarness, model.id).any { it.type == "boolean" }
        }
        val targetOption = providerOptionsForModel(targetHarness, targetModel.id).first { it.type == "boolean" }
        val optionValue = (!targetOption.defaultValue.equals("true", ignoreCase = true)).toString()
        val targetEffort = targetHarness.effortOptionsFor(targetModel.id).lastOrNull()
        val preferences = container.appPreferences
        val original = preferences.conversationCreation.value
        val attachment = MessagePart.newBuilder().setType("file").setFilename("draft.txt")
            .setMediaType("text/plain").setData(ByteString.copyFromUtf8("Draft attachment")).build()
        val fixtureTitle = "Android creation defaults ${UUID.randomUUID().toString().take(8)}"

        try {
            runBlocking {
                manager.ensureCheckoutRoute(project.id, requireNotNull(project.checkoutsList.firstOrNull()).id)
            }
            preferences.setConversationCreationPreferences(
                ConversationCreationPreferences(
                    provider = targetHarness.id,
                    model = targetModel.id,
                    effort = targetEffort?.id.orEmpty(),
                    workspaceMode = "worktree",
                ),
            )
            val label = runBlocking {
                container.repository.createBoardLabel(board.id, "Draft regression", "#5588aa").labelsList.last()
            }
            manager.onAppForegrounded(project.id)
            composeRule.waitForIdle()

            composeRule.onNodeWithTag("nav-board").performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("space-project-${project.id}").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNode(
                androidx.compose.ui.test.hasText(project.name) and androidx.compose.ui.test.hasClickAction() and
                    androidx.compose.ui.test.hasAnyAncestor(androidx.compose.ui.test.hasTestTag("space-project-${project.id}")),
            ).performScrollTo().performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("new-card").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("quick-task-popover").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("quick-task-story").performTextInput("Preserve the quick task draft")
            capture("quick-task-before-options.png")
            composeRule.onNodeWithText("More options").performScrollTo().performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("conversation-title").fetchSemanticsNodes().isNotEmpty()
            }
            capture("quick-task-after-options.png")
            composeRule.onNodeWithTag("conversation-prompt").assertTextContains("Preserve the quick task draft")
            composeRule.onNodeWithTag("conversation-title").performScrollTo().assertIsDisplayed()

            cardNode("agent", hasTestTag("creation-provider")).assertTextEquals(targetHarness.name)
            cardNode("agent", hasTestTag("creation-model")).assertTextEquals(targetModel.name)
            targetEffort?.let { cardNode("agent", hasTestTag("creation-effort")).assertTextEquals(it.name) }
            cardNode("agent", hasTestTag("provider-option-${targetOption.id}")).performClick()
            cardNode("workspace", hasTestTag("workspace-mode-project")).performClick().assertIsSelected()
            cardNode("lane", hasTestTag("create-lane-todo")).performClick()
            composeRule.onNodeWithTag("conversation-title").performScrollTo().performTextReplacement(fixtureTitle)

            cardNode("labels", hasText(label.name)).performClick()
            // Supply the same MessagePart produced by the Android file picker;
            // the actual editor, recreation and daemon submission remain real.
            composeRule.runOnIdle {
                ViewModelProvider(composeRule.activity)[DieterViewModel::class.java]
                    .cardCreationDraft().attachments += attachment
            }
            // Both toolbar Back and system Back dispose the full editor. The
            // shared board draft must still own the text and selected settings.
            composeRule.onNodeWithContentDescription("Back").performClick()
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.onNodeWithTag("quick-task-story").assertTextContains("Preserve the quick task draft")
            composeRule.onNodeWithContentDescription("Close quick task").performClick()
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.activityRule.scenario.recreate()
            composeRule.onNodeWithTag("quick-task-story").assertTextContains("Preserve the quick task draft")
            composeRule.onNodeWithText("More options").performScrollTo().performClick()
            composeRule.onNodeWithTag("conversation-title").assertTextContains(fixtureTitle)
            composeRule.onNodeWithTag("conversation-prompt").performTextReplacement("Edited task\nKeep every line")
            composeRule.activityRule.scenario.recreate()
            composeRule.onNodeWithTag("conversation-prompt").assertTextContains("Edited task\nKeep every line")
            cardNode("attachments", hasText("draft.txt")).assertIsDisplayed()
            cardNode("labels", hasText(label.name)).assertIsSelected()
            cardNode("workspace", hasTestTag("workspace-mode-project")).assertIsSelected()
            cardNode("agent", hasTestTag("creation-provider")).assertTextEquals(targetHarness.name)
            cardNode("agent", hasTestTag("creation-model")).assertTextEquals(targetModel.name)
            targetEffort?.let { cardNode("agent", hasTestTag("creation-effort")).assertTextEquals(it.name) }
            composeRule.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.onNodeWithTag("quick-task-story").assertTextContains("Edited task\nKeep every line")
            composeRule.onNodeWithText("More options").performScrollTo().performClick()
            composeRule.onNodeWithTag("conversation-title").assertTextContains(fixtureTitle)

            capture("creation-preferences-card-selected.png")
            composeRule.onAllNodesWithText("Save")[0].performClick()
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodesWithTag("new-card").fetchSemanticsNodes().isNotEmpty()
            }
            val created = runBlocking {
                withTimeout(30_000) {
                    manager.state.first { value -> value.cards.any {
                        it.title == fixtureTitle && it.ownerDaemonId.isNotBlank()
                    } }.cards.single { it.title == fixtureTitle && it.ownerDaemonId.isNotBlank() }
                }
            }
            assertEquals("Edited task\nKeep every line", created.initialPrompt)
            assertEquals(targetHarness.id, created.provider)
            assertEquals(targetModel.id, created.model)
            assertEquals(targetEffort?.id.orEmpty(), created.effort)
            assertEquals("project", created.workspaceMode)
            assertEquals(optionValue, created.providerOptionsMap[targetOption.id])
            assertEquals("todo", created.lane)
            assertEquals(project.checkoutsList.first().id, created.checkoutId)
            assertEquals(listOf(label.id), created.labelIdsList)
            val snapshot = runBlocking { container.repository.conversation(created.id) }
            assertEquals(listOf(attachment), snapshot.conversation.draftAttachmentsList)
            composeRule.onNodeWithTag("new-card").performClick()
            assertEquals("", composeRule.onNodeWithTag("quick-task-story").fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            composeRule.onNodeWithContentDescription("Close quick task").performClick()
            val expected = ConversationCreationPreferences(
                provider = targetHarness.id,
                model = targetModel.id,
                effort = targetEffort?.id.orEmpty(),
                workspaceMode = "project",
            )
            assertEquals(expected, preferences.conversationCreation.value)

            // A user may return from More options and use Add task instead
            // of Save. That path must submit the same expanded draft fields.
            val quickTitle = "$fixtureTitle quick"
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.onNodeWithTag("quick-task-story").performTextInput("Second task body")
            composeRule.onNodeWithText("More options").performScrollTo().performClick()
            composeRule.onNodeWithTag("conversation-title").performTextReplacement(quickTitle)
            cardNode("agent", hasTestTag("provider-option-${targetOption.id}")).performClick()
            cardNode("labels", hasText(label.name)).performClick()
            composeRule.runOnIdle {
                ViewModelProvider(composeRule.activity)[DieterViewModel::class.java]
                    .cardCreationDraft().attachments += attachment
            }
            composeRule.onNodeWithContentDescription("Back").performClick()
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.onNodeWithTag("quick-task-create").performClick()
            val quickCreated = runBlocking {
                withTimeout(30_000) {
                    manager.state.first { value -> value.cards.any {
                        it.title == quickTitle && it.ownerDaemonId.isNotBlank()
                    } }.cards.single { it.title == quickTitle && it.ownerDaemonId.isNotBlank() }
                }
            }
            assertEquals("Second task body", quickCreated.initialPrompt)
            assertEquals(listOf(label.id), quickCreated.labelIdsList)
            assertEquals(targetHarness.id, quickCreated.provider)
            assertEquals(targetModel.id, quickCreated.model)
            assertEquals(targetEffort?.id.orEmpty(), quickCreated.effort)
            assertEquals("project", quickCreated.workspaceMode)
            assertEquals(optionValue, quickCreated.providerOptionsMap[targetOption.id])
            assertEquals("todo", quickCreated.lane)
            assertEquals(listOf(attachment), runBlocking {
                container.repository.conversation(quickCreated.id).conversation.draftAttachmentsList
            })

            // Reproduce opening a project chat while the app is currently
            // routed to a different machine. The creation screen must route
            // back to this project's checkout before exposing its catalog.
            val expectedAlternateDaemon = arguments.getString("isolatedSecondDaemon").orEmpty()
            val otherMachine = if (expectedAlternateDaemon.isBlank()) {
                connected.endpointConnections.firstOrNull { candidate ->
                    candidate.online && candidate.daemonId != null &&
                        candidate.daemonId != project.checkoutsList.firstOrNull()?.daemonId
                }
            } else {
                runBlocking {
                    withTimeout(20_000) {
                        manager.state.first { state ->
                            state.endpointConnections.any { candidate ->
                                candidate.online && candidate.daemonId == expectedAlternateDaemon
                            }
                        }.endpointConnections.first { it.online && it.daemonId == expectedAlternateDaemon }
                    }
                }
            }
            otherMachine?.let {
                runBlocking { manager.ensureMachineRoute(otherMachine.id) }
                runBlocking {
                    withTimeout(20_000) {
                        manager.state.first { state ->
                            state.harnessesEndpointId == otherMachine.id && state.harnesses.any { it.modelsCount > 0 }
                        }
                    }
                }
            }

            composeRule.onNodeWithTag("nav-chats").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("new-chat").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("new-chat").performClick()
            composeRule.waitUntil(20_000) {
                manager.state.value.harnessesEndpointId ==
                    manager.state.value.endpointConnections.firstOrNull {
                        it.daemonId == project.checkoutsList.firstOrNull()?.daemonId
                    }?.id &&
                    composeRule.onAllNodesWithTag("creation-model").fetchSemanticsNodes().isNotEmpty() &&
                    composeRule.onAllNodesWithTag("conversation-prompt").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("conversation-prompt").assertIsDisplayed()
            composeRule.onNodeWithTag("creation-provider").assertTextEquals(targetHarness.name)
            composeRule.onNodeWithTag("creation-model").assertTextEquals(targetModel.name)
            targetEffort?.let { composeRule.onNodeWithTag("creation-effort").assertTextEquals(it.name) }
            composeRule.onNodeWithTag("workspace-mode-project").assertIsSelected()
            capture("creation-preferences-chat-restored.png")
        } finally {
            preferences.setConversationCreationPreferences(original)
        }
    }

    private fun cardNode(section: String, matcher: SemanticsMatcher): SemanticsNodeInteraction {
        composeRule.onNodeWithTag("card-section-$section").performScrollTo().assertIsDisplayed()
        return composeRule.onNode(matcher).performScrollTo().assertIsDisplayed()
    }

    private fun capture(name: String) {
        val arguments = InstrumentationRegistry.getArguments()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = arguments.getString("additionalTestOutputDir")
            ?.takeIf(String::isNotBlank)?.let(::File)
            ?: requireNotNull(context.getExternalFilesDir(null))
        directory.mkdirs()
        File(directory, name).outputStream().use { output ->
            composeRule.waitForIdle()
            requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()).compress(
                android.graphics.Bitmap.CompressFormat.PNG,
                100,
                output,
            )
        }
    }
}

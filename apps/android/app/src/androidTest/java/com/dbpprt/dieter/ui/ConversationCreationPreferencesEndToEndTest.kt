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
import com.dbpprt.dieter.api.v1.MessagePart
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.core.selection.Selections
import com.dbpprt.dieter.e2e.IsolatedCore
import okio.ByteString.Companion.encodeUtf8
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
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val core = container.core
        val connected = IsolatedCore.connect(container)
        val board = connected.boards.values.flatten().first()
        val project = connected.projects.first { it.id == board.project_id }
        val checkout = requireNotNull(project.checkouts.firstOrNull())
        val harnesses = IsolatedCore.harnesses(container, checkout.daemon_id)
        val targetHarness = harnesses.first { harness -> harness.models.any { model ->
            Selections.options(harness, model.id).any { it.type == "boolean" }
        } }
        val targetModel = targetHarness.models.last { model ->
            Selections.options(targetHarness, model.id).any { it.type == "boolean" }
        }
        val targetOption = Selections.options(targetHarness, targetModel.id).first { it.type == "boolean" }
        val optionValue = (!targetOption.default_value.equals("true", ignoreCase = true)).toString()
        val targetEffort = AgentControls(HarnessSelection(targetHarness.id, targetModel.id), listOf(targetHarness)).efforts.lastOrNull()
        val original = runBlocking { core.onCore { core.creation.state.value } }
        val attachment = MessagePart(type = "file", filename = "draft.txt", media_type = "text/plain", data_ = "Draft attachment".encodeUtf8())
        val fixtureTitle = "Android creation defaults ${UUID.randomUUID().toString().take(8)}"
        fun model() = ViewModelProvider(composeRule.activity)[DieterViewModel::class.java]

        try {
            runBlocking {
                core.onCore {
                    core.creation.remember(HarnessSelection(targetHarness.id, targetModel.id, targetEffort?.id.orEmpty()), WorkspaceMode.WORKTREE)
                }
            }
            val label = runBlocking { core.admin.createLabel(board.id, "Draft regression", "#5588aa").labels.last() }
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
                model().activeCapture!!.edit { TaskDrafts.admit(it, attachment) }
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
            val created = IsolatedCore.awaitCard(container) { it.title == fixtureTitle && it.owner_daemon_id.isNotBlank() }
            assertEquals("Edited task\nKeep every line", created.initial_prompt)
            assertEquals(targetHarness.id, created.provider)
            assertEquals(targetModel.id, created.model)
            assertEquals(targetEffort?.id.orEmpty(), created.effort)
            assertEquals("project", created.workspace_mode)
            assertEquals(optionValue, created.provider_options[targetOption.id])
            assertEquals("todo", created.lane)
            assertEquals(project.checkouts.first().id, created.checkout_id)
            assertEquals(listOf(label.id), created.label_ids)
            val snapshot = IsolatedCore.conversation(container, created.id, created.owner_daemon_id)
            assertEquals(listOf(attachment), snapshot.conversation?.draft_attachments)
            composeRule.onNodeWithTag("new-card").performClick()
            assertEquals("", composeRule.onNodeWithTag("quick-task-story").fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            composeRule.onNodeWithContentDescription("Close quick task").performClick()
            val remembered = runBlocking { core.onCore { core.creation.state.value } }
            assertEquals(targetHarness.id, remembered.provider)
            assertEquals(targetModel.id, remembered.model)
            assertEquals(targetEffort?.id.orEmpty(), remembered.effort)
            assertEquals("project", remembered.workspace_mode)

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
                model().activeCapture!!.edit { TaskDrafts.admit(it, attachment) }
            }
            composeRule.onNodeWithContentDescription("Back").performClick()
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.onNodeWithTag("quick-task-create").performClick()
            val quickCreated = IsolatedCore.awaitCard(container) { it.title == quickTitle && it.owner_daemon_id.isNotBlank() }
            assertEquals("Second task body", quickCreated.initial_prompt)
            assertEquals(listOf(label.id), quickCreated.label_ids)
            assertEquals(targetHarness.id, quickCreated.provider)
            assertEquals(targetModel.id, quickCreated.model)
            assertEquals(targetEffort?.id.orEmpty(), quickCreated.effort)
            assertEquals("project", quickCreated.workspace_mode)
            assertEquals(optionValue, quickCreated.provider_options[targetOption.id])
            assertEquals("todo", quickCreated.lane)
            assertEquals(listOf(attachment), IsolatedCore.conversation(container, quickCreated.id, quickCreated.owner_daemon_id).conversation?.draft_attachments)

            // Reproduce opening a project chat while the app is currently
            // routed to a different machine. The creation screen must route
            // back to this project's checkout before exposing its catalog.
            val expectedAlternateDaemon = arguments.getString("isolatedSecondDaemon").orEmpty()
            val otherDaemon = runBlocking {
                withTimeout(20_000) {
                    core.connection.machines.first { directory ->
                        expectedAlternateDaemon.isBlank() || directory.all.any { it.id == expectedAlternateDaemon && it.online(directory.evaluatedAt) }
                    }
                }.let { directory ->
                    directory.all.firstOrNull { candidate ->
                        candidate.online(directory.evaluatedAt) && candidate.id != checkout.daemon_id &&
                            (expectedAlternateDaemon.isBlank() || candidate.id == expectedAlternateDaemon)
                    }?.id
                }
            }
            otherDaemon?.let {
                runBlocking { core.attachMachine(it) }
                IsolatedCore.harnesses(container, it)
            }

            composeRule.onNodeWithTag("nav-chats").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("new-chat").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("new-chat").performClick()
            composeRule.waitUntil(20_000) {
                model().state.value.harnessesEndpointId == checkout.daemon_id &&
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
            runBlocking {
                core.onCore {
                    core.creation.remember(
                        HarnessSelection(original.provider, original.model, original.effort, original.provider_options),
                        WorkspaceMode.parse(original.workspace_mode),
                    )
                }
            }
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

package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
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
        val targetHarness = connected.harnesses.last { it.modelsCount > 0 }
        val targetModel = targetHarness.modelsList.last()
        val targetEffort = targetHarness.effortOptionsFor(targetModel.id).lastOrNull()
        val preferences = container.appPreferences
        val original = preferences.conversationCreation.value
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
            manager.onAppForegrounded(project.id)
            composeRule.waitForIdle()

            composeRule.onNodeWithTag("nav-board").performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("space-project-${project.id}").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNode(androidx.compose.ui.test.hasText(project.name) and androidx.compose.ui.test.hasClickAction()).performScrollTo().performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("new-card").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("quick-task-popover").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithText("More options").performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("conversation-title").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("conversation-title").performScrollTo().assertIsDisplayed()

            composeRule.onNodeWithTag("creation-provider").performScrollTo().assertTextEquals(targetHarness.name)
            composeRule.onNodeWithTag("creation-model").assertTextEquals(targetModel.name)
            targetEffort?.let { composeRule.onNodeWithTag("creation-effort").assertTextEquals(it.name) }
            composeRule.onNodeWithTag("workspace-mode-project").performScrollTo().performClick().assertIsSelected()
            composeRule.onNodeWithTag("create-lane-todo").performScrollTo().performClick()
            composeRule.onNodeWithTag("conversation-title").performScrollTo().performTextInput(fixtureTitle)

            capture("creation-preferences-card-selected.png")
            composeRule.onAllNodesWithText("Save")[0].performClick()
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodesWithTag("new-card").fetchSemanticsNodes().isNotEmpty()
            }
            val expected = ConversationCreationPreferences(
                provider = targetHarness.id,
                model = targetModel.id,
                effort = targetEffort?.id.orEmpty(),
                workspaceMode = "project",
            )
            assertEquals(expected, preferences.conversationCreation.value)

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
}

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
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

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
                        state.boards.isNotEmpty() && state.harnesses.any { it.modelsCount > 0 }
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

            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithText(board.name).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithText(board.name)[0].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("new-card").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("new-card").performClick()
            composeRule.onNodeWithTag("conversation-title").assertIsDisplayed()

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

            composeRule.onNodeWithTag("nav-chats").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("new-chat").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("new-chat").performClick()
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

package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.v1.CreateConversationRequest
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Visible Activity → scoped machine route → daemon project/workspace coverage. */
@RunWith(AndroidJUnit4::class)
class ProjectWorkspaceAdministrationEndToEndTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

    @Test
    fun createsOnSelectedHostAndAdministersWorkspaceThroughTheVisibleApp() {
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val origin = DieterEndpoint(
            id = "android_project_admin_e2e",
            label = "Isolated project gateway",
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

        val initial = runBlocking {
            withTimeout(30_000) {
                manager.state.first { state ->
                    state.phase == ConnectionPhase.CONNECTED && state.projects.isNotEmpty() && state.boards.isNotEmpty()
                }
            }
        }
        val initialBoard = initial.boards.first()
        val initialProject = initial.projects.first { it.id == initialBoard.projectId }
        val compatibleHostEndpointId = requireNotNull(initial.projectHosts[initialProject.id]).endpointId
        manager.onAppForegrounded(initialProject.id)
        val nonce = UUID.randomUUID().toString().take(8)
        val projectName = "Android host project $nonce"
        var projectId: String? = null
        var cardId: String? = null
        try {
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithText(initialBoard.name).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithText(initialBoard.name)[0].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithContentDescription("Board actions").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithContentDescription("Board actions")[0].performClick()
            composeRule.onAllNodesWithText("Workspace settings")[0].performClick()
            composeRule.onNodeWithTag("add-project").performClick()
            composeRule.onNodeWithTag("new-project-machine").assertIsDisplayed()
            composeRule.onNodeWithTag("new-project-mode-create").performClick()
            composeRule.onNodeWithTag("new-project-path").performTextInput("/tmp/dieter-android-ui-$nonce")
            composeRule.onNodeWithTag("new-project-name").performTextInput(projectName)
            composeRule.onNodeWithTag("new-project-summary").performTextInput("Scoped Android project creation")
            composeRule.onNodeWithTag("add-validation-command").performScrollTo().performClick()
            composeRule.onNodeWithTag("validation-executable-0").performScrollTo().performTextInput("git")
            composeRule.onNodeWithTag("new-project-submit").performScrollTo().performClick()

            val createdState = runBlocking {
                withTimeout(45_000) {
                    manager.state.first { state ->
                        state.phase == ConnectionPhase.CONNECTED && state.projects.any { it.name == projectName }
                    }
                }
            }
            val project = createdState.projects.first { it.name == projectName }
            projectId = project.id
            assertEquals("main", project.baseBranch)
            assertEquals("git", project.validationCommandsList.single().executable)
            assertEquals(compatibleHostEndpointId, createdState.projectHosts[project.id]?.endpointId)
            capture("project-created-on-selected-host-e2e.png")

            manager.selectProject(initialProject.id)
            val fixtureState = runBlocking {
                withTimeout(30_000) {
                    manager.state.first { state ->
                        state.phase == ConnectionPhase.CONNECTED && state.selectedState?.project?.id == initialProject.id
                    }
                }
            }
            val board = fixtureState.boards.first { it.projectId == initialProject.id }
            val harness = createdState.harnesses.first()
            val card = runBlocking {
                repository.createConversation(
                    CreateConversationRequest.newBuilder()
                        .setProjectId(initialProject.id)
                        .setBoardId(board.id)
                        .setLane("todo")
                        .setTitle("Managed workspace $nonce")
                        .setPrompt("Deferred workspace administration fixture")
                        .setProvider(harness.id)
                        .setModel(harness.defaultModel)
                        .setDeferStart(true)
                        .setWorkspaceMode("worktree")
                        .setWorkspaceBaseBranch("main")
                        .build(),
                    chat = false,
                ).also { repository.workspace(it.id) }
            }
            cardId = card.id

            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithText(initialBoard.name).fetchSemanticsNodes().isNotEmpty() &&
                    composeRule.onAllNodesWithContentDescription("Board actions").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithContentDescription("Board actions")[0].performClick()
            composeRule.onAllNodesWithText("Workspace settings")[0].performClick()
            composeRule.onNodeWithTag("manage-project-workspaces").performScrollTo().performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("project-workspace-${card.id}").fetchSemanticsNodes().isNotEmpty()
            }
            capture("project-workspace-management-e2e.png")
            composeRule.onNodeWithTag("discard-workspace-${card.id}").performScrollTo().performClick()
            composeRule.onNodeWithTag("confirm-workspace-operation").performClick()
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithTag("project-workspace-${card.id}").fetchSemanticsNodes().isEmpty()
            }
            assertFalse(runBlocking { repository.projectWorkspaces(initialProject.id).workspacesList.any { it.cardId == card.id } })

            androidx.test.espresso.Espresso.pressBack()
            composeRule.onNodeWithTag("add-validation-command").performScrollTo().performClick()
            composeRule.onNodeWithTag("validation-executable-0").performScrollTo().performTextInput("git")
            androidx.test.espresso.Espresso.pressBack()
            composeRule.onNodeWithTag("project-base-branch").performScrollTo().performTextClearance()
            composeRule.onNodeWithTag("project-base-branch").performTextInput("trunk")
            androidx.test.espresso.Espresso.pressBack()
            composeRule.onNodeWithTag("save-project-settings").performScrollTo().performClick()
            val updatedState = runBlocking {
                withTimeout(20_000) {
                    manager.state.first { state ->
                        state.projects.firstOrNull { it.id == initialProject.id }?.let { project ->
                            project.baseBranch == "trunk" && project.validationCommandsList.singleOrNull()?.executable == "git"
                        } == true
                    }
                }
            }
            val updated = updatedState.projects.first { it.id == initialProject.id }
            assertEquals("trunk", updated.baseBranch)
            assertTrue(updated.validationCommandsList.single().executable == "git")
            capture("project-workspace-settings-saved-e2e.png")
        } finally {
            cardId?.let {
                runBlocking { runCatching { manager.ensureProjectRoute(initialProject.id); repository.archiveCard(it, true) } }
            }
            projectId?.let { id ->
                runBlocking { runCatching { manager.ensureProjectRoute(id); repository.archiveProject(id, true) } }
            }
            manager.updateEndpoints(DIETER_ENDPOINTS)
            manager.connect()
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

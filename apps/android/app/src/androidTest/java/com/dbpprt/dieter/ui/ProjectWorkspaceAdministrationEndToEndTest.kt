package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.ConversationRef
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.ProjectRef
import com.dbpprt.dieter.api.v1.UpdateProjectWorkspaceSettingsRequest
import com.dbpprt.dieter.core.store.WorkspaceView
import com.dbpprt.dieter.e2e.IsolatedCore
import com.dbpprt.dieter.e2e.saveEvidence
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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
    val rules: RuleChain =
        RuleChain.outerRule(permissionRule)
            .around(composeRule)
            .around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun createsOnSelectedHostAndAdministersWorkspaceThroughTheVisibleApp() {
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val core = container.core
        val initial = IsolatedCore.connect(container)
        val initialBoard = initial.boards.values.flatten().first()
        val initialProject = initial.projects.first { it.id == initialBoard.project_id }
        val checkout = initialProject.checkouts.single { !it.detached }
        val compatibleHost = requireNotNull(core.choice.checkout(initialProject.id))
        fun model() = ViewModelProvider(composeRule.activity)[DieterViewModel::class.java]
        fun awaitWorkspace(predicate: (WorkspaceView) -> Boolean): WorkspaceView = runBlocking {
            withTimeout(45_000) { core.workspace.state.first(predicate) }
        }
        val nonce = UUID.randomUUID().toString().take(8)
        val projectName = "Android host project $nonce"
        var projectId: String? = null
        var cardId: String? = null
        try {
            composeRule.onNodeWithTag("nav-board").performClick()
            composeRule.waitUntil(20_000) {
                composeRule
                    .onAllNodesWithTag("space-project-${initialProject.id}")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            composeRule
                .onNode(
                    androidx.compose.ui.test.hasText(initialProject.name) and
                        androidx.compose.ui.test.hasClickAction() and
                        androidx.compose.ui.test.hasAnyAncestor(
                            androidx.compose.ui.test.hasTestTag(
                                "space-project-${initialProject.id}"
                            )
                        )
                )
                .performScrollTo()
                .performClick()
            composeRule.waitUntil(10_000) {
                composeRule
                    .onAllNodesWithContentDescription("Board actions")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            composeRule.onAllNodesWithContentDescription("Board actions")[0].performClick()
            composeRule.onAllNodesWithText("Workspace settings")[0].performClick()
            composeRule.onNodeWithTag("add-project").performClick()
            composeRule.onNodeWithTag("new-project-machine").assertIsDisplayed()
            composeRule.onNodeWithText("First-board publishing").assertDoesNotExist()
            composeRule.onNodeWithTag("new-project-mode-create").performClick()
            composeRule
                .onNodeWithTag("new-project-path")
                .performTextInput("/tmp/dieter-android-ui-$nonce")
            composeRule.onNodeWithTag("new-project-name").performTextInput(projectName)
            composeRule
                .onNodeWithTag("new-project-summary")
                .performTextInput("Scoped Android project creation")
            composeRule.onNodeWithTag("add-validation-command").performScrollTo().performClick()
            composeRule
                .onNodeWithTag("validation-executable-0")
                .performScrollTo()
                .performTextInput("git")
            composeRule.onNodeWithTag("new-project-submit").performScrollTo().performClick()

            val createdState = awaitWorkspace { state ->
                state.projects.any { it.name == projectName }
            }
            val project = createdState.projects.first { it.name == projectName }
            projectId = project.id
            assertEquals("main", project.base_branch)
            assertEquals("git", project.validation_commands.single().executable)
            assertEquals(compatibleHost, core.choice.checkout(project.id))
            composeRule.onRoot().saveEvidence("project-created-on-selected-host-e2e.png")

            composeRule.runOnIdle { model().selectProject(initialProject.id) }
            composeRule.waitUntil(30_000) {
                model().state.value.selectedProjectId == initialProject.id
            }
            val board = initial.boards.getValue(initialProject.id).first()
            val card =
                IsolatedCore.createConversation(
                    container,
                    CreateConversationRequest(
                        project_id = initialProject.id,
                        board_id = board.id,
                        lane = "todo",
                        title = "Managed workspace $nonce",
                        prompt = "Deferred workspace administration fixture",
                        provider = "mock",
                        model = "mock",
                        defer_start = true,
                        workspace_mode = "worktree",
                        workspace_base_branch = "main",
                    ),
                    chat = false,
                )
            // Provision the conversation's worktree before administering it.
            runBlocking {
                core.onMachine(card.owner_daemon_id) {
                    it.GetWorkspace().execute(ConversationRef(card_id = card.id))
                }
            }
            cardId = card.id

            composeRule.waitUntil(20_000) {
                composeRule
                    .onAllNodesWithText(initialBoard.name)
                    .fetchSemanticsNodes()
                    .isNotEmpty() &&
                    composeRule
                        .onAllNodesWithContentDescription("Board actions")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
            }
            composeRule.onAllNodesWithContentDescription("Board actions")[0].performClick()
            composeRule.onAllNodesWithText("Workspace settings")[0].performClick()
            composeRule.onNodeWithTag("manage-project-workspaces").performScrollTo().performClick()
            composeRule.waitUntil(20_000) {
                composeRule
                    .onAllNodesWithTag("project-workspace-${card.id}")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            composeRule.onRoot().saveEvidence("project-workspace-management-e2e.png")
            composeRule
                .onNodeWithTag("discard-workspace-${card.id}")
                .performScrollTo()
                .performClick()
            composeRule.onNodeWithTag("confirm-workspace-operation").performClick()
            composeRule.waitUntil(30_000) {
                composeRule
                    .onAllNodesWithTag("project-workspace-${card.id}")
                    .fetchSemanticsNodes()
                    .isEmpty()
            }
            assertFalse(
                runBlocking {
                    core.onMachine(checkout.daemon_id) {
                        it.ListProjectWorkspaces()
                            .execute(
                                ProjectRef(
                                    project_id = initialProject.id,
                                    checkout_id = checkout.id,
                                )
                            )
                    }
                }
                    .workspaces
                    .any { it.card_id == card.id }
            )

            androidx.test.espresso.Espresso.pressBack()
            composeRule.onNodeWithTag("add-validation-command").performScrollTo().performClick()
            composeRule
                .onNodeWithTag("validation-executable-0")
                .performScrollTo()
                .performTextInput("git")
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            composeRule
                .onNodeWithTag("project-base-branch")
                .performScrollTo()
                .performTextClearance()
            composeRule.onNodeWithTag("project-base-branch").performTextInput("trunk")
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            composeRule.onNodeWithTag("save-project-settings").performScrollTo().performClick()
            val updatedState = awaitWorkspace { state ->
                state.projects
                    .firstOrNull { it.id == initialProject.id }
                    ?.let { project ->
                        project.base_branch == "trunk" &&
                            project.validation_commands.singleOrNull()?.executable == "git"
                    } == true
            }
            val updated = updatedState.projects.first { it.id == initialProject.id }
            assertEquals("trunk", updated.base_branch)
            assertTrue(updated.validation_commands.single().executable == "git")
            composeRule.onRoot().saveEvidence("project-workspace-settings-saved-e2e.png")
        } finally {
            // Each journey shares the disposable fixture, so restore its checkout defaults.
            runBlocking {
                core.onMachine(checkout.daemon_id) {
                    it.UpdateProjectWorkspaceSettings()
                        .execute(
                            UpdateProjectWorkspaceSettingsRequest(
                                project_id = initialProject.id,
                                checkout_id = checkout.id,
                                base_remote = initialProject.base_remote,
                                base_branch = initialProject.base_branch,
                                validation_commands = checkout.validation_commands.toList(),
                            )
                        )
                }
            }
            cardId?.let { runBlocking { runCatching { core.onBoard { archive(it) } } } }
            projectId?.let { id ->
                runBlocking { runCatching { core.admin.setProjectArchived(id, true) } }
            }
            IsolatedCore.disconnect(container)
        }
    }
}

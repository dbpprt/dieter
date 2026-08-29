package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
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
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * Real Activity → isolated gateway → worktree changes/diff/commit coverage.
 * A worktree card gets real file changes through the card-scoped file APIs,
 * then the Changes tab reviews the diff and commits it through a durable
 * Git operation, all on the visible emulator.
 */
@RunWith(AndroidJUnit4::class)
class WorkspaceChangesEndToEndTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

    @Test
    fun worktreeChangesAreReviewedAndCommittedOnTheVisibleEmulator() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val endpoint = DieterEndpoint(
            id = "android_workspace_changes_e2e",
            label = "Isolated workspace gateway",
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
        val repository = container.repository
        val harness = runBlocking { repository.harnesses().harnessesList.first() }
        val fixture = runBlocking {
            repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(project.id)
                    .setBoardId(board.id)
                    .setLane(todoLane)
                    .setTitle("Android workspace E2E ${UUID.randomUUID().toString().take(8)}")
                    .setPrompt("Review-only workspace fixture. Do not start.")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setWorkspaceMode("worktree")
                    .setClientId("android-workspace-changes-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )
        }

        try {
            // Card-scoped file writes lazily provision the worktree and give the
            // changeset real tracked content without starting an agent turn.
            runBlocking {
                repository.createFile(
                    projectId = project.id,
                    path = "android-e2e-note.md",
                    kind = "file",
                    content = "# Android workspace E2E\n\nWritten through the card-scoped file API.\n",
                    cardId = fixture.id,
                )
            }

            runBlocking { manager.refreshMachineDirectory(includeArchivedChats = true) }
            manager.onAppForegrounded(project.id)
            runBlocking {
                withTimeout(10_000) { manager.state.first { state -> state.cards.any { it.id == fixture.id } } }
            }
            container.requestOpen(cardId = fixture.id)

            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithText("Changes").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithText("Changes").performClick()
            composeRule.waitUntil(60_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.waitUntil(60_000) {
                composeRule.onAllNodesWithText("android-e2e-note.md").fetchSemanticsNodes().isNotEmpty()
            }
            val screenshotDirectory = arguments.getString("additionalTestOutputDir")
                ?.takeIf(String::isNotBlank)
                ?.let(::File)
                ?: requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
            screenshotDirectory.mkdirs()
            capture(screenshotDirectory, "workspace-changes-list-e2e.png")

            // Review the unified diff for the untracked file.
            composeRule.onNodeWithText("android-e2e-note.md").performClick()
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithTag("workspace-diff").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-diff-opened-e2e.png")
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithText("Android workspace E2E", substring = true)
                    .fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-diff-e2e.png")
            composeRule.onNodeWithTag("workspace-diff-back").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty()
            }

            // Commit through the durable Git operation flow.
            composeRule.onNodeWithTag("workspace-commit").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("commit-subject").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-commit-sheet-e2e.png")
            composeRule.onNodeWithTag("operation-start").performClick()
            // The changeset compares against the base branch, so the committed
            // file stays listed; the commit row appearing proves the durable
            // operation ran, streamed, and the surface refreshed.
            composeRule.waitUntil(120_000) {
                composeRule.onAllNodesWithText("COMMITS").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithText("COMMITS").assertIsDisplayed()
            capture(screenshotDirectory, "workspace-committed-e2e.png")

            val changeset = runBlocking { repository.changeset(fixture.id) }
            assertTrue("Commit should appear in the changeset", changeset.commitsCount >= 1)
            assertTrue("Committed file should still diff against the base", changeset.filesCount == 1)
            val workspace = runBlocking { repository.workspace(fixture.id) }
            assertTrue("Working tree should be clean after commit", !workspace.dirty)

            // Merge into the base branch through the orchestrated flow:
            // merge_local, cleanup, and the card moving to Done.
            composeRule.onNodeWithTag("workspace-merge").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("merge-confirm").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-merge-sheet-e2e.png")
            composeRule.onNodeWithTag("merge-confirm").performClick()
            composeRule.waitUntil(180_000) {
                composeRule.onAllNodesWithText("Workspace removed").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-merged-e2e.png")
            val merged = runBlocking { repository.card(fixture.id).card }
            assertTrue("Card should move to Done after merge, was ${merged.lane}", merged.lane == "done")
        } finally {
            runBlocking { repository.archiveCard(fixture.id, true) }
        }
    }

    private fun capture(directory: File, name: String) {
        composeRule.waitForIdle()
        File(directory, name).outputStream().use { output ->
            composeRule.onRoot()
                .captureToImage()
                .asAndroidBitmap()
                .compress(Bitmap.CompressFormat.PNG, 100, output)
        }
    }
}

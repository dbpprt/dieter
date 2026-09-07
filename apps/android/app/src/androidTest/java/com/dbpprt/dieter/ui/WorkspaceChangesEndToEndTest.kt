package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
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
import io.grpc.Status
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.delay
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
            val worktreeNote = "android-e2e-${UUID.randomUUID().toString().take(8)}.md"
            runBlocking {
                repository.createFile(
                    projectId = project.id,
                    path = worktreeNote,
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
            val screenshotDirectory = arguments.getString("additionalTestOutputDir")
                ?.takeIf(String::isNotBlank)
                ?.let(::File)
                ?: requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
            screenshotDirectory.mkdirs()

            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("card-detail-changes").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithTag("card-detail-changes")[1].performClick()
            composeRule.waitForIdle()
            capture(screenshotDirectory, "workspace-tab-opened-e2e.png")
            composeRule.waitUntil(60_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.waitUntil(60_000) {
                composeRule.onAllNodesWithText(worktreeNote).fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-changes-list-e2e.png")

            // Review the unified diff for the untracked file.
            composeRule.onAllNodesWithText(worktreeNote)[1].performClick()
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithTag("workspace-diff").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-diff-opened-e2e.png")
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithText("Android workspace E2E", substring = true)
                    .fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-diff-e2e.png")
            composeRule.onAllNodesWithTag("workspace-diff-back")[1].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty()
            }

            // Commit through the durable Git operation flow.
            composeRule.onAllNodesWithTag("workspace-commit")[1].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("commit-subject").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "workspace-commit-sheet-e2e.png")
            composeRule.onNodeWithTag("operation-start").performClick()
            // Working Changes is local-only, so a successful commit empties it.
            composeRule.waitUntil(120_000) {
                composeRule.onAllNodesWithText("No local changes.").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithText("No local changes.")[1].assertIsDisplayed()
            capture(screenshotDirectory, "workspace-committed-e2e.png")

            val changeset = runBlocking { repository.changeset(fixture.id) }
            assertTrue("Committed history must not appear in Working Changes", changeset.commitsCount == 0)
            assertTrue("Committed files must leave Working Changes", changeset.filesCount == 0)
            val workspace = runBlocking { repository.workspace(fixture.id) }
            assertTrue("Working tree should be clean after commit", !workspace.dirty)

            // Merge into the base branch through the orchestrated flow:
            // merge_local, cleanup, and the card moving to Done.
            composeRule.onAllNodesWithTag("workspace-merge")[1].performClick()
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

            // Project-directory changes live under Files > Changes and are
            // project-scoped rather than attributed to the card above.
            val projectNote = "android-project-${UUID.randomUUID().toString().take(8)}.md"
            runBlocking {
                repository.createFile(
                    projectId = project.id,
                    path = projectNote,
                    kind = "file",
                    content = "# Android project Changes\n",
                )
            }
            composeRule.onAllNodesWithContentDescription("Back")[1].performClick()
            composeRule.waitUntil(20_000) { composeRule.onAllNodesWithText("Files").fetchSemanticsNodes().isNotEmpty() }
            composeRule.onAllNodesWithText("Files")[0].performClick()
            composeRule.waitUntil(20_000) { composeRule.onAllNodesWithText("Browse").fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithTag("project-files-changes").performClick()
            composeRule.waitUntil(30_000) { composeRule.onAllNodesWithText(projectNote).fetchSemanticsNodes().isNotEmpty() }
            capture(screenshotDirectory, "project-changes-list-e2e.png")

            val projectChanges = runBlocking {
                retryTransient {
                    manager.ensureProjectRoute(project.id)
                    repository.projectChangeset(project.id)
                }
            }
            assertTrue("Project changes must carry project scope", projectChanges.projectId == project.id && projectChanges.cardId.isEmpty())
            assertTrue("Project note must be unstaged", projectChanges.filesList.any { it.path == projectNote && it.unstaged })
            composeRule.onNodeWithTag("project-changes-stage-all").performClick()
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithText("No unstaged changes").fetchSemanticsNodes().isNotEmpty() &&
                    composeRule.onAllNodesWithTag("project-changes-commit").fetchSemanticsNodes().isNotEmpty()
            }
            capture(screenshotDirectory, "project-changes-staged-e2e.png")
            composeRule.onNodeWithTag("project-changes-commit").performClick()
            composeRule.waitForIdle()
            capture(screenshotDirectory, "project-commit-clicked-e2e.png")
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("project-commit-subject").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("project-commit-subject").performTextInput("Android project changes E2E")
            composeRule.onNodeWithTag("project-operation-start").performClick()
            composeRule.waitUntil(120_000) { composeRule.onAllNodesWithTag("project-changes-clean").fetchSemanticsNodes().isNotEmpty() }
            capture(screenshotDirectory, "project-changes-committed-e2e.png")
            val cleanProject = runBlocking {
                retryTransient {
                    manager.ensureProjectRoute(project.id)
                    repository.projectChangeset(project.id)
                }
            }
            assertTrue("Project checkout must be clean after the staged commit", cleanProject.filesCount == 0 && !cleanProject.dirty)

            val discarded = "android-discard-${UUID.randomUUID().toString().take(8)}.txt"
            runBlocking {
                retryTransient {
                    manager.ensureProjectRoute(project.id)
                    repository.createFile(project.id, discarded, "file", "discard me\n")
                }
            }
            composeRule.onNodeWithContentDescription("Refresh project changes").performClick()
            composeRule.waitUntil(30_000) { composeRule.onAllNodesWithText(discarded).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithContentDescription("Discard $discarded").performClick()
            composeRule.onNodeWithText("Discard").performClick()
            composeRule.waitUntil(120_000) { composeRule.onAllNodesWithTag("project-changes-clean").fetchSemanticsNodes().isNotEmpty() }
            assertTrue(
                "Discard must remove the untracked project file",
                runBlocking {
                    retryTransient {
                        manager.ensureProjectRoute(project.id)
                        repository.projectChangeset(project.id)
                    }
                }.filesCount == 0,
            )
        } finally {
            runBlocking { runCatching { retryTransient { repository.archiveCard(fixture.id, true) } } }
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

    private suspend fun <T> retryTransient(block: suspend () -> T): T = withTimeout(30_000) {
        while (true) {
            try {
                return@withTimeout block()
            } catch (error: Throwable) {
                if (Status.fromThrowable(error).code !in setOf(Status.Code.UNAVAILABLE, Status.Code.UNAUTHENTICATED)) throw error
                delay(250)
            }
        }
        error("unreachable")
    }
}

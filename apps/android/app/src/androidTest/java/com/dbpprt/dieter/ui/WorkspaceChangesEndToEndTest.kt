package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.isDisplayed
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.ConversationRef
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.CreateFileRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.GetCardRequest
import com.dbpprt.dieter.api.v1.GetChangesetRequest
import com.dbpprt.dieter.core.workspace.GitOperationKinds
import com.dbpprt.dieter.e2e.IsolatedCore
import com.dbpprt.dieter.e2e.Evidence
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
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
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun worktreeChangesAreReviewedAndCommittedOnTheVisibleEmulator() {
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val core = container.core
        val connected = IsolatedCore.connect(container)
        val board = connected.boards.values.flatten().first { candidate ->
            candidate.lanes.any { lane -> lane.id.equals("todo", true) || lane.name.equals("todo", true) }
        }
        val todoLane = board.lanes.first { lane ->
            lane.id.equals("todo", true) || lane.name.equals("todo", true)
        }.id
        val project = connected.projects.first { it.id == board.project_id }
        val checkout = project.checkouts.single { !it.detached }
        fun <T> daemon(block: suspend (DieterServiceClient) -> T): T = runBlocking { retryTransient { core.onMachine(checkout.daemon_id, block) } }
        fun projectChangeset() = daemon { it.GetChangeset().execute(GetChangesetRequest(project_id = project.id, checkout_id = checkout.id)) }
        val fixture = IsolatedCore.createConversation(
            container,
            CreateConversationRequest(project_id = project.id, board_id = board.id, lane = todoLane, title = "Android workspace E2E ${UUID.randomUUID().toString().take(8)}", prompt = "Review-only workspace fixture. Do not start.", provider = "mock", model = "mock", defer_start = true, workspace_mode = "worktree"),
            chat = false,
        )

        try {
            // Card-scoped file writes lazily provision the worktree and give the
            // changeset real tracked content without starting an agent turn.
            val worktreeNote = "android-e2e-${UUID.randomUUID().toString().take(8)}.md"
            daemon {
                it.CreateFile().execute(CreateFileRequest(
                    project_id = project.id, path = worktreeNote, kind = "file",
                    content = "# Android workspace E2E\n\nWritten through the card-scoped file API.\n", card_id = fixture.id,
                ))
            }
            IsolatedCore.awaitCard(container, 10.seconds) { it.id == fixture.id }
            composeRule.onNodeWithTag("nav-board").performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("space-project-${project.id}").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNode(
                androidx.compose.ui.test.hasText(project.name) and androidx.compose.ui.test.hasClickAction() and
                    androidx.compose.ui.test.hasAnyAncestor(androidx.compose.ui.test.hasTestTag("space-project-${project.id}")),
            ).performScrollTo().performClick()
            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithText(fixture.title).fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-before-card-click.png")
            composeRule.onNodeWithTag("nav-board").assertIsSelected()
            composeRule.onNodeWithTag("swipe-card-${fixture.id}").assertIsDisplayed().performTouchInput { click() }
            capture("workspace-after-card-click.png")

            composeRule.waitUntil(20_000) {
                composeRule.onAllNodesWithTag("card-detail-changes").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithTag("card-detail-changes")[0].performClick()
            composeRule.waitForIdle()
            capture("workspace-tab-opened-e2e.png")
            composeRule.waitUntil(60_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty() ||
                    composeRule.onAllNodesWithTag("workspace-diff-back").fetchSemanticsNodes().isNotEmpty()
            }
            // The core selects the first patch on entry. Return to the compact
            // file list before exercising explicit selection and commit controls.
            if (composeRule.onAllNodesWithTag("workspace-diff-back").fetchSemanticsNodes().isNotEmpty()) {
                composeRule.onAllNodesWithTag("workspace-diff-back")[0].performClick()
            }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.waitUntil(60_000) {
                composeRule.onAllNodesWithText(worktreeNote).fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-changes-list-e2e.png")

            // Review the unified diff for the untracked file.
            composeRule.onAllNodesWithText(worktreeNote)[0].performClick()
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithTag("workspace-diff").fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-diff-opened-e2e.png")
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithText("Android workspace E2E", substring = true)
                    .fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-diff-e2e.png")
            composeRule.onAllNodesWithTag("workspace-diff-back")[0].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("workspace-changes-list").fetchSemanticsNodes().isNotEmpty()
            }

            // Commit through the durable Git operation flow.
            composeRule.onAllNodesWithTag("workspace-commit")[0].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("commit-subject").fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-commit-sheet-e2e.png")
            composeRule.onNodeWithTag("operation-start").performClick()
            // Working Changes is local-only, so a successful commit empties it.
            composeRule.waitUntil(120_000) {
                composeRule.onAllNodesWithText("No local changes.").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onAllNodesWithText("No local changes.")[0].assertIsDisplayed()
            capture("workspace-committed-e2e.png")

            val changeset = daemon { it.GetChangeset().execute(GetChangesetRequest(card_id = fixture.id)) }
            assertTrue("Committed history must not appear in Working Changes", changeset.commits.size == 0)
            assertTrue("Committed files must leave Working Changes", changeset.files.size == 0)
            val workspace = daemon { it.GetWorkspace().execute(ConversationRef(card_id = fixture.id)) }
            assertTrue("Working tree should be clean after commit", !workspace.dirty)

            // Merge into the base branch through the orchestrated flow:
            // merge_local, cleanup, and the card moving to Done.
            composeRule.onAllNodesWithTag("workspace-merge")[0].performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("merge-confirm").fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-merge-sheet-e2e.png")
            composeRule.onNodeWithTag("merge-confirm").performClick()
            composeRule.waitUntil(180_000) {
                composeRule.onAllNodesWithText("Workspace removed").fetchSemanticsNodes().isNotEmpty()
            }
            capture("workspace-merged-e2e.png")
            // Cleanup publishes the removed workspace before the final board
            // mutation. Wait for that last step of the core's merge flow.
            var merged = requireNotNull(daemon { it.GetCard().execute(GetCardRequest(card_id = fixture.id)) }.card)
            composeRule.waitUntil(30_000) {
                merged = requireNotNull(daemon { it.GetCard().execute(GetCardRequest(card_id = fixture.id)) }.card)
                merged.lane == "done"
            }
            assertTrue("Card should move to Done after merge, was ${merged.lane}", merged.lane == "done")

            // Project-directory changes live under Files > Changes and are
            // project-scoped rather than attributed to the card above.
            val projectNote = "android-project-${UUID.randomUUID().toString().take(8)}.md"
            daemon {
                it.CreateFile().execute(CreateFileRequest(project_id = project.id, checkout_id = checkout.id, path = projectNote, kind = "file", content = "# Android project Changes\n"))
            }
            composeRule.onAllNodesWithContentDescription("Back")[0].performClick()
            composeRule.onNodeWithTag("nav-tools").performClick()
            composeRule.onNodeWithTag("tool-files").performClick()
            composeRule.waitUntil(20_000) { composeRule.onAllNodesWithTag("project-files-browse").fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithTag("project-files-changes").performClick()
            composeRule.waitUntil(30_000) { composeRule.onAllNodesWithText(projectNote).fetchSemanticsNodes().isNotEmpty() }
            capture("project-changes-list-e2e.png")

            val projectChanges = projectChangeset()
            assertTrue("Project changes must carry project scope", projectChanges.project_id == project.id && projectChanges.card_id.isEmpty())
            assertTrue("Project note must be unstaged", projectChanges.files.any { it.path == projectNote && it.unstaged })
            composeRule.onNodeWithTag("project-changes-stage-all").performClick()
            composeRule.waitUntil(30_000) {
                composeRule.onAllNodesWithText("No unstaged changes").fetchSemanticsNodes().isNotEmpty() &&
                    composeRule.onAllNodesWithTag("project-changes-commit").fetchSemanticsNodes().isNotEmpty()
            }
            capture("project-changes-staged-e2e.png")
            composeRule.onNodeWithTag("project-changes-commit").performClick()
            composeRule.waitForIdle()
            capture("project-commit-clicked-e2e.png")
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodesWithTag("project-commit-subject").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("project-commit-subject").performTextInput("Android project changes E2E")
            composeRule.onNodeWithTag("project-operation-start").performClick()
            composeRule.waitUntil(120_000) { composeRule.onAllNodesWithTag("project-changes-clean").fetchSemanticsNodes().isNotEmpty() }
            capture("project-changes-committed-e2e.png")
            val cleanProject = projectChangeset()
            assertTrue("Project checkout must be clean after the staged commit", cleanProject.files.size == 0 && !cleanProject.dirty)

            // Shipping stays explicit. Update and validation execute through the
            // same durable operation path; push is present but is not clicked
            // because this isolated fixture intentionally has no publish remote.
            composeRule.onNodeWithTag("project-changes-actions").performClick()
            composeRule.onNodeWithTag("project-changes-update").assertIsDisplayed().performClick()
            composeRule.waitUntil(120_000) {
                val operation = androidx.lifecycle.ViewModelProvider(composeRule.activity)[DieterViewModel::class.java]
                    .state.value.projectChanges.operation
                operation?.kind == GitOperationKinds.UPDATE && operation.status == "succeeded"
            }
            composeRule.waitForIdle()
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodes(isEnabled() and hasTestTag("project-changes-actions")).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("project-changes-actions").assertIsEnabled()
            composeRule.onNodeWithTag("project-changes-actions").performClick()
            composeRule.waitUntil(10_000) { composeRule.onNodeWithTag("project-changes-validate").isDisplayed() }
            composeRule.onNodeWithTag("project-changes-validate").assertIsDisplayed().performClick()
            composeRule.waitUntil(120_000) {
                val operation = androidx.lifecycle.ViewModelProvider(composeRule.activity)[DieterViewModel::class.java]
                    .state.value.projectChanges.operation
                operation?.kind == GitOperationKinds.VALIDATE && operation.status == "succeeded"
            }
            val discarded = "android-discard-${UUID.randomUUID().toString().take(8)}.txt"
            daemon { it.CreateFile().execute(CreateFileRequest(project_id = project.id, checkout_id = checkout.id, path = discarded, kind = "file", content = "discard me\n")) }
            composeRule.onNodeWithContentDescription("Refresh project changes").performClick()
            composeRule.waitUntil(30_000) { composeRule.onAllNodesWithText(discarded).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithContentDescription("Actions for $discarded").performClick()
            composeRule.onNodeWithText("Discard").performClick()
            composeRule.waitForIdle()
            composeRule.onNodeWithText("Discard").performClick()
            composeRule.waitUntil(120_000) { composeRule.onAllNodesWithTag("project-changes-clean").fetchSemanticsNodes().isNotEmpty() }
            assertTrue(
                "Discard must remove the untracked project file",
                projectChangeset().files.isEmpty(),
            )
            composeRule.onNodeWithTag("project-changes-actions").performClick()
            composeRule.onNodeWithTag("project-changes-push").assertIsDisplayed()
        } catch (error: Throwable) {
            runCatching { capture("workspace-before-cleanup-failure.png") }
            throw error
        } finally {
            runBlocking { runCatching { retryTransient { core.onBoard { archive(fixture.id) } } } }
        }
    }

    private fun capture(name: String) {
        composeRule.waitForIdle()
        val state = androidx.lifecycle.ViewModelProvider(composeRule.activity)[DieterViewModel::class.java].state.value
        Evidence.text("$name.txt", "destination=${state.destination} selectedCard=${state.selectedCardId} error=${state.error}\n")
        Evidence.display(name)
    }

    private suspend fun <T> retryTransient(block: suspend () -> T): T = withTimeout(30_000) {
        while (true) {
            try {
                return@withTimeout block()
            } catch (error: Throwable) {
                if (error is CancellationException || (error as? GrpcException)?.grpcStatus !in setOf(GrpcStatus.UNAVAILABLE, GrpcStatus.UNAUTHENTICATED)) throw error
                delay(250)
            }
        }
        error("unreachable")
    }
}

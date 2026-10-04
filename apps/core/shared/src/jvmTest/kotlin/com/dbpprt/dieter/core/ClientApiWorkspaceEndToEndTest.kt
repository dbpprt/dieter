package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.DiffRow
import com.dbpprt.dieter.client.v1.GitOperationForm
import com.dbpprt.dieter.client.v1.ProjectChangeSelect
import com.dbpprt.dieter.client.v1.ProjectChangesCommand
import com.dbpprt.dieter.client.v1.ProjectChangesSlice
import com.dbpprt.dieter.client.v1.ProjectChangesTarget
import com.dbpprt.dieter.client.v1.ProjectWorkspacesCommand
import com.dbpprt.dieter.client.v1.ProjectWorkspacesLoad
import com.dbpprt.dieter.client.v1.ReviewCommand
import com.dbpprt.dieter.client.v1.ReviewLayout
import com.dbpprt.dieter.client.v1.ReviewMerge
import com.dbpprt.dieter.client.v1.ReviewSelect
import com.dbpprt.dieter.client.v1.ReviewSlice
import com.dbpprt.dieter.client.v1.ReviewTarget
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Step
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import com.dbpprt.dieter.core.workspace.WorkspaceStatus
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The review contract as the Mac drives it: a conversation's worktree is
 * reviewed and merged through a review surface, a checkout's change is staged
 * through a project changes surface, and the project's workspaces are listed.
 */
class ClientApiWorkspaceEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun theMacReviewsAWorkspaceAndStagesAProjectChangeThroughSurfaces() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        suspend fun step(name: String, command: Command) =
            try { api.dispatch(command) } catch (failure: ClientFailure) { throw AssertionError("$name: ${failure.message}", failure) }

        // An agent's worktree change is reviewed and merged through a review surface.
        val local = runtime.createConversation(
            CreateConversationRequest(
                project_id = fixture.projectId, board_id = fixture.boardId, lane = "running", title = "Write a file", prompt = "mock-concurrent-workspace-write",
                provider = "mock", model = "mock", effort = "low", workspace_mode = "worktree",
            ),
            chat = false,
        )
        val cardId = runtime.outbox.view.await(45.seconds) { local.id in it.resolutions }.resolve(local.id)
        runtime.workspace.state.await(60.seconds, describe = { "turn finished: ${runtime.workspace.state.value.card(cardId)}" }) { view ->
            view.card(cardId)?.let { it.initial_prompt_sent_at.isNotEmpty() && it.runtime != "running" && it.runtime != "starting" } == true
        }
        val workspaces = step(
            "workspaces load", Command(project_workspaces = ProjectWorkspacesCommand(load = ProjectWorkspacesLoad(project_id = fixture.projectId))),
        ).project_workspaces!!
        assertTrue(workspaces.rows.any { it.card_id == cardId }, "workspaces: ${workspaces.rows.map { it.card_id }}")
        val row = workspaces.rows.single { it.card_id == cardId }
        assertEquals("Write a file", row.title, "the list names the conversation")
        assertTrue(row.can_discard && !row.pending, "row: $row")

        val review = MutableStateFlow<ReviewSlice?>(null)
        val reviewWatch = api.observe(Slice.SLICE_REVIEW, "review-test") { review.value = Update.ADAPTER.decode(it.encode()).review }
        fun reviewCommand(action: ReviewCommand) = Command(review = action.copy(scope = "review-test"))
        step("review bind", reviewCommand(ReviewCommand(bind = ReviewTarget(cardId, fixture.daemonId))))
        step("review refresh", reviewCommand(ReviewCommand(refresh = Step())))
        val loaded = review.await(30.seconds, describe = { "review: ${review.value?.copy(display_rows = emptyList())}" }) { slice ->
            slice?.changeset?.files?.isNotEmpty() == true && slice.display_rows.isNotEmpty() && slice.availability != null
        }!!
        assertTrue(loaded.display_rows.any { it.line?.row?.kind == DiffRow.Kind.KIND_ADDITION })
        assertTrue(loaded.availability!!.allows_merge_flow, "availability: ${loaded.availability}")
        // A command's result carries the whole slice: availability and the laid-out diff.
        val full = step("review refresh again", reviewCommand(ReviewCommand(refresh = Step()))).review!!
        assertTrue(full.availability != null, "a command result keeps availability")
        assertTrue(full.display_rows.any { it.line?.row?.kind == DiffRow.Kind.KIND_ADDITION && it.line?.commentable == true }, "display: ${full.display_rows}")
        assertTrue(!full.diff_more && !full.diff_too_large && full.diff_note.isEmpty(), "slice: ${full.copy(display_rows = emptyList())}")
        assertEquals(WorkspaceStatus.stateLabel(full.workspace!!.state), full.workspace_state)
        assertTrue(full.workspace_state.isNotEmpty(), "the workspace's state in words")
        assertTrue(full.moves_to_done)
        assertTrue(full.merge_readiness!!.items.any { it.id == "conflicts" })
        val cleared = step("review Back", reviewCommand(ReviewCommand(select = ReviewSelect()))).review!!
        assertTrue(cleared.selected_path.isEmpty() && cleared.selected_commit.isEmpty())
        assertTrue(cleared.diff == null && cleared.display_rows.isEmpty() && !cleared.diff_loading)
        val listing = step("review refresh in file list", reviewCommand(ReviewCommand(refresh = Step()))).review!!
        assertTrue(listing.selected_path.isEmpty() && listing.diff == null && listing.display_rows.isEmpty(), "refresh preserves Back")
        val reopened = step("review reselect file", reviewCommand(ReviewCommand(select = ReviewSelect(path = full.selected_path)))).review!!
        assertTrue(reopened.display_rows.any { it.line?.row?.kind == DiffRow.Kind.KIND_ADDITION }, "select opens the diff again")
        val split = step("review split", reviewCommand(ReviewCommand(layout = ReviewLayout(split = true)))).review!!
        assertTrue(split.split && split.display_rows.any { it.pair?.after?.kind == DiffRow.Kind.KIND_ADDITION }, "split: ${split.display_rows}")
        val merged = step("review merge", reviewCommand(ReviewCommand(merge = ReviewMerge(strategy = "squash", subject = "Add mock file", validate = true, remove_workspace = true, move_to_done = true)))).outcome!!
        assertTrue(merged.succeeded, "merge: ${review.value?.error} ${review.value?.operation}")
        review.await(describe = { "merged: ${review.value?.toast}" }) { it?.toast == "Merged ${loaded.workspace!!.branch} into main · card moved to Done" }
        runtime.workspace.state.await(20.seconds) { it.card(cardId)?.lane == "done" || it.card(cardId) == null }
        reviewWatch.close()

        // A project's checkout change is selected, shown as diff rows, and
        // staged; a local merge needs a clean base, so this runs after it.
        val checkout = runtime.workspace.state.value.project(fixture.projectId)!!.checkouts.first { it.daemon_id == fixture.daemonId }
        File(checkout.path, "contract-notes.txt").writeText("hello\n")
        val changes = MutableStateFlow<ProjectChangesSlice?>(null)
        val changesWatch = api.observe(Slice.SLICE_PROJECT_CHANGES, "changes-test") { changes.value = Update.ADAPTER.decode(it.encode()).project_changes }
        fun changesCommand(action: ProjectChangesCommand) = Command(project_changes = action.copy(scope = "changes-test"))
        step("changes bind", changesCommand(ProjectChangesCommand(bind = ProjectChangesTarget(fixture.projectId, checkout.id, fixture.daemonId, select_first = true))))
        val refreshed = step("changes refresh", changesCommand(ProjectChangesCommand(refresh = Step()))).project_changes!!
        assertTrue(refreshed.changes?.files?.any { it.path == "contract-notes.txt" && it.unstaged } == true, "changes: ${refreshed.changes}")
        assertEquals(ProjectChangeSelect(path = refreshed.changes!!.files.first { it.unstaged }.path, staged = false), refreshed.selection, "the view opens on the first change")
        assertTrue("stage" in refreshed.allowed && "discard_changes" in refreshed.allowed, "allowed: ${refreshed.allowed}")
        val selected = step("changes select", changesCommand(ProjectChangesCommand(select = ProjectChangeSelect(path = "contract-notes.txt", staged = false)))).project_changes!!
        assertEquals("", selected.diff?.patch, "the patch travels as rows only")
        assertTrue(
            selected.display_rows.any { it.line?.row?.kind == DiffRow.Kind.KIND_ADDITION && it.line?.row?.text?.contains("hello") == true && it.line?.commentable == false },
            "display: ${selected.display_rows}",
        )
        val splitChanges = step("changes split", changesCommand(ProjectChangesCommand(layout = ReviewLayout(split = true)))).project_changes!!
        assertTrue(splitChanges.split && splitChanges.display_rows.any { it.pair?.after?.text?.contains("hello") == true }, "split: ${splitChanges.display_rows}")
        val staged = step("changes stage", changesCommand(ProjectChangesCommand(run = GitOperationForm(kind = "stage", path = "contract-notes.txt")))).outcome!!
        assertTrue(staged.succeeded, "stage: ${changes.value?.operation_error}")
        val stagedSlice = changes.await(describe = { "staged: ${changes.value}" }) { it?.notice == "Changes staged" }!!
        assertTrue(stagedSlice.changes!!.files.single { it.path == "contract-notes.txt" }.staged)
        changesWatch.close()
    }
}

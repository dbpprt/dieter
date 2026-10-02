package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.FileDiff
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.client.v1.DiffRow
import com.dbpprt.dieter.client.v1.WorkspaceTone
import com.dbpprt.dieter.core.workspace.DiffPages
import com.dbpprt.dieter.core.workspace.ProjectChangesView
import com.dbpprt.dieter.core.workspace.ProjectWorkspacesView
import com.dbpprt.dieter.core.workspace.UnifiedDiff
import com.dbpprt.dieter.core.workspace.WorkspaceReviewView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The review and project changes slices carry laid-out diffs and their presentation. */
class ReviewSliceTest {
    private val patch = "diff --git a/Sample.swift b/Sample.swift\n--- a/Sample.swift\n+++ b/Sample.swift\n@@ -1,2 +1,2 @@\n-let old = 1\n+let new = 2\n print(new)"

    @Test
    fun displayRowsCarryTheirLinesComments() {
        val comments = listOf(
            ChangeComment(id = "old", path = "Sample.swift", side = "old", line = 1),
            ChangeComment(id = "new", path = "Sample.swift", side = "new", line = 1),
            ChangeComment(id = "elsewhere", path = "Other.swift", side = "new", line = 1),
        )
        val view = WorkspaceReviewView(cardId = "c", selectedPath = "Sample.swift", comments = comments).withDiffLines(UnifiedDiff.parse(patch))
        val slice = reviewSlice(view, Card(id = "c"))
        val lines = slice.display_rows.mapNotNull { it.line }
        assertEquals(listOf(DiffRow.Kind.KIND_DELETION, DiffRow.Kind.KIND_ADDITION, DiffRow.Kind.KIND_CONTEXT), lines.map { it.row!!.kind })
        assertEquals(listOf(listOf("old"), listOf("new"), emptyList()), lines.map { line -> line.comments.map { it.id } })
        assertTrue(lines.all { it.commentable })
        assertEquals("@@ -1,2 +1,2 @@", slice.display_rows.firstNotNullOf { it.hunk }.text)
        assertEquals(1 to 1, slice.display_rows.firstNotNullOf { it.hunk }.let { it.additions to it.deletions })
        assertFalse(slice.split)

        val split = reviewSlice(view.copy(split = true).withDiffLines(view.diffLines), Card(id = "c"))
        val pair = split.display_rows.firstNotNullOf { it.pair }
        assertEquals("-let old = 1" to "+let new = 2", pair.before?.text to pair.after?.text)
        assertTrue(split.split)

        val commit = reviewSlice(WorkspaceReviewView(cardId = "c", selectedCommit = "abc").withDiffLines(UnifiedDiff.parse(patch)), null)
        assertTrue(commit.display_rows.mapNotNull { it.line }.none { it.commentable }, "a whole commit takes no comments")
        assertEquals("Sample.swift", commit.display_rows.firstNotNullOf { it.file_boundary }.path)
    }

    @Test
    fun unchangedDisplayRowsAreLeftOut() {
        val view = WorkspaceReviewView(cardId = "c", selectedPath = "Sample.swift").withDiffLines(UnifiedDiff.parse(patch))
        assertFalse(reviewDiffUnchanged(null, view))
        assertTrue(reviewDiffUnchanged(view, view.copy(loading = true)))
        assertFalse(reviewDiffUnchanged(view, view.copy(comments = listOf(ChangeComment(id = "x")))), "a new comment resends the rows")
        assertFalse(reviewDiffUnchanged(view, view.copy(split = true).withDiffLines(view.diffLines)))
        val slice = reviewSlice(view, null, diffUnchanged = true)
        assertTrue(slice.diff_unchanged)
        assertTrue(slice.display_rows.isEmpty())
        assertTrue(slice.diff_max_columns > 0)
    }

    @Test
    fun aDiffAtItsLimitSaysSoInsteadOfLoadingMore() {
        val limited = reviewSlice(WorkspaceReviewView(diff = FileDiff(truncated = true, next_offset = DiffPages.LIMIT)), null)
        assertFalse(limited.diff_more)
        assertTrue(limited.diff_too_large)
        assertEquals(DiffPages.TOO_LARGE, limited.diff_note)
        assertEquals("", limited.error, "the limit is not an error")
        val more = projectChangesSlice(ProjectChangesView(diff = FileDiff(truncated = true, next_offset = DiffPages.PAGE.toLong())))
        assertTrue(more.diff_more)
        assertFalse(more.diff_too_large)
        assertEquals("", more.diff_note)
    }

    @Test
    fun theReviewCarriesItsPresentationAndAvailability() {
        val card = Card(id = "c", scope = "board", board_id = "b", runtime = "idle", workspace_mode = "worktree", pull_request = PullRequestSummary(number = 5, state = "open", checks_state = "running", mergeable = true))
        val view = WorkspaceReviewView(
            cardId = "c", workspace = Workspace(mode = "worktree", state = "conflicted", base_branch = "main", branch = "feature"),
            operation = GitOperation(card_id = "c", status = "waiting_for_resolution"), needsReconciliation = false,
        )
        val slice = reviewSlice(view, card)
        assertTrue(slice.operation_visible)
        assertFalse(slice.operation_cancelable)
        assertFalse(slice.operation_active)
        assertTrue(slice.conflicted)
        assertEquals("This workspace conflicts with main", slice.conflict_title)
        assertTrue(slice.conflict_prompt.startsWith("Please resolve the merge conflicts"))
        assertTrue(slice.moves_to_done)
        assertEquals(listOf("continue_conflict", "abort_conflict"), slice.availability!!.allowed)
        val pr = slice.pull_request!!
        assertEquals("Open" to WorkspaceTone.WORKSPACE_TONE_SUCCESS, pr.state_label to pr.state_tone)
        assertEquals("waiting on checks", pr.merge_blocked_reason)
        assertEquals(listOf("checks running"), pr.signals.map { it.text })
        val readiness = slice.merge_readiness!!
        assertTrue(readiness.blocked)
        assertEquals(WorkspaceTone.WORKSPACE_TONE_DANGER, readiness.items.first().tone)
        assertEquals(listOf("squash", "merge_commit", "fast_forward"), readiness.strategies.map { it.strategy })
        assertNull(reviewSlice(WorkspaceReviewView(), null).pull_request)
    }

    @Test
    fun aCheckoutSliceListsWhatCanRunAndTheWorkspacesTheirActions() {
        val changes = Changeset(branch = "main", files = listOf(ChangedFile(path = "a", staged = true)))
        val slice = projectChangesSlice(ProjectChangesView(changes = changes, needsReconciliation = false, hasRemote = true))
        assertEquals(listOf("stage", "unstage", "discard_changes", "commit", "update", "validate", "push"), slice.allowed)
        assertTrue(projectChangesSlice(ProjectChangesView(changes = changes, pendingKind = "commit", needsReconciliation = false)).allowed.isEmpty())

        val workspaces = projectWorkspacesSlice(ProjectWorkspacesView(projectId = "p", workspaces = listOf(Workspace(card_id = "c", mode = "worktree", state = "ready", branch = "b")), titles = mapOf("c" to "Task")))
        val row = workspaces.rows.single()
        assertEquals("Task" to "b · ready", row.title to row.detail)
        assertTrue(row.can_clean_up && row.can_discard && !row.pending)
    }
}

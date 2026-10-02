package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.FileDiff
import com.dbpprt.dieter.api.v1.GitConflict
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.ValidationResult
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.api.v1.WorkspaceCommit
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The review's presentation: the merge checklist, conflicts, the pull request, diff paging, and the project lists. */
class ReviewPresentationTest {
    private val goTest = GitOperation(card_id = "c", kind = "validate", status = "succeeded", validation_results = listOf(ValidationResult(name = "go test")), finished_at = "2026-10-01T10:00:00Z")

    @Test
    fun aCleanWorkspaceIsReadyToMerge() {
        val readiness = MergeReadiness.of(Workspace(state = "ready"), Changeset(files = listOf(ChangedFile(), ChangedFile())), goTest, "c", "main")
        assertFalse(readiness.blocked)
        assertFalse(readiness.commitsFirst)
        assertEquals(listOf("conflicts", "validation"), readiness.items.map { it.id })
        assertEquals("No conflicts with main", readiness.items[0].text)
        assertEquals("go test passed on the workspace" to "2026-10-01T10:00:00Z", readiness.items[1].let { it.text to it.at })
        assertEquals(StatusTone.SUCCESS, readiness.items[1].tone)
        assertEquals("Merge 2 files", readiness.mergeTitle)
        assertEquals(ValidationSummary("go test passed", true, "2026-10-01T10:00:00Z"), readiness.validation)
        assertFalse(readiness.mergeFailed)
    }

    @Test
    fun conflictsBlockTheMergeAndADirtyTreeIsCommittedFirst() {
        val operation = GitOperation(card_id = "c", kind = "update", status = "waiting_for_resolution", conflicts = listOf(GitConflict(path = "a"), GitConflict(path = "b")))
        val readiness = MergeReadiness.of(Workspace(state = "conflicted", behind = 2, dirty = true), null, operation, "c", "main")
        assertTrue(readiness.blocked)
        assertTrue(readiness.commitsFirst)
        assertEquals("2 files conflict with main", readiness.items[0].text)
        assertEquals(StatusTone.DANGER, readiness.items[0].tone)
        assertEquals("main moved · 2 new commits", readiness.items.single { it.id == "behind" }.text)
        assertTrue(readiness.items.any { it.id == "uncommitted" })
        assertNull(readiness.validation, "only a finished operation's validation counts")
        assertEquals("Merge into main", readiness.mergeTitle)
        assertEquals("1 file conflicts with base", MergeReadiness.of(Workspace(state = "conflicted"), null, null, "c", "base").items[0].text)
    }

    @Test
    fun validationsAndStrategiesAreSummarized() {
        val failed = goTest.copy(validation_results = listOf(ValidationResult(name = "lint"), ValidationResult(name = "test", exit_code = 1)))
        assertEquals(ValidationSummary("2 validations failed", false, "2026-10-01T10:00:00Z"), MergeReadiness.validation(failed, "c"))
        assertEquals(StatusTone.WARNING, MergeReadiness.of(Workspace(), null, failed, "c", "main").items.single { it.id == "validation" }.tone)
        assertNull(MergeReadiness.validation(goTest, "other"))
        assertNull(MergeReadiness.validation(goTest.copy(status = "running"), "c"))
        assertNull(MergeReadiness.validation(goTest.copy(validation_results = emptyList()), "c"))

        val captions = MergeReadiness.strategies(3, "main").associate { it.strategy to it.caption }
        assertEquals("3 commits become one on main.", captions["squash"])
        assertEquals("Keeps every commit and adds a merge commit.", captions["merge_commit"])
        assertEquals("Moves main forward without a new commit.", captions["fast_forward"])
        assertEquals("The work lands as a single commit on main.", MergeReadiness.strategies(1, "main").first().caption)
        assertEquals(3, MergeReadiness.of(null, Changeset(commits = listOf(WorkspaceCommit(), WorkspaceCommit(), WorkspaceCommit())), null, "c", "main").strategies.size)
        assertTrue(MergeReadiness.of(null, null, GitOperation(card_id = "c", kind = "merge_local", status = "failed"), "c", "main").mergeFailed)
    }

    @Test
    fun theReviewShowsItsOperationConflictsPullRequestAndCard() {
        val card = Card(id = "c", scope = "chat", board_id = "b", workspace = WorkspaceSummary(base_branch = "develop"), pull_request = PullRequestSummary(number = 9, state = "open", checks_state = "failed"))
        val waiting = GitOperation(card_id = "c", status = "waiting_for_resolution", conflicts = listOf(GitConflict(path = "a.kt", hunk_count = 2)))
        val shown = ReviewPresentation.of(WorkspaceReviewView(cardId = "c", operation = waiting), card)
        assertTrue(shown.operationVisible)
        assertFalse(shown.operationCancelable, "a conflict is continued or aborted")
        assertEquals("develop", shown.base, "the card's summary names the base without a workspace")
        assertEquals("1 file conflicts with develop", shown.conflictTitle)
        assertTrue(shown.conflictPrompt.contains("- a.kt (2 hunks)"))
        assertTrue(shown.movesToDone, "a chat filed on a board has a lane")
        assertEquals("checks failed", shown.pullRequest?.mergeBlockedReason)

        val running = ReviewPresentation.of(WorkspaceReviewView(cardId = "c", workspace = Workspace(base_branch = "main"), operation = GitOperation(status = "running")), Card(scope = "chat"))
        assertTrue(running.operationCancelable)
        assertFalse(running.movesToDone, "an unfiled chat has no lane")
        assertNull(running.pullRequest)
        assertEquals("This workspace conflicts with main", running.conflictTitle)
        assertFalse(ReviewPresentation.of(WorkspaceReviewView(operation = GitOperation(status = "succeeded")), null).operationVisible)
        assertEquals("base", ReviewPresentation.of(WorkspaceReviewView(), null).base)
    }

    @Test
    fun aDiffLoadsMorePagesUpToItsLimit() {
        val page = FileDiff(truncated = true, next_offset = DiffPages.PAGE.toLong())
        assertTrue(WorkspaceReviewView(diff = page).diffMore)
        assertFalse(WorkspaceReviewView(diff = page).diffTooLarge)
        val limited = WorkspaceReviewView(diff = page.copy(next_offset = DiffPages.LIMIT))
        assertFalse(limited.diffMore)
        assertTrue(limited.diffTooLarge)
        assertFalse(WorkspaceReviewView(diff = FileDiff()).diffTooLarge, "a complete diff")
        assertTrue(ProjectChangesView(diff = page.copy(next_offset = DiffPages.LIMIT + 1)).diffTooLarge)
        assertTrue(ProjectChangesView(diff = page).diffMore)
    }

    @Test
    fun aViewLaysItsDiffOutForItsLayout() {
        val lines = UnifiedDiff.parse("@@ -1 +1 @@\n-a\n+b")
        val unified = WorkspaceReviewView(selectedPath = "a.kt").withDiffLines(lines)
        assertEquals(2, unified.layout.rows.count { it is DiffRow.Line })
        val split = unified.copy(split = true).withDiffLines(unified.diffLines)
        assertEquals(1, split.layout.rows.count { it is DiffRow.Pair })
        assertNotSame(unified.layout, split.layout)
        assertSame(unified.layout, unified.copy(loading = true).layout, "a change elsewhere keeps the layout")
        val commit = WorkspaceReviewView(selectedCommit = "abc").withDiffLines(UnifiedDiff.parse("diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b"))
        assertTrue(commit.wholeCommit)
        assertEquals(listOf("x"), commit.layout.rows.filterIsInstance<DiffRow.File>().map { it.path })
        assertSame(DiffLayout.EMPTY, unified.withDiffLines(emptyList()).layout)
    }

    @Test
    fun aStartInFlightOrAwaitingReconciliationBlocksTheReview() {
        val card = Card(id = "c", workspace_mode = "worktree")
        val view = WorkspaceReviewView(cardId = "c", workspace = Workspace(mode = "worktree", state = "ready", dirty = true), changeset = Changeset(files = listOf(ChangedFile(path = "a.kt"))))
        assertTrue(view.availability(card).allows("commit"))
        assertFalse(view.copy(needsReconciliation = true).availability(card).allows("commit"), "an ambiguous start waits for a refresh")
        assertFalse(view.copy(submitting = true).availability(card).allows("commit"))
        val waiting = view.copy(operation = GitOperation(card_id = "c", status = "waiting_for_resolution"))
        assertTrue(waiting.availability(card).allows("abort_conflict"))
        assertFalse(waiting.copy(needsReconciliation = true).availability(card).allows("abort_conflict"))
    }

    @Test
    fun commentsAttachToNumberedLinesOfOneFile() {
        val (hunk, deleted, added) = UnifiedDiff.parse("@@ -1 +1 @@\n-a\n+b")
        val file = WorkspaceReviewView(selectedPath = "a.kt")
        assertTrue(file.canComment(deleted))
        assertTrue(file.canComment(added))
        assertFalse(file.canComment(hunk), "a hunk header has no line number")
        assertFalse(WorkspaceReviewView(selectedCommit = "abc").canComment(added), "a whole commit takes no comments")
        assertFalse(WorkspaceReviewView(selectedPath = "a.kt", selectedCommit = "abc").canComment(added))
        assertFalse(WorkspaceReviewView().canComment(added))
    }

    @Test
    fun aCheckoutAllowsWhatItsStateAndRemoteAllow() {
        val changes = Changeset(branch = "main", files = listOf(ChangedFile(path = "a", staged = true), ChangedFile(path = "b", unstaged = true)), dirty = true)
        val view = ProjectChangesView(changes = changes, needsReconciliation = false, hasRemote = true)
        assertEquals(listOf("stage", "unstage", "discard_changes", "commit", "validate", "push"), view.allowed, "a dirty checkout does not update")
        assertEquals(listOf("stage", "unstage", "discard_changes", "commit", "validate"), view.copy(hasRemote = false).allowed)
        assertEquals(listOf("stage", "unstage", "discard_changes", "validate", "push"), view.copy(changes = changes.copy(files = listOf(ChangedFile(path = "b", unstaged = true)))).allowed, "a commit needs staged files")
        assertTrue(view.copy(pendingKind = "stage").allowed.isEmpty(), "nothing while an operation runs")
        assertTrue(ProjectChangesView().allowed.isEmpty())
        assertTrue(ProjectChangesView.ready("commit", "Subject"))
        assertFalse(ProjectChangesView.ready("commit", " "))
        assertTrue(ProjectChangesView.ready("stage", ""))
        assertEquals(mapOf("path" to "a"), ProjectChangesView.parameters("stage", path = "a"))
        assertEquals(emptyMap(), ProjectChangesView.parameters("unstage"))
    }

    @Test
    fun aCheckoutOpensOnItsFirstChange() {
        val both = Changeset(files = listOf(ChangedFile(path = "staged.swift", staged = true), ChangedFile(path = "edited.swift", unstaged = true)))
        assertEquals("edited.swift" to ChangeSection.UNSTAGED, ProjectChangesRules.first(both), "an unstaged change first")
        assertEquals("staged.swift" to ChangeSection.STAGED, ProjectChangesRules.first(Changeset(files = listOf(ChangedFile(path = "staged.swift", staged = true)))))
        assertNull(ProjectChangesRules.first(Changeset()))
    }

    @Test
    fun projectWorkspacesListWithTheirActions() {
        val view = ProjectWorkspacesView(
            projectId = "p",
            workspaces = listOf(
                Workspace(card_id = "clean", mode = "worktree", state = "ready", branch = "feature/x", path = "/w/x", size_bytes = 1536),
                Workspace(card_id = "dirty", mode = "worktree", state = "conflicted", changed_files = 1, additions = 4, deletions = 2),
                Workspace(card_id = "direct", mode = "project", state = "cleanup_pending", changed_files = 3),
            ),
            pending = setOf("dirty"),
            errors = mapOf("dirty" to "Workspace operation failed."),
            titles = mapOf("clean" to "Fold chats"),
        )
        val (clean, dirty, direct) = view.rows
        assertEquals("Fold chats", clean.title)
        assertEquals("feature/x · ready", clean.detail)
        assertEquals("0 files · +0 −0 · 1.5 KB", clean.stats)
        assertTrue(clean.canCleanUp && clean.canDiscard && !clean.pending)
        assertEquals("dirty", dirty.title, "the card ID when there is no title or branch")
        assertEquals("Worktree · conflicted", dirty.detail)
        assertTrue(dirty.conflicted && dirty.pending)
        assertFalse(dirty.canCleanUp || dirty.canDiscard, "nothing while one runs")
        assertEquals("Workspace operation failed.", dirty.error)
        assertEquals("1 file · +4 −2 · 0 B", dirty.stats)
        assertEquals("Project directory · cleanup pending", direct.detail)
        assertFalse(direct.canCleanUp || direct.canDiscard, "only a worktree is removed")
    }
}

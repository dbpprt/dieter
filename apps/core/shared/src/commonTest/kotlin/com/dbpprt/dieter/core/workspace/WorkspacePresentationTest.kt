package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.GitConflict
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.api.v1.WorkspaceCommit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WorkspacePresentationTest {
    @Test fun changedFilesMapStatusesToBadgesAndSplitPaths() {
        assertEquals("A", ChangedFiles.badge("added"))
        assertEquals("D", ChangedFiles.badge("d"))
        assertEquals("R", ChangedFiles.badge("renamed"))
        assertEquals("M", ChangedFiles.badge("modified"))
        assertEquals("!", ChangedFiles.badge("modified", conflicted = true))
        assertEquals("U", ChangedFiles.badge("modified", untracked = true))
        assertEquals("Added", ChangedFiles.title("A"))
        assertEquals("Conflicted", ChangedFiles.title("M", conflicted = true))
        assertEquals("Untracked", ChangedFiles.title("M", untracked = true))
        assertEquals("service.go", ChangedFiles.filename("internal/changeset/service.go"))
        assertEquals("internal/changeset", ChangedFiles.directory("internal/changeset/service.go"))
        assertEquals("", ChangedFiles.directory("README.md"))
    }

    @Test fun operationsStartImmediatelyAfterConfirmationOrThroughAForm() {
        assertEquals(OperationStart.IMMEDIATE, GitOperations.start(GitOperationKinds.REFRESH_PR))
        assertEquals(OperationStart.IMMEDIATE, GitOperations.start(GitOperationKinds.CONTINUE_CONFLICT))
        assertEquals(OperationStart.CONFIRM, GitOperations.start(GitOperationKinds.ABORT_CONFLICT))
        assertEquals(OperationStart.FORM, GitOperations.start(GitOperationKinds.COMMIT))
        assertTrue(GitOperations.destructive(GitOperationKinds.DISCARD))
        assertFalse(GitOperations.destructive(GitOperationKinds.CLEANUP))
        assertEquals("Commit changes", GitOperations.title("commit"))
        assertEquals("Future kind", GitOperations.title("future_kind"))
        assertEquals("Waiting for resolution", GitOperations.statusLabel(GitOperation(status = "waiting_for_resolution")))
        assertTrue(GitOperations.cancelable(GitOperation(status = "running")))
        assertFalse(GitOperations.cancelable(GitOperation(status = "waiting_for_resolution")))
        assertFalse(GitOperations.cancelable(GitOperation(status = "succeeded")))
        assertTrue(GitOperations.description("update", "main")!!.contains("latest main"))
        assertNull(GitOperations.description("stage", "main"))
    }

    @Test fun operationFormsNeedWhatTheDaemonNeeds() {
        val commit = GitOperationForm.initial("commit", Card(title = "Fix the crash"))
        assertEquals("Fix the crash", commit.subject)
        assertTrue(commit.ready)
        assertFalse(commit.copy(subject = " ").ready)
        assertEquals(mapOf("subject" to "Fix the crash", "body" to "Details", "stage_all" to "false"), commit.copy(body = " Details ", stageAll = false).parameters())
        assertEquals("", GitOperationForm.initial("update", Card(title = "x")).subject)
        assertEquals(mapOf("validate" to "true"), GitOperationForm("update").parameters())
        assertEquals(mapOf("draft" to "false"), GitOperationForm("create_pr").parameters())
        assertEquals(mapOf("title" to "Title", "body" to "Body", "draft" to "true"), GitOperationForm("create_pr", subject = "Title", body = "Body", draft = true).parameters())
        assertEquals(mapOf("strategy" to "rebase", "expected_head_sha" to "abc"), GitOperationForm("merge_pr", strategy = "rebase").parameters("abc"))
        assertEquals(mapOf("strategy" to "squash"), GitOperationForm("merge_pr").parameters())
        assertEquals(emptyMap(), GitOperationForm("push").parameters())
        assertEquals(listOf("squash", "merge", "rebase"), GitOperationForm.PULL_REQUEST_STRATEGIES.map { it.first })
    }

    @Test fun statusLinesPutTheMostImportantStateFirst() {
        assertEquals("Conflicted" to StatusTone.DANGER, WorkspaceStatus.status(Workspace(state = "conflicted", dirty = true), Changeset(volatile = true)))
        assertEquals("Merged · cleanup pending" to StatusTone.SUCCESS, WorkspaceStatus.status(Workspace(state = "cleanup_pending"), null))
        assertEquals("Provisioning" to StatusTone.NEUTRAL, WorkspaceStatus.status(Workspace(state = "reserved"), null))
        assertEquals("Needs attention · orphaned" to StatusTone.WARNING, WorkspaceStatus.status(Workspace(state = "orphaned"), null))
        assertEquals("Agent is working — live view" to StatusTone.ACTIVE, WorkspaceStatus.status(Workspace(dirty = true), Changeset(volatile = true)))
        assertEquals("Uncommitted changes", WorkspaceStatus.line(Workspace(dirty = true), null))
        assertNull(WorkspaceStatus.status(Workspace(state = "ready"), Changeset()))
        assertEquals("1 file · 2 commits · +40 −12", WorkspaceStatus.summary(Changeset(files = listOf(ChangedFile()), commits = listOf(WorkspaceCommit(), WorkspaceCommit()), additions = 40, deletions = 12)))
        assertEquals("a.kt · 1 hunk", WorkspaceStatus.conflict(GitConflict(path = "a.kt", hunk_count = 1)))
        assertTrue(WorkspaceStatus.settingsEditable(Card()))
        assertFalse(WorkspaceStatus.settingsEditable(Card(initial_prompt_sent_at = "2026-01-01T00:00:00Z")))
        assertFalse(WorkspaceStatus.movesToDone(Card(scope = "chat")))
        assertTrue(WorkspaceStatus.movesToDone(Card(scope = "board")))
    }

    @Test fun agentPromptsListCommentsAndConflicts() {
        val comments = listOf(ChangeComment(path = "a.kt", line = 3, body = " Rename this "), ChangeComment(path = "README.md", body = "Typo"))
        assertEquals("Please address these review comments:\n- a.kt:3 — Rename this\n- README.md — Typo", WorkspaceStatus.reviewPrompt(comments))
        val prompt = WorkspaceStatus.conflictPrompt(listOf(GitConflict(path = "a.kt", hunk_count = 2)))
        assertTrue(prompt.contains("- a.kt (2 hunks)"))
        assertTrue(prompt.endsWith("run validation, and report back."))
    }

    @Test fun reviewCommentsAnchorToTheSideTheyDescribe() {
        assertEquals("old" to 4, ReviewComments.anchor(DiffLine(1, DiffLineKind.DELETION, "-x", oldLine = 4)))
        assertEquals("new" to 7, ReviewComments.anchor(DiffLine(2, DiffLineKind.ADDITION, "+y", newLine = 7)))
        assertEquals("new" to 8, ReviewComments.anchor(DiffLine(3, DiffLineKind.CONTEXT, " z", oldLine = 5, newLine = 8)))
        assertNull(ReviewComments.anchor(DiffLine(0, DiffLineKind.HUNK, "@@")))
        val comments = listOf(ChangeComment(id = "1", path = "a.kt", side = "new", line = 7), ChangeComment(id = "2", path = "b.kt", side = "new", line = 7))
        assertEquals(mapOf(("new" to 7) to listOf(comments[0])), ReviewComments.byLine(comments, "a.kt"))
    }
}

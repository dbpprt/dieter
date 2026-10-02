package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.GitConflict
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.PullRequestSummary
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
        assertTrue(GitOperations.description("abort_conflict", "main")!!.contains("previous ready state"))
    }

    @Test fun operationFormsNeedWhatTheDaemonNeeds() {
        val commit = GitOperationForm.initial("commit", Card(title = "Fix the crash"))
        assertEquals("Fix the crash", commit.subject)
        assertTrue(commit.ready)
        assertFalse(commit.copy(subject = " ").ready)
        assertEquals(mapOf("subject" to "Fix the crash", "body" to "Details", "stage_all" to "false"), commit.copy(body = " Details ", stageAll = false).parameters())
        assertEquals("", GitOperationForm.initial("update", Card(title = "x")).subject)
        assertEquals(mapOf("fetch" to "true", "validate" to "true"), GitOperationForm("update").parameters())
        assertEquals(mapOf("fetch" to "false", "validate" to "false"), GitOperationForm("update", fetch = false, validate = false).parameters())
        assertEquals(mapOf("draft" to "false", "push" to "true"), GitOperationForm("create_pr").parameters())
        assertEquals(mapOf("title" to "Title", "body" to "Body", "draft" to "true", "push" to "false"), GitOperationForm("create_pr", subject = " Title ", body = "Body", draft = true, push = false).parameters())
        assertEquals(mapOf("strategy" to "rebase", "expected_head_sha" to "abc"), GitOperationForm("merge_pr", strategy = "rebase").parameters("abc"))
        assertEquals(mapOf("strategy" to "squash"), GitOperationForm("merge_pr").parameters())
        assertEquals(mapOf("force_with_lease" to "false"), GitOperationForm("push", expectedRemoteSha = "abc").parameters())
        assertEquals(mapOf("force_with_lease" to "true", "expected_remote_sha" to "abc"), GitOperationForm("push", forceWithLease = true, expectedRemoteSha = " abc ").parameters())
        assertEquals(mapOf("strategy" to "fast_forward", "subject" to "Ship it", "validate" to "false"), GitOperationForm("merge_local", subject = "Ship it ", strategy = "fast_forward", validate = false).parameters())
        assertEquals(mapOf("strategy" to "squash", "validate" to "true"), GitOperationForm("merge_local").parameters())
        assertEquals(mapOf("validate" to "false"), GitOperationForm("continue_conflict", validate = false).parameters())
        assertEquals(emptyMap(), GitOperationForm("abort_conflict").parameters(), "the daemon names the conflicted operation")
        assertEquals(mapOf("target_card_id" to "c_next"), GitOperationForm("adopt", targetCardId = " c_next ").parameters())
        assertEquals(listOf("squash", "merge", "rebase"), GitOperationForm.PULL_REQUEST_STRATEGIES.map { it.first })
    }

    @Test fun operationFormsAreReadyWithWhatTheyNeedAndStartFromTheConversation() {
        assertFalse(GitOperationForm("create_pr").ready, "a pull request needs a title")
        assertTrue(GitOperationForm("create_pr", subject = "Title").ready)
        assertFalse(GitOperationForm("adopt").ready)
        assertTrue(GitOperationForm("adopt", targetCardId = "c_1").ready)
        assertTrue(GitOperationForm("push").ready)
        assertFalse(GitOperationForm("push", forceWithLease = true).ready, "a forced push names the remote head it expects")
        assertTrue(GitOperationForm("push", forceWithLease = true, expectedRemoteSha = "abc").ready)
        assertTrue(GitOperationForm("update").ready)

        val card = Card(title = "Fold chats", initial_prompt = "Fold each project", pull_request = PullRequestSummary(number = 4, head_sha = "abc"))
        assertEquals("Fold chats" to "Fold each project", GitOperationForm.initial("create_pr", card).let { it.subject to it.body })
        assertEquals("Fold chats" to "", GitOperationForm.initial("merge_local", card).let { it.subject to it.body })
        assertEquals("abc", GitOperationForm.initial("push", card).expectedRemoteSha)
        assertEquals("", GitOperationForm.initial("validate", card).subject)
        assertEquals("squash", GitOperationForm.initial("merge_pr", card).strategy)

        assertEquals(listOf(GitFormField.FETCH, GitFormField.VALIDATE), GitOperations.fields("update"))
        assertEquals(listOf(GitFormField.SUBJECT, GitFormField.BODY, GitFormField.PUSH, GitFormField.DRAFT), GitOperations.fields("create_pr"))
        assertEquals(listOf(GitFormField.STRATEGY, GitFormField.SUBJECT, GitFormField.VALIDATE), GitOperations.fields("merge_local"))
        assertEquals(listOf(GitFormField.TARGET_CARD_ID), GitOperations.fields("adopt"))
        assertTrue(GitOperations.fields("cleanup").isEmpty())
        assertEquals(listOf("squash", "merge_commit", "fast_forward"), GitOperations.strategies("merge_local").map { it.first })
        assertEquals(listOf("squash", "merge", "rebase"), GitOperations.strategies("merge_pr").map { it.first })
        assertTrue(GitOperations.strategies("push").isEmpty())
        assertTrue(GitOperations.description("merge_local", "main")!!.contains("main"))
        assertTrue(GitOperations.visible(GitOperation(status = "failed")))
        assertTrue(GitOperations.visible(GitOperation(status = "waiting_for_resolution")))
        assertFalse(GitOperations.visible(GitOperation(status = "succeeded")))
        assertFalse(GitOperations.visible(null))
    }

    @Test fun statusLinesPutTheMostImportantStateFirst() {
        assertEquals("Conflicted" to StatusTone.DANGER, WorkspaceStatus.status(Workspace(state = "conflicted", dirty = true), Changeset(volatile = true)))
        assertEquals("Merged · cleanup pending" to StatusTone.SUCCESS, WorkspaceStatus.status(Workspace(state = "cleanup_pending"), null))
        assertEquals("Provisioning" to StatusTone.NEUTRAL, WorkspaceStatus.status(Workspace(state = "reserved"), null))
        assertEquals("Needs attention · orphaned" to StatusTone.WARNING, WorkspaceStatus.status(Workspace(state = "orphaned"), null))
        assertEquals("Agent is working — live view" to StatusTone.ACTIVE, WorkspaceStatus.status(Workspace(dirty = true), Changeset(volatile = true)))
        assertEquals("Uncommitted changes", WorkspaceStatus.line(Workspace(dirty = true), null))
        assertNull(WorkspaceStatus.status(Workspace(state = "ready"), Changeset()))
        assertEquals(
            listOf("Ready", "Conflicted", "Provisioning", "Provisioning", "Cleanup pending", "Recovery required", ""),
            listOf("ready", "conflicted", "provisioning", "reserved", "cleanup_pending", "recovery_required", "").map(WorkspaceStatus::stateLabel),
        )
        assertEquals("1 file · 2 commits · +40 −12", WorkspaceStatus.summary(Changeset(files = listOf(ChangedFile()), commits = listOf(WorkspaceCommit(), WorkspaceCommit()), additions = 40, deletions = 12)))
        assertEquals("a.kt · 1 hunk", WorkspaceStatus.conflict(GitConflict(path = "a.kt", hunk_count = 1)))
        assertTrue(WorkspaceStatus.settingsEditable(Card()))
        assertFalse(WorkspaceStatus.settingsEditable(Card(initial_prompt_sent_at = "2026-01-01T00:00:00Z")))
        assertFalse(WorkspaceStatus.movesToDone(Card(scope = "chat")))
        assertTrue(WorkspaceStatus.movesToDone(Card(scope = "board")))
        assertTrue(WorkspaceStatus.movesToDone(Card(scope = "chat", board_id = "b")), "a chat filed on a board has a lane")
    }

    @Test fun agentPromptsListCommentsAndConflicts() {
        val comments = listOf(ChangeComment(path = "a.kt", line = 3, body = " Rename this "), ChangeComment(path = "README.md", body = "Typo"))
        assertEquals("Please address these review comments:\n- a.kt:3 — Rename this\n- README.md — Typo", WorkspaceStatus.reviewPrompt(comments))
        val prompt = WorkspaceStatus.conflictPrompt(listOf(GitConflict(path = "a.kt", hunk_count = 2)))
        assertTrue(prompt.contains("- a.kt (2 hunks)"))
        assertTrue(prompt.endsWith("run validation, and report back."))
        assertEquals("Please resolve the merge conflicts in this workspace.\nResolve the conflict markers, run validation, and report back.", WorkspaceStatus.conflictPrompt(emptyList()))
        assertEquals("1 file conflicts with main", WorkspaceStatus.conflictTitle(1, "main"))
        assertEquals("2 files conflict with main", WorkspaceStatus.conflictTitle(2, "main"))
        assertEquals("This workspace conflicts with base", WorkspaceStatus.conflictTitle(0, "base"))
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

package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationLogEntry
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import com.dbpprt.dieter.core.composition.WorkspaceMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WorkspaceRulesTest {
    @Test
    fun parserNumbersBothSidesAndResetsBetweenFiles() {
        val lines = UnifiedDiff.parse("diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -10,3 +20,4 @@ fun main\n context\n-old\n+new\n+more\n tail\n")
        assertEquals(listOf(DiffLineKind.HEADER, DiffLineKind.HEADER, DiffLineKind.HEADER, DiffLineKind.HEADER, DiffLineKind.HUNK), lines.take(5).map { it.kind })
        val context = lines[5]
        assertEquals(10 to 20, context.oldLine to context.newLine)
        assertEquals(11, lines[6].oldLine)
        assertEquals(listOf(21, 22), lines.filter { it.kind == DiffLineKind.ADDITION }.map { it.newLine })
        assertEquals(12 to 23, lines.last().let { it.oldLine to it.newLine })
        assertEquals(10, lines.size, "the patch terminator is not a line")

        val inHunk = UnifiedDiff.parse("@@ -1 +1 @@\n---x\n+++y\n\\ No newline at end of file")
        assertEquals(listOf(DiffLineKind.HUNK, DiffLineKind.DELETION, DiffLineKind.ADDITION, DiffLineKind.HEADER), inHunk.map { it.kind })

        val commit = UnifiedDiff.parse("diff --git a/a b/a\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/c b/d\nrename from c\nrename to d\n@@ -5 +6 @@\n kept")
        assertEquals(DiffLineKind.HEADER, commit[5].kind)
        assertEquals(5 to 6, commit.last().let { it.oldLine to it.newLine })
    }

    @Test
    fun displayFoldsLongContextAndCountsSkippedLines() {
        val context = (1..40).joinToString("\n") { " line $it" }
        val lines = UnifiedDiff.parse("@@ -1,41 +1,41 @@\n$context\n-a\n+b\n@@ -300,2 +300,2 @@\n x\n-y")
        val rows = DiffDisplay.rows(lines, split = false)
        val fold = rows.filterIsInstance<DiffRow.Fold>().single()
        assertEquals(30, fold.count, "a run between a hunk and a change keeps five lines on each side")
        assertEquals(listOf(0, 258), rows.filterIsInstance<DiffRow.Hunk>().map { it.skippedLines })
        assertEquals("-1,41 +1,41", rows.filterIsInstance<DiffRow.Hunk>().first().text)
        assertEquals("-1,2 +1,2 fun x", DiffDisplay.hunkText("@@ -1,2 +1,2 @@ fun x"))

        val short = DiffDisplay.rows(UnifiedDiff.parse("@@ -1,3 +1,3 @@\n a\n b\n-c\n+d"), split = false)
        assertTrue(short.none { it is DiffRow.Fold })

        val split = DiffDisplay.rows(UnifiedDiff.parse("@@ -1,3 +1,4 @@\n-a\n-b\n+c\n+d\n+e\n x"), split = true)
        val pairs = split.filterIsInstance<DiffRow.Pair>()
        assertEquals(4, pairs.size)
        assertEquals(listOf(true, true, false, true), pairs.map { it.old != null })

        val whole = DiffDisplay.rows(UnifiedDiff.parse("diff --git a/x b/src/x.kt\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/y b/y.kt\n@@ -1 +1 @@\n-c\n+d"), split = false, wholeCommit = true)
        assertEquals(listOf("src/x.kt", "y.kt"), whole.filterIsInstance<DiffRow.File>().map { it.path })
        assertEquals(mapOf(1 to (1 to 1)), DiffDisplay.hunkDeltas(UnifiedDiff.parse("h\n@@ -1 +1 @@\n-a\n+b")).filterKeys { it == 1 })
    }

    private fun availability(
        agent: Boolean = false, operation: Boolean = false, state: String = "ready", mode: WorkspaceMode = WorkspaceMode.WORKTREE, changed: Int = 0,
        commits: Boolean = false, remote: Boolean = false, auth: Boolean = false, pr: Boolean = false, dirty: Boolean = false,
        branch: String = "feature", base: String = "main", publish: String = "manual",
    ) = WorkspaceAvailability(agent, operation, state, mode, changed, commits, remote, auth, pr, dirty, branch, base, publish)

    @Test
    fun actionsFollowTheWorkspaceRules() {
        assertFalse(availability(agent = true, dirty = true).allows("commit"))
        assertFalse(availability(operation = true).allows("update"))
        assertEquals(listOf(true, true), listOf("continue_conflict", "abort_conflict").map { availability(state = "conflicted").allows(it) })
        assertFalse(availability(state = "conflicted").allows("update"))
        assertTrue(availability(changed = 1).allows("commit"))
        assertFalse(availability().allows("commit"))
        assertTrue(availability(commits = true).allows("merge_local"))
        assertFalse(availability(commits = true, changed = 1).allows("merge_local"))
        assertFalse(availability(commits = true, publish = "pull_request").allows("merge_local"))
        assertTrue(availability(commits = true, remote = true).allows("push"))
        assertTrue(availability(commits = true, remote = true, auth = true).allows("create_pr"))
        assertFalse(availability(commits = true, remote = true, auth = true, publish = "push_base").allows("create_pr"))
        assertTrue(availability(publish = "push_base").mergeDestination.contains("pushed to the configured base remote"))
        assertTrue(availability().mergeDestination.contains("nothing is pushed"))
        assertTrue(availability(pr = true, auth = true).allows("merge_pr"))
        assertTrue(availability(changed = 1).allows("discard"))
        assertFalse(availability(changed = 1).allows("cleanup"))
        assertTrue(availability(changed = 1).allowsMergeFlow)
        assertTrue(availability(state = "conflicted").allowsMergeFlow)
        assertFalse(availability().allowsMergeFlow)
        assertFalse(availability(changed = 1, mode = WorkspaceMode.PROJECT).allowsMergeFlow)
        assertFalse(availability(changed = 1, publish = "push_base").allowsMergeFlow)
        val derived = WorkspaceAvailability.of(Card(runtime = "idle", workspace_mode = "legacy", workspace = WorkspaceSummary(ahead = 2, mode = "worktree")), null, null, null, GitOperation(status = "running"))
        assertTrue(derived.hasCommits)
        assertTrue(derived.operationActive)
        assertEquals(WorkspaceMode.WORKTREE, derived.mode)
        assertEquals(WorkspaceMode.PROJECT, WorkspaceMode.parse("main"))
    }

    @Test
    fun operationsReconcileAndLogsMergeBySequence() {
        assertEquals("ws", GitOperations.reconciliationId("ws", GitOperation(id = "obs", card_id = "c", status = "running"), "c"))
        assertEquals("obs", GitOperations.reconciliationId("", GitOperation(id = "obs", card_id = "c", status = "running"), "c"))
        assertNull(GitOperations.reconciliationId("", GitOperation(id = "obs", card_id = "c", status = "succeeded"), "c"))
        val existing = listOf(GitOperationLogEntry(sequence = 1, message = "first"), GitOperationLogEntry(sequence = 3, message = "third"))
        val merged = GitOperations.mergeLogs(existing, listOf(GitOperationLogEntry(sequence = 3, message = "dup"), GitOperationLogEntry(sequence = 2, message = "second")))
        assertEquals(listOf("first", "second", "third"), merged.map { it.message })
        assertTrue(GitOperations.mergeLogs(existing, listOf(existing[0])) === existing)
        assertEquals(2, GitOperations.trimLogs(merged, maxEntries = 2).size)
        assertEquals(7L, GitOperations.cursor(2, GitOperation(sequence = 5), listOf(GitOperationLogEntry(sequence = 7))))
        assertEquals("Merge locally", GitOperations.title("merge_local"))
        assertEquals("Future op", GitOperations.title("future_op"))
    }

    @Test
    fun pullRequestsAndBadges() {
        assertEquals("draft", PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", draft = true, mergeable = true)))
        assertEquals("already merged", PullRequests.mergeBlockedReason(PullRequestSummary(state = "MERGED")))
        assertEquals("checks failed", PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", checks_state = "failure", mergeable = true)))
        assertNull(PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", checks_state = "success", mergeable = true)))
        assertTrue(PullRequests.canAskAgent(PullRequestSummary(state = "open", review_decision = "changes_requested")))

        assertNull(WorkspaceBadge.of(Card()))
        val badge = WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(mode = "worktree", branch = "feature/card-branches", ahead = 2, behind = 1)))!!
        assertEquals("feature/card-branches", badge.title)
        assertEquals("Workspace: Worktree · feature/card-branches · 2 ahead, 1 behind", badge.accessibilityLabel)
        assertEquals("Conflicts", WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(state = "conflicted", changed_files = 3)))!!.title)
        assertEquals("3 changed", WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(changed_files = 3)))!!.title)
        assertEquals("Project", WorkspaceBadge.of(Card(workspace_mode = "main"))!!.title)
    }

    @Test
    fun validationCommandsRoundTripAndValidate() {
        val command = ValidationCommand(name = "test", executable = "go", arguments = listOf("test", "  ./... "), working_directory = "sub", environment = mapOf("B" to "2", "A" to "x=y"), timeout_seconds = 300)
        val draft = ValidationCommandDraft.from(command)
        assertEquals("A=x=y\nB=2", draft.environment)
        assertEquals(command, draft.toCommand())
        assertEquals("0", ValidationCommandDraft.from(ValidationCommand()).timeoutSeconds)
        assertEquals("Every validation command needs an executable.", ValidationCommandDraft.problem(listOf(ValidationCommandDraft())))
        assertEquals("Validation timeout must be a number from 0 to 3600.", ValidationCommandDraft.problem(listOf(draft.copy(timeoutSeconds = "4000"))))
        assertEquals("Validation working directories must stay inside the workspace.", ValidationCommandDraft.problem(listOf(draft.copy(workingDirectory = "a\\..\\b"))))
        assertEquals("Environment entries must use KEY=VALUE, one per line.", ValidationCommandDraft.problem(listOf(draft.copy(environment = "=bad"))))
        assertNull(ValidationCommandDraft.problem(listOf(draft)))
    }
}

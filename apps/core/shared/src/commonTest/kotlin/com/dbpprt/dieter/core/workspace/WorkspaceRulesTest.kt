package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationLogEntry
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.SCMCapabilities
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import com.dbpprt.dieter.core.composition.WorkspaceMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
    fun anEmptyAddedOrContextLineIsALineButThePatchTerminatorIsNot() {
        val added = UnifiedDiff.parse("@@ -0,0 +1,2 @@\n+new line\n+\n")
        assertTrue(added.none { it.kind == DiffLineKind.CONTEXT })
        assertEquals(listOf(1, 2), added.filter { it.kind == DiffLineKind.ADDITION }.map { it.newLine })
        val context = UnifiedDiff.parse("@@ -1 +1 @@\n \n")
        assertEquals(DiffLineKind.CONTEXT, context.last().kind)
        assertEquals(1, context.last().newLine)
    }

    private fun availability(
        agent: Boolean = false, operation: Boolean = false, state: String = "ready", mode: WorkspaceMode = WorkspaceMode.WORKTREE, changed: Int = 0,
        commits: Boolean = false, remote: Boolean = false, auth: Boolean = false, pr: Boolean = false, dirty: Boolean = false,
        branch: String = "feature", base: String = "main", publish: String = "manual",
    ) = WorkspaceAvailability(agent, operation, state, mode, changed, commits, remote, auth, pr, dirty, branch, base, publish)

    @Test
    fun aProjectDirectoryPublishesOnlyAReviewBranchAndPushBaseMergesLocally() {
        val feature = availability(mode = WorkspaceMode.PROJECT, commits = true, remote = true, auth = true, branch = "feature/direct", base = "main")
        assertTrue(feature.allows("push"))
        assertTrue(feature.allows("create_pr"))
        assertFalse(feature.allows("merge_local"))
        assertFalse(feature.allows("discard"))
        assertFalse(feature.allowsMergeFlow)
        val base = availability(mode = WorkspaceMode.PROJECT, commits = true, remote = true, auth = true, branch = "main", base = "main")
        assertFalse(base.allows("push"))
        assertFalse(base.allows("create_pr"))
        val pushBase = availability(commits = true, remote = true, auth = true, publish = "push_base")
        assertTrue(pushBase.allowsMergeFlow)
        assertTrue(pushBase.allows("merge_local"))
        assertFalse(pushBase.allows("create_pr"))
    }

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
        val derived = WorkspaceAvailability.of(Card(runtime = "idle", workspace_mode = "other", workspace = WorkspaceSummary(ahead = 2, mode = "worktree")), null, null, null, GitOperation(status = "running"))
        assertTrue(derived.hasCommits)
        assertTrue(derived.operationActive)
        assertEquals(WorkspaceMode.WORKTREE, derived.mode)
        assertEquals(WorkspaceMode.PROJECT, WorkspaceMode.parse("main"))
    }

    @Test
    fun anOperationWaitingOnAConflictLeavesTheConflictActionsAndTheMergeFlowOpen() {
        // The daemon keeps the stopped operation as the workspace's current one and admits continue or abort beside it.
        val card = Card(runtime = "idle", workspace_mode = "worktree", workspace = WorkspaceSummary(mode = "worktree", state = "conflicted", ahead = 1))
        val waiting = WorkspaceAvailability.of(card, Workspace(mode = "worktree", state = "conflicted", branch = "feature", base_branch = "main"), null, null, GitOperation(status = "waiting_for_resolution"))
        assertFalse(waiting.operationActive)
        assertTrue(waiting.conflicted)
        assertTrue(waiting.allows("continue_conflict"))
        assertTrue(waiting.allows("abort_conflict"))
        assertFalse(waiting.allows("update"), "only the conflict actions while conflicted")
        assertTrue(waiting.allowsMergeFlow, "the merge sheet resolves the conflict")
        assertFalse(WorkspaceAvailability.of(card, null, null, null, GitOperation(status = "waiting_for_resolution"), submitting = true).allows("abort_conflict"), "not while a start is in flight")
        val stopped = WorkspaceAvailability.of(Card(runtime = "idle", workspace_mode = "worktree"), Workspace(mode = "worktree", state = "ready"), null, null, GitOperation(status = "waiting_for_resolution"))
        assertTrue(stopped.conflicted, "a waiting operation alone makes the workspace conflicted")
        assertTrue(stopped.allows("continue_conflict"))

        val review = WorkspaceReviewView(operation = GitOperation(status = "waiting_for_resolution"))
        assertFalse(review.operationActive)
        assertTrue(review.conflicted)
        assertTrue(WorkspaceReviewView(operation = GitOperation(status = "running")).operationActive)
    }

    @Test
    fun aBlockedPullRequestCannotMerge() {
        val open = PullRequestSummary(number = 7, state = "open", mergeable = true, checks_state = "passed")
        fun availability(pr: PullRequestSummary) =
            WorkspaceAvailability.of(Card(runtime = "idle", workspace_mode = "worktree", pull_request = pr), null, null, SCMCapabilities(authenticated = true), null)
        assertTrue(availability(open).allows("merge_pr"))
        assertTrue(availability(open).allows("refresh_pr"))
        val running = availability(open.copy(checks_state = "running"))
        assertFalse(running.allows("merge_pr"))
        assertEquals("waiting on checks", running.pullRequestBlocked)
        assertTrue(running.allows("refresh_pr"))
        assertFalse(availability(open.copy(draft = true)).allows("merge_pr"))
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
        // The daemon reports checks as "passed", "running", or "failed".
        assertEquals("draft", PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", draft = true, mergeable = true)))
        assertEquals("already merged", PullRequests.mergeBlockedReason(PullRequestSummary(state = "MERGED")))
        assertEquals("already closed", PullRequests.mergeBlockedReason(PullRequestSummary(state = "closed", draft = true)))
        assertEquals("checks failed", PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", checks_state = "failed", mergeable = true)))
        assertEquals("waiting on checks", PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", checks_state = "running", mergeable = true)))
        assertEquals("not mergeable", PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", checks_state = "passed")))
        assertNull(PullRequests.mergeBlockedReason(PullRequestSummary(state = "open", checks_state = "passed", mergeable = true)))
        assertEquals(listOf("running", "failed", "passed", ""), listOf("pending", "FAILURE", "success", "unknown").map { PullRequests.checks(PullRequestSummary(checks_state = it)) }, "other providers' words read the same")
        assertTrue(PullRequests.canAskAgent(PullRequestSummary(state = "open", review_decision = "changes_requested")))

        assertNull(WorkspaceBadge.of(Card()))
        val badge = WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(mode = "worktree", branch = "feature/card-branches", ahead = 2, behind = 1)))!!
        assertEquals("feature/card-branches", badge.title)
        assertEquals("Workspace: Worktree · feature/card-branches · 2 ahead, 1 behind", badge.accessibilityLabel)
        assertEquals("Conflicts", WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(state = "conflicted", changed_files = 3)))!!.title)
        assertEquals("3 changed", WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(changed_files = 3)))!!.title)
        assertEquals("Project", WorkspaceBadge.of(Card(workspace_mode = "main"))!!.title)
        val withPullRequest = WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace_branch = "feature/x", pull_request = PullRequestSummary(number = 12), workspace = WorkspaceSummary(changed_files = 2)))!!
        assertEquals("PR #12", withPullRequest.title)
        assertEquals("feature/x", withPullRequest.fullTitle, "a conversation's header names the branch")
        assertEquals("Workspace: Worktree · feature/x · PR #12", withPullRequest.accessibilityLabel)
        assertEquals("Conflicts", WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(state = "conflicted")))!!.fullTitle)
        assertEquals("Worktree", WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = WorkspaceSummary(changed_files = 3)))!!.fullTitle)
    }

    /** Ported from Android's `WorkspaceCardBadgeTest`: a conflict outranks a pull request, which outranks changes. */
    @Test
    fun cardBadgesRankConflictsAbovePullRequestsAboveChanges() {
        val summary = WorkspaceSummary(mode = "worktree", branch = "feature/card-branches", state = "conflicted", changed_files = 3)
        val conflicted = WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = summary, pull_request = PullRequestSummary(number = 42)))!!
        assertEquals("Conflicts", conflicted.title)
        assertTrue(conflicted.conflicted)
        val pullRequest = WorkspaceBadge.of(Card(workspace_mode = "worktree", workspace = summary.copy(state = "ready"), pull_request = PullRequestSummary(number = 42)))!!
        assertEquals("PR #42", pullRequest.title)
        assertFalse(pullRequest.conflicted)
        assertEquals("Worktree", WorkspaceBadge.of(Card(workspace_mode = "worktree"))!!.title)
        assertEquals("Project", WorkspaceBadge.of(Card(workspace_mode = "branch"))!!.title)
    }

    @Test
    fun pullRequestsReadAsTheReviewShowsThem() {
        val running = PullRequests.view(PullRequestSummary(number = 142, url = "https://x/142", state = "open", mergeable = true, checks_state = "running", review_decision = "review_required", last_synced_at = "2026-10-01T10:00:00Z"))!!
        assertEquals("Open", running.stateLabel)
        assertEquals(StatusTone.SUCCESS, running.stateTone)
        assertEquals("waiting on checks", running.mergeBlockedReason)
        assertEquals(listOf("checks running" to StatusTone.ACTIVE, "review requested" to StatusTone.WARNING), running.signals.map { it.text to it.tone })
        assertFalse(running.canAskAgent)
        assertEquals("2026-10-01T10:00:00Z", running.lastSyncedAt)

        val failing = PullRequests.view(PullRequestSummary(number = 142, state = "open", mergeable = true, checks_state = "failed", review_decision = "changes_requested"))!!
        assertTrue(failing.canAskAgent)
        assertEquals("checks failed", failing.mergeBlockedReason)
        assertEquals(listOf(StatusTone.DANGER, StatusTone.WARNING), failing.signals.map { it.tone })
        assertTrue(failing.askAgentPrompt.contains("#142"))
        assertTrue(failing.askAgentPrompt.contains("failing checks and requested review changes"))

        val ready = PullRequests.view(PullRequestSummary(number = 1, state = "open", mergeable = true, checks_state = "passed", review_decision = "approved"))!!
        assertNull(ready.mergeBlockedReason)
        assertFalse(ready.canAskAgent)
        assertEquals(listOf("checks passed", "approved"), ready.signals.map { it.text })
        assertEquals("Pull request #1 needs attention: please address the open review feedback, push the fixes to the pull request branch, and summarize what changed.", PullRequests.askAgentPrompt(PullRequestSummary(number = 1)))

        val merged = PullRequests.view(PullRequestSummary(number = 3, state = "merged", checks_state = "passed"))!!
        assertEquals("Merged" to StatusTone.NEUTRAL, merged.stateLabel to merged.stateTone)
        assertEquals("already merged", merged.mergeBlockedReason)
        assertEquals("Closed" to StatusTone.DANGER, PullRequests.stateLabel(PullRequestSummary(state = "closed")) to PullRequests.stateTone(PullRequestSummary(state = "closed")))
        assertEquals("Draft" to StatusTone.NEUTRAL, PullRequests.stateLabel(PullRequestSummary(state = "open", draft = true)) to PullRequests.stateTone(PullRequestSummary(state = "open", draft = true)))
        assertNull(PullRequests.view(PullRequestSummary(number = 0)))
        assertNull(PullRequests.view(null))
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

    @Test
    fun aSelectedFileFollowsItselfBetweenTheStagedAndUnstagedHalves() {
        val readme = ChangedFile(path = "README.md", staged = true)
        val partial = ChangedFile(path = "notes.txt", staged = true, unstaged = true)
        val changes = Changeset(files = listOf(readme, partial))
        assertEquals("README.md" to ChangeSection.STAGED, ProjectChangesRules.follow(changes, "README.md", ChangeSection.UNSTAGED), "staging moves the selection")
        assertEquals("README.md" to ChangeSection.STAGED, ProjectChangesRules.follow(changes, "README.md", ChangeSection.STAGED))
        assertEquals("notes.txt" to ChangeSection.UNSTAGED, ProjectChangesRules.follow(changes, "notes.txt", ChangeSection.UNSTAGED), "a half that still exists stays")
        assertNull(ProjectChangesRules.follow(changes, "gone.txt", ChangeSection.UNSTAGED), "a file that left the changes clears the selection")
    }
}

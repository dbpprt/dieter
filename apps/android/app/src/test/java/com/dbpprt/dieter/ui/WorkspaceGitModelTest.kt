package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Changeset
import com.dbpprt.dieter.v1.ChangedFile
import com.dbpprt.dieter.v1.GitOperation
import com.dbpprt.dieter.v1.GitOperationLogEntry
import com.dbpprt.dieter.v1.SCMCapabilities
import com.dbpprt.dieter.v1.Workspace
import com.dbpprt.dieter.v1.WorkspaceCommit
import com.dbpprt.dieter.v1.WorkspaceSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedDiffParserTest {
    @Test
    fun numbersAdditionsDeletionsAndContextFromHunkHeaders() {
        val lines = UnifiedDiffParser.parse(
            """
            diff --git a/main.go b/main.go
            index 123..456 100644
            --- a/main.go
            +++ b/main.go
            @@ -10,3 +20,4 @@ func main() {
             context
            -removed
            +added one
            +added two
            """.trimIndent(),
        )
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[0].kind)
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[1].kind)
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[2].kind)
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[3].kind)
        assertEquals(UnifiedDiffLine.Kind.HUNK, lines[4].kind)

        val context = lines[5]
        assertEquals(UnifiedDiffLine.Kind.CONTEXT, context.kind)
        assertEquals(10, context.oldLine)
        assertEquals(20, context.newLine)

        val removed = lines[6]
        assertEquals(UnifiedDiffLine.Kind.DELETION, removed.kind)
        assertEquals(11, removed.oldLine)
        assertNull(removed.newLine)

        val addedOne = lines[7]
        assertEquals(UnifiedDiffLine.Kind.ADDITION, addedOne.kind)
        assertEquals(21, addedOne.newLine)
        assertNull(addedOne.oldLine)

        val addedTwo = lines[8]
        assertEquals(22, addedTwo.newLine)
    }

    @Test
    fun resetsNumberingForEachFileSectionInCommitPatches() {
        val lines = UnifiedDiffParser.parse(
            """
            diff --git a/a.txt b/a.txt
            @@ -1 +1 @@
            -old
            +new
            diff --git a/b.txt b/b.txt
            rename from old-name.txt
            rename to b.txt
            @@ -5 +6 @@
             kept
            """.trimIndent(),
        )
        val secondHeader = lines.indexOfFirst { it.text.contains("b/b.txt") }
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[secondHeader].kind)
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[secondHeader + 1].kind)
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines[secondHeader + 2].kind)
        val kept = lines.last()
        assertEquals(UnifiedDiffLine.Kind.CONTEXT, kept.kind)
        assertEquals(5, kept.oldLine)
        assertEquals(6, kept.newLine)
    }

    @Test
    fun plusAndMinusInsideHunksAreNeverMetadata() {
        val lines = UnifiedDiffParser.parse(
            """
            @@ -1,2 +1,2 @@
            ---literal minus content
            +++literal plus content
            """.trimIndent(),
        )
        assertEquals(UnifiedDiffLine.Kind.DELETION, lines[1].kind)
        assertEquals(UnifiedDiffLine.Kind.ADDITION, lines[2].kind)
    }

    @Test
    fun keepsNoNewlineMarkerAsHeader() {
        val lines = UnifiedDiffParser.parse("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file")
        assertEquals(UnifiedDiffLine.Kind.HEADER, lines.last().kind)
    }
}

class WorkspaceActionAvailabilityTest {
    private fun availability(
        agentActive: Boolean = false,
        operationActive: Boolean = false,
        workspaceState: String = "ready",
        workspaceMode: String = "worktree",
        changedFiles: Int = 0,
        hasCommits: Boolean = false,
        hasRemote: Boolean = false,
        scmAuthenticated: Boolean = false,
        hasPullRequest: Boolean = false,
        dirty: Boolean = false,
    ) = WorkspaceActionAvailability(
        agentActive, operationActive, workspaceState, workspaceMode,
        changedFiles, hasCommits, hasRemote, scmAuthenticated, hasPullRequest, dirty,
    )

    @Test
    fun activeAgentOrOperationBlocksEverything() {
        assertFalse(availability(agentActive = true, changedFiles = 3).allows(GitOperationKinds.COMMIT))
        assertFalse(availability(operationActive = true, changedFiles = 3).allows(GitOperationKinds.COMMIT))
        assertFalse(availability(agentActive = true, hasCommits = true).allowsMergeFlow)
    }

    @Test
    fun conflictedWorkspaceOnlyAllowsConflictActions() {
        val conflicted = availability(workspaceState = "conflicted", changedFiles = 2, hasCommits = true)
        assertTrue(conflicted.allows(GitOperationKinds.CONTINUE_CONFLICT))
        assertTrue(conflicted.allows(GitOperationKinds.ABORT_CONFLICT))
        assertFalse(conflicted.allows(GitOperationKinds.COMMIT))
        assertFalse(conflicted.allows(GitOperationKinds.MERGE_LOCAL))
        assertTrue(conflicted.allowsMergeFlow)
    }

    @Test
    fun commitNeedsDirtyTreeOrChangedFiles() {
        assertFalse(availability().allows(GitOperationKinds.COMMIT))
        assertTrue(availability(changedFiles = 1).allows(GitOperationKinds.COMMIT))
        assertTrue(availability(dirty = true).allows(GitOperationKinds.COMMIT))
    }

    @Test
    fun mergeLocalNeedsCommitsAndCleanTreeOutsideMain() {
        assertTrue(availability(hasCommits = true).allows(GitOperationKinds.MERGE_LOCAL))
        assertFalse(availability(hasCommits = true, changedFiles = 1).allows(GitOperationKinds.MERGE_LOCAL))
        assertFalse(availability(workspaceMode = "main", hasCommits = true).allows(GitOperationKinds.MERGE_LOCAL))
    }

    @Test
    fun pullRequestActionsFollowScmCapabilities() {
        val ready = availability(hasCommits = true, hasRemote = true, scmAuthenticated = true)
        assertTrue(ready.allows(GitOperationKinds.CREATE_PR))
        assertFalse(ready.copy(hasPullRequest = true).allows(GitOperationKinds.CREATE_PR))
        assertFalse(ready.copy(scmAuthenticated = false).allows(GitOperationKinds.CREATE_PR))
        assertFalse(ready.copy(workspaceMode = "main").allows(GitOperationKinds.CREATE_PR))
        assertFalse(ready.allows(GitOperationKinds.MERGE_PR))
        assertTrue(ready.copy(hasPullRequest = true).allows(GitOperationKinds.MERGE_PR))
    }

    @Test
    fun migrateOnlyMovesCleanBranchWorkspaces() {
        assertTrue(availability(workspaceMode = "branch").allows(GitOperationKinds.MIGRATE))
        assertFalse(availability(workspaceMode = "branch", changedFiles = 1).allows(GitOperationKinds.MIGRATE))
        assertFalse(availability(workspaceMode = "worktree").allows(GitOperationKinds.MIGRATE))
    }

    @Test
    fun cleanupRequiresACleanTreeAndDiscardDoesNot() {
        assertTrue(availability().allows(GitOperationKinds.CLEANUP))
        assertFalse(availability(changedFiles = 2).allows(GitOperationKinds.CLEANUP))
        assertTrue(availability(changedFiles = 2).allows(GitOperationKinds.DISCARD))
    }

    @Test
    fun mergeFlowOpensForDirtyOrCommittedWorkButNeverOnMain() {
        assertTrue(availability(changedFiles = 1).allowsMergeFlow)
        assertTrue(availability(hasCommits = true).allowsMergeFlow)
        assertFalse(availability().allowsMergeFlow)
        assertFalse(availability(workspaceMode = "main", hasCommits = true).allowsMergeFlow)
    }
}

class GitOperationReconciliationTest {
    @Test
    fun workspaceOperationIdWins() {
        assertEquals("op-1", gitOperationReconciliationId("op-1", "op-2", "running"))
    }

    @Test
    fun observedOperationSurvivesOnlyWhileActive() {
        assertEquals("op-2", gitOperationReconciliationId("", "op-2", "running"))
        assertEquals("op-2", gitOperationReconciliationId("", "op-2", "waiting_for_resolution"))
        assertNull(gitOperationReconciliationId("", "op-2", "succeeded"))
        assertNull(gitOperationReconciliationId("", null, null))
    }
}

class GitOperationLogMergeTest {
    private fun entry(sequence: Long, message: String): GitOperationLogEntry =
        GitOperationLogEntry.newBuilder().setSequence(sequence).setMessage(message).build()

    @Test
    fun deduplicatesBySequenceAndKeepsOrder() {
        val merged = mergeGitOperationLogs(
            listOf(entry(1, "a"), entry(3, "c")),
            listOf(entry(3, "duplicate"), entry(2, "b"), entry(4, "d")),
        )
        assertEquals(listOf(1L, 2L, 3L, 4L), merged.map { it.sequence })
        assertEquals("c", merged.first { it.sequence == 3L }.message)
    }

    @Test
    fun returnsSameListWhenNothingIsNew() {
        val current = listOf(entry(1, "a"))
        assertEquals(current, mergeGitOperationLogs(current, listOf(entry(1, "again"))))
    }
}

class WorkspaceChangePresentationTest {
    @Test
    fun mapsStatusesToBadges() {
        assertEquals("A", WorkspaceChangePresentation.badge("added"))
        assertEquals("D", WorkspaceChangePresentation.badge("d"))
        assertEquals("R", WorkspaceChangePresentation.badge("renamed"))
        assertEquals("M", WorkspaceChangePresentation.badge("modified"))
        assertEquals("!", WorkspaceChangePresentation.badge("modified", conflicted = true))
        assertEquals("U", WorkspaceChangePresentation.badge("modified", untracked = true))
    }

    @Test
    fun splitsPathsForDisplay() {
        assertEquals("service.go", WorkspaceChangePresentation.filename("internal/changeset/service.go"))
        assertEquals("internal/changeset", WorkspaceChangePresentation.directory("internal/changeset/service.go"))
        assertEquals("", WorkspaceChangePresentation.directory("README.md"))
    }
}

class WorkspaceAvailabilityDerivationTest {
    @Test
    fun derivesFromFreshWorkspaceOverCardSummary() {
        val card = Card.newBuilder()
            .setRuntime("idle")
            .setWorkspaceMode("main")
            .setWorkspace(WorkspaceSummary.newBuilder().setMode("main").setChangedFiles(9))
            .build()
        val review = WorkspaceReviewState(
            cardId = "c1",
            workspace = Workspace.newBuilder().setMode("worktree").setDirty(true).setAhead(2).build(),
            changeset = Changeset.newBuilder()
                .addFiles(ChangedFile.newBuilder().setPath("a.txt"))
                .addCommits(WorkspaceCommit.newBuilder().setSha("abc"))
                .build(),
            scm = SCMCapabilities.newBuilder().setPushAvailable(true).setAuthenticated(true).build(),
        )
        val availability = workspaceActionAvailability(card, review)
        assertEquals("worktree", availability.workspaceMode)
        assertEquals(1, availability.changedFiles)
        assertTrue(availability.hasCommits)
        assertTrue(availability.dirty)
        assertTrue(availability.hasRemote)
        assertTrue(availability.scmAuthenticated)
        assertFalse(availability.agentActive)
    }

    @Test
    fun runningAgentTurnBlocksMutations() {
        val card = Card.newBuilder().setRuntime("running").build()
        val availability = workspaceActionAvailability(card, WorkspaceReviewState(cardId = "c1"))
        assertTrue(availability.agentActive)
    }

    @Test
    fun activeOperationInReviewStateBlocksMutations() {
        val review = WorkspaceReviewState(
            cardId = "c1",
            operation = GitOperation.newBuilder().setId("op").setStatus("running").build(),
        )
        assertTrue(workspaceActionAvailability(null, review).operationActive)
    }

    @Test
    fun conflictedStateComesFromWorkspaceOrWaitingOperation() {
        val fromWorkspace = WorkspaceReviewState(
            cardId = "c1",
            workspace = Workspace.newBuilder().setState("conflicted").build(),
        )
        assertTrue(fromWorkspace.conflicted)
        val fromOperation = WorkspaceReviewState(
            cardId = "c1",
            operation = GitOperation.newBuilder().setStatus("waiting_for_resolution").build(),
        )
        assertTrue(fromOperation.conflicted)
    }
}

package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.PullRequestSummary
import com.dbpprt.dieter.v1.WorkspaceSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceCardBadgeTest {
    @Test
    fun hidesCardsWithoutWorkspaceInformation() {
        assertNull(workspaceCardBadgeInfo(Card.getDefaultInstance()))
    }

    @Test
    fun fallsBackFromBranchToWorkspaceMode() {
        val worktree = card(workspaceMode = "worktree")
        val branch = card(workspaceMode = "branch")
        val main = card(workspaceMode = "main")

        assertEquals("Worktree", workspaceCardBadgeInfo(worktree)?.title)
        assertEquals("Branch", workspaceCardBadgeInfo(branch)?.title)
        assertEquals("Main", workspaceCardBadgeInfo(main)?.title)
    }

    @Test
    fun prefersFreshWorkspaceBranchAndIncludesSyncStateForAccessibility() {
        val card = card(
            workspaceMode = "worktree",
            workspaceBranch = "stale-branch",
            workspace = WorkspaceSummary.newBuilder()
                .setMode("worktree")
                .setBranch("feature/card-branches")
                .setAhead(2)
                .setBehind(1)
                .build(),
        )

        val badge = workspaceCardBadgeInfo(card)!!
        assertEquals("feature/card-branches", badge.title)
        assertEquals("Workspace: Worktree · feature/card-branches · 2 ahead, 1 behind", badge.accessibilityLabel)
        assertFalse(badge.conflicted)
    }

    @Test
    fun conflictPullRequestAndChangesFollowMacPriority() {
        val conflicted = card(
            workspace = workspace(state = "conflicted", changedFiles = 3),
            pullRequestNumber = 42,
        )
        val pullRequest = card(workspace = workspace(changedFiles = 3), pullRequestNumber = 42)
        val changed = card(workspace = workspace(changedFiles = 3))

        assertEquals("Conflicts", workspaceCardBadgeInfo(conflicted)?.title)
        assertTrue(workspaceCardBadgeInfo(conflicted)!!.conflicted)
        assertEquals("PR #42", workspaceCardBadgeInfo(pullRequest)?.title)
        assertEquals("3 changed", workspaceCardBadgeInfo(changed)?.title)
    }

    private fun card(
        workspaceMode: String = "worktree",
        workspaceBranch: String = "",
        workspace: WorkspaceSummary = WorkspaceSummary.getDefaultInstance(),
        pullRequestNumber: Int = 0,
    ): Card = Card.newBuilder()
        .setWorkspaceMode(workspaceMode)
        .setWorkspaceBranch(workspaceBranch)
        .setWorkspace(workspace)
        .setPullRequest(PullRequestSummary.newBuilder().setNumber(pullRequestNumber))
        .build()

    private fun workspace(state: String = "ready", changedFiles: Int = 0): WorkspaceSummary =
        WorkspaceSummary.newBuilder()
            .setMode("worktree")
            .setBranch("feature/card-branches")
            .setState(state)
            .setChangedFiles(changedFiles)
            .build()
}

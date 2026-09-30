package com.dbpprt.dieter.ui

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceCardBadgeTest {
    @Test
    fun hidesCardsWithoutWorkspaceInformation() {
        assertNull(workspaceCardBadgeInfo(Card()))
    }

    @Test
    fun fallsBackFromBranchToWorkspaceModeAndCanonicalizesLegacyValues() {
        val worktree = card(workspaceMode = "worktree")
        val project = card(workspaceMode = "project")
        val legacyBranch = card(workspaceMode = "branch")
        val legacyMain = card(workspaceMode = "main")

        assertEquals("Worktree", workspaceCardBadgeInfo(worktree)?.title)
        assertEquals("Project", workspaceCardBadgeInfo(project)?.title)
        assertEquals("Project", workspaceCardBadgeInfo(legacyBranch)?.title)
        assertEquals("Project", workspaceCardBadgeInfo(legacyMain)?.title)
    }

    @Test
    fun prefersFreshWorkspaceBranchAndIncludesSyncStateForAccessibility() {
        val card = card(
            workspaceMode = "worktree",
            workspaceBranch = "stale-branch",
            workspace = WorkspaceSummary(mode = "worktree", branch = "feature/card-branches", ahead = 2, behind = 1),
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
        workspace: WorkspaceSummary = WorkspaceSummary(),
        pullRequestNumber: Int = 0,
    ): Card = Card(workspace_mode = workspaceMode, workspace_branch = workspaceBranch, workspace = workspace, pull_request = PullRequestSummary(number = pullRequestNumber))

    private fun workspace(state: String = "ready", changedFiles: Int = 0): WorkspaceSummary =
        WorkspaceSummary(mode = "worktree", branch = "feature/card-branches", state = state, changed_files = changedFiles)
}

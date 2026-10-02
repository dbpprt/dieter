package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ChangedFileLabel
import com.dbpprt.dieter.client.v1.GitOperationForm
import com.dbpprt.dieter.client.v1.GitOperationFormSpec
import com.dbpprt.dieter.client.v1.WorkspaceBadgeView
import com.dbpprt.dieter.client.v1.WorkspaceTone
import com.dbpprt.dieter.core.workspace.StatusTone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WorkspaceExportsTest {
    @Test
    fun aCardsWorkspaceBadgeReadsAsTheCoreSaysAndRoundTrips() {
        val badge = WorkspaceExports.workspaceBadge(
            mode = "worktree", state = "", branch = "feature/x", changedFiles = 3, ahead = 2, behind = 1,
            cardMode = "", cardBranch = "", pullRequest = 0,
        )
        assertEquals(WorkspaceBadgeView(shown = true, title = "3 changed", full_title = "feature/x", accessibility_label = "Workspace: Worktree · feature/x · 2 ahead, 1 behind", conflicted = false), badge)
        assertEquals(badge, WorkspaceBadgeView.ADAPTER.decode(WorkspaceBadgeView.ADAPTER.encode(badge)))

        val fromCard = WorkspaceExports.workspaceBadge("", "conflicted", "", 0, 0, 0, cardMode = "worktree", cardBranch = "feature/y", pullRequest = 12)
        assertEquals("Conflicts" to "Conflicts", fromCard.title to fromCard.full_title)
        assertTrue(fromCard.conflicted)
        assertEquals("Workspace: Worktree · feature/y · PR #12", fromCard.accessibility_label)
        assertEquals("PR #12", WorkspaceExports.workspaceBadge("project", "", "main", 0, 0, 0, "", "", 12).title)
        assertEquals("Project", WorkspaceExports.workspaceBadge("project", "", "", 0, 0, 0, "", "", 0).title)
        assertFalse(WorkspaceExports.workspaceBadge("", "", "", 0, 0, 0, "", "", 0).shown, "a card without a workspace mode shows none")
    }

    @Test
    fun aChangedFileHasItsBadgeTitleNameAndDirectory() {
        assertEquals(ChangedFileLabel(badge = "M", title = "Modified", filename = "Workspace.swift", directory = "Sources/App"), WorkspaceExports.changedFile("Sources/App/Workspace.swift", "modified", conflicted = false, untracked = false))
        assertEquals("A" to "Added", WorkspaceExports.changedFile("a", "added", false, false).let { it.badge to it.title })
        assertEquals("!" to "Conflicted", WorkspaceExports.changedFile("a", "modified", true, false).let { it.badge to it.title })
        assertEquals("U" to "Untracked", WorkspaceExports.changedFile("a", "modified", false, true).let { it.badge to it.title })
        assertEquals("Renamed", WorkspaceExports.changedFile("a", "renamed", false, false).title)
        assertEquals("", WorkspaceExports.changedFile("README.md", "modified", false, false).directory)
    }

    @Test
    fun gitOperationFormsSayWhatToCollectAndWhenTheyCanStart() {
        val commit = WorkspaceExports.gitOperationForm("commit", cardTitle = "Fold chats", cardPrompt = "Fold each project", pullRequestHeadSha = "", baseBranch = "main")
        assertEquals("Commit changes", commit.title)
        assertEquals(GitOperationFormSpec.Start.START_FORM, commit.start)
        assertEquals(listOf(GitOperationFormSpec.Input.INPUT_SUBJECT, GitOperationFormSpec.Input.INPUT_BODY, GitOperationFormSpec.Input.INPUT_STAGE_ALL), commit.inputs)
        assertEquals("Fold chats" to "Fold each project", commit.initial!!.subject to commit.initial!!.body)
        assertTrue(commit.initial!!.stage_all)
        assertFalse(commit.destructive)

        val merge = WorkspaceExports.gitOperationForm("merge_local", "Fold chats", "", "", "main")
        assertEquals(listOf("squash", "merge_commit", "fast_forward"), merge.strategies.map { it.strategy })
        assertEquals("squash", merge.initial!!.strategy)
        assertTrue(merge.summary.contains("main"))
        assertEquals(listOf("squash", "merge", "rebase"), WorkspaceExports.gitOperationForm("merge_pr", "", "", "abc", "main").strategies.map { it.strategy })
        assertEquals("abc", WorkspaceExports.gitOperationForm("push", "", "", "abc", "main").initial!!.expected_remote_sha)
        assertTrue(WorkspaceExports.gitOperationForm("update", "", "", "", "").summary.contains("latest base."))

        val abort = WorkspaceExports.gitOperationForm("abort_conflict", "", "", "", "main")
        assertEquals(GitOperationFormSpec.Start.START_CONFIRM, abort.start)
        assertTrue(abort.destructive)
        assertTrue(abort.inputs.isEmpty())
        assertEquals(GitOperationFormSpec.Start.START_IMMEDIATE, WorkspaceExports.gitOperationForm("refresh_pr", "", "", "", "main").start)
        assertEquals("", WorkspaceExports.gitOperationForm("stage", "", "", "", "main").summary)

        assertTrue(WorkspaceExports.gitOperationReady(GitOperationForm(kind = "commit", subject = "Ship")))
        assertFalse(WorkspaceExports.gitOperationReady(GitOperationForm(kind = "commit", subject = " ")))
        assertFalse(WorkspaceExports.gitOperationReady(GitOperationForm(kind = "create_pr")))
        assertFalse(WorkspaceExports.gitOperationReady(GitOperationForm(kind = "adopt")))
        assertFalse(WorkspaceExports.gitOperationReady(GitOperationForm(kind = "push", force_with_lease = true)))
        assertTrue(WorkspaceExports.gitOperationReady(GitOperationForm(kind = "validate")))
        assertEquals(WorkspaceExports.core(merge.initial!!).parameters(), mapOf("strategy" to "squash", "subject" to "Fold chats", "validate" to "true"))
        assertEquals("merge", WorkspaceExports.core(GitOperationForm(kind = "merge_pr", strategy = "merge")).strategy)
        assertEquals("squash", WorkspaceExports.core(GitOperationForm(kind = "merge_pr")).strategy, "an empty strategy is the kind's default")
    }

    @Test
    fun tonesMapOneToOne() {
        assertEquals(StatusTone.entries.size, StatusTone.entries.map(WorkspaceExports::tone).toSet().size)
        assertEquals(WorkspaceTone.WORKSPACE_TONE_DANGER, WorkspaceExports.tone(StatusTone.DANGER))
    }
}

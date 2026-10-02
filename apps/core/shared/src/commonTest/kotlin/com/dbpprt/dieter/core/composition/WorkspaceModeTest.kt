package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import kotlin.test.Test
import kotlin.test.assertEquals

class WorkspaceModeTest {
    @Test
    fun pickersOfferAWorktreeFirstAndOtherValuesRunInTheProject() {
        assertEquals(listOf(WorkspaceMode.WORKTREE, WorkspaceMode.PROJECT), WorkspaceMode.choices)
        assertEquals(WorkspaceMode.WORKTREE, WorkspaceMode.parse("WORKTREE"))
        for (value in listOf("project", "branch", "", null)) assertEquals(WorkspaceMode.PROJECT, WorkspaceMode.parse(value), value)
        assertEquals(listOf("Project directory", "Project", "project"), WorkspaceMode.PROJECT.let { listOf(it.title, it.shortTitle, it.wire) })
        assertEquals(listOf("Worktree", "Worktree", "worktree"), WorkspaceMode.WORKTREE.let { listOf(it.title, it.shortTitle, it.wire) })
    }

    @Test
    fun aCardRunsInItsOwnModeElseItsWorkspaces() {
        assertEquals(WorkspaceMode.WORKTREE, WorkspaceMode.of(Card(workspace = WorkspaceSummary(mode = "worktree"))))
        assertEquals(WorkspaceMode.PROJECT, WorkspaceMode.of(Card(workspace_mode = "project", workspace = WorkspaceSummary(mode = "worktree"))), "the card's own mode wins")
        assertEquals(WorkspaceMode.WORKTREE, WorkspaceMode.of(Card(workspace_mode = "Worktree")))
        assertEquals(WorkspaceMode.PROJECT, WorkspaceMode.of(Card()))
    }
}

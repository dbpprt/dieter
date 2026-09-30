package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.TokenUsage
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import kotlin.test.Test
import kotlin.test.assertEquals

class DirectoryTest {
    private val owner = Card(
        id = "card", owner_daemon_id = "owner", scope = "board", project_id = "project", board_id = "board", lane = "todo",
        title = "Remote task", provider = "codex", initial_prompt = "Implement it", workspace_mode = "project",
        workspace = WorkspaceSummary(mode = "project", branch = "main"), token_usage = TokenUsage(reported_messages = 1, total_tokens = 125, partial = true),
    )

    @Test
    fun sparsePeerUpdatesKeepTheOwnersPromptWorkspaceAndUsage() {
        // A peer serves the shared item contract only; owner-local fields are absent.
        val peer = Card(id = "card", owner_daemon_id = "owner", scope = "board", project_id = "project", board_id = "board", lane = "todo", title = "Remote task renamed", provider = "codex")
        val merged = DirectoryReducer.retainingOwnerDetails(peer, owner, sourceDaemonId = "peer")
        assertEquals("Remote task renamed", merged.title)
        assertEquals("Implement it", merged.initial_prompt)
        assertEquals("project", merged.workspace_mode)
        assertEquals(owner.workspace, merged.workspace)
        assertEquals(owner.token_usage, merged.token_usage)
    }

    @Test
    fun theOwnersOwnUpdateReplacesItsDetails() {
        val update = owner.copy(initial_prompt = "Revised", runtime_updated_at = "2026-09-30T10:00:00Z")
        assertEquals("Revised", DirectoryReducer.retainingOwnerDetails(update, owner, sourceDaemonId = "owner").initial_prompt)
    }
}

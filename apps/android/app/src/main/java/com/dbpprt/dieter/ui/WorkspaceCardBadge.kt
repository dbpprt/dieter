package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card

/** Compact workspace identity and state shown directly on board cards. */
internal data class WorkspaceCardBadgeInfo(
    val title: String,
    val accessibilityLabel: String,
    val conflicted: Boolean,
)

internal fun workspaceCardBadgeInfo(card: Card): WorkspaceCardBadgeInfo? {
    val summary = card.workspace
    val mode = summary.mode.ifBlank { card.workspaceMode }.trim()
    if (mode.isEmpty()) return null

    val conflicted = summary.state == "conflicted"
    val branch = summary.branch.ifBlank { card.workspaceBranch }.trim()
    val branchOrMode = branch.ifBlank { ConversationWorkspaceMode.resolve(mode).shortTitle }
    val title = when {
        conflicted -> "Conflicts"
        card.pullRequest.number > 0 -> "PR #${card.pullRequest.number}"
        summary.changedFiles > 0 -> "${summary.changedFiles} changed"
        else -> branchOrMode
    }
    val detail = buildList {
        add(ConversationWorkspaceMode.resolve(mode).title)
        if (branch.isNotEmpty()) add(branch)
        if (summary.ahead > 0 || summary.behind > 0) add("${summary.ahead} ahead, ${summary.behind} behind")
        if (card.pullRequest.number > 0) add("PR #${card.pullRequest.number}")
    }.joinToString(" · ")

    return WorkspaceCardBadgeInfo(
        title = title,
        accessibilityLabel = "Workspace: $detail",
        conflicted = conflicted,
    )
}

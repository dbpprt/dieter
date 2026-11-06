package com.getdieter.core.admin

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.ConversationRef
import com.getdieter.api.v1.FileDocument
import com.getdieter.api.v1.ListChatsRequest
import com.getdieter.api.v1.ReadFileRequest
import com.getdieter.api.v1.UpdateConversationWorkspaceRequest
import com.getdieter.api.v1.Workspace
import com.getdieter.core.composition.WorkspaceMode
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.store.WorkspaceStore

/**
 * Conversations' workspaces, a machine's archived chats, and single files, each on the machine that
 * holds them. Confined to the core dispatcher.
 */
class ConversationAdmin
internal constructor(private val calls: AdminCalls, private val store: WorkspaceStore) {
    /** The machine that runs [cardId]: its owner, else its checkout's machine. */
    private fun ownerOf(cardId: String): String {
        val directory = store.directoryProjection
        val card =
            directory.item(cardId)
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "The conversation is no longer available.",
                )
        return directory.owner(card)
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "The conversation's machine is unavailable.",
            )
    }

    /** A conversation's workspace, provisioning it when needed. */
    suspend fun workspace(cardId: String): Workspace =
        calls.call(AdminRoute.Target(ownerOf(cardId)), Deadlines.PROVISION) {
            it.GetWorkspace().execute(ConversationRef(card_id = cardId))
        }

    /** Changes a conversation's workspace before its first turn, on the machine that owns it. */
    suspend fun updateWorkspace(
        cardId: String,
        mode: WorkspaceMode,
        branch: String,
        baseBranch: String,
        baseRemote: String,
        publishMode: String,
    ): Card {
        val daemon = ownerOf(cardId)
        val worktree = mode == WorkspaceMode.WORKTREE
        return calls.call(AdminRoute.Target(daemon)) {
            it.UpdateConversationWorkspace()
                .execute(
                    UpdateConversationWorkspaceRequest(
                        card_id = cardId,
                        mode = mode.wire,
                        branch = if (worktree) branch.trim() else "",
                        base_branch = if (worktree) baseBranch.trim() else "",
                        base_remote = baseRemote.trim(),
                        remote_publish_mode = publishMode.trim(),
                    )
                )
        }
    }

    /** A machine's archived chats; live chats are in the workspace. */
    suspend fun archivedChats(daemonId: String): List<Card> =
        calls
            .call(AdminRoute.Target(daemonId)) {
                it.ListChats().execute(ListChatsRequest(include_archived = true))
            }
            .chats
            .filter { it.archived }

    /** One file of a checkout, or of a conversation's workspace when [cardId] is set. */
    suspend fun readFile(
        daemonId: String,
        projectId: String,
        checkoutId: String,
        cardId: String,
        path: String,
    ): FileDocument =
        calls.call(AdminRoute.Target(daemonId), Deadlines.PROVISION) {
            it.ReadFile()
                .execute(
                    ReadFileRequest(
                        project_id = projectId,
                        checkout_id = if (cardId.isEmpty()) checkoutId else "",
                        card_id = cardId,
                        path = path,
                    )
                )
        }
}

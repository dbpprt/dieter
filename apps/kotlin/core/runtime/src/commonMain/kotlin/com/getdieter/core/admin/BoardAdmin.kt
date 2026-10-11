package com.getdieter.core.admin

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.BoardRef
import com.getdieter.api.v1.CreateBoardLabelRequest
import com.getdieter.api.v1.CreateBoardRequest
import com.getdieter.api.v1.DeleteBoardLabelRequest
import com.getdieter.api.v1.RenameBoardRequest
import com.getdieter.api.v1.SetBoardArchivePolicyRequest
import com.getdieter.api.v1.SetBoardRetiredRequest
import com.getdieter.api.v1.UpdateBoardGitSettingsRequest
import com.getdieter.api.v1.UpdateBoardHostnamesRequest
import com.getdieter.api.v1.UpdateBoardLabelRequest
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.store.WorkspaceStore
import okio.ByteString.Companion.encodeUtf8

/**
 * Boards and their labels, on a reachable machine that holds the board's project; the peer store
 * replicates each write. Returned boards show at once and yield to the account view once it is at
 * least as new. Confined to the core dispatcher.
 */
class BoardAdmin
internal constructor(private val calls: AdminCalls, private val store: WorkspaceStore) {
    suspend fun create(
        projectId: String,
        name: String,
        workflow: String = AdminForms.DEFAULT_WORKFLOW,
        description: String = "",
        policy: String = AdminForms.DEFAULT_ARCHIVE_POLICY,
        baseRemote: String = "",
        publishMode: String = AdminForms.DEFAULT_PUBLISH_MODE,
    ): Board {
        if (name.isBlank()) throw CoreException(FailureKind.PERMANENT, "board name is required")
        val request =
            CreateBoardRequest(
                project_id = projectId,
                name = name.trim(),
                workflow = workflow,
                description = description.trim(),
                done_archive_policy = policy,
                base_remote =
                    baseRemote.ifEmpty {
                        store.directoryProjection.projects[projectId]?.base_remote.orEmpty()
                    },
                remote_publish_mode = publishMode,
            )
        return calls
            .call(AdminRoute.ForProject(projectId)) { it.CreateBoard().execute(request) }
            .also(store::overlayBoard)
    }

    suspend fun rename(boardId: String, name: String): Board {
        if (name.isBlank()) throw CoreException(FailureKind.PERMANENT, "board name is required")
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.RenameBoard().execute(RenameBoardRequest(board_id = boardId, name = name.trim()))
            }
            .also(store::overlayBoard)
    }

    suspend fun setArchivePolicy(boardId: String, policy: String): Board {
        if (policy !in AdminForms.ARCHIVE_POLICIES)
            throw CoreException(
                FailureKind.PERMANENT,
                "Done archive policy must be never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days",
            )
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.SetBoardArchivePolicy()
                    .execute(
                        SetBoardArchivePolicyRequest(
                            board_id = boardId,
                            done_archive_policy = policy,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    suspend fun setGitSettings(boardId: String, baseRemote: String, publishMode: String): Board {
        if (publishMode !in AdminForms.PUBLISH_MODES)
            throw CoreException(
                FailureKind.PERMANENT,
                "remote publish mode must be manual, pull_request, or push_base",
            )
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.UpdateBoardGitSettings()
                    .execute(
                        UpdateBoardGitSettingsRequest(
                            board_id = boardId,
                            base_remote = baseRemote.trim(),
                            remote_publish_mode = publishMode,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    suspend fun setHostnames(
        boardId: String,
        hostnames: List<String>,
        append: Boolean = false,
    ): Board {
        val values =
            Hostnames.normalize(hostnames).getOrElse {
                throw CoreException(FailureKind.PERMANENT, it.message.orEmpty())
            }
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.UpdateBoardHostnames()
                    .execute(
                        UpdateBoardHostnamesRequest(
                            board_id = boardId,
                            hostnames = values,
                            append = append,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    /**
     * Retires (deletes) or restores a board against the lifecycle revision of a machine that
     * observed every intent this client shows. Only empty boards can be retired. The operation ID
     * is kept for the whole intent, so a retry never applies twice.
     */
    suspend fun setRetired(boardId: String, retired: Boolean): Board {
        val route = AdminRoute.Observer("board/$boardId.retired", calls.projectOf(boardId))
        return calls
            .idempotent("board", "retire:$boardId:$retired".encodeUtf8()) { operationId ->
                calls.call(route) { client ->
                    val current = client.GetBoard().execute(BoardRef(board_id = boardId))
                    client
                        .SetBoardRetired()
                        .execute(
                            SetBoardRetiredRequest(
                                board_id = boardId,
                                retired = retired,
                                expected_revision = current.retirement_revision,
                                operation_id = operationId,
                            )
                        )
                }
            }
            .also(store::overlayBoard)
    }

    // --- Labels ---------------------------------------------------------------------

    suspend fun createLabel(
        boardId: String,
        name: String,
        color: String = "",
        instructions: String = "",
    ): Board {
        Labels.validate(name, color)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.CreateBoardLabel()
                    .execute(
                        CreateBoardLabelRequest(
                            board_id = boardId,
                            name = name.trim(),
                            color = color.trim(),
                            instructions = instructions,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    suspend fun updateLabel(
        boardId: String,
        labelId: String,
        name: String,
        color: String,
        instructions: String,
    ): Board {
        Labels.validate(name, color)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.UpdateBoardLabel()
                    .execute(
                        UpdateBoardLabelRequest(
                            board_id = boardId,
                            label_id = labelId,
                            name = name.trim(),
                            color = color.trim(),
                            instructions = instructions,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    /** Removes the label from the board and from every card. */
    suspend fun deleteLabel(boardId: String, labelId: String): Board =
        calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.DeleteBoardLabel()
                    .execute(DeleteBoardLabelRequest(board_id = boardId, label_id = labelId))
            }
            .also(store::overlayBoard)
}

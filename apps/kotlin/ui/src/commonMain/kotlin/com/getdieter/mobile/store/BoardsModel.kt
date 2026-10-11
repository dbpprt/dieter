package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The visible board, and the board, project and checkout that tools and new tasks use. */
class BoardsModel
internal constructor(
    private val context: StoreContext,
    private val workspace: StateFlow<WorkspaceSlice>,
) {
    val slice = MutableStateFlow(BoardViewSlice())
    val filter = MutableStateFlow(BoardViewTarget())
    val selectedBoard = MutableStateFlow("")
    val selectedProject = MutableStateFlow("")
    val selectedCheckout = MutableStateFlow("")

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_BOARD_VIEW, MobileStore.BOARD_SCOPE) { update ->
            update.board_view?.let { slice.value = it }
        }
    }

    fun currentProjectId() =
        selectedProject.value.ifEmpty {
            workspace.value.boards.firstOrNull { it.id == selectedBoard.value }?.project_id
                ?: workspace.value.projects.firstOrNull()?.id.orEmpty()
        }

    fun filterBoard(target: BoardViewTarget) {
        filter.value = target
        context.command(
            Command(board_view = BoardViewCommand(scope = MobileStore.BOARD_SCOPE, bind = target))
        )
    }

    fun chooseBoard(id: String) {
        selectedBoard.value = id
        val project = workspace.value.boards.firstOrNull { it.id == id }?.project_id.orEmpty()
        if (project != selectedProject.value) selectedCheckout.value = ""
        selectedProject.value = project
        filterBoard(BoardViewTarget(board_id = id))
    }

    /** Scopes project tools to [id]; the checkout returns to the project's default. */
    fun selectProject(id: String) {
        selectedProject.value = id
        selectedCheckout.value = ""
    }
}

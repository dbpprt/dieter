package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableStateFlow

/** The visible board; new tasks start on it. */
class BoardsModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(BoardViewSlice())
    val filter = MutableStateFlow(BoardViewTarget())
    val selectedBoard = MutableStateFlow("")

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_BOARD_VIEW, MobileStore.BOARD_SCOPE) { update ->
            update.board_view?.let { slice.value = it }
        }
    }

    fun filterBoard(target: BoardViewTarget) {
        filter.value = target
        context.command(
            Command(board_view = BoardViewCommand(scope = MobileStore.BOARD_SCOPE, bind = target))
        )
    }

    fun chooseBoard(id: String) {
        selectedBoard.value = id
        filterBoard(BoardViewTarget(board_id = id))
    }
}

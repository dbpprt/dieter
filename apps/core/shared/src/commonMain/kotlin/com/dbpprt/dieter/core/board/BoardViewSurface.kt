package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.core.connection.MachineDirectory
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.outbox.OutboxView
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.store.WorkspaceView
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import okio.ByteString

/**
 * One view's board: the board and filters it binds, the board as shown, and
 * drops measured against the lanes it shows. Confined to the core dispatcher.
 */
class BoardViewSurface(
    private val workspace: StateFlow<WorkspaceView>,
    private val operations: BoardOperations,
    private val outbox: StateFlow<OutboxView>,
    private val navigation: StateFlow<Map<String, ByteString>>,
    private val machines: StateFlow<MachineDirectory>,
) {
    private val target = MutableStateFlow(BoardTarget())

    val view: Flow<BoardView> = combine(
        target, workspace, operations.view, outbox, combine(navigation, machines, ::Pair),
    ) { bound, view, board, pending, (layout, directory) ->
        build(bound, view, board, pending, layout, directory)
    }.distinctUntilChanged()

    fun bind(next: BoardTarget) {
        target.value = next
    }

    /** The board as shown now. */
    fun current(): BoardView = build(target.value, workspace.value, operations.view.value, outbox.value, navigation.value, machines.value)

    /**
     * Drops [cardId] into [laneId] above [beforeCardId] as this view shows
     * the lane (blank: at its end). False when the card stays where it is.
     */
    suspend fun drop(cardId: String, laneId: String, beforeCardId: String): Boolean {
        val view = current()
        val lane = view.lane(laneId) ?: throw CoreException(FailureKind.PERMANENT, "This board has no such lane.")
        val anchors = view.drop(cardId, lane, beforeCardId) ?: return false
        return operations.move(cardId, lane.lane.id, anchors)
    }

    private fun build(
        target: BoardTarget,
        workspace: WorkspaceView,
        board: BoardOperationsView,
        outbox: OutboxView,
        navigation: Map<String, ByteString>,
        machines: MachineDirectory,
    ): BoardView {
        val layout = NavigationLayout(navigation)
        return BoardViews.build(
            target = target,
            board = workspace.board(target.boardId) ?: workspace.retiredBoards.firstOrNull { it.id == target.boardId },
            items = workspace.cards.values.flatten(),
            operations = board.operations,
            moves = board.moves,
            startingCardIds = outbox.startingCardIds,
            pendingCardIds = outbox.pendingCardIds,
            failedCardIds = outbox.failedIds,
            laneDescending = { lane -> layout.laneDescending(target.boardId, lane) },
            machineLabel = { id -> machines.machine(id)?.name?.ifBlank { null } ?: id },
        )
    }
}

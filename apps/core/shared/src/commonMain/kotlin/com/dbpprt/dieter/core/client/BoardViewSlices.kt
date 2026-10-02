package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.BoardAgentStatus
import com.dbpprt.dieter.client.v1.BoardCardFlags
import com.dbpprt.dieter.client.v1.BoardLaneKind
import com.dbpprt.dieter.client.v1.BoardLaneView as ClientBoardLaneView
import com.dbpprt.dieter.client.v1.BoardStateFilter as ClientBoardStateFilter
import com.dbpprt.dieter.client.v1.BoardStateOption
import com.dbpprt.dieter.client.v1.BoardViewCommand
import com.dbpprt.dieter.client.v1.BoardViewSlice
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.client.v1.RuntimeTone as ClientRuntimeTone
import com.dbpprt.dieter.core.board.AgentStatus
import com.dbpprt.dieter.core.board.BoardCardState
import com.dbpprt.dieter.core.board.BoardStateFilter
import com.dbpprt.dieter.core.board.BoardTarget
import com.dbpprt.dieter.core.board.BoardView
import com.dbpprt.dieter.core.board.BoardViewSurface
import com.dbpprt.dieter.core.board.LaneKind
import com.dbpprt.dieter.core.board.RuntimeTone

// The board view surface (SLICE_BOARD_VIEW) and its commands.

internal suspend fun BoardViewSurface.execute(command: BoardViewCommand): Result {
    command.bind?.let { bind(boardTarget(it)); return Result(done = Done()) }
    // A card dropped where it already is succeeds without a change.
    command.drop?.let { drop(it.card_id, it.lane_id, it.before_card_id); return Result(done = Done()) }
    invalid("Choose a board view action.")
}

internal fun boardTarget(target: BoardViewTarget) = BoardTarget(
    boardId = target.board_id, machineId = target.machine_id, labelId = target.label_id, state = boardStateFilter(target.state), query = target.query,
)

internal fun boardViewTarget(target: BoardTarget) = BoardViewTarget(
    board_id = target.boardId, machine_id = target.machineId, label_id = target.labelId, state = clientStateFilter(target.state), query = target.query,
)

internal fun boardViewSlice(view: BoardView) = BoardViewSlice(
    target = boardViewTarget(view.target),
    lanes = view.lanes.map { lane ->
        ClientBoardLaneView(lane_id = lane.lane.id, name = lane.lane.name, kind = laneKind(lane.kind), descending = lane.descending, card_ids = lane.cards.map { it.id })
    },
    label_counts = view.labelCounts,
    total = view.total,
    machine_ids = view.machineIds,
    cards = view.cards.mapValues { (_, state) -> boardCardFlags(state) },
    state_options = BoardView.STATE_OPTIONS.map { BoardStateOption(clientStateFilter(it), BoardStateFilter.title(it)) },
    state_title = view.stateTitle,
    summary = view.summary,
)

internal fun boardCardFlags(state: BoardCardState) = BoardCardFlags(
    badge = state.badge.orEmpty(),
    tone = runtimeTone(state.tone),
    runtime_label = state.runtimeLabel,
    agent = agentStatus(state.agent),
    agent_label = state.agent.label,
    can_start = state.canStart,
    starting = state.starting,
    can_edit_draft = state.canEditDraft,
    can_cancel = state.canCancel,
    merge_source_key = state.mergeSourceKey,
    merge_target_key = state.mergeTargetKey,
    operation = state.operation?.name.orEmpty(),
    pending = state.pending,
    failed = state.failed,
)

internal fun runtimeTone(tone: RuntimeTone): ClientRuntimeTone = when (tone) {
    RuntimeTone.IDLE -> ClientRuntimeTone.RUNTIME_TONE_IDLE
    RuntimeTone.ACTIVE -> ClientRuntimeTone.RUNTIME_TONE_ACTIVE
    RuntimeTone.ATTENTION -> ClientRuntimeTone.RUNTIME_TONE_ATTENTION
    RuntimeTone.DONE -> ClientRuntimeTone.RUNTIME_TONE_DONE
    RuntimeTone.FAILED -> ClientRuntimeTone.RUNTIME_TONE_FAILED
}

internal fun agentStatus(status: AgentStatus): BoardAgentStatus = when (status) {
    AgentStatus.IDLE -> BoardAgentStatus.BOARD_AGENT_STATUS_IDLE
    AgentStatus.RUNNING -> BoardAgentStatus.BOARD_AGENT_STATUS_RUNNING
    AgentStatus.FAILED -> BoardAgentStatus.BOARD_AGENT_STATUS_FAILED
}

internal fun laneKind(kind: LaneKind): BoardLaneKind = when (kind) {
    LaneKind.OTHER -> BoardLaneKind.BOARD_LANE_KIND_OTHER
    LaneKind.RUNNING -> BoardLaneKind.BOARD_LANE_KIND_RUNNING
    LaneKind.REVIEW -> BoardLaneKind.BOARD_LANE_KIND_REVIEW
    LaneKind.DONE -> BoardLaneKind.BOARD_LANE_KIND_DONE
}

private fun boardStateFilter(state: ClientBoardStateFilter): BoardStateFilter? = when (state) {
    ClientBoardStateFilter.BOARD_STATE_FILTER_ALL -> null
    ClientBoardStateFilter.BOARD_STATE_FILTER_RUNNING -> BoardStateFilter.RUNNING
    ClientBoardStateFilter.BOARD_STATE_FILTER_WAITING -> BoardStateFilter.WAITING
    ClientBoardStateFilter.BOARD_STATE_FILTER_REVIEW -> BoardStateFilter.REVIEW
    ClientBoardStateFilter.BOARD_STATE_FILTER_FAILED -> BoardStateFilter.FAILED
    ClientBoardStateFilter.BOARD_STATE_FILTER_IDLE -> BoardStateFilter.IDLE
}

private fun clientStateFilter(state: BoardStateFilter?): ClientBoardStateFilter = when (state) {
    null -> ClientBoardStateFilter.BOARD_STATE_FILTER_ALL
    BoardStateFilter.RUNNING -> ClientBoardStateFilter.BOARD_STATE_FILTER_RUNNING
    BoardStateFilter.WAITING -> ClientBoardStateFilter.BOARD_STATE_FILTER_WAITING
    BoardStateFilter.REVIEW -> ClientBoardStateFilter.BOARD_STATE_FILTER_REVIEW
    BoardStateFilter.FAILED -> ClientBoardStateFilter.BOARD_STATE_FILTER_FAILED
    BoardStateFilter.IDLE -> ClientBoardStateFilter.BOARD_STATE_FILTER_IDLE
}

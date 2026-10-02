package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.presentation.Counts

/** The board's state filter: what a card's agent does, or its review lane. */
enum class BoardStateFilter(val title: String) {
    /** An agent works, starts, or stops. */
    RUNNING("Running"),

    /** The agent waits for the user. */
    WAITING("Waiting"),

    /** The card waits in a review lane, whatever its agent does. */
    REVIEW("Review"),
    FAILED("Failed"),
    IDLE("Idle"),
    ;

    /** Whether [card] matches; [operation] is this client's start or cancel in flight. */
    fun matches(card: Card, operation: CardOperation? = null): Boolean {
        val active = Runtimes.isActive(card, operation = operation)
        val state = Runtimes.classify(card.runtime)
        return when (this) {
            RUNNING -> active
            WAITING -> !active && state == RuntimeState.NEEDS_INPUT
            REVIEW -> Lanes.isReview(card.lane)
            FAILED -> !active && state == RuntimeState.FAILED
            IDLE -> !active && state == RuntimeState.IDLE
        }
    }

    companion object {
        const val ALL = "All states"

        /** "All states", or [filter]'s title. */
        fun title(filter: BoardStateFilter?): String = filter?.title ?: ALL
    }
}

/** What a board view shows: a board narrowed by machine, label, state, and text; blank means any. */
data class BoardTarget(
    val boardId: String = "",
    val machineId: String = "",
    val labelId: String = "",
    val state: BoardStateFilter? = null,
    val query: String = "",
)

/** What a board shows for one card and offers on it now. */
data class BoardCardState(
    /** This client's operation in flight; STARTING also while a start waits in the outbox. */
    val operation: CardOperation?,
    /** "Starting…", "Stopping…", "Running"; null while the agent rests. */
    val badge: String?,
    val tone: RuntimeTone,
    /** The runtime pill's text. */
    val runtimeLabel: String,
    val agent: AgentStatus,
    val canStart: Boolean,
    val starting: Boolean,
    val canEditDraft: Boolean,
    val canCancel: Boolean,
    val mergeSourceKey: String,
    val mergeTargetKey: String,
    /** The card exists only in this device's outbox. */
    val pending: Boolean,
    /** Its creation was rejected; the user retries or discards it. */
    val failed: Boolean,
) {
    /** The card can be dragged or moved: it exists on its machine and this client has nothing in flight for it. */
    val canMove: Boolean get() = operation == null && !pending

    companion object {
        /**
         * [card] on [board] with [operation] in flight. A card that exists
         * only in the outbox ([pending]) cannot start until it is created.
         */
        fun of(card: Card, board: Board?, operation: CardOperation? = null, pending: Boolean = false, failed: Boolean = false): BoardCardState {
            val starting = operation == CardOperation.STARTING
            return BoardCardState(
                operation = operation,
                badge = Runtimes.badge(card.runtime, operation),
                tone = Runtimes.tone(card.runtime, operation),
                runtimeLabel = Runtimes.label(card.runtime, operation),
                agent = Runtimes.agentStatus(card, operation),
                canStart = !starting && !pending && CardPolicy.canStart(card, board),
                starting = starting,
                canEditDraft = !starting && CardPolicy.canEditDraft(card),
                canCancel = CardPolicy.canCancel(card, operation),
                mergeSourceKey = CardPolicy.mergeSourceKey(card, operation),
                mergeTargetKey = CardPolicy.mergeTargetKey(card),
                pending = pending,
                failed = failed,
            )
        }
    }
}

/** One lane as a board view shows it: its shown cards top to bottom. */
data class BoardLaneView(val lane: Lane, val kind: LaneKind, val descending: Boolean, val cards: List<Card>)

/** A board as one view shows it, with the counts its chrome reads. */
data class BoardView(
    val target: BoardTarget = BoardTarget(),
    val board: Board? = null,
    val lanes: List<BoardLaneView> = emptyList(),
    /** Label ID → the board's cards with it, before filtering. */
    val labelCounts: Map<String, Int> = emptyMap(),
    /** The board's cards, before filtering. */
    val total: Int = 0,
    /** The board's cards waiting for the user: an answer or an unread reply. */
    val needsYou: Int = 0,
    /** Machines running the board's cards, by name. */
    val machineIds: List<String> = emptyList(),
    /** Shown card ID → its state. */
    val cards: Map<String, BoardCardState> = emptyMap(),
) {
    val stateTitle: String get() = BoardStateFilter.title(target.state)

    /** "board · 4 conversations · 1 needs you". */
    val summary: String get() = summary("board")

    /** [scope] (the board, or its project), "4 conversations", and "1 needs you" or "2 need you" when any card does. */
    fun summary(scope: String): String =
        listOfNotNull(scope, Counts.of(total, "conversation"), "$needsYou ${Counts.word(needsYou, "needs", "need")} you".takeIf { needsYou > 0 }).joinToString(" · ")

    /** The shown lane with [id], ignoring case. */
    fun lane(id: String): BoardLaneView? = lanes.firstOrNull { it.lane.id.equals(id, ignoreCase = true) }

    /**
     * The daemon's anchors for dropping [cardId] into [lane] above
     * [beforeCardId] as shown (blank: at the lane's end); null when the card
     * would stay where it is.
     */
    fun drop(cardId: String, lane: BoardLaneView, beforeCardId: String): DropAnchors? {
        if (beforeCardId == cardId) return null
        val current = lane.cards.indexOfFirst { it.id == cardId }
        val shown = lane.cards.filterNot { it.id == cardId }
        val index = shown.indexOfFirst { it.id == beforeCardId }.takeIf { beforeCardId.isNotEmpty() && it >= 0 }
        if (current >= 0 && (index ?: shown.size) == current) return null
        return Lanes.anchors(shown, index, lane.descending)
    }

    companion object {
        /** The state filter's choices: null ("All states") first. */
        val STATE_OPTIONS: List<BoardStateFilter?> = listOf(null) + BoardStateFilter.entries
    }
}

object BoardViews {
    /**
     * [target]'s [board] as shown. [items] are the workspace's cards (any
     * board); [operations] this client's card operations, with
     * [startingCardIds] (starts waiting in the outbox) as STARTING where it
     * has none; [moves] its unconfirmed moves. Lane cards match by lane ID,
     * ignoring case, and sort by [Lanes.ordered] in [laneDescending]'s
     * direction.
     */
    fun build(
        target: BoardTarget,
        board: Board?,
        items: List<Card>,
        operations: Map<String, CardOperation> = emptyMap(),
        moves: Map<String, PendingMove> = emptyMap(),
        startingCardIds: Set<String> = emptySet(),
        pendingCardIds: Set<String> = emptySet(),
        failedCardIds: Set<String> = emptySet(),
        laneDescending: (laneId: String) -> Boolean = { true },
        machineLabel: (daemonId: String) -> String = { it },
    ): BoardView {
        if (target.boardId.isEmpty()) return BoardView(target)
        val cards = items.filter { it.board_id == target.boardId }
        fun operation(id: String): CardOperation? = operations[id] ?: CardOperation.STARTING.takeIf { id in startingCardIds }
        val shown = BoardFilters.cards(cards, target.boardId, target.machineId.ifEmpty { null }, target.labelId, target.query)
            .filter { card -> target.state?.matches(card, operation(card.id)) != false }
        val lanes = Lanes.shown(board).map { lane ->
            val descending = laneDescending(lane.id)
            BoardLaneView(lane, Lanes.kind(lane), descending, Lanes.ordered(shown.filter { it.lane.equals(lane.id, ignoreCase = true) }, moves, descending))
        }
        return BoardView(
            target = target,
            board = board,
            lanes = lanes,
            labelCounts = cards.flatMap { it.label_ids.distinct() }.groupingBy { it }.eachCount(),
            total = cards.size,
            needsYou = cards.count { Activity.classify(it)?.needsYou == true },
            machineIds = BoardFilters.machines(cards, target.boardId, machineLabel).filter { it.isNotEmpty() },
            cards = lanes.flatMap { it.cards }.associate { card ->
                card.id to BoardCardState.of(card, board, operation(card.id), card.id in pendingCardIds, card.id in failedCardIds)
            },
        )
    }
}

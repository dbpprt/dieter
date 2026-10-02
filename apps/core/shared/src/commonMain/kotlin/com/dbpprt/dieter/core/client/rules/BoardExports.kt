package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.DraftAgentSettings
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.client.v1.BoardCardFlags
import com.dbpprt.dieter.client.v1.BoardLaneKind
import com.dbpprt.dieter.client.v1.BoardViewSlice
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.Cards as CardList
import com.dbpprt.dieter.client.v1.RuntimeTone
import com.dbpprt.dieter.core.board.BoardCardState
import com.dbpprt.dieter.core.board.BoardViews
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.client.boardCardFlags as clientCardFlags
import com.dbpprt.dieter.core.client.boardTarget
import com.dbpprt.dieter.core.client.boardViewSlice
import com.dbpprt.dieter.core.client.laneKind as clientLaneKind
import com.dbpprt.dieter.core.client.runtimeTone as clientRuntimeTone

/**
 * Card and runtime rules for views outside the board view surface (chat
 * rows, the Inbox's card menu, the conversation header, the edit card form),
 * and the board view laid out from given cards.
 */
object BoardExports {
    /** An unfiled chat; a chat filed on a board ([boardId] not empty) is a card. */
    fun isChat(scope: String, boardId: String): Boolean = Cards.isChat(Card(scope = scope, board_id = boardId))

    /** [runtime]'s colour family, e.g. for a chat row's indicator. */
    fun runtimeTone(runtime: String): RuntimeTone = clientRuntimeTone(Runtimes.tone(runtime))

    /** The runtime pill: "Running", "Starting…", "Waiting for you", "Failed", "Idle", … */
    fun runtimeLabel(runtime: String): String = Runtimes.label(runtime)

    /** A turn is admitted, running, streaming, or stopping. */
    fun runtimeActive(runtime: String): Boolean = Runtimes.isActive(runtime)

    /** A lane's kind for its tint, by its ID, else its name. */
    fun laneKind(laneId: String, laneName: String): BoardLaneKind = clientLaneKind(Lanes.kind(Lane(laneId, laneName)))

    /**
     * What a board shows for [card] and offers on it, as the board view
     * computes it; [board] is the card's board (empty when unknown),
     * [operation] this client's CardOperation name in flight ("" for none),
     * [pending] when the card exists only in the outbox, and [failed] when
     * its creation was rejected.
     */
    fun cardFlags(card: Card, board: Board, operation: String, pending: Boolean, failed: Boolean): BoardCardFlags =
        clientCardFlags(BoardCardState.of(card, board, CardOperation.entries.firstOrNull { it.name == operation }, pending, failed))

    /**
     * Why the edit card form cannot save [title], [task], and the agent
     * [selection] it shows on [card] ([CardPolicy.draftProblem], which
     * saving enforces); "" when it can.
     */
    fun cardDraftProblem(card: Card, title: String, task: String, selection: HarnessSelection): String =
        CardPolicy.draftProblem(card, title, task, DraftAgentSettings(selection.provider, selection.model, selection.effort, selection.provider_options)).orEmpty()

    /**
     * [target]'s board as the board view shows [cards] on [board], without
     * this device's operations or pending moves, e.g. for cards a fixture
     * shows without the workspace.
     */
    fun boardView(board: Board, cards: CardList, target: BoardViewTarget): BoardViewSlice =
        boardViewSlice(BoardViews.build(boardTarget(target), board, cards.cards))
}

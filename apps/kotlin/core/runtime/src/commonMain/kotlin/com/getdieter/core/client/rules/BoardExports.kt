package com.getdieter.core.client.rules

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.DraftAgentSettings
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.Lane
import com.getdieter.client.v1.BoardCardFlags
import com.getdieter.client.v1.BoardLaneKind
import com.getdieter.client.v1.BoardViewSlice
import com.getdieter.client.v1.BoardViewTarget
import com.getdieter.client.v1.Cards as CardList
import com.getdieter.client.v1.RuntimeTone
import com.getdieter.core.board.BoardCardState
import com.getdieter.core.board.BoardViews
import com.getdieter.core.board.CardOperation
import com.getdieter.core.board.CardPolicy
import com.getdieter.core.board.Cards
import com.getdieter.core.board.Lanes
import com.getdieter.core.board.Runtimes
import com.getdieter.core.client.boardCardFlags as clientCardFlags
import com.getdieter.core.client.boardTarget
import com.getdieter.core.client.boardViewSlice
import com.getdieter.core.client.laneKind as clientLaneKind
import com.getdieter.core.client.runtimeTone as clientRuntimeTone

/**
 * Card and runtime rules for views outside the board view surface (chat rows, the Inbox's card
 * menu, the conversation header, the edit card form), and the board view laid out from given cards.
 */
object BoardExports {
    /** The machine produced a reply the user has not seen. */
    fun isUnread(card: Card): Boolean = Runtimes.isUnread(card)

    /** An unfiled chat; a chat filed on a board ([boardId] not empty) is a card. */
    fun isChat(scope: String, boardId: String): Boolean =
        Cards.isChat(Card(scope = scope, board_id = boardId))

    /** [runtime]'s colour family, e.g. for a chat row's indicator. */
    fun runtimeTone(runtime: String): RuntimeTone = clientRuntimeTone(Runtimes.tone(runtime))

    /** The runtime pill: "Running", "Starting…", "Waiting for you", "Failed", "Idle", … */
    fun runtimeLabel(runtime: String): String = Runtimes.label(runtime)

    /** A turn is admitted, running, streaming, or stopping. */
    fun runtimeActive(runtime: String): Boolean = Runtimes.isActive(runtime)

    /** A lane's kind for its tint, by its ID, else its name. */
    fun laneKind(laneId: String, laneName: String): BoardLaneKind =
        clientLaneKind(Lanes.kind(Lane(laneId, laneName)))

    /**
     * What a board shows for [card] and offers on it, as the board view computes it; [board] is the
     * card's board (empty when unknown), [operation] this client's CardOperation name in flight (""
     * for none), [pending] when the card exists only in the outbox, and [failed] when its creation
     * was rejected.
     */
    fun cardFlags(
        card: Card,
        board: Board,
        operation: String,
        pending: Boolean,
        failed: Boolean,
    ): BoardCardFlags =
        clientCardFlags(
            BoardCardState.of(
                card,
                board,
                CardOperation.entries.firstOrNull { it.name == operation },
                pending,
                failed,
            )
        )

    /**
     * Why the edit card form cannot save [title], [task], and the agent [selection] it shows on
     * [card] ([CardPolicy.draftProblem], which saving enforces); "" when it can.
     */
    fun cardDraftProblem(
        card: Card,
        title: String,
        task: String,
        selection: HarnessSelection,
    ): String =
        CardPolicy.draftProblem(
                card,
                title,
                task,
                DraftAgentSettings(
                    selection.provider,
                    selection.model,
                    selection.effort,
                    selection.provider_options,
                ),
            )
            .orEmpty()

    /**
     * [target]'s board as the board view shows [cards] on [board], without this device's operations
     * or pending moves, e.g. for cards a fixture shows without the workspace.
     */
    fun boardView(board: Board, cards: CardList, target: BoardViewTarget): BoardViewSlice =
        boardViewSlice(BoardViews.build(boardTarget(target), board, cards.cards))
}

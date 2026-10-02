package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.DraftAgentSettings
import com.dbpprt.dieter.api.v1.Lane

enum class LaneKind { REVIEW, DONE, RUNNING, OTHER }

/** A move this client made that sync has not confirmed yet. */
data class PendingMove(val lane: String, val afterCardId: String = "", val beforeCardId: String = "")

/** A drop position expressed as the daemon's ordering anchors. */
data class DropAnchors(val afterCardId: String = "", val beforeCardId: String = "")

object Lanes {
    const val TODO = "todo"
    const val RUNNING = "running"
    const val DONE = "done"

    private fun find(board: Board?, id: String): Lane? {
        val lanes = board?.lanes.orEmpty()
        return lanes.firstOrNull { it.id.equals(id, ignoreCase = true) } ?: lanes.firstOrNull { it.name.equals(id, ignoreCase = true) }
    }

    fun running(board: Board?): Lane? = find(board, RUNNING)

    /** The card's own board decides: the "done" lane by ID or name, else its last lane. */
    fun done(board: Board?): Lane? = find(board, DONE) ?: board?.lanes?.lastOrNull()

    fun isTodo(lane: String): Boolean = lane.equals(TODO, ignoreCase = true)

    const val REVIEW = "review"

    /** A review lane, by ID or a name such as "In review"; its cards wait for the user. */
    fun isReview(lane: String): Boolean = lane.contains(REVIEW, ignoreCase = true)

    fun isRunning(lane: String): Boolean = lane.equals(RUNNING, ignoreCase = true)

    /** What kind of lane [lane] is, by ID or name fragment, e.g. to color it. */
    fun kind(lane: String): LaneKind = when {
        isReview(lane) -> LaneKind.REVIEW
        lane.contains(DONE, ignoreCase = true) -> LaneKind.DONE
        lane.contains(RUNNING, ignoreCase = true) -> LaneKind.RUNNING
        else -> LaneKind.OTHER
    }

    /** A board lane's kind by its ID, else by its name, e.g. "in-flight" named "Running". */
    fun kind(lane: Lane): LaneKind = kind(lane.id).takeUnless { it == LaneKind.OTHER } ?: kind(lane.name)

    fun isDone(lane: String): Boolean = lane.equals(DONE, ignoreCase = true)

    /** The default (review) workflow's lanes, as the daemon creates them. */
    val DEFAULT: List<Lane> = listOf(Lane(TODO, "Todo"), Lane(RUNNING, "Running"), Lane(REVIEW, "Review"), Lane(DONE, "Done"))

    /** The lanes a board shows: its own, or [DEFAULT] for a board without lanes. */
    fun shown(board: Board?): List<Lane> = board?.lanes?.takeIf { it.isNotEmpty() } ?: DEFAULT

    /** Placement order: order key, then position for cards without one, then ID. */
    val placement: Comparator<Card> = compareBy<Card> { it.order_key }
        .thenBy { if (it.order_key.isEmpty()) it.position else 0L }
        .thenBy { it.id }

    /**
     * One lane's cards in ascending placement with this client's pending moves
     * applied: a moved card sits before its before-anchor, else after its
     * after-anchor, else at the end.
     */
    /** A lane as shown: [arrange]d, newest first unless [descending] is false (the lane's shared sort). */
    fun ordered(cards: List<Card>, moves: Map<String, PendingMove> = emptyMap(), descending: Boolean = true): List<Card> =
        arrange(cards, moves).let { if (descending) it.reversed() else it }

    fun arrange(cards: List<Card>, moves: Map<String, PendingMove> = emptyMap()): List<Card> {
        val sorted = cards.sortedWith(placement).toMutableList()
        for ((id, move) in moves.entries.sortedBy { it.key }) {
            val index = sorted.indexOfFirst { it.id == id }
            if (index < 0 || !sorted[index].lane.equals(move.lane, ignoreCase = true)) continue
            val card = sorted.removeAt(index)
            val before = sorted.indexOfFirst { it.id == move.beforeCardId }.takeIf { move.beforeCardId.isNotEmpty() && it >= 0 }
            val after = sorted.indexOfFirst { it.id == move.afterCardId }.takeIf { move.afterCardId.isNotEmpty() && it >= 0 }
            when {
                before != null -> sorted.add(before, card)
                after != null -> sorted.add(after + 1, card)
                else -> sorted.add(card)
            }
        }
        return sorted
    }

    /**
     * Anchors for dropping into [displayed] (the lane as shown, without the
     * moving card) before index [index], or at the end when null. A lane
     * shown newest-first swaps the visual neighbours.
     */
    fun anchors(displayed: List<Card>, index: Int?, descending: Boolean): DropAnchors {
        val position = index?.coerceIn(0, displayed.size) ?: displayed.size
        val above = displayed.getOrNull(position - 1)?.id.orEmpty()
        val below = displayed.getOrNull(position)?.id.orEmpty()
        return if (descending) DropAnchors(afterCardId = below, beforeCardId = above) else DropAnchors(afterCardId = above, beforeCardId = below)
    }
}

object Cards {
    /** An unfiled chat. A chat filed on a board sits in its lanes and behaves like a card. */
    fun isChat(card: Card): Boolean = card.scope == "chat" && card.board_id.isEmpty()

    /** The agent a card runs: its provider (or "agent") and model, e.g. "codex · gpt-5". */
    fun agent(card: Card): String = listOf(card.provider.ifBlank { "agent" }, card.model).filter { it.isNotBlank() }.joinToString(" · ")
}

/** Which card actions are available. Ported from Android `CardStartPolicy` and the Mac board policies. */
object CardPolicy {
    /** A never-started todo card with a task (text or attachments) and a board with a running lane. */
    fun canStart(card: Card, board: Board?, hasDraftAttachments: Boolean = false): Boolean =
        card.scope == "board" && Lanes.isTodo(card.lane) && card.initial_prompt_sent_at.isEmpty() &&
            card.merged_into_card_id.isEmpty() && (card.initial_prompt.isNotBlank() || hasDraftAttachments) &&
            Lanes.running(board) != null

    /** The lane a Start moves [card] to, when it can start now. */
    fun startLane(card: Card, board: Board?): String? = if (canStart(card, board)) Lanes.running(board)?.id else null

    /** A todo card whose initial task was never sent can still be edited. */
    fun canEditDraft(card: Card): Boolean =
        card.scope == "board" && Lanes.isTodo(card.lane) && card.merged_into_card_id.isEmpty() &&
            card.initial_prompt_sent_at.isEmpty() && card.initial_prompt.isNotBlank()

    /**
     * Why the edit card form cannot save [title], [task], and [agent] (null:
     * the card's own agent) on [card]; null when it can. A never-started
     * draft takes all three but needs a title and a task; a card whose task
     * was sent only takes a new title.
     */
    fun draftProblem(card: Card, title: String, task: String, agent: DraftAgentSettings?): String? = when {
        title.isBlank() -> "Enter a title."
        canEditDraft(card) -> "Enter the agent's task.".takeIf { task.isBlank() }
        task.trim() != card.initial_prompt.trim() || (agent != null && !sameAgent(card, agent)) ->
            "The task was already sent to the agent; only the title can change."
        else -> null
    }

    private fun sameAgent(card: Card, agent: DraftAgentSettings): Boolean =
        agent.provider == card.provider && agent.model == card.model && agent.effort == card.effort && agent.provider_options == card.provider_options

    /** An idle card can be merged into a started card on the same board and machine. */
    fun canMerge(source: Card, target: Card): Boolean =
        source.id != target.id && mergeSourceKey(source).let { it.isNotEmpty() && it == mergeTargetKey(target) }

    /**
     * The key a dragged [card] merges by: its board, project, and machine
     * while it can be merged into another card (idle, unmerged, unarchived,
     * on a board); "" otherwise. [operation] is this client's in flight.
     */
    fun mergeSourceKey(card: Card, operation: CardOperation? = null): String =
        if (mergeable(card) && !Runtimes.isBoardActive(card, operation = operation)) mergeKey(card) else ""

    /** The key a started, unmerged, unarchived board card accepts merges by; "" otherwise. */
    fun mergeTargetKey(card: Card): String = if (mergeable(card) && card.initial_prompt_sent_at.isNotEmpty()) mergeKey(card) else ""

    private fun mergeable(card: Card): Boolean = card.board_id.isNotEmpty() && !card.archived && card.merged_into_card_id.isEmpty()

    private fun mergeKey(card: Card): String = "${card.board_id}|${card.project_id}|${card.owner_daemon_id}"

    /**
     * The card's turn can be stopped: its agent works (and is not already
     * stopping) or waits for input, and this client is not cancelling it.
     */
    fun canCancel(card: Card, operation: CardOperation? = null): Boolean =
        operation != CardOperation.CANCELLING && Runtimes.classify(card.runtime).let { it == RuntimeState.ACTIVE || it == RuntimeState.NEEDS_INPUT }

    /** The optimistic look of a started card. */
    fun started(card: Card, board: Board?): Card? {
        if (card.initial_prompt_sent_at.isNotEmpty()) return null
        val running = Lanes.running(board) ?: return null
        return card.copy(lane = running.id, runtime = "starting")
    }
}

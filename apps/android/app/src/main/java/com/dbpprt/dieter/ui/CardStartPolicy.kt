package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card

internal fun Card.canStartFromTodo(hasDraftAttachments: Boolean = false): Boolean =
    scope == "board" &&
        lane.equals("todo", ignoreCase = true) &&
        (initialPrompt.isNotBlank() || hasDraftAttachments) &&
        initialPromptSentAt.isBlank()

internal fun Board.runningLaneId(): String? =
    lanesList.firstOrNull { it.id.equals("running", ignoreCase = true) }?.id
        ?: lanesList.firstOrNull { it.name.equals("running", ignoreCase = true) }?.id

internal fun Card.startLane(board: Board?): String? =
    if (canStartFromTodo()) board?.runningLaneId() else null

internal fun Card.optimisticStart(board: Board?): Card? {
    val runningLane = startLane(board) ?: return null
    return toBuilder()
        .setLane(runningLane)
        .setRuntime("starting")
        .build()
}

data class OptimisticCardMove(
    val operationId: String,
    val lane: String,
    val position: Long,
    val confirmsPosition: Boolean,
) {
    fun isConfirmedBy(card: Card): Boolean =
        card.lane == lane && (!confirmsPosition || card.position == position)

    fun applyingTo(card: Card): Card = card.toBuilder()
        .setLane(lane)
        .setPosition(position)
        .build()
}

internal data class CardOperationProjection(
    val cards: List<Card>,
    val pendingMoves: Map<String, OptimisticCardMove>,
)

/** Keeps local lane changes visible while stale workspace frames catch up. */
internal fun projectCardsDuringOperations(
    remoteCards: List<Card>,
    localCards: List<Card>,
    operations: Map<String, CardOperation>,
    pendingMoves: Map<String, OptimisticCardMove>,
): CardOperationProjection {
    if (pendingMoves.isEmpty() && operations.values.none { it == CardOperation.STARTING }) {
        return CardOperationProjection(remoteCards, pendingMoves)
    }
    val localById = localCards.associateBy(Card::getId)
    val startingCards = localById.filterKeys { operations[it] == CardOperation.STARTING }
    val remainingMoves = pendingMoves.toMutableMap()
    val projected = remoteCards.map { remote ->
        val move = pendingMoves[remote.id]
        when {
            move != null && move.isConfirmedBy(remote) -> {
                remainingMoves.remove(remote.id)
                remote
            }
            move != null -> move.applyingTo(remote)
            startingCards[remote.id] != null && remote.initialPromptSentAt.isBlank() ->
                requireNotNull(startingCards[remote.id])
            else -> remote
        }
    }.toMutableList()
    val remoteIds = remoteCards.mapTo(hashSetOf(), Card::getId)
    startingCards.values.filterTo(projected) { it.id !in remoteIds }
    pendingMoves.forEach { (cardId, move) ->
        if (cardId !in remoteIds) localById[cardId]?.let { projected += move.applyingTo(it) }
    }
    return CardOperationProjection(projected, remainingMoves)
}

internal fun reconcileCardsDuringOperations(
    remoteCards: List<Card>,
    localCards: List<Card>,
    operations: Map<String, CardOperation>,
): List<Card> = projectCardsDuringOperations(
    remoteCards = remoteCards,
    localCards = localCards,
    operations = operations,
    pendingMoves = emptyMap(),
).cards

internal fun resolvedCardRuntime(
    cardRuntime: String,
    conversationStatus: String,
    operation: CardOperation? = null,
): String {
    if (operation == CardOperation.STARTING) return "starting"
    if (operation == CardOperation.CANCELLING) return "cancelling"
    val card = cardRuntime.trim().lowercase()
    val conversation = conversationStatus.trim().lowercase()
    val active = setOf("starting", "running", "working", "streaming")
    return when {
        conversation in active -> conversation
        card in active -> card
        card.isNotBlank() -> card
        conversation.isNotBlank() -> conversation
        else -> "idle"
    }
}

internal fun isActiveCardRuntime(runtime: String): Boolean =
    runtime.lowercase() in setOf("starting", "running", "working", "streaming", "cancelling")

internal fun shouldShowAgentWorking(activeTurn: Boolean, awaitingAgent: Boolean): Boolean =
    activeTurn || awaitingAgent

internal fun agentWorkingLabel(toolName: String): String =
    if (toolName.isBlank()) "Thinking" else "Working · ${displayAgentToolName(toolName)}"

private fun displayAgentToolName(name: String): String = name
    .removePrefix("tool-")
    .replace('_', ' ')
    .replace('-', ' ')
    .replaceFirstChar { it.uppercase() }

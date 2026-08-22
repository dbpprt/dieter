package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Board
import com.dbpprt.nauclio.v1.Card

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

internal fun reconcileCardsDuringOperations(
    remoteCards: List<Card>,
    localCards: List<Card>,
    operations: Map<String, CardOperation>,
): List<Card> {
    val startingCards = localCards.associateBy(Card::getId).filterKeys { operations[it] == CardOperation.STARTING }
    if (startingCards.isEmpty()) return remoteCards

    val reconciled = remoteCards.map { remote ->
        val optimistic = startingCards[remote.id]
        if (optimistic != null && remote.initialPromptSentAt.isBlank()) optimistic else remote
    }.toMutableList()
    val remoteIds = remoteCards.mapTo(hashSetOf(), Card::getId)
    startingCards.values.filterTo(reconciled) { it.id !in remoteIds }
    return reconciled
}

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

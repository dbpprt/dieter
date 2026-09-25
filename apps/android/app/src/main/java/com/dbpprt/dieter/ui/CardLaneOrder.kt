package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card

internal enum class CardPlacementSortDirection {
    DESCENDING,
    ASCENDING;

    fun toggled(): CardPlacementSortDirection = if (this == DESCENDING) ASCENDING else DESCENDING
}

internal fun cardsByPlacement(
    cards: List<Card>,
    direction: CardPlacementSortDirection = CardPlacementSortDirection.DESCENDING,
    moves: Map<String, OptimisticCardMove> = emptyMap(),
): List<Card> {
    val ordered = cards.sortedWith(compareBy<Card> { it.orderKey }.thenBy { if (it.orderKey.isEmpty()) it.position else 0L }.thenBy { it.id })
    val projected = ordered.toMutableList()
    for ((id, move) in moves.toSortedMap()) {
        val index = projected.indexOfFirst { it.id == id && it.lane == move.lane }
        if (index < 0) continue
        val card = projected.removeAt(index)
        val before = projected.indexOfFirst { it.id == move.beforeCardId }
        val after = projected.indexOfFirst { it.id == move.afterCardId }
        projected.add(if (before >= 0) before else if (after >= 0) after + 1 else projected.size, card)
    }
    return if (direction == CardPlacementSortDirection.ASCENDING) projected else projected.reversed()
}

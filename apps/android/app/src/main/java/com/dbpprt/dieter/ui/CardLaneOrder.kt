package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import java.time.Instant

internal enum class CardCreationSortDirection {
    DESCENDING,
    ASCENDING;

    fun toggled(): CardCreationSortDirection = if (this == DESCENDING) ASCENDING else DESCENDING
}

internal fun cardsByCreationTime(
    cards: List<Card>,
    direction: CardCreationSortDirection = CardCreationSortDirection.DESCENDING,
): List<Card> = cards.sortedWith { left, right ->
    val leftCreatedAt = runCatching { Instant.parse(left.createdAt) }.getOrNull()
    val rightCreatedAt = runCatching { Instant.parse(right.createdAt) }.getOrNull()
    when {
        leftCreatedAt == null && rightCreatedAt == null -> compareIds(left.id, right.id, direction)
        leftCreatedAt == null -> 1
        rightCreatedAt == null -> -1
        leftCreatedAt != rightCreatedAt -> if (direction == CardCreationSortDirection.DESCENDING) {
            rightCreatedAt.compareTo(leftCreatedAt)
        } else {
            leftCreatedAt.compareTo(rightCreatedAt)
        }
        else -> compareIds(left.id, right.id, direction)
    }
}

private fun compareIds(
    left: String,
    right: String,
    direction: CardCreationSortDirection,
): Int = if (direction == CardCreationSortDirection.DESCENDING) right.compareTo(left) else left.compareTo(right)

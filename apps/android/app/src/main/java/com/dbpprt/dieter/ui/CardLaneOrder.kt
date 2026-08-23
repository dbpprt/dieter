package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import java.time.Instant

internal fun newestCardsFirst(cards: List<Card>): List<Card> = cards.sortedWith(
    compareByDescending<Card> { card ->
        runCatching { Instant.parse(card.createdAt) }.getOrDefault(Instant.MIN)
    }.thenByDescending { it.id },
)

package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Test

class CardLaneOrderTest {
    @Test
    fun sortsCardsByCreationTimeNewestFirstByDefault() {
        val cards = listOf(
            card("oldest", "2026-08-16T18:00:00Z"),
            card("newest", "2026-08-16T20:00:00Z"),
            card("middle", "2026-08-16T19:00:00Z"),
        )

        assertEquals(listOf("newest", "middle", "oldest"), cardsByCreationTime(cards).map { it.id })
    }

    @Test
    fun sortsCardsByCreationTimeOldestFirstWhenAscending() {
        val cards = listOf(
            card("oldest", "2026-08-16T18:00:00Z"),
            card("newest", "2026-08-16T20:00:00Z"),
            card("middle", "2026-08-16T19:00:00Z"),
        )

        assertEquals(
            listOf("oldest", "middle", "newest"),
            cardsByCreationTime(cards, CardCreationSortDirection.ASCENDING).map { it.id },
        )
    }

    @Test
    fun putsMissingTimestampsLastAndBreaksTiesDeterministically() {
        val cards = listOf(
            card("a", "not-a-timestamp"),
            card("b", "2026-08-16T20:00:00Z"),
            card("c", "2026-08-16T20:00:00Z"),
        )

        assertEquals(listOf("c", "b", "a"), cardsByCreationTime(cards).map { it.id })
        assertEquals(
            listOf("b", "c", "a"),
            cardsByCreationTime(cards, CardCreationSortDirection.ASCENDING).map { it.id },
        )
    }

    private fun card(id: String, createdAt: String): Card = Card.newBuilder()
        .setId(id)
        .setCreatedAt(createdAt)
        .build()
}

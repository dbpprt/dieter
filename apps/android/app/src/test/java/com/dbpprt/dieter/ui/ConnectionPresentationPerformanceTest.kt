package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.*
import org.junit.Test

class ConnectionPresentationPerformanceTest {
    @Test fun idleDirectoryProjectionPreservesReferences() {
        val cards = (1..1000).map { Card.newBuilder().setId("card-$it").build() }
        val projects = (1..100).map { Project.newBuilder().setId("p-$it").build() }
        val order = projects.reversed().map { it.id }
        val projection = ProjectOrderProjection()
        val ordered = projection.apply(projects, order)
        repeat(1000) {
            assertSame(cards, projectCardsDuringOperations(cards, emptyList(), emptyMap(), emptyMap()).cards)
            assertSame(ordered, projection.apply(projects, order))
        }
        assertEquals(projects, projection.apply(projects, emptyList()))
        val added = projects + Project.newBuilder().setId("new").build()
        assertEquals("new", projection.apply(added, order).last().id)
    }

    @Test fun activityUpdatesRetainOtherEntriesAndEvictRemovedChats() {
        fun snapshot(id: String) = ConversationSnapshot.newBuilder().setDetail(
            com.dbpprt.dieter.v1.CardDetail.newBuilder().setCard(Card.newBuilder().setId(id)),
        ).build()
        val initial = (1..24).associate { "c-$it" to snapshot("c-$it") }
        val projection = ActivityDetailsProjection()
        val first = projection.apply(initial)
        repeat(1000) { assertSame(first, projection.apply(initial)) }
        val changed = initial.getValue("c-1").toBuilder().setDetail(
            initial.getValue("c-1").detail.toBuilder().setCard(
                initial.getValue("c-1").detail.card.toBuilder().setRuntimeUpdatedAt("new-turn"),
            ),
        ).build()
        val next = projection.apply(initial + ("c-1" to changed))
        assertNotEquals(first["c-1"], next["c-1"])
        assertSame(first["c-2"], next["c-2"])
        assertEquals(activityDetails(initial + ("c-1" to changed)), next)
        assertTrue(projection.apply(emptyMap()).isEmpty())
    }
}

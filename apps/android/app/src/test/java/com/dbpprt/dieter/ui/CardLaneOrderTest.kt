package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Test

class CardLaneOrderTest {
    @Test fun placementWinsOverCreationTimeInBothDirections() {
        val cards = listOf(
            Card.newBuilder().setId("a").setOrderKey("100").setCreatedAt("2099-01-01T00:00:00Z").build(),
            Card.newBuilder().setId("b").setOrderKey("300").setCreatedAt("2020-01-01T00:00:00Z").build(),
            Card.newBuilder().setId("c").setOrderKey("200").build(),
        )
        assertEquals(listOf("b", "c", "a"), cardsByPlacement(cards).map { it.id })
        assertEquals(listOf("a", "c", "b"), cardsByPlacement(cards, CardPlacementSortDirection.ASCENDING).map { it.id })
    }

    @Test fun pendingCrossLaneMoveUsesItsDestinationUntilTheReceiptArrives() {
        val cards = listOf("a", "b", "c").map {
            Card.newBuilder().setId(it).setLane("done").setOrderKey(it).build()
        }
        val move = OptimisticCardMove("move", "done", 4096)
        assertEquals(listOf("a", "c", "b"), cardsByPlacement(cards, moves = mapOf("a" to move)).map { it.id })
    }

    @Test fun simultaneousPlacementTiesUseStableIdentity() {
        val cards = listOf("b", "a", "c").map { Card.newBuilder().setId(it).setOrderKey("same").build() }
        assertEquals(listOf("c", "b", "a"), cardsByPlacement(cards).map { it.id })
    }
}

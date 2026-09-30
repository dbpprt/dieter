package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.GlobalDelta
import com.dbpprt.dieter.api.v1.GlobalSnapshot
import com.dbpprt.dieter.api.v1.State
import com.dbpprt.dieter.api.v1.SyncCursor
import com.dbpprt.dieter.api.v1.SyncFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SyncReplicaTest {
    private fun snapshot(vararg ids: String) = GlobalSnapshot(state = State(cards = ids.map { Card(id = it, title = it.uppercase()) }))

    @Test
    fun deltaKeepsPositionsAndAppendsNewObjects() {
        val next = applyGlobalDelta(
            snapshot("a", "b", "c"),
            GlobalDelta(cards = listOf(Card(id = "d", title = "D"), Card(id = "a", title = "A2")), removed_card_ids = listOf("b")),
        )
        assertEquals(listOf("a=A2", "c=C", "d=D"), next.state!!.cards.map { "${it.id}=${it.title}" })
    }

    @Test
    fun heartbeatsNeverAdvanceTheAppliedCursor() {
        val replica = SyncReplica()
        assertTrue(replica.apply(SyncFrame(cursor = SyncCursor(epoch = "e", sequence = 1), snapshot = snapshot("a"))).projection)
        val change = replica.apply(SyncFrame(heartbeat = true, cursor = SyncCursor(epoch = "e", sequence = 9)))
        assertEquals(SyncReplica.Change(projection = false, cursor = false), change)
        assertEquals(1L, replica.cursor?.sequence)
    }

    @Test
    fun pendingProjectionIsBufferedAndClearsTheResumeCursor() {
        val replica = SyncReplica()
        replica.apply(SyncFrame(cursor = SyncCursor(epoch = "e", sequence = 1), snapshot = snapshot("a")))
        replica.apply(SyncFrame(projection_pending = true, delta = GlobalDelta(cards = listOf(Card(id = "b")))))
        assertEquals(listOf("a"), replica.snapshot!!.state!!.cards.map { it.id })
        assertNull(replica.cursor)
        val change = replica.apply(SyncFrame(cursor = SyncCursor(epoch = "e", sequence = 3), delta = GlobalDelta(cards = listOf(Card(id = "c")))))
        assertTrue(change.projection && change.cursor)
        assertEquals(listOf("a", "b", "c"), replica.snapshot!!.state!!.cards.map { it.id })
    }
}

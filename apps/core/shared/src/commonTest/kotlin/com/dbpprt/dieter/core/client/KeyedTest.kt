package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.ConversationState
import com.dbpprt.dieter.client.v1.TimelineItem
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.testing.SliceFolds
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class KeyedTest {
    private fun card(id: String, title: String = id) = Card(id = id, title = title)

    @Test
    fun appendsAndEditsKeepTheOrderImplicit() {
        val diff = Keyed.diff(listOf(card("a"), card("b")), listOf(card("a", "A"), card("b"), card("c")), Card::id)
        assertEquals(listOf("a", "c"), diff.upserted.map { it.id })
        assertEquals(emptyList(), diff.removed)
        assertFalse(diff.orderChanged)
    }

    @Test
    fun insertsAndMovesResendTheOrder() {
        assertTrue(Keyed.diff(listOf(card("a"), card("b")), listOf(card("c"), card("a"), card("b")), Card::id).orderChanged)
        assertTrue(Keyed.diff(listOf(card("a"), card("b")), listOf(card("b"), card("a")), Card::id).orderChanged)
        val removal = Keyed.diff(listOf(card("a"), card("b"), card("c")), listOf(card("a"), card("c")), Card::id)
        assertEquals(listOf("b"), removal.removed)
        assertFalse(removal.orderChanged)
    }

    @Test
    fun foldingDeltasAlwaysReproducesTheSnapshot() {
        val random = Random(7)
        var previous = WorkspaceSlice()
        var folded = previous
        repeat(500) { step ->
            val ids = (0 until 12).map { "c$it" }.filter { random.nextBoolean() }.shuffled(random).let { if (random.nextInt(4) == 0) it.sorted() else it }
            val next = WorkspaceSlice(cards = ids.map { card(it, "$it@${random.nextInt(3)}") }, loaded = step % 2 == 0)
            val delta = Deltas.workspace(previous, next)
            if (delta == null) {
                assertEquals(previous, next)
            } else {
                folded = SliceFolds.apply(folded, delta)
            }
            assertEquals(next, folded, "step $step")
            previous = next
        }
        assertNull(Deltas.workspace(previous, previous))
    }

    @Test
    fun foldingConversationDeltasReproducesTheTimeline() {
        val random = Random(11)
        var previous = ConversationSlice()
        var folded = previous
        repeat(300) { step ->
            val ids = (0 until 10).map { "message:$it" }.filter { random.nextBoolean() }.shuffled(random).let { if (random.nextInt(3) == 0) it.sorted() else it }
            val next = ConversationSlice(
                timeline = ids.map { TimelineItem(id = it, summary = "$it@${random.nextInt(3)}") },
                unattached_plan_ids = if (random.nextBoolean()) listOf("plan") else emptyList(),
                state = ConversationState(working = step % 3 == 0),
            )
            val delta = Deltas.conversation(previous, next)
            if (delta == null) {
                assertEquals(previous, next)
            } else {
                assertTrue(delta.upserted_timeline.all { item -> previous.timeline.none { it == item } }, "only changed rows travel")
                folded = SliceFolds.apply(folded, delta)
            }
            assertEquals(next, folded, "step $step")
            previous = next
        }
    }
}

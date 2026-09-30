package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.WorkspaceSlice
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
            val delta = ClientApi.workspaceDelta(previous, next)
            if (delta == null) {
                assertEquals(previous, next)
            } else {
                folded = ClientApi.apply(folded, delta)
            }
            assertEquals(next, folded, "step $step")
            previous = next
        }
        assertNull(ClientApi.workspaceDelta(previous, previous))
    }
}

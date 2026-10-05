package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.core.sync.TestRecords.version
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RegistersTest {
    private val first = version("\"a\"", "a" to 1L)
    private val later = version("\"b\"", "a" to 2L)
    private val concurrent = version("\"c\"", "b" to 1L)
    private val merged = version("\"d\"", "a" to 2L, "b" to 1L)

    @Test
    fun theJoinKeepsWhatNoVersionSucceedsWhateverTheOrderOrRepetition() {
        assertEquals(listOf(later), Registers.join(listOf(listOf(first), listOf(later))))
        val siblings = Registers.join(listOf(listOf(later), listOf(concurrent)))
        assertEquals(setOf(later, concurrent), siblings.toSet())
        assertEquals(
            siblings,
            Registers.join(listOf(listOf(concurrent), listOf(later), listOf(later, first))),
        )
        assertEquals(
            listOf(merged),
            Registers.join(listOf(siblings, listOf(merged), listOf(first))),
        )
        assertEquals(siblings.map { it.rank }.sorted(), siblings.map { it.rank }, "ordered by rank")
    }

    @Test
    fun clocksCompareAsUnsignedCounters() {
        val high = version("true", "a" to Long.MAX_VALUE)
        val higher = version("false", "a" to Long.MIN_VALUE)
        assertTrue(Registers.covers(higher.clock, high.clock))
        assertFalse(Registers.covers(high.clock, higher.clock))
        assertEquals(listOf(higher), Registers.join(listOf(listOf(high), listOf(higher))))
    }

    @Test
    fun selectionShowsTheHighestRankUnlessATombstoneExists() {
        val tombstone = version(null, "b" to 2L)
        assertEquals(
            listOf(later, concurrent).maxBy { it.rank }.value_json,
            Registers.selected(listOf(later, concurrent)),
        )
        assertNull(Registers.selected(listOf(later, tombstone)), "a tombstone wins")
        assertNull(Registers.selected(emptyList()))
        assertEquals(tombstone, Registers.selectedKv(listOf(later, tombstone)))
        assertEquals(
            listOf(later, concurrent).maxBy { it.rank },
            Registers.selectedKv(listOf(later, concurrent)),
        )
        assertTrue(Registers.same(listOf(later, concurrent), listOf(concurrent, later)))
        assertFalse(Registers.same(listOf(later), listOf(concurrent, later)))
    }
}

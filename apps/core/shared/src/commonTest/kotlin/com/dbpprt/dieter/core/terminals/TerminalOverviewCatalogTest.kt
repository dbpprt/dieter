package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.api.v1.Terminal
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TerminalOverviewCatalogTest {
    private fun entry(daemon: String, machine: String, id: String, created: String) = TerminalOverviewEntry(daemon, machine, Terminal(id = id, created_at = created))

    @Test
    fun entriesSortByAgeThenMachineThenId() {
        val entries = listOf(
            entry("d_2", "beta", "t_2", "2026-09-30T10:00:00Z"),
            entry("d_1", "Alpha", "t_3", "2026-09-30T10:00:00Z"),
            entry("d_1", "Alpha", "t_1", "2026-09-30T09:00:00Z"),
        )
        assertEquals(listOf("d_1|t_1", "d_1|t_3", "d_2|t_2"), TerminalOverviewCatalog.sorted(entries).map { it.id })
    }

    @Test
    fun selectionKeepsTheCurrentThenPrefersTheMachine() {
        val entries = listOf(entry("d_1", "a", "t_1", "1"), entry("d_2", "b", "t_2", "2"))
        assertEquals("d_2|t_2", TerminalOverviewCatalog.selection(entries, "d_2|t_2", "d_1")?.id)
        assertEquals("d_2|t_2", TerminalOverviewCatalog.selection(entries, "gone", "d_2")?.id)
        assertEquals("d_1|t_1", TerminalOverviewCatalog.selection(entries, null, null)?.id)
        assertNull(TerminalOverviewCatalog.selection(emptyList(), null, "d_1"))
    }
}

package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.core.sync.TestRecords.board
import com.dbpprt.dieter.core.sync.TestRecords.checkout
import com.dbpprt.dieter.core.sync.TestRecords.project
import com.dbpprt.dieter.core.sync.TestRecords.record
import com.dbpprt.dieter.core.sync.TestRecords.replica
import com.dbpprt.dieter.core.sync.TestRecords.version
import kotlin.test.Test
import kotlin.test.assertEquals

/** Board retirement as a causal intent, joined across machines. */
class BoardLifecycleTest {
    private class Row(val name: String, val observations: String, val referenced: Boolean, val retired: Boolean, val blocked: Boolean)

    /**
     * The rows of `tests/fixtures/board-lifecycle.tsv`, which the daemon's
     * projection is tested against too: each machine's copy of the intent
     * (`clock=retired`, `-` for a machine without one), whether an item
     * references the board, and the expected projection.
     */
    private val fixture = listOf(
        Row("absent", "-", referenced = false, retired = false, blocked = false),
        Row("retire_then_stale", "a:1=true;-", referenced = false, retired = true, blocked = false),
        Row("stale_then_retire", "-;a:1=true", referenced = false, retired = true, blocked = false),
        Row("restore_then_stale", "a:1=true;a:2=false;a:1=true;-", referenced = false, retired = false, blocked = false),
        Row("concurrent_intents", "a:1=true;b:1=false", referenced = false, retired = false, blocked = true),
        Row("reverse_concurrent", "b:1=false;a:1=true", referenced = false, retired = false, blocked = true),
        Row("resolved_conflict", "a:1=true;b:1=false;a:2,b:1=false;b:1=false", referenced = false, retired = false, blocked = false),
        Row("late_reference", "a:1=true;-", referenced = true, retired = false, blocked = true),
        Row(
            "unsigned_clock", "a:9223372036854775807=true;a:9223372036854775808=false;a:9223372036854775807=true",
            referenced = false, retired = false, blocked = false,
        ),
    )

    @Test
    fun theSharedLifecycleFixtureProjectsAsTheDaemonDoes() {
        for (row in fixture) {
            val base = project("p") + checkout("co", "p", "m0") + board("b_fixture", "p")
            val reference = if (row.referenced) listOf(TestRecords.field("item", "card", "placement", """{"boardId":"b_fixture","lane":"todo"}""")) else emptyList()
            val machines = row.observations.split(';').mapIndexed { index, observation ->
                val records = if (observation == "-") emptyList() else {
                    val clock = observation.substringBefore('=').split(',').map { entry ->
                        entry.substringBefore(':') to entry.substringAfter(':').toULong().toLong()
                    }
                    listOf(record("board/b_fixture.retired", version(observation.substringAfter('='), *clock.toTypedArray())))
                }
                replica("m$index", records + if (index == 0) base + reference else emptyList())
            }
            val view = TestRecords.project(*machines.toTypedArray()).directory
            val board = view.retiredBoards["b_fixture"] ?: view.boards.getValue("p").single()
            assertEquals(row.retired, board.retired, row.name)
            assertEquals(row.blocked, board.retirement_blocked, row.name)
            assertEquals(if (board.retired) 0 else 1, view.projects.getValue("p").board_count, row.name)
            // Arrival order never matters.
            val reversed = TestRecords.project(*machines.reversed().toTypedArray()).directory
            assertEquals(view.boards, reversed.boards, row.name)
            assertEquals(view.retiredBoards, reversed.retiredBoards, row.name)
        }
    }

    @Test
    fun aRetirementBlockedByAnItemNamesItAndARevisionOnlyAnObserverHas() {
        val base = project("p") + checkout("co", "p", "m0") + board("b", "p")
        val retired = record("board/b.retired", version("true", "a" to 1L))
        val placed = TestRecords.field("item", "c_1", "placement", """{"boardId":"b","lane":"done"}""")
        val view = TestRecords.project(replica("m0", base + retired + placed)).directory
        val board = view.boards.getValue("p").single()
        assertEquals(true, board.retirement_blocked)
        assertEquals(listOf("item/c_1"), board.retirement_references)
        assertEquals(retired.revision, board.retirement_revision)

        // Two machines with different intents: no machine has observed the join, so no compare-and-swap can target it.
        val restored = record("board/b.retired", version("false", "b" to 1L))
        val joined = TestRecords.project(replica("m0", base + retired), replica("m1", listOf(restored))).directory
        assertEquals(UNOBSERVED_JOIN, joined.boards.getValue("p").single().retirement_revision)
        assertEquals("absent", TestRecords.project(replica("m0", base)).directory.boards.getValue("p").single().retirement_revision)
    }
}

package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRetirementVersion
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Board retirement as a causal intent, joined across observations. */
class BoardLifecycleTest {
    private class Row(val name: String, val observations: String, val referenced: Boolean, val retired: Boolean, val blocked: Boolean)

    /**
     * The rows of `tests/fixtures/board-lifecycle.tsv`, which the daemon's
     * projection is tested against too: observations in arrival order
     * (`clock=retired`, `-` for a board without an intent), whether a card
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

    private fun observed(observation: String): Board {
        val board = Board(id = "b_fixture", project_id = "project")
        if (observation == "-") return board
        val clock = observation.substringBefore('=').split(',').associate { entry ->
            entry.substringBefore(':') to entry.substringAfter(':').toULong().toLong()
        }
        val version = BoardRetirementVersion(clock = clock, rank = observation, retired = observation.substringAfter('=') == "true")
        return board.copy(retirement_versions = listOf(version), retired = version.retired, retirement_revision = observation)
    }

    @Test
    fun theSharedLifecycleFixtureProjectsAsTheDaemonDoes() {
        for (row in fixture) {
            var current: Board? = null
            for (observation in row.observations.split(';')) current = DirectoryReducer.mergeBoardLifecycle(observed(observation), current)
            val project = Project(id = "project")
            val card = Card(id = "card", project_id = project.id, board_id = "b_fixture")
            val initial = DirectoryProjection(
                projects = mapOf(project.id to project),
                boards = mapOf(project.id to listOf(current!!)),
                cards = if (row.referenced) mapOf(project.id to listOf(card)) else emptyMap(),
            )
            val result = DirectoryReducer.merge(initial, listOf(MachineSnapshot("peer", listOf(project), emptyList(), emptyList(), emptyList())))
            val board = result.retiredBoards["b_fixture"] ?: result.boards.getValue(project.id).single()
            assertEquals(row.retired, board.retired, row.name)
            assertEquals(row.blocked, board.retirement_blocked, row.name)
            assertEquals(if (board.retired) 0 else 1, result.projects.getValue(project.id).board_count, row.name)
        }
    }

    @Test
    fun aLaterRetirementCannotEraseKnownBlockingReferences() {
        val version = BoardRetirementVersion(clock = mapOf("a" to 1L), rank = "a", retired = true)
        val known = Board(id = "board", retirement_versions = listOf(version), retirement_blocked = true, retirement_references = listOf("item/offline"))
        val later = known.copy(
            retirement_versions = listOf(version.copy(clock = mapOf("a" to 2L), rank = "b")),
            retirement_blocked = false, retired = true, retirement_references = emptyList(),
        )
        val merged = DirectoryReducer.mergeBoardLifecycle(later, known)
        assertFalse(merged.retired)
        assertTrue(merged.retirement_blocked)
        assertEquals(listOf("item/offline"), merged.retirement_references)
    }

    @Test
    fun aViewCoversAnIntentOnlyOnceItsLifecycleIncludesIt() {
        val retired = observed("a:1=true")
        val restored = observed("a:2=false")
        assertTrue(DirectoryReducer.coversLifecycle(restored, retired))
        assertFalse(DirectoryReducer.coversLifecycle(retired, restored))
        assertFalse(DirectoryReducer.coversLifecycle(observed("-"), retired))
        // A board without an intent is covered by any view of it.
        assertTrue(DirectoryReducer.coversLifecycle(observed("-"), observed("-")))
    }

    @Test
    fun aCardFiledOnOrPlacedOnABoardReferencesIt() {
        val filed = Card(id = "c_1", board_id = "b_1")
        val chat = Card(id = "c_2", scope = "chat")
        assertEquals(setOf("b_1", ""), DirectoryReducer.referencedBoards(listOf(filed, chat)))
        val retired = Board(id = "b_1", retired = true)
        assertEquals(Board(id = "b_1", retirement_blocked = true), DirectoryReducer.blockingReferenced(retired, setOf("b_1")))
        assertEquals(retired, DirectoryReducer.blockingReferenced(retired, setOf("b_2")))
    }
}

package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.api.v1.ListRetiredBoardsResponse
import com.dbpprt.dieter.api.v1.State
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The account view the core projects from machines' records equals the one
 * a daemon materializes after merging the same records. The fixture is
 * generated and verified by the daemon (internal/server
 * `TestAccountProjectionFixture`): two machines that diverged and an
 * observer that merged both.
 */
class AccountProjectionConformanceTest {
    private val fixture = Json.parseToJsonElement(checkNotNull(javaClass.getResource("/account-projection.json")).readText()).jsonObject
    private val expected = State.ADAPTER.decode(decode(fixture.getValue("state").jsonPrimitive.content))
    private val retired = ListRetiredBoardsResponse.ADAPTER.decode(decode(fixture.getValue("retiredBoards").jsonPrimitive.content))

    private fun decode(value: String): ByteArray = Base64.getDecoder().decode(value)

    private fun frame(machine: String): ChangesFrame =
        ChangesFrame.ADAPTER.decode(decode(fixture.getValue("machines").jsonObject.getValue(machine).jsonPrimitive.content))

    /** Each named machine's records as its stream delivers them, under the given machine IDs. */
    private fun project(vararg machines: Pair<String, String>): DirectoryProjection {
        val replicas = machines.map { (id, name) ->
            MachineReplica(id).also { it.apply(frame(name).copy(reset_records = true, reset_local = true, caught_up = true)) }
        }
        val records = AccountRecords()
        records.update(replicas, replicas.flatMap { it.recordKeys }.toSet())
        return AccountProjector().project(records, replicas).directory
    }

    private fun assertMatchesDaemon(view: DirectoryProjection, unobservedAllowed: Boolean = false) {
        fun normalized(card: Card, actual: Card?): Card {
            if (!unobservedAllowed || actual == null) return card
            val fields = card.state_fields.map { field ->
                val shown = actual.state_fields.firstOrNull { it.name == field.name }
                if (shown?.revision == UNOBSERVED_JOIN) field.copy(revision = UNOBSERVED_JOIN) else field
            }
            val placement = if (actual.placement_revision == UNOBSERVED_JOIN) UNOBSERVED_JOIN else card.placement_revision
            return card.copy(state_fields = fields, placement_revision = placement)
        }
        fun normalized(board: Board, actual: Board?): Board =
            if (unobservedAllowed && actual?.retirement_revision == UNOBSERVED_JOIN) board.copy(retirement_revision = UNOBSERVED_JOIN) else board
        assertEquals(expected.projects.associateBy { it.id }, view.projects)
        val boards = view.boards.values.flatten().associateBy { it.id }
        assertEquals(expected.boards.associateBy { it.id }.mapValues { (id, board) -> normalized(board, boards[id]) }, boards)
        val retiredBoards = view.retiredBoards
        assertEquals(retired.boards.associateBy { it.id }.mapValues { (id, board) -> normalized(board, retiredBoards[id]) }, retiredBoards)
        val items = view.allItems.associateBy { it.id }
        assertEquals((expected.cards + expected.chats).associateBy { it.id }.mapValues { (id, card) -> normalized(card, items[id]) }, items)
    }

    @Test
    fun theAccountViewIsTheDaemonsProjection() {
        assertMatchesDaemon(project("a" to "machine_a", "b" to "machine_b", "o" to "observer"))
    }

    @Test
    fun divergedMachinesJoinToTheMergedProjection() {
        val view = project("a" to "machine_a", "b" to "machine_b")
        assertMatchesDaemon(view, unobservedAllowed = true)
        // Concurrent renames stay visible as a conflict, chosen the same way everywhere.
        assertTrue(view.allItems.any { card -> card.conflict_keys.any { it.endsWith(".title") } })
    }

    @Test
    fun arrivalOrderAndDuplicateMachinesNeverChangeTheView() {
        val reference = project("a" to "machine_a", "b" to "machine_b")
        assertEquals(reference, project("b" to "machine_b", "a" to "machine_a"))
        // The same records from more machines are the same versions.
        assertEquals(reference.copy(machinesByDaemon = emptyMap()), project("a" to "machine_a", "a2" to "machine_a", "b" to "machine_b").copy(machinesByDaemon = emptyMap()))
    }
}

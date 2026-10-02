package com.dbpprt.dieter.core.store

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRetirementVersion
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardStateField
import com.dbpprt.dieter.api.v1.CardStateVersion
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.SharedArchives
import com.dbpprt.dieter.core.sync.MachineSnapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Administrative results show in the workspace at once: projects with their
 * replica, boards placed as live or retired, checkouts, and consolidations,
 * each until a machine view reflects it.
 */
class WorkspaceStoreTest {
    private val t1 = "2026-10-01T10:00:00Z"
    private val t2 = "2026-10-01T11:00:00Z"
    private val t3 = "2026-10-01T12:00:00Z"
    private val checkout = Checkout(id = "co_1", project_id = "p_1", daemon_id = "d_1", name = "one", path = "/work/one")
    private val project = Project(id = "p_1", name = "One", updated_at = t1, checkouts = listOf(checkout))
    private val board = Board(id = "b_1", project_id = "p_1", name = "Main", updated_at = t1)
    private val second = Board(id = "b_2", project_id = "p_1", name = "Second", updated_at = t1)

    private fun snapshot(
        daemonId: String = "d_1",
        projects: List<Project> = listOf(project),
        boards: List<Board> = listOf(board),
        cards: List<Card> = emptyList(),
        retired: List<Board> = emptyList(),
    ) = MachineSnapshot(daemonId, projects, boards, cards, emptyList(), SharedArchives(retired_boards = retired))

    private fun storeWith(snapshot: MachineSnapshot) = WorkspaceStore().also { it.applyMachines(listOf(snapshot)) }

    private fun retirement(count: Long, retired: Boolean) = BoardRetirementVersion(clock = mapOf("a" to count), rank = "a$count", retired = retired)

    private fun retiredBoard() = board.copy(retired = true, retirement_revision = "r1", retirement_versions = listOf(retirement(1, true)))

    @Test
    fun aCreatedProjectShowsWithItsBoardAndReplicaUntilAMachineViewListsIt() {
        val store = storeWith(snapshot())
        val created = Project(
            id = "p_new", name = "New", updated_at = t2,
            checkouts = listOf(Checkout(id = "co_new", project_id = "p_new", daemon_id = "d_2", name = "new", path = "/work/new")),
        )
        val main = Board(id = "b_new", project_id = "p_new", name = "Main", updated_at = t2)
        store.overlayProject(created, replicaDaemonId = "d_2")
        store.overlayBoard(main)
        val view = store.state.value
        assertEquals(listOf("New", "One"), view.projects.map { it.name })
        assertEquals(1, view.project("p_new")!!.board_count)
        assertEquals(listOf("b_new"), view.boards["p_new"]?.map { it.id })
        assertEquals("d_2", view.projectReplicas["p_new"])
        // Calls that follow reach the machine that created it.
        assertEquals("d_2", store.directoryProjection.projectReplicas["p_new"])
        assertEquals("d_2", store.directoryProjection.checkoutMachine("p_new", "co_new"))

        // A view that predates the project keeps it, and counts its own boards.
        store.applyMachines(listOf(snapshot(boards = listOf(board, second))))
        assertEquals("d_2", store.state.value.projectReplicas["p_new"])
        assertEquals(2, store.state.value.project("p_1")!!.board_count)

        // Once a machine lists it, that machine is its replica.
        store.applyMachines(listOf(snapshot(daemonId = "d_3", projects = listOf(created), boards = listOf(main))))
        assertEquals("d_3", store.state.value.projectReplicas["p_new"])
        assertEquals("d_3", store.directoryProjection.projectReplicas["p_new"])
        assertEquals(1, store.state.value.project("p_new")!!.board_count)
    }

    @Test
    fun aRetiredBoardListsAsRetiredAndARestoredOneAsLiveAtOnce() {
        val store = storeWith(snapshot())
        val retired = retiredBoard()
        store.overlayBoard(retired)
        assertNull(store.state.value.board("b_1"))
        assertEquals(listOf("b_1"), store.state.value.retiredBoards.map { it.id })
        assertEquals(0, store.state.value.project("p_1")!!.board_count)
        assertNull(store.directoryProjection.board("b_1"))
        assertEquals("p_1", store.findBoard("b_1")?.project_id)

        // Retiring keeps the board's timestamp: a view without the intent does not undo it.
        store.applyMachines(listOf(snapshot(boards = listOf(board, second))))
        assertEquals(listOf("b_2"), store.state.value.boards["p_1"]?.map { it.id })
        assertEquals(listOf("b_1"), store.state.value.retiredBoards.map { it.id })
        assertEquals(1, store.state.value.project("p_1")!!.board_count)

        val restored = board.copy(retirement_revision = "r2", retirement_versions = listOf(retirement(2, false)))
        store.overlayBoard(restored)
        assertEquals("Main", store.state.value.board("b_1")?.name)
        assertEquals(emptyList(), store.state.value.retiredBoards)
        assertEquals(2, store.state.value.project("p_1")!!.board_count)

        // A view that has the retirement but not the restore lists it once, live.
        store.applyMachines(listOf(snapshot(boards = listOf(second), retired = listOf(retired))))
        assertEquals(listOf("b_1", "b_2"), store.state.value.boards["p_1"]?.map { it.id })
        assertEquals(emptyList(), store.state.value.retiredBoards)

        store.applyMachines(listOf(snapshot(boards = listOf(restored, second))))
        assertEquals(listOf("b_1", "b_2"), store.state.value.boards["p_1"]?.map { it.id })
        assertEquals(emptyList(), store.state.value.retiredBoards)
        assertEquals(2, store.state.value.project("p_1")!!.board_count)
    }

    @Test
    fun aBoardACardIsFiledOnStaysShownWithItsRetirementBlocked() {
        val store = storeWith(snapshot(cards = listOf(Card(id = "c_1", project_id = "p_1", board_id = "b_1", title = "Filed"))))
        store.overlayBoard(retiredBoard())
        val shown = store.state.value.board("b_1")!!
        assertFalse(shown.retired)
        assertTrue(shown.retirement_blocked)
        assertEquals(emptyList(), store.state.value.retiredBoards)
        assertEquals(1, store.state.value.project("p_1")!!.board_count)
    }

    @Test
    fun aLivePlacementOnABoardAlsoBlocksItsRetirement() {
        val placement = CardStateField(name = "placement", versions = listOf(CardStateVersion(clock = mapOf("a" to 1L), rank = "a1", value_ = Card(board_id = "b_1"))))
        val moving = Card(id = "c_1", project_id = "p_1", board_id = "b_2", title = "Moving", state_fields = listOf(placement))
        val store = storeWith(snapshot(boards = listOf(board, second), cards = listOf(moving)))
        store.overlayBoard(retiredBoard())
        assertTrue(store.state.value.board("b_1")!!.retirement_blocked)
        assertEquals(emptyList(), store.state.value.retiredBoards)
    }

    @Test
    fun aRenameShowsAtOnceAndYieldsToANewerEditFromAnotherPeer() {
        val store = storeWith(snapshot())
        store.overlayBoard(board.copy(name = "Renamed", updated_at = t2))
        assertEquals("Renamed", store.state.value.board("b_1")?.name)
        store.applyMachines(listOf(snapshot(boards = listOf(board, second))))
        assertEquals("Renamed", store.state.value.board("b_1")?.name)
        store.applyMachines(listOf(snapshot(boards = listOf(board.copy(name = "Other", updated_at = t3), second))))
        assertEquals("Other", store.state.value.board("b_1")?.name)
    }

    @Test
    fun anArchivedProjectLeavesWithItsBoardsAndReplica() {
        val store = storeWith(snapshot())
        store.overlayProject(project.copy(archived = true, updated_at = t2))
        assertEquals(emptyList(), store.state.value.projects)
        assertNull(store.state.value.boards["p_1"])
        assertEquals(emptyMap(), store.state.value.projectReplicas)
        // Restoring it still reaches the machine that listed it.
        assertEquals("d_1", store.directoryProjection.projectReplicas["p_1"])
    }

    @Test
    fun attachedAndDetachedCheckoutsShowOnTheirProjectAtOnce() {
        val store = storeWith(snapshot())
        val attached = Checkout(id = "co_2", project_id = "p_1", daemon_id = "d_2", name = "two", path = "/work/two")
        store.overlayCheckout(attached)
        assertEquals(listOf("co_1", "co_2"), store.state.value.project("p_1")!!.checkouts.map { it.id })
        assertEquals("d_2", store.directoryProjection.checkoutMachine("p_1", "co_2"))

        store.overlayCheckout(checkout.copy(detached = true))
        assertEquals(listOf(true, false), store.state.value.project("p_1")!!.checkouts.map { it.detached })
        // A view that predates both changes keeps them.
        store.applyMachines(listOf(snapshot(boards = listOf(board, second))))
        assertEquals(listOf(true, false), store.state.value.project("p_1")!!.checkouts.map { it.detached })

        store.applyMachines(listOf(snapshot(projects = listOf(project.copy(checkouts = listOf(checkout.copy(detached = true), attached))))))
        assertEquals(listOf("co_1", "co_2"), store.state.value.project("p_1")!!.checkouts.map { it.id })
        assertEquals(listOf(true, false), store.state.value.project("p_1")!!.checkouts.map { it.detached })
    }

    @Test
    fun aConsolidatedProjectLeavesAndItsBoardsItemsAndCheckoutsShowOnTheDestination() {
        val sourceCheckout = Checkout(id = "co_src", project_id = "p_src", daemon_id = "d_2", name = "src", path = "/work/src")
        val source = Project(id = "p_src", name = "Source", updated_at = t1, checkouts = listOf(sourceCheckout))
        val sourceBoard = Board(id = "b_src", project_id = "p_src", name = "Source board", updated_at = t1)
        val item = Card(id = "c_src", project_id = "p_src", board_id = "b_src", title = "Moved")
        val store = storeWith(snapshot(projects = listOf(project, source), boards = listOf(board, sourceBoard), cards = listOf(item)))
        // The daemon returns the destination with every checkout the source had.
        val destination = project.copy(checkouts = listOf(checkout, sourceCheckout.copy(project_id = "p_1")))
        store.overlayConsolidation("p_src", destination)

        val view = store.state.value
        assertEquals(listOf("p_1"), view.projects.map { it.id })
        assertEquals(listOf("b_1", "b_src"), view.boards["p_1"]?.map { it.id })
        assertNull(view.boards["p_src"])
        assertEquals(2, view.project("p_1")!!.board_count)
        assertEquals(listOf("c_src"), view.cards["p_1"]?.map { it.id })
        assertEquals(listOf("co_1", "co_src"), view.project("p_1")!!.checkouts.map { it.id })
        assertEquals(setOf("p_1"), view.projectReplicas.keys)
        assertEquals("d_2", store.directoryProjection.checkoutMachine("p_1", "co_src"))

        // The view that reflects the consolidation lists the same.
        store.applyMachines(
            listOf(snapshot(projects = listOf(destination), boards = listOf(board, sourceBoard.copy(project_id = "p_1")), cards = listOf(item.copy(project_id = "p_1")))),
        )
        val reflected = store.state.value
        assertEquals(listOf("p_1"), reflected.projects.map { it.id })
        assertEquals(listOf("b_1", "b_src"), reflected.boards["p_1"]?.map { it.id })
        assertEquals(2, reflected.project("p_1")!!.board_count)
        assertEquals(listOf("c_src"), reflected.cards["p_1"]?.map { it.id })
        assertEquals(listOf("co_1", "co_src"), reflected.project("p_1")!!.checkouts.map { it.id })
        assertFalse(store.directoryProjection.projects.containsKey("p_src"))
    }
}

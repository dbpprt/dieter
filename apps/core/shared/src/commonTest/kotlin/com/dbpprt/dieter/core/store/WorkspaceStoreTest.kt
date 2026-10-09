package com.dbpprt.dieter.core.store

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRetirementVersion
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.sync.DirectoryProjection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Administrative results show in the workspace at once: projects with their
 * checkouts, boards placed as live or retired, and consolidations, each
 * until the account view reflects it.
 */
class WorkspaceStoreTest {
    private val t1 = "2026-10-01T10:00:00Z"
    private val t2 = "2026-10-01T11:00:00Z"
    private val t3 = "2026-10-01T12:00:00Z"
    private val checkout = Checkout(id = "co_1", project_id = "p_1", daemon_id = "d_1", name = "one", path = "/work/one")
    private val project = Project(id = "p_1", name = "One", updated_at = t1, checkouts = listOf(checkout))
    private val board = Board(id = "b_1", project_id = "p_1", name = "Main", updated_at = t1)
    private val second = Board(id = "b_2", project_id = "p_1", name = "Second", updated_at = t1)

    private fun directory(
        projects: List<Project> = listOf(project),
        boards: List<Board> = listOf(board),
        cards: List<Card> = emptyList(),
        retired: List<Board> = emptyList(),
    ) = DirectoryProjection(
        projects = projects.associateBy { it.id },
        boards = boards.groupBy { it.project_id },
        retiredBoards = retired.associateBy { it.id },
        cards = cards.groupBy { it.project_id },
    )

    private fun storeWith(view: DirectoryProjection) = WorkspaceStore().also { it.applyDirectory(view, loaded = true) }

    private fun retirement(count: Long, retired: Boolean) = BoardRetirementVersion(clock = mapOf("a" to count), rank = "a$count", retired = retired)

    private fun retiredBoard() = board.copy(retired = true, retirement_revision = "r1", retirement_versions = listOf(retirement(1, true)))

    @Test
    fun aCreatedProjectShowsWithItsBoardAndRoutesByItsCheckoutUntilTheAccountViewListsIt() {
        val store = storeWith(directory())
        val created = Project(
            id = "p_new", name = "New", updated_at = t2,
            checkouts = listOf(Checkout(id = "co_new", project_id = "p_new", daemon_id = "d_2", name = "new", path = "/work/new")),
        )
        val main = Board(id = "b_new", project_id = "p_new", name = "Main", updated_at = t2)
        store.overlayProject(created)
        store.overlayBoard(main)
        val view = store.state.value
        assertEquals(listOf("New", "One"), view.projects.map { it.name })
        assertEquals(1, view.project("p_new")!!.board_count)
        assertEquals(listOf("b_new"), view.boards["p_new"]?.map { it.id })
        // Calls that follow reach the machine that created it.
        assertEquals("d_2", store.directoryProjection.checkoutMachine("p_new", "co_new"))

        // A view that predates the project keeps it, and counts its own boards.
        store.applyDirectory(directory(boards = listOf(board, second)), loaded = true)
        assertEquals("New", store.state.value.project("p_new")?.name)
        assertEquals(2, store.state.value.project("p_1")!!.board_count)

        // Once the account view lists it, the view's copy shows.
        store.applyDirectory(directory(projects = listOf(project, created.copy(name = "Listed")), boards = listOf(board, main)), loaded = true)
        assertEquals("Listed", store.state.value.project("p_new")?.name)
        assertEquals(1, store.state.value.project("p_new")!!.board_count)
    }

    @Test
    fun aRetiredBoardListsAsRetiredAndARestoredOneAsLiveAtOnce() {
        val store = storeWith(directory())
        val retired = retiredBoard()
        store.overlayBoard(retired)
        assertNull(store.state.value.board("b_1"))
        assertEquals(listOf("b_1"), store.state.value.retiredBoards.map { it.id })
        assertEquals(0, store.state.value.project("p_1")!!.board_count)
        assertNull(store.directoryProjection.board("b_1"))
        assertEquals("p_1", store.findBoard("b_1")?.project_id)

        // Retiring keeps the board's timestamp: a view without the intent does not undo it.
        store.applyDirectory(directory(boards = listOf(board, second)), loaded = true)
        assertEquals(listOf("b_2"), store.state.value.boards["p_1"]?.map { it.id })
        assertEquals(listOf("b_1"), store.state.value.retiredBoards.map { it.id })
        assertEquals(1, store.state.value.project("p_1")!!.board_count)

        val restored = board.copy(retirement_revision = "r2", retirement_versions = listOf(retirement(2, false)))
        store.overlayBoard(restored)
        assertEquals("Main", store.state.value.board("b_1")?.name)
        assertEquals(emptyList(), store.state.value.retiredBoards)
        assertEquals(2, store.state.value.project("p_1")!!.board_count)

        // A view that has the retirement but not the restore keeps the restore shown.
        store.applyDirectory(directory(boards = listOf(second), retired = listOf(retired)), loaded = true)
        assertEquals(listOf("b_1", "b_2"), store.state.value.boards["p_1"]?.map { it.id })
        assertEquals(emptyList(), store.state.value.retiredBoards)

        store.applyDirectory(directory(boards = listOf(restored, second)), loaded = true)
        assertEquals(listOf("b_1", "b_2"), store.state.value.boards["p_1"]?.map { it.id })
        assertEquals(emptyList(), store.state.value.retiredBoards)
        assertEquals(2, store.state.value.project("p_1")!!.board_count)
    }

    @Test
    fun aRenameShowsAtOnceAndYieldsToANewerEditFromAnotherPeer() {
        val store = storeWith(directory())
        store.overlayBoard(board.copy(name = "Renamed", updated_at = t2))
        assertEquals("Renamed", store.state.value.board("b_1")?.name)
        store.applyDirectory(directory(boards = listOf(board, second)), loaded = true)
        assertEquals("Renamed", store.state.value.board("b_1")?.name)
        store.applyDirectory(directory(boards = listOf(board.copy(name = "Other", updated_at = t3), second)), loaded = true)
        assertEquals("Other", store.state.value.board("b_1")?.name)
    }

    @Test
    fun anArchivedProjectLeavesWithItsBoards() {
        val store = storeWith(directory())
        store.overlayProject(project.copy(archived = true, updated_at = t2))
        assertEquals(emptyList(), store.state.value.projects)
        assertNull(store.state.value.boards["p_1"])
        assertFalse(store.directoryProjection.projects.containsKey("p_1"))
    }

    @Test
    fun attachedAndDetachedCheckoutsShowOnTheirProjectAtOnce() {
        val store = storeWith(directory())
        val attached = Checkout(id = "co_2", project_id = "p_1", daemon_id = "d_2", name = "two", path = "/work/two")
        store.overlayCheckout(attached)
        assertEquals(listOf("co_1", "co_2"), store.state.value.project("p_1")!!.checkouts.map { it.id })
        assertEquals("d_2", store.directoryProjection.checkoutMachine("p_1", "co_2"))

        store.overlayCheckout(checkout.copy(detached = true))
        assertEquals(listOf(true, false), store.state.value.project("p_1")!!.checkouts.map { it.detached })
        // A view that predates both changes keeps them.
        store.applyDirectory(directory(boards = listOf(board, second)), loaded = true)
        assertEquals(listOf(true, false), store.state.value.project("p_1")!!.checkouts.map { it.detached })

        store.applyDirectory(directory(projects = listOf(project.copy(checkouts = listOf(checkout.copy(detached = true), attached)))), loaded = true)
        assertEquals(listOf("co_1", "co_2"), store.state.value.project("p_1")!!.checkouts.map { it.id })
        assertEquals(listOf(true, false), store.state.value.project("p_1")!!.checkouts.map { it.detached })
    }

    @Test
    fun aConsolidatedProjectLeavesAndItsBoardsItemsAndCheckoutsShowOnTheDestination() {
        val sourceCheckout = Checkout(id = "co_src", project_id = "p_src", daemon_id = "d_2", name = "src", path = "/work/src")
        val source = Project(id = "p_src", name = "Source", updated_at = t1, checkouts = listOf(sourceCheckout))
        val sourceBoard = Board(id = "b_src", project_id = "p_src", name = "Source board", updated_at = t1)
        val item = Card(id = "c_src", project_id = "p_src", board_id = "b_src", title = "Moved")
        val store = storeWith(directory(projects = listOf(project, source), boards = listOf(board, sourceBoard), cards = listOf(item)))
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
        assertEquals("d_2", store.directoryProjection.checkoutMachine("p_1", "co_src"))

        // The account view that reflects the consolidation lists the same.
        store.applyDirectory(
            directory(projects = listOf(destination), boards = listOf(board, sourceBoard.copy(project_id = "p_1")), cards = listOf(item.copy(project_id = "p_1"))),
            loaded = true,
        )
        val reflected = store.state.value
        assertEquals(listOf("p_1"), reflected.projects.map { it.id })
        assertEquals(listOf("b_1", "b_src"), reflected.boards["p_1"]?.map { it.id })
        assertEquals(2, reflected.project("p_1")!!.board_count)
        assertEquals(listOf("c_src"), reflected.cards["p_1"]?.map { it.id })
        assertEquals(listOf("co_1", "co_src"), reflected.project("p_1")!!.checkouts.map { it.id })
        assertFalse(store.directoryProjection.projects.containsKey("p_src"))
    }

    private class Overlay(override val cardId: String, val change: (Card) -> Card, val done: (Card) -> Boolean) : CardOverlay {
        override val operationId = "op_$cardId"
        override fun apply(card: Card) = change(card)
        override fun satisfiedBy(card: Card) = done(card)
    }

    @Test
    fun aChangeInFlightShowsOnTheItemAndEndsWhenTheViewReflectsItOrTheItemLeaves() {
        val card = Card(id = "c_1", project_id = "p_1", board_id = "b_1", title = "Old")
        val store = storeWith(directory(cards = listOf(card)))
        store.addOverlay(Overlay("c_1", { it.copy(title = "New") }, { it.title == "New" }))
        assertEquals("New", store.shownItem("c_1")?.title, "a change builds on the one in flight")
        assertEquals("New", store.state.value.card("c_1")?.title)
        assertEquals("Old", store.directoryProjection.item("c_1")?.title)
        store.applyDirectory(directory(cards = listOf(card.copy(title = "New"))), loaded = true)
        assertTrue(store.overlayIds.value.isEmpty())

        // An archive is reflected by the item leaving the view, so restoring it later shows it again.
        store.addOverlay(Overlay("c_1", { it.copy(archived = true) }, { it.archived }))
        assertNull(store.state.value.card("c_1"))
        store.applyDirectory(directory(), loaded = true)
        assertTrue(store.overlayIds.value.isEmpty())
        store.applyDirectory(directory(cards = listOf(card)), loaded = true)
        assertEquals("Old", store.state.value.card("c_1")?.title)
        assertNull(store.shownItem("missing"))

        // An item the view does not list yet, e.g. one still being created, keeps its overlay until it arrives.
        store.addOverlay(Overlay("c_new", { it.copy(lane = "running") }, { it.lane == "running" }))
        assertEquals(setOf("op_c_new"), store.overlayIds.value)
        store.applyDirectory(directory(cards = listOf(card, card.copy(id = "c_new", lane = "todo"))), loaded = true)
        assertEquals("running", store.state.value.card("c_new")?.lane)
    }

    @Test
    fun clearingDropsOverlaysButKeepsTheAccountView() {
        val store = storeWith(directory(cards = listOf(Card(id = "c_1", project_id = "p_1", board_id = "b_1", title = "Kept"))))
        store.overlayBoard(board.copy(name = "Pending", updated_at = t2))
        store.clear()
        assertEquals("Main", store.state.value.board("b_1")?.name)
        assertEquals(listOf("c_1"), store.state.value.cards["p_1"]?.map { it.id })
        assertTrue(store.state.value.loaded)
    }
}

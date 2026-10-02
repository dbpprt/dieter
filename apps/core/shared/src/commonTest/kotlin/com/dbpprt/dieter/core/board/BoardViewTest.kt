package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BoardViewTest {
    private val board = Board(id = "b", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("review", "In review"), Lane("done", "Done")))

    private fun view(
        items: List<Card>,
        target: BoardTarget = BoardTarget(boardId = "b"),
        board: Board? = this.board,
        operations: Map<String, CardOperation> = emptyMap(),
        moves: Map<String, PendingMove> = emptyMap(),
        starting: Set<String> = emptySet(),
        pending: Set<String> = emptySet(),
        failed: Set<String> = emptySet(),
        ascending: Set<String> = emptySet(),
        labels: Map<String, String> = emptyMap(),
    ) = BoardViews.build(
        target, board, items, operations, moves, starting, pending, failed,
        laneDescending = { it !in ascending }, machineLabel = { labels[it] ?: it },
    )

    private fun BoardView.ids(laneId: String) = lane(laneId)!!.cards.map { it.id }

    @Test
    fun lanesShowPlacementOrderInTheirSharedDirection() {
        // Ported from the Mac's boardOrderingUsesPlacementEvenWhenCreationTimesDisagree.
        val a = Card(id = "a", board_id = "b", lane = "todo", order_key = "100", created_at = "2099-01-01T00:00:00Z")
        val b = a.copy(id = "b", order_key = "200", created_at = "2020-01-01T00:00:00Z")
        val c = a.copy(id = "c", order_key = "300")
        val cards = listOf(c, a, b)
        assertEquals(listOf("c", "b", "a"), view(cards).ids("todo"))
        assertEquals(listOf("a", "b", "c"), view(cards, ascending = setOf("todo")).ids("todo"))
        val moved = view(cards, moves = mapOf("b" to PendingMove("todo", beforeCardId = "a")), ascending = setOf("todo"))
        assertEquals(listOf("b", "a", "c"), moved.ids("todo"), "a pending move shows at once")
        assertTrue(moved.lane("todo")!!.descending.not())
        assertEquals(LaneKind.REVIEW, view(cards).lane("review")!!.kind, "kinds come from the ID or the name")
    }

    @Test
    fun cardsMatchLanesIgnoringCaseAndLanelessBoardsShowTheDefaultWorkflow() {
        val cards = listOf(Card(id = "x", board_id = "b", lane = "Review"), Card(id = "y", board_id = "b", lane = "elsewhere"))
        val shown = view(cards, board = Board(id = "b"))
        assertEquals(listOf("todo", "running", "review", "done"), shown.lanes.map { it.lane.id })
        assertEquals(listOf("x"), shown.ids("review"))
        assertEquals(setOf("x"), shown.cards.keys, "a card in no shown lane gets no flags")
        assertEquals(2, shown.total)
        assertEquals(BoardView(BoardTarget()), view(cards, target = BoardTarget()), "no board, nothing shown")
    }

    @Test
    fun filtersNarrowTheShownCardsWhileCountsCoverTheBoard() {
        // Ported from the Mac's boardProjectionBuildsLaneAndLabelIndexesOnce; the state filter is WAITING, not the raw "waiting".
        val first = Card(id = "first", board_id = "b", lane = "todo", runtime = "waiting", title = "Matching card", label_ids = listOf("label-one", "label-two"), owner_daemon_id = "d1")
        val second = Card(id = "second", board_id = "b", lane = "done", runtime = "completed", label_ids = listOf("label-one"), owner_daemon_id = "d2")
        val unrelated = Card(id = "unrelated", board_id = "other", owner_daemon_id = "d3")
        val target = BoardTarget(boardId = "b", labelId = "label-two", state = BoardStateFilter.WAITING, query = " matching ")
        val shown = view(listOf(first, second, unrelated), target, labels = mapOf("d1" to "Zeta", "d2" to "Alpha"))
        assertEquals(listOf("first"), shown.ids("todo"))
        assertEquals(emptyList(), shown.ids("done"))
        assertEquals(mapOf("label-one" to 2, "label-two" to 1), shown.labelCounts)
        assertEquals(2, shown.total)
        assertEquals(1, shown.needsYou)
        assertEquals(listOf("d2", "d1"), shown.machineIds, "machines by name")
        assertEquals("board · 2 conversations · 1 needs you", shown.summary)
        assertEquals("dieter · 2 conversations · 1 needs you", shown.summary("dieter"))
        assertEquals("board · 2 conversations · 2 need you", view(listOf(first, second.copy(runtime = "waiting_for_user"))).summary)
        assertEquals("Waiting", shown.stateTitle)

        assertEquals(listOf("second"), view(listOf(first, second), BoardTarget(boardId = "b", machineId = "d2")).cards.keys.toList())
        val quiet = view(listOf(second.copy(owner_daemon_id = "")), BoardTarget(boardId = "b"))
        assertEquals("board · 1 conversation", quiet.summary)
        assertEquals("All states", quiet.stateTitle)
        assertEquals(emptyList(), quiet.machineIds, "a card without a machine adds no filter")
    }

    @Test
    fun stateFiltersFollowTheRuntimeClassifierAndTheReviewLane() {
        val cards = listOf(
            Card(id = "run", board_id = "b", lane = "todo", runtime = "streaming"),
            Card(id = "wait", board_id = "b", lane = "todo", runtime = "waiting_for_user"),
            Card(id = "rev", board_id = "b", lane = "In review", runtime = "idle"),
            Card(id = "fail", board_id = "b", lane = "todo", runtime = "error"),
            Card(id = "idle", board_id = "b", lane = "todo", runtime = ""),
            Card(id = "go", board_id = "b", lane = "todo", runtime = "idle"),
        )
        fun matching(state: BoardStateFilter) = cards.filter { state.matches(it, if (it.id == "go") CardOperation.STARTING else null) }.map { it.id }
        assertEquals(listOf("run", "go"), matching(BoardStateFilter.RUNNING))
        assertEquals(listOf("wait"), matching(BoardStateFilter.WAITING))
        assertEquals(listOf("rev"), matching(BoardStateFilter.REVIEW))
        assertEquals(listOf("fail"), matching(BoardStateFilter.FAILED))
        assertEquals(listOf("rev", "idle"), matching(BoardStateFilter.IDLE))
        assertEquals(listOf("All states", "Running", "Waiting", "Review", "Failed", "Idle"), BoardView.STATE_OPTIONS.map { BoardStateFilter.title(it) })
    }

    @Test
    fun cardFlagsComeFromTheCoresPolicies() {
        val todo = Card(id = "s", scope = "board", board_id = "b", lane = "todo", initial_prompt = "Go", project_id = "p", owner_daemon_id = "d")
        val started = Card(id = "t", scope = "board", board_id = "b", lane = "review", runtime = "waiting_for_user", initial_prompt_sent_at = "x", project_id = "p", owner_daemon_id = "d")
        val idle = view(listOf(todo, started)).cards
        with(idle.getValue("s")) {
            assertTrue(canStart && canEditDraft && !starting && !canCancel)
            assertNull(badge)
            assertEquals("Idle", runtimeLabel)
            assertEquals(AgentStatus.IDLE, agent)
            assertEquals("b|p|d", mergeSourceKey)
            assertEquals("", mergeTargetKey)
        }
        with(idle.getValue("t")) {
            assertTrue(canCancel && !canStart && !canEditDraft)
            assertEquals(RuntimeTone.ATTENTION, tone)
            assertEquals("Waiting for you", runtimeLabel)
            assertEquals("b|p|d", mergeTargetKey, "a started card accepts merges")
        }

        // A start waiting in the outbox shows as starting; this client's own operation wins.
        with(view(listOf(todo), starting = setOf("s")).cards.getValue("s")) {
            assertTrue(starting && !canStart && !canEditDraft)
            assertEquals(CardOperation.STARTING, operation)
            assertEquals("Starting…", badge)
            assertEquals(RuntimeTone.ACTIVE, tone)
            assertEquals(AgentStatus.RUNNING, agent)
            assertEquals("", mergeSourceKey, "a starting card is busy")
        }
        assertEquals(CardOperation.MOVING, view(listOf(todo), starting = setOf("s"), operations = mapOf("s" to CardOperation.MOVING)).cards.getValue("s").operation)
        assertFalse(view(listOf(started), operations = mapOf("t" to CardOperation.CANCELLING)).cards.getValue("t").canCancel)

        // A card only in the outbox cannot start yet; a rejected one says so.
        with(view(listOf(todo), pending = setOf("s"), failed = setOf("s")).cards.getValue("s")) {
            assertTrue(pending && failed && !canStart && !canMove)
        }
        assertTrue(idle.getValue("s").canMove)
        assertFalse(view(listOf(todo), operations = mapOf("s" to CardOperation.ARCHIVING)).cards.getValue("s").canMove, "a change in flight holds the card")
        assertFalse(view(listOf(todo), board = Board(id = "b", lanes = listOf(Lane("todo", "Todo")))).cards.getValue("s").canStart, "no running lane")
    }

    @Test
    fun dropsMeasureAgainstTheLaneAsShown() {
        // Ported from the Mac's BoardDropOrdering.neighbors checks.
        val a = Card(id = "a", board_id = "b", lane = "todo", order_key = "100")
        val b = a.copy(id = "b", order_key = "200")
        val c = a.copy(id = "c", order_key = "300")
        val cards = listOf(c, a, b)
        val ascending = view(cards, ascending = setOf("todo"))
        val descending = view(cards)
        assertEquals(DropAnchors(afterCardId = "a", beforeCardId = "b"), ascending.drop("c", ascending.lane("todo")!!, "b"))
        assertEquals(DropAnchors(afterCardId = "b", beforeCardId = "c"), descending.drop("a", descending.lane("todo")!!, "b"))
        assertEquals(DropAnchors(afterCardId = "", beforeCardId = "a"), descending.drop("c", descending.lane("todo")!!, ""))
        val moving = view(cards, moves = mapOf("b" to PendingMove("todo", beforeCardId = "a")), ascending = setOf("todo"))
        assertEquals(DropAnchors(afterCardId = "b", beforeCardId = "a"), moving.drop("c", moving.lane("todo")!!, "a"), "a pending move is where the card shows")

        // Dropping a card where it already is changes nothing.
        assertNull(ascending.drop("c", ascending.lane("todo")!!, "c"))
        assertNull(ascending.drop("c", ascending.lane("todo")!!, ""), "the last card dropped at the end")
        assertNull(ascending.drop("a", ascending.lane("todo")!!, "b"), "dropped above the card that follows it")
        assertEquals(DropAnchors(afterCardId = "", beforeCardId = ""), ascending.drop("c", ascending.lane("review")!!, ""), "into an empty lane")
        assertEquals(DropAnchors(afterCardId = "", beforeCardId = "a"), ascending.drop("c", ascending.lane("todo")!!, "a"), "above the first card")
        assertEquals("todo", ascending.lane("TODO")?.lane?.id)
    }
}

package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.client.v1.ActivityRow
import com.dbpprt.dieter.client.v1.ActivitySummary
import com.dbpprt.dieter.client.v1.BoardAgentStatus
import com.dbpprt.dieter.client.v1.BoardLaneKind
import com.dbpprt.dieter.client.v1.BoardStateFilter as ClientBoardStateFilter
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.RuntimeTone
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.board.BoardStateFilter
import com.dbpprt.dieter.core.board.BoardTarget
import com.dbpprt.dieter.core.board.BoardViews
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.testing.SliceFolds
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/** The board view, workspace attention, and activity slices carry the core's board and inbox rules. */
class BoardViewSliceTest {
    private val now = Instant.parse("2026-09-30T12:00:00Z")
    private val board = Board(id = "b", lanes = listOf(Lane("todo", "Todo"), Lane("in-flight", "Running"), Lane("review", "Review")))

    @Test
    fun theBoardViewSliceCarriesLanesFlagsAndChrome() {
        val todo = Card(id = "t", scope = "board", board_id = "b", lane = "todo", initial_prompt = "Go", order_key = "1", project_id = "p", owner_daemon_id = "d")
        val older = todo.copy(id = "o", order_key = "0", initial_prompt_sent_at = "x", runtime = "waiting_for_user")
        val view = BoardViews.build(BoardTarget(boardId = "b", state = BoardStateFilter.WAITING), board, listOf(todo, older), operations = mapOf("o" to CardOperation.MOVING))
        val slice = boardViewSlice(view)
        assertEquals(BoardViewTarget(board_id = "b", state = ClientBoardStateFilter.BOARD_STATE_FILTER_WAITING), slice.target)
        assertEquals(listOf("todo", "in-flight", "review"), slice.lanes.map { it.lane_id })
        assertEquals(BoardLaneKind.BOARD_LANE_KIND_RUNNING, slice.lanes[1].kind)
        assertEquals(listOf("o"), slice.lanes[0].card_ids, "the state filter leaves the waiting card")
        assertTrue(slice.lanes[0].descending)
        assertEquals(setOf("o"), slice.cards.keys)
        val flags = slice.cards.getValue("o")
        assertEquals(RuntimeTone.RUNTIME_TONE_ATTENTION, flags.tone)
        assertEquals("Waiting for you", flags.runtime_label)
        assertEquals("MOVING", flags.operation)
        assertTrue(flags.can_cancel)
        assertEquals(BoardAgentStatus.BOARD_AGENT_STATUS_IDLE, flags.agent)
        assertEquals("Waiting", slice.state_title)
        assertEquals(listOf("All states", "Running", "Waiting", "Review", "Failed", "Idle"), slice.state_options.map { it.title })
        assertEquals(ClientBoardStateFilter.BOARD_STATE_FILTER_ALL, slice.state_options.first().state)
        assertEquals("board · 2 conversations · 1 needs you", slice.summary)
        assertEquals(2, slice.total)
        assertEquals(BoardTarget(boardId = "b", state = BoardStateFilter.WAITING), boardTarget(slice.target!!))
    }

    @Test
    fun workspaceAttentionTravelsWithTheDelta() {
        val previous = WorkspaceSlice(cards = listOf(Card(id = "a", board_id = "b", lane = "todo")))
        val next = WorkspaceSlice(cards = listOf(Card(id = "a", board_id = "b", lane = "review")), board_attention = mapOf("b" to 1))
        val delta = Deltas.workspace(previous, next)!!
        assertEquals(mapOf("b" to 1), delta.board_attention)
        assertEquals(next, SliceFolds.apply(previous, delta))
    }

    @Test
    fun theActivitySliceCarriesRowFieldsTheIslandAndTheMenuBar() {
        fun card(id: String, runtime: String, minutesAgo: Int, lane: String = "todo", scope: String = "board", title: String = id) = Card(
            id = id, runtime = runtime, lane = lane, scope = scope, board_id = if (scope == "chat") "" else "b", project_id = "p", title = title,
            initial_prompt_sent_at = (now - (minutesAgo + 1).minutes).toString(), runtime_updated_at = (now - minutesAgo.minutes).toString(),
            last_activity_at = (now - minutesAgo.minutes).toString(), active_subagents = if (runtime == "running") listOf(Subagent(status = "running")) else emptyList(),
        )
        val items = Activity.project(
            listOf(
                card("run", "running", 30), card("ask", "waiting_for_user", 20), card("rev", "idle", 10, lane = "In review"),
                card("chat", "idle", 5, scope = "chat", title = ""), card("old", "idle", 400),
            ),
            emptyMap(), emptyList(), emptyList(),
        )
        val slice = activitySlice(items, now)
        val rows = slice.rows.associateBy { it.card!!.id }
        with(rows.getValue("run")) {
            assertEquals("RUNNING", kind)
            assertEquals(ActivityRow.Section.SECTION_RUNNING, section)
            assertEquals(started_at_millis, shown_at_millis, "a running row shows its start")
            assertEquals("Running", kind_label)
        }
        with(rows.getValue("ask")) {
            assertTrue(needs_you)
            assertEquals("Needs you", menu_bar_title)
            assertEquals(at_millis, shown_at_millis)
        }
        assertTrue(rows.getValue("rev").can_finish, "a review lane counts by name")
        assertEquals("Ready for review", rows.getValue("rev").menu_bar_title)
        assertEquals("Untitled chat", rows.getValue("chat").title)
        assertTrue(rows.getValue("chat").chat)
        assertEquals(ActivitySummary(running = 1, attention = 1, recent = 3, review = 1, subagents = 1), slice.summary)
        assertEquals(listOf("run", "ask", "chat", "rev"), slice.island_ids)
        assertEquals("Dieter Island. 1 running, 1 need attention, 3 recent.", slice.island_accessibility)
        assertEquals(listOf("rev", "ask", "chat"), slice.menu_bar_ids, "in feed order; results older than six hours leave the menu")
    }
}
